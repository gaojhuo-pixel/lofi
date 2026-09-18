import Foundation

// MARK: - Description → credits
//
// Lofi Girl, Settle, jeez and most mix channels write their description as a
// timestamped tracklist. Parsing it is what turns "a 6 hour video" into "a
// stack of songs": the app can tell you who you are hearing *right now*, credit
// them, and let you tap a credit to jump the disc there.
//
//   0:00 Surf
//   3:40 Woods
//   [00:12:34] Artist — Title
//   6:20 Yasumu - We Met
//
// All offsets below are UTF-16 based (NSString + NSRegularExpression), because
// lofi titles are full of ／ ～ ✦ and Swift String indexes would trap.

enum TracklistParser {
  private static let line = try! NSRegularExpression(
    pattern: #"^\s*\[?(\d{1,2}:)?(\d{1,2}):(\d{2})\]?\s*[-–—•·:*>]*\s*(.+?)\s*$"#,
    options: [.anchorsMatchLines]
  )
  private static let artistSep = try! NSRegularExpression(pattern: #"\s+[-–—]\s+"#)
  private static let bySuffix = try! NSRegularExpression(pattern: #"\s+by\s+(.+)$"#, options: [.caseInsensitive])
  private static let repeatedTimecode = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}\s*[-–—]\s*"#)
  private static let noise = try! NSRegularExpression(
    pattern: #"^(stream|listen|follow|subscribe|social|track ?list|timestamps?|merch|discord|instagram|twitter|tiktok|submit|©|copyright)"#,
    options: [.caseInsensitive]
  )
  private static let producerPrefix = try! NSRegularExpression(
    pattern: #"^\s*(prod\.?|beat|music)\s*(by)?\s*[:\-]?\s*"#,
    options: [.caseInsensitive]
  )
  private static let featRe = try! NSRegularExpression(pattern: #"\b(?:ft\.?|feat\.?|with)\b[:\s]+(.+)$"#, options: [.caseInsensitive])
  private static let hashtagRe = try! NSRegularExpression(pattern: #"#[\p{L}\p{N}_][\p{L}\p{N}_-]*"#)

  // MARK: Helpers

  private static func group(_ result: NSTextCheckingResult, at index: Int, in ns: NSString) -> String? {
    let r = result.range(at: index)
    guard r.location != NSNotFound, r.length > 0 else { return nil }
    let s = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? nil : s
  }

  private static func digits(_ s: String?) -> Int? {
    guard let s else { return nil }
    let only = String(s.filter(\.isNumber))
    return only.isEmpty ? nil : Int(only)
  }

  private static func stripProducer(_ s: String) -> String {
    let ns = s as NSString
    guard let m = producerPrefix.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
      return s.trimmingCharacters(in: .whitespaces)
    }
    return (ns.substring(from: NSMaxRange(m.range)) as String).trimmingCharacters(in: .whitespaces)
  }

  private static func firstRange(of re: NSRegularExpression, in s: String) -> NSRange? {
    let ns = s as NSString
    return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))?.range
  }

  // MARK: API

  static func parse(_ text: String) -> [TrackCredit] {
    let ns = text as NSString
    var out: [TrackCredit] = []

    for result in line.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      guard let minutes = digits(group(result, at: 2, in: ns)),
            let seconds = digits(group(result, at: 3, in: ns)),
            let rawLabel = group(result, at: 4, in: ns) else { continue }

      let hours = digits(group(result, at: 1, in: ns).map { $0.replacingOccurrences(of: ":", with: "") }) ?? 0
      var label = rawLabel
      if let repeatTC = firstRange(of: repeatedTimecode, in: label) {
        label = (label as NSString).substring(from: NSMaxRange(repeatTC))
      }
      guard label.count >= 3 else { continue }
      guard firstRange(of: noise, in: label) == nil else { continue }

      var artist = stripProducer(label)
      var title = ""

      if let sep = firstRange(of: artistSep, in: label) {
        let labelNS = label as NSString
        artist = stripProducer(labelNS.substring(to: sep.location))
        title = labelNS.substring(from: NSMaxRange(sep)).trimmingCharacters(in: .whitespaces)
      } else if let by = firstRange(of: bySuffix, in: label) {
        let labelNS = label as NSString
        title = labelNS.substring(to: by.location).trimmingCharacters(in: .whitespaces)
        artist = stripProducer(labelNS.substring(from: NSMaxRange(by)))
      }

      guard !artist.isEmpty else { continue }
      let start = hours * 3600 + minutes * 60 + seconds

      let joined = "\(artist) \(title)"
      var feat: String?
      if let m = featRe.firstMatch(in: joined, range: NSRange(location: 0, length: (joined as NSString).length)),
         m.numberOfRanges == 2 {
        let found = (joined as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        feat = found.isEmpty ? nil : found
      }

      out.append(TrackCredit(startSeconds: start, artist: artist, title: title.isEmpty ? label : title, feat: feat))
    }

    // Sort first, *then* drop duplicates/backwards jumps: a description whose
    // lines are out of order should keep all of its credits, not one.
    var kept: [TrackCredit] = []
    for entry in out.sorted(by: { $0.startSeconds < $1.startSeconds }) {
      if let last = kept.last, entry.startSeconds <= last.startSeconds { continue }
      kept.append(entry)
    }
    return kept
  }

  /// Hashtags, in the order the uploader wrote them — the UI never invents tags.
  static func hashtags(in text: String) -> [String] {
    let ns = text as NSString
    var seen = Set<String>()
    var out: [String] = []
    for result in hashtagRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let raw = ns.substring(with: result.range)
      let tag = String(raw.dropFirst()).lowercased()
      if tag.count > 1, seen.insert(tag).inserted { out.append(tag) }
    }
    return out
  }

  /// Explicit hashtags first, then live hashtags, then gate-inferred labels.
  static func tags(explicit: [String], description: String, gate: GateVerdict) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for raw in explicit + hashtags(in: description) + gate.hits + gate.moods {
      let clean = raw.replacingOccurrences(of: "#", with: "").lowercased().trimmingCharacters(in: .whitespaces)
      guard clean.count > 1, seen.insert(clean).inserted else { continue }
      out.append(clean)
      if out.count >= 12 { break }
    }
    return out
  }

  /// Convenience for tests and the info sheet.
  static func credit(_ text: String, at seconds: TimeInterval) -> TrackCredit? {
    parse(text).credit(at: seconds)
  }
}
