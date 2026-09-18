import Foundation

// MARK: - Models
//
// The shapes below are exactly `shared/seed/lofi-feed.json`, which is also what
// the live providers normalise into. One vocabulary, three sources.

enum TrackKind: String, Codable, CaseIterable {
  case track
  case mix
  case live

  var label: String {
    switch self {
    case .track: return "TRACK"
    case .mix: return "MIX"
    case .live: return "LIVE"
    }
  }
}

enum DataProvenance: String, Codable {
  case seed
  case piped
  case invidious
  case youtubeAPI = "youtube_api"

  var label: String {
    switch self {
    case .seed: return "seed cache"
    case .piped: return "piped"
    case .invidious: return "invidious"
    case .youtubeAPI: return "youtube data api"
    }
  }
}

/// One disc. Everything the UI shows about a song hangs off this.
struct LofiTrack: Codable, Identifiable, Hashable {
  var videoId: String
  var kind: String = "track"
  var title: String
  var channelName: String = ""
  var channelHandle: String?
  var channelId: String?
  var durationSeconds: Int = 0
  var viewCount: Int?
  var watching: String?
  var publishedLabel: String?
  var mood: String?
  var descriptionExcerpt: String?
  var description: String?
  var tags: [String] = []
  var tracklist: [TrackCredit]?
  var license: String?
  var creditOverride: String?
  var comments: [YTComment]?
  var gate: GateVerdict?

  /// Which provider produced this — surfaced in the UI, never hidden.
  var source: DataProvenance = .seed


  enum CodingKeys: String, CodingKey {
    case videoId, kind, title, channelName, channelHandle, channelId
    case durationSeconds, viewCount, watching, publishedLabel, mood
    case descriptionExcerpt, description, tags, tracklist, license
    case creditOverride, comments, gate, source
  }

  /// Everything except `videoId` is optional on the wire, so decoding is
  /// hand-written: seed JSON, Piped and the Data API each omit different keys,
  /// and a missing key must never take the whole deck down.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    videoId = try c.decodeIfPresent(String.self, forKey: .videoId) ?? ""
    kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "track"
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? "untitled"
    channelName = try c.decodeIfPresent(String.self, forKey: .channelName) ?? ""
    channelHandle = try c.decodeIfPresent(String.self, forKey: .channelHandle)
    channelId = try c.decodeIfPresent(String.self, forKey: .channelId)
    durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
    viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
    watching = try c.decodeIfPresent(String.self, forKey: .watching)
    publishedLabel = try c.decodeIfPresent(String.self, forKey: .publishedLabel)
    mood = try c.decodeIfPresent(String.self, forKey: .mood)
    descriptionExcerpt = try c.decodeIfPresent(String.self, forKey: .descriptionExcerpt)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    tracklist = try c.decodeIfPresent([TrackCredit].self, forKey: .tracklist)
    license = try c.decodeIfPresent(String.self, forKey: .license)
    creditOverride = try c.decodeIfPresent(String.self, forKey: .creditOverride)
    comments = try c.decodeIfPresent([YTComment].self, forKey: .comments)
    gate = try c.decodeIfPresent(GateVerdict.self, forKey: .gate)
    source = try c.decodeIfPresent(DataProvenance.self, forKey: .source) ?? .seed
  }

  init(
    videoId: String,
    title: String,
    kind: String = "track",
    channelName: String = "",
    channelHandle: String? = nil,
    channelId: String? = nil,
    durationSeconds: Int = 0,
    viewCount: Int? = nil,
    watching: String? = nil,
    publishedLabel: String? = nil,
    mood: String? = nil,
    descriptionExcerpt: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    tracklist: [TrackCredit]? = nil,
    license: String? = nil,
    creditOverride: String? = nil,
    comments: [YTComment]? = nil,
    gate: GateVerdict? = nil,
    source: DataProvenance = .seed
  ) {
    self.videoId = videoId
    self.title = title
    self.kind = kind
    self.channelName = channelName
    self.channelHandle = channelHandle
    self.channelId = channelId
    self.durationSeconds = durationSeconds
    self.viewCount = viewCount
    self.watching = watching
    self.publishedLabel = publishedLabel
    self.mood = mood
    self.descriptionExcerpt = descriptionExcerpt
    self.description = description
    self.tags = tags
    self.tracklist = tracklist
    self.license = license
    self.creditOverride = creditOverride
    self.comments = comments
    self.gate = gate
    self.source = source
  }

  var id: String { videoId }

  var resolvedKind: TrackKind { TrackKind(rawValue: kind) ?? .track }
  var isLive: Bool { resolvedKind == .live }

  /// Whatever text we have, longest first: enrichment writes `description`.
  var bestDescription: String {
    let full = description ?? ""
    let excerpt = descriptionExcerpt ?? ""
    return full.count >= excerpt.count ? full : excerpt
  }

  var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(videoId)") }
  var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg") }
  var channelURL: URL? {
    guard let handle = channelHandle, !handle.isEmpty else { return nil }
    return URL(string: "https://www.youtube.com/\(handle.hasPrefix("@") ? handle : "@\(handle)")")
  }

  /// The card's headline credit: whoever's track the playhead is inside, or the
  /// channel when there is no parsed tracklist.
  func credit(at seconds: TimeInterval) -> TrackCredit? {
    tracklist?.credit(at: seconds)
  }

  func headline(at seconds: TimeInterval) -> String {
    if let override = creditOverride, !override.isEmpty, tracklist?.isEmpty != false { return override }
    if let c = credit(at: seconds) {
      return c.title.isEmpty ? c.artist : "\(c.artist) — \(c.title)"
    }
    return channelName
  }

  var durationText: String {
    guard durationSeconds > 0 else { return "LIVE" }
    let h = durationSeconds / 3600, m = (durationSeconds % 3600) / 60, s = durationSeconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  var viewText: String {
    if let watching, !watching.isEmpty { return watching }
    guard let viewCount, viewCount > 0 else { return "" }
    return "👁 \(viewCount.abbreviated)"
  }
}

