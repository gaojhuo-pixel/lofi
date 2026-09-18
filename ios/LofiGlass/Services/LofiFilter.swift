import Foundation

// MARK: - The lofi gate
//
// "finds only youtube lofi stuff" is a filter problem, not a search problem:
// YouTube returns jazz-café ambience and deep-house festival mixes for the same
// queries. So every candidate — from the seed corpus or a live search — is
// scored on title + description + hashtags + channel + length, and anything
// under the threshold is dropped (and remembered, so the UI can show what it
// threw away).
//
// Weights and threshold are the same ones in prototype/src/lofi-filter.js, and
// `node tools/gate-check.mjs` is the executable reference for both.

enum LofiFilter {
  static let threshold: Double = 4

  private struct Signal {
    let pattern: String
    let weight: Double
    let tag: String
  }

  private static let positive: [Signal] = [
    .init(pattern: "lo[.\\-\\s]?fi", weight: 5, tag: "lofi"),
    .init(pattern: "l o f i", weight: 4, tag: "lofi"),
    .init(pattern: "\u{FF4C}\u{FF4F}\u{FF46}\u{FF49}", weight: 4, tag: "lofi"),
    .init(pattern: "chill ?hop", weight: 4, tag: "chillhop"),
    .init(pattern: "jazz ?hop", weight: 4, tag: "jazzy"),
    .init(pattern: "(music|beats|sounds|tunes|radio)\\s*(to|for)\\s+(relax|study|sleep|focus|chill|work|drive|code)", weight: 3.5, tag: "beats to \u{2026}"),
    .init(pattern: "beats? ?to ?(relax|study|sleep|chill|focus|drive)", weight: 4, tag: "beats to \u{2026}"),
    .init(pattern: "study beats", weight: 3, tag: "study"),
    .init(pattern: "instrumental hip ?hop", weight: 3, tag: "instrumental"),
    .init(pattern: "hip ?hop radio", weight: 3, tag: "radio"),
    .init(pattern: "boom ?bap", weight: 3, tag: "boom bap"),
    .init(pattern: "tape hiss|tape loop|4th ?gen tape", weight: 2.5, tag: "tape"),
    .init(pattern: "\\bvhs\\b|crt|scan ?line", weight: 2, tag: "vhs"),
    .init(pattern: "chill beats", weight: 2, tag: "chill"),
    .init(pattern: "sleep lofi", weight: 3, tag: "sleep"),
    .init(pattern: "anime (edit|loop|amv)", weight: 2, tag: "anime edit"),
    .init(pattern: "type beat", weight: 2, tag: "type beat"),
    .init(pattern: "neo soul", weight: 1.5, tag: "neo soul"),
    .init(pattern: "\\bjazzy\\b", weight: 1.5, tag: "jazzy"),
    .init(pattern: "24\\s*/\\s*7", weight: 2, tag: "24/7"),
    .init(pattern: "lofi girl|chilledcow", weight: 3, tag: "lofi girl"),
    .init(pattern: "\\b(?:prod\\.|beat)\\s*(?:by\\s*)?[a-z0-9_.-]+\\b", weight: 1, tag: "beatmaker"),
  ]

  private static let negative: [Signal] = [
    .init(pattern: "deep house", weight: -4, tag: "deep house"),
    .init(pattern: "progressive house", weight: -4, tag: "progressive house"),
    .init(pattern: "\u{0008}trance\u{0008}", weight: -3.5, tag: "trance"),
    .init(pattern: "hard ?style", weight: -5, tag: "hardstyle"),
    .init(pattern: "phonk", weight: -3, tag: "phonk"),
    .init(pattern: "\u{0008}drill\u{0008}", weight: -2, tag: "drill"),
    .init(pattern: "heavy metal|deathcore|metalcore", weight: -5, tag: "metal"),
    .init(pattern: "k[s-]?pop", weight: -2, tag: "k-pop"),
    .init(pattern: "binaural", weight: -3, tag: "binaural beats"),
    .init(pattern: "subliminal|affirmation|solfeggio|d{3} ?hz", weight: -3.5, tag: "frequencies/affirmations"),
    .init(pattern: "karaoke", weight: -3, tag: "karaoke"),
    .init(pattern: "workout|gym motivation", weight: -3, tag: "workout"),
    .init(pattern: "edm (festival|mix)", weight: -4, tag: "edm"),
    .init(pattern: "lofi (fake|filter scam)", weight: -5, tag: "lofi-bait"),
  ]

  /// Channels whose whole catalogue is curated lofi.
  static let trustedChannels: [String] = [
    "lofi girl", "chilledcow", "lofi records", "chillhop music",
    "settle", "the bootleg boy", "afro lofi", "jeez",
    "lofi coffee", "mimi lofi chill", "the japanese town", "a lofi soul",
    "lofi shop 24h", "flux.fm", "lofi corners"
  ]

