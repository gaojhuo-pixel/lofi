import Foundation

// MARK: - Seed provider (offline)
//
// `shared/seed/lofi-feed.json` is referenced straight from the Xcode project
// (see ios/project.yml), so there is exactly one copy of the corpus shared with
// the prototype. It holds real video IDs, titles, channels, description
// excerpts and tracklists read off public YouTube pages on 2026-09-18. The
// comments in it carry provenance == "sample", and the UI badges them.

final class SeedProvider {
  static let shared = SeedProvider()

  private(set) var file = SeedFile()
  private(set) var tracks: [LofiTrack] = []
  /// Real non-lofi results kept around so the UI can show what the gate rejects.
  private(set) var rejected: [LofiTrack] = []
  private(set) var loadedAt: Date?

  init(loadImmediately: Bool = true) {
    if loadImmediately { _ = load() }
  }

  @discardableResult
  func load() -> Bool {
    guard let url = Self.seedURL else { return false }
    do {
      let data = try Data(contentsOf: url)
      return ingest(data)
    } catch {
      NSLog("lofi.glass: seed load failed — %@", "\(error)")
      return false
    }
  }

  /// Split out so unit tests can feed the same JSON without touching the bundle.
  @discardableResult
  func ingest(_ data: Data) -> Bool {
    do {
      let decoded = try JSONDecoder().decode(SeedFile.self, from: data)
      let stamped = decoded.tracks.map { LofiFilter.stamped($0) }
      file = decoded
      // Only lofi survives into the deck; the rest becomes gate evidence.
      tracks = stamped.filter { $0.gate?.lofi == true }
      rejected = stamped.filter { $0.gate?.lofi != true } + decoded.excludedExamples.map { example in
        var t = LofiTrack(videoId: example.videoId, title: example.title, channelName: example.channelName, source: .seed)
        t.gate = LofiFilter.evaluate(title: example.title, description: "", channelName: example.channelName)
        return t
      }
      loadedAt = Date()
      return true
    } catch {
      NSLog("lofi.glass: seed decode failed — %@", "\(error)")
      return false
    }
  }

  static var seedURL: URL? {
    if let url = Bundle.main.url(forResource: "lofi-feed", withExtension: "json") { return url }
    for bundle in Bundle.allBundles + Bundle.allFrameworks {
      if let url = bundle.url(forResource: "lofi-feed", withExtension: "json") { return url }
    }
    return nil
  }

  /// Rotation for the deck: never repeats what you have already swiped.
  func rotation(seen: Set<String>, seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> [LofiTrack] {
    var generator = SeededGenerator(seed: seed)
    let fresh = tracks.filter { !seen.contains($0.videoId) }
    let pool = fresh.isEmpty ? tracks : fresh
    return pool.shuffled(using: &generator)
  }

  var querySeeds: [String] { radioSeeds.map(\.text) }

  /// The seeded searches, with their moods intact.
  var radioSeeds: [QuerySeed] {
    guard let seeds = file.querySeeds, !seeds.isEmpty else {
      return [
        QuerySeed(label: "lofi hip hop radio", query: "lofi hip hop radio", mood: "study"),
        QuerySeed(label: "lofi mix", query: "lofi hip hop mix beats to relax study", mood: nil),
        QuerySeed(label: "lofi sleep", query: "lofi sleep 8 hours", mood: "sleep"),
        QuerySeed(label: "jazzhop", query: "jazzhop", mood: "jazzy"),
      ]
    }
    return seeds
  }

  /// Radio mode picks a mood to drift toward instead of replaying the same feed.
  func randomRadioSeed() -> QuerySeed? {
    var generator = SystemRandomNumberGenerator()
    return radioSeeds.shuffled(using: &generator).first
  }

  var isReady: Bool { !tracks.isEmpty }
}

/// Reproducible shuffle, so tests and screenshots don't drift.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

extension SeedProvider: LofiProviding {
  var name: String { "seed corpus" }

  func search(_ query: String, mood: String?, limit: Int) async throws -> LofiSearchResults {
    let words = query
      .lowercased()
      .split(whereSeparator: { " ,.-_#:;".contains($0) })
      .filter { $0 != "lofi" && $0.count > 1 }
      .map(String.init)

    let scored: [(track: LofiTrack, score: Double)] = tracks.map { track in
      let hay = """
        \(track.title) \(track.channelName) \(track.tags.joined(separator: " ")) \
        \(track.mood ?? "") \(track.bestDescription)
        """
        .lowercased()
      var score = 0.0
      for word in words where hay.contains(word) { score += 2 }
      if let mood, !mood.isEmpty, track.mood == mood { score += 3 }
      if let gate = track.gate { score += max(0, gate.score - gate.threshold) * 0.2 }
      return (track, score)
    }

    let accepted = scored
      .filter { words.isEmpty || $0.score > 0 }
      .sorted { $0.score > $1.score }
      .prefix(max(1, limit))
      .map(\.track)

    return LofiSearchResults(query: query, accepted: Array(accepted), rejected: rejected, origin: "seed corpus")
  }

  func details(for track: LofiTrack) async throws -> LofiTrack {
    var updated = track
    if let cached = tracks.first(where: { $0.videoId == track.videoId }) {
      updated.description = cached.description ?? cached.descriptionExcerpt ?? updated.description
      if updated.tracklist?.isEmpty != false {
        let parsed = TracklistParser.parse(cached.bestDescription)
        if !parsed.isEmpty { updated.tracklist = parsed }
      }
      let gate = cached.gate ?? LofiFilter.evaluate(title: cached.title, description: cached.bestDescription)
      updated.tags = TracklistParser.tags(explicit: cached.tags, description: cached.bestDescription, gate: gate)
      updated.durationSeconds = cached.durationSeconds != 0 ? cached.durationSeconds : updated.durationSeconds
      updated.source = .seed
    }
    return updated
  }

  func topComments(for track: LofiTrack, max: Int) async throws -> [YTComment] {
    let cached = track.comments ?? tracks.first { $0.videoId == track.videoId }?.comments
    return Array((cached ?? []).prefix(max))
  }
}