/// A line from a description tracklist: "6:20 Yasumu - We Met".
struct TrackCredit: Codable, Identifiable, Hashable {
  var startSeconds: Int
  var artist: String
  var title: String = ""
  var feat: String?

  init(startSeconds: Int, artist: String, title: String = "", feat: String? = nil) {
    self.startSeconds = startSeconds
    self.artist = artist
    self.title = title
    self.feat = feat
  }

  private enum CodingKeys: String, CodingKey { case startSeconds, artist, title, feat }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    startSeconds = try c.decodeIfPresent(Int.self, forKey: .startSeconds) ?? 0
    artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    feat = try c.decodeIfPresent(String.self, forKey: .feat)
  }

  var id: String { "\(startSeconds)-\(artist)-\(title)" }

  var timecode: String {
    let h = startSeconds / 3600, m = (startSeconds % 3600) / 60, s = startSeconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  var display: String { title.isEmpty ? artist : "\(artist) — \(title)" }
}

extension [TrackCredit] {
  /// Binary-ish lookup: the last credit whose start is at or before `seconds`.
  func credit(at seconds: TimeInterval) -> TrackCredit? {
    guard !isEmpty else { return nil }
    let s = Int(seconds)
    var current: TrackCredit?
    for entry in self {
      if entry.startSeconds <= s { current = entry } else { break }
    }
    return current ?? first
  }

  func next(after seconds: TimeInterval) -> TrackCredit? {
    let s = Int(seconds)
    return first { $0.startSeconds > s }
  }
}

/// A YouTube comment. `provenance` says where it came from — the UI badges it,
/// because showing cached text as if it were live would be a lie.
struct YTComment: Codable, Identifiable, Hashable {
  var author: String = "anon"
  var text: String = ""
  var likes: Int = 0
  var time: String?
  var pinned: Bool?
  var creatorReplied: Bool?
  var provenance: String = "sample"

  init(
    author: String = "anon",
    text: String = "",
    likes: Int = 0,
    time: String? = nil,
    pinned: Bool? = nil,
    creatorReplied: Bool? = nil,
    provenance: String = "sample"
  ) {
    self.author = author
    self.text = text
    self.likes = likes
    self.time = time
    self.pinned = pinned
    self.creatorReplied = creatorReplied
    self.provenance = provenance
  }

  private enum CodingKeys: String, CodingKey {
    case author, text, likes, time, pinned, creatorReplied, provenance, title_note
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    author = try c.decodeIfPresent(String.self, forKey: .author) ?? "anon"
    text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
    time = try c.decodeIfPresent(String.self, forKey: .time)
    pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned)
    creatorReplied = try c.decodeIfPresent(Bool.self, forKey: .creatorReplied)
    provenance = try c.decodeIfPresent(String.self, forKey: .provenance) ?? "sample"
  }

  var id: String { "\(author)-\(text.prefix(24).hashValue)" }
  var isLive: Bool { provenance == "youtube" }
  var likeText: String { likes > 0 ? "▲ \(likes.abbreviated)" : "▲ 0" }
}

/// Output of LofiFilter. Kept on the track so the UI can explain itself.
struct GateVerdict: Codable, Hashable {
  var lofi: Bool
  var score: Double
  var threshold: Double
  var hits: [String] = []
  var penalties: [String] = []
  var moods: [String] = []