  /// Producers who only exist in this scene — a bare "Artist - Title" upload
  /// from one of them is lofi even with an empty description.
  static let knownActs: [String] = [
    "kudasai", "no spirit", "tonion", "nymano",
    "yasumu", "hm surf", "lilac", "trxxshed",
    "jhove", "blurred figures", "another silent weekend", "swiftly",
    "hazue", "noji", "sutton", "thymes",
    "home grown", "luella", "idealism", "sleep bean",
    "jinsang", "fantompower", "powfu", "dj hazel",
    "luvlee", "mnts", "tenncoats", "cwrd",
    "philo", "kuun", "vanyforce", "dthcheese",
    "shimza", "purrple cat"
  ]

  private static let moods: [(name: String, words: [String])] = [
    ("sleep", ["sleep", "bedtime", "dream", "insomnia", "8 hours", "\u{1F4A4}"]),
    ("study", ["study", "exam", "homework", "revision", "relax/study"]),
    ("rain", ["rain", "storm", "thunder", "wet"]),
    ("cafe", ["cafe", "coffee", "barista", "latte"]),
    ("night-drive", ["night drive", "headlights", "midnight", "\u{FF5E} drive", "drive to"]),
    ("jazzy", ["jazz", "sax", "piano trio", "swing"]),
    ("sad", ["sad", "cry", "lonely", "heartbreak", "melanch", "\u{1F494}"]),
    ("anime", ["anime", "ghibli", "spirited away", "opening"]),
    ("morning", ["morning", "sunrise", "breakfast", "upbeat"]),
    ("code", ["code", "coding", "programming"]),
    ("focus", ["focus", "deep work", "concentration"]),
  ]

  /// Surrounds with spaces and squashes separators, so word-boundary checks can
  /// be plain `contains` without fighting regex escaping.
  static func normalized(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = " "
    for ch in lowered {
      if ch == "|" || ch == "·" || ch == "—" || ch == "–" || ch == "\n" || ch == "\r" || ch == "\t" { out.append(" ") }
      else { out.append(ch) }
    }
    while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
    return out + " "
  }

  private static func matches(_ pattern: String, in text: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  static func evaluate(
    title: String,
    description: String = "",
    tags: [String] = [],
    channelName: String = "",
    durationSeconds: Int = 0
  ) -> GateVerdict {
    let titleHay = normalized(title)
    let hay = titleHay + "|" + normalized(description) + "|" + normalized(tags.joined(separator: " ")) + "|" + normalized(channelName)

    var score: Double = 0
    var hits: [String] = []
    var penalties: [String] = []

    for signal in positive {
      let inTitle = matches(signal.pattern, in: titleHay)
      if inTitle || matches(signal.pattern, in: hay) {
        score += signal.weight + (inTitle ? 1 : 0)
        if !hits.contains(signal.tag) { hits.append(signal.tag) }
      }
    }

    for signal in negative where matches(signal.pattern, in: hay) {
      score += signal.weight
      if !penalties.contains(signal.tag) { penalties.append(signal.tag) }
    }

    let channelKey = normalized(channelName)
    if trustedChannels.contains(where: { channelKey.contains($0) }) { score += 2 }

    // Mirrors the JS reference exactly: a word in the title *starting* with the
    // act's name (loose on purpose — "Artist - Title" uploads come in every
    // punctuation shape), or an explicit "act - title" credit in the haystack.
    for act in knownActs {
      if titleHay.contains(" \(act)") || hay.contains("\(act) - ") {
        score += 4
        let tag = "\(act) (known lofi act)"
        if !hits.contains(tag) { hits.append(tag) }
        break
      }
    }

    // Long-form mixes and 24/7 streams are lofi's habitat; sub-90s clips are not.
    if durationSeconds > 3600 { score += 0.75 }
    else if durationSeconds > 0 && durationSeconds < 90 { score -= 0.75 }
    else if durationSeconds == 0 { score += 0.25 } // live

    let foundMoods = moods.filter { mood in mood.words.contains { hay.contains($0) } }.map(\.name)

    return GateVerdict(
      lofi: score >= threshold,
      score: (score * 100).rounded() / 100,
      threshold: threshold,
      hits: hits,
      penalties: penalties,
      moods: Array(Set(foundMoods)).sorted()
    )
  }

  /// Tags = whatever the uploader wrote, then whatever the gate inferred.
  static func deriveTags(for track: LofiTrack, gate: GateVerdict) -> [String] {
    var out: [String] = []
    let explicit = track.tags.map { $0.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) }
    for candidate in explicit + gate.hits + gate.moods {
      let clean = candidate.lowercased().trimmingCharacters(in: .whitespaces)
      guard clean.count > 1, !out.contains(clean) else { continue }
      out.append(clean)
      if out.count >= 12 { break }
    }
    return out
  }

  static func deriveMood(for track: LofiTrack, gate: GateVerdict) -> String {
    if let mood = track.mood, !mood.isEmpty { return mood }
    return gate.moods.first ?? "chill"
  }

  /// Attach a verdict + derived tags to a raw track.
  static func stamped(_ track: LofiTrack) -> LofiTrack {
    var t = track
    let gate = evaluate(
      title: t.title,
      description: t.bestDescription,
      tags: t.tags,
      channelName: t.channelName,
      durationSeconds: t.durationSeconds
    )
    t.gate = gate
    t.tags = deriveTags(for: t, gate: gate)
    t.mood = deriveMood(for: t, gate: gate)
    return t
  }
}
