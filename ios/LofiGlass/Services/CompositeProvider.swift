import Foundation

// MARK: - Composite provider
//
// Primary source → secondary mirror → seed corpus, with the lofi gate applied
// once, here, so no provider can smuggle a deep-house festival mix into the
// deck. Every rejection is remembered so the UI can show its work.

final class CompositeProvider {
  private let gateEnabled: () -> Bool
  private let thresholdOverride: () -> Double

  var onEvent: ((String, String) -> Void)?

  init(
    primary: LofiProviding?,
    mirror: LofiProviding?,
    seed: SeedProvider,
    gateEnabled: @escaping () -> Bool = { true },
    thresholdOverride: @escaping () -> Double = { LofiFilter.threshold }
  ) {
    self.primary = primary
    self.mirror = mirror
    self.seed = seed
    self.gateEnabled = gateEnabled
    self.thresholdOverride = thresholdOverride
    self.stats = GateStats()
  }

  let primary: LofiProviding?
  let mirror: LofiProviding?
  let seed: SeedProvider

  struct GateStats {
    var accepted = 0
    var rejected = 0
    var lastRejected: [LofiTrack] = []
    var origin = "seed corpus"
  }

  private(set) var stats = GateStats()

  /// Second pass, so a provider can never claim something is lofi on its own.
  /// `thresholdOverride` lets Settings dial strictness up (only obvious lofi)
  /// without touching the weights.
  private func applyGate(_ results: LofiSearchResults) -> LofiSearchResults {
    guard gateEnabled() else {
      stats.origin = results.origin
      return results
    }
    let threshold = max(LofiFilter.threshold, thresholdOverride())
    var kept: [LofiTrack] = []
    var dropped: [LofiTrack] = []
    for track in results.accepted {
      let stamped = track.gate == nil ? LofiFilter.stamped(track) : track
      if (stamped.gate?.score ?? 0) >= threshold { kept.append(stamped) } else { dropped.append(stamped) }
    }
    stats.accepted += kept.count
    stats.rejected += dropped.count
    stats.lastRejected = Array((dropped + stats.lastRejected).prefix(12))
    stats.origin = results.origin
    return LofiSearchResults(
      query: results.query,
      accepted: kept,
      rejected: dropped + results.rejected,
      origin: results.origin
    )
  }

  /// The app's promise is "only lofi", so a query that never mentions the genre
  /// gets it prepended before it leaves the device. The gate still decides what
  /// comes back — this only stops "rain sounds" from returning ASMR videos.
  static func lofiQuery(_ query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.isEmpty { return "lofi hip hop" }
    let alreadyGenre = ["lofi", "l o f i", "lo fi", "chillhop", "jazzhop", "beatmaker", "lofi"]
      .contains { lower.contains($0) }
    return alreadyGenre ? trimmed : "lofi \(trimmed)"
  }

  /// The hunt. Tries each configured source in order and stops at the first one
  /// that returns lofi. Never throws: a dead network still gives you the deck.
  func hunt(query rawQuery: String, mood: String?, limit: Int) async -> LofiSearchResults {
    let query = Self.lofiQuery(rawQuery)
    var attempted: [String] = []

    for provider in [primary, mirror].compactMap({ $0 }) {
      do {
        let results = applyGate(try await provider.search(query, mood: mood, limit: limit))
        if !results.accepted.isEmpty {
          onEvent?("search", "\(provider.name) · \(results.accepted.count) accepted")
          return results
        }
        attempted.append("\(provider.name): 0 accepted")
      } catch {
        attempted.append("\(provider.name): \(error.localizedDescription)")
      }
    }

    do {
      let results = applyGate(try await seed.search(query, mood: mood, limit: limit))
      onEvent?("search-fallback", attempted.isEmpty ? "seed corpus" : attempted.joined(separator: " · "))
      return results
    } catch {
      onEvent?("search-failed", error.localizedDescription)
      return LofiSearchResults(query: query, accepted: [], rejected: stats.lastRejected, origin: "nothing reachable")
    }
  }

  func details(for track: LofiTrack) async -> LofiTrack {
    for provider in [primary, mirror].compactMap({ $0 }) {
      if let enriched = try? await provider.details(for: track) {
        onEvent?("details", provider.name)
        return enriched
      }
    }
    return (try? await seed.details(for: track)) ?? track
  }

  func comments(for track: LofiTrack, max: Int = 8) async -> (items: [YTComment], origin: String) {
    for provider in [primary, mirror].compactMap({ $0 }) {
      do {
        let items = try await provider.topComments(for: track, max: max)
        if !items.isEmpty {
          onEvent?("comments", "\(provider.name) · \(items.count)")
          return (items, provider.name)
        }
      } catch {
        continue
      }
    }
    let items = (try? await seed.topComments(for: track, max: max)) ?? []
    return (items, "seed cache")
  }

  func streamURL(for track: LofiTrack) async -> URL? {
    for provider in [primary, mirror].compactMap({ $0 }) {
      if let url = try? await provider.audioStreamURL(for: track) { return url }
    }
    return nil
  }
}