  var explain: String {
    let h = hits.isEmpty ? "—" : hits.joined(separator: ", ")
    let p = penalties.isEmpty ? "" : " · penalised: \(penalties.joined(separator: ", "))"
    return "score \(String(format: "%.2f", score)) ≥ \(String(format: "%.0f", threshold)) · matched: \(h)\(p)"
  }
}

/// One search worth running, as authored in the seed file. The JSON keeps the
/// label and the mood next to the query so the radio can pick a *mood*, not just
/// words — and so the prototype and the app read the same object.
struct QuerySeed: Codable, Hashable {
  var label: String?
  var query: String?
  var mood: String?
  var kind: String?
  var channel: String?

  var text: String { query ?? label ?? "lofi hip hop" }
}

/// The offline corpus. One copy on disk (`shared/seed/lofi-feed.json`) is served
/// by Vite to the prototype and bundled by XcodeGen into the app.
struct SeedFile: Codable {
  var version: Int = 0
  var generatedAt: String?
  var notes: [String]?
  var querySeeds: [QuerySeed]?
  var tracks: [LofiTrack] = []
  var excludedExamples: [ExcludedExample] = []
}

struct ExcludedExample: Codable, Identifiable, Hashable {
  var videoId: String
  var title: String
  var channelName: String = ""
  var rejectReason: String?

  var id: String { videoId }
}

// MARK: - Search / feed plumbing

struct LofiSearchResults {
  var query: String
  var accepted: [LofiTrack]
  var rejected: [LofiTrack]
  var origin: String

  static let empty = LofiSearchResults(query: "", accepted: [], rejected: [], origin: "none")
}

struct BoostSettings: Codable, Equatable {
  /// VLC's slider: 0 dB is unity, +12 dB is the ceiling, negative is a trim.
  var db: Double = 0
  var lowShelfDb: Double = 0
  var midPeakDb: Double = 0
  var highShelfDb: Double = 0
  var limiterEnabled: Bool = true
  var softClipEnabled: Bool = true
  /// 0…1 system output, separate from the digital boost so the two never fight.
  var output: Double = 0.85
  var preset: String = "flat"

  static let minDb = -12.0
  static let maxDb = 12.0

  var linear: Double { pow(10, db / 20) }
  var isBoosting: Bool { db > 0.01 }

  /// Maps the dB request onto a 0…100 player volume, for the paths where a
  /// real gain stage is not reachable (embedded YouTube player).
  var systemVolumePercent: Int {
    let t = min(1, max(0, (db - Self.minDb) / (Self.maxDb - Self.minDb)))
    return Int((22 + t * 78).rounded())
  }
}

enum Preset: String, CaseIterable, Identifiable {
  case flat = "flat"
  case tapeWarm = "tape warm"
  case rainShelf = "rain shelf"
  case bassHead = "bass head"
  case voicePod = "voice / pod"
  case club = "club (+12)"
  case night = "3am no-limiter"

  var id: String { rawValue }

  func applied(to settings: inout BoostSettings) {
    switch self {
    case .flat: (settings.lowShelfDb, settings.midPeakDb, settings.highShelfDb, settings.limiterEnabled) = (0, 0, 0, true)
    case .tapeWarm: (settings.lowShelfDb, settings.midPeakDb, settings.highShelfDb, settings.limiterEnabled) = (2.5, 1.0, -2.5, true)
    case .rainShelf: (settings.lowShelfDb, settings.midPeakDb, settings.highShelfDb, settings.limiterEnabled) = (-1.5, 0, 3.5, true)
    case .bassHead: (settings.lowShelfDb, settings.midPeakDb, settings.highShelfDb, settings.limiterEnabled) = (6, -1, 1, true)
    case .voicePod: (settings.lowShelfDb, settings.midPeakDb, settings.highShelfDb, settings.limiterEnabled) = (-3, 4, 2, true)
    case .club: (settings.lowShelfDb, settings.midPeakDb, settings.highShelfDb, settings.limiterEnabled) = (3, 0, 3, true)
    case .night: (settings.lowShelfDb, settings.midPeakDb, settings.highShelfDb, settings.limiterEnabled) = (1.5, -2, -1, false)
    }
    settings.preset = rawValue
  }
}

fileprivate extension Int {
  var abbreviated: String {
    switch self {
    case 1_000_000_000...: return String(format: "%.1fB", Double(self) / 1e9).replacingOccurrences(of: ".0B", with: "B")
    case 1_000_000...: return String(format: "%.1fM", Double(self) / 1e6).replacingOccurrences(of: ".0M", with: "M")
    case 1_000...: return String(format: "%.0fK", Double(self) / 1e3)
    default: return String(self)
    }
  }
}
