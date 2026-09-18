import Foundation

// MARK: - Piped / Invidious provider
//
// The no-key path. Piped and Invidious expose plain JSON for exactly what this
// app needs — search, description, hashtags, chapters, audio-only streams and
// YouTube's top comments. They are community mirrors, so: rotate hosts, keep
// timeouts short, cache hard, and never pretend a failure is a feature.
//
// Terms of service note: these mirrors read YouTube on your behalf. Whatever
// you ship, read docs/DATA-SOURCES.md — the compliant route is the Data API for
// metadata plus YouTube's own player for playback.

final class PipedProvider {
  private let rotator: InstanceRotator
  private let cache = NSCache<NSString, NSData>()
  private let decoder = JSONDecoder()

  static let defaultHosts = [
    "https://pipedapi.kavin.rocks",
    "https://pipedapi.adminforge.de",
    "https://api.piped.private.coffee",
    "https://pipedapi.drgns.space",
  ]

  init(hosts: [String] = PipedProvider.defaultHosts) {
    rotator = InstanceRotator(hosts: hosts)
  }

  // MARK: DTOs

  private struct SearchResponse: Decodable {
    var items: [Item]?
    struct Item: Decodable {
      var title: String?
      var url: String?
      var thumbnail: String?
      var duration: Int?
      var uploaderName: String?
      var uploaderUrl: String?
      var uploadedDate: String?
      var shortDescription: String?
      var views: Int?
    }
  }

  private struct StreamsResponse: Decodable {
    var title: String?
    var description: String?
    var uploader: String?
    var uploaderName: String?
    var uploaderUrl: String?
    var uploaderId: String?
    var tags: [String]?
    var duration: Int?
    var views: Int?
    var chapters: [Chapter]?
    var relatedStreams: [SearchResponse.Item]?
    var audioStreams: [AudioStream]?

    struct Chapter: Decodable {
      var title: String?
      var start: Int?
    }
    struct AudioStream: Decodable {
      var url: String?
      var format: String?
      var mimeType: String?
      var bitrate: Int?
    }
  }

  private struct CommentsResponse: Decodable {
    var comments: [Comment]?
    var nextpage: String?
    struct Comment: Decodable {
      var author: String?
      var thumbnail: String?
      var commentText: String?
      var likeCount: Int?
      var pinned: Bool?
      var creatorReplied: Bool?
      var uploadedDate: String?
      var replies: Int?
    }
  }

  // MARK: Plumbing

  /// One GET, with mirror rotation + a small in-memory cache. Data is cached
  /// (not decoded models) so the DTOs stay plain Decodable.
  private func data(path: String, query: [String: String] = [:]) async throws -> Data {
    let key = path + "?" + query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
    let cacheKey = key as NSString
    if let hit = cache.object(forKey: cacheKey) { return hit as Data }

    var lastError: Error = ProviderError(.unreachable, detail: "no mirrors configured")
    for _ in 0..<4 {
      guard let host = await rotator.current() else { break }
      guard var components = URLComponents(string: host + path) else { continue }
      if !query.isEmpty {
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
      }
      guard let url = components.url else { continue }
      do {
        let (bytes, response) = try await HTTP.session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          throw ProviderError(.http(http.statusCode), detail: url.host)
        }
        await rotator.markSuccess(host)
        cache.setObject(bytes as NSData, forKey: cacheKey)
        return bytes
      } catch {
        lastError = error
        await rotator.markFailure(host)
      }
    }
    throw lastError
  }

  private func request<T: Decodable>(_ type: T.Type, path: String, query: [String: String] = [:]) async throws -> T {
    let bytes = try await data(path: path, query: query)
    do {
      return try decoder.decode(type, from: bytes)
    } catch {
      throw ProviderError(.decoding(String("\(error)".prefix(180))))
    }
  }

  /// Pulls an 11-character video id out of every shape YouTube emits —
  /// `/watch?v=`, `youtu.be/`, `/embed/`, `/shorts/`, `/live/`, `/v/` and bare
  /// ids. Anything that is not exactly 11 `[A-Za-z0-9_-]` characters is not an
  /// id, so playlists and channel URLs come back nil instead of a wrong deck.
  static func videoId(from url: String?) -> String? {
    guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    let token = Substring(raw).prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    if raw.count == 11, token.count == 11 { return raw }

    for marker in ["v=", "youtu.be/", "/embed/", "/shorts/", "/live/", "/v/"] {
      guard let range = raw.range(of: marker) else { continue }
      let after = raw[range.upperBound...]
      let candidate = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
      if candidate.count == 11 { return String(candidate) }
    }
    return nil
  }

  private func track(from item: SearchResponse.Item) -> LofiTrack? {
    guard let id = Self.videoId(from: item.url), let title = item.title else { return nil }
    let duration = item.duration ?? 0
    let kind: String = duration == 0 ? "live" : duration > 1200 ? "mix" : "track"
    var handle: String?
    if let up = item.uploaderUrl { handle = up.hasPrefix("@") ? up : up.replacingOccurrences(of: "/@", with: "@") }
    var track = LofiTrack(
      videoId: id,
      title: title,
      kind: kind,
      channelName: item.uploaderName ?? "unknown",
      channelHandle: handle,
      durationSeconds: max(0, duration),
      viewCount: item.views,
      publishedLabel: item.uploadedDate,
      descriptionExcerpt: item.shortDescription,
      source: .piped
    )
    track.tags = TracklistParser.hashtags(in: item.shortDescription ?? "")
    return track
  }
}

extension PipedProvider: LofiProviding {
  var name: String { "piped mirrors" }

  func search(_ query: String, mood: String?, limit: Int) async throws -> LofiSearchResults {
    let q = [query, mood].compactMap { $0 }.filter { !$0.isEmpty && $0 != "all" }.joined(separator: " ")
    let response: SearchResponse = try await request(
      SearchResponse.self,
      path: "/search",
      query: ["q": q.isEmpty ? "lofi hip hop" : q, "filter": "music_tracks"]
    )
    let raw = (response.items ?? []).compactMap { self.track(from: $0) }
    let stamped = raw.map { LofiFilter.stamped($0) }
    return LofiSearchResults(
      query: q,
      accepted: Array(stamped.filter { $0.gate?.lofi == true }.prefix(limit)),
      rejected: Array(stamped.filter { $0.gate?.lofi != true }.prefix(limit)),
      origin: "piped · \(query.isEmpty ? "radio" : query)"
    )
  }

  func details(for track: LofiTrack) async throws -> LofiTrack {
    let s: StreamsResponse = try await request(StreamsResponse.self, path: "/streams/\(track.videoId)")
    var updated = track
    updated.title = s.title ?? updated.title
    updated.description = s.description ?? updated.description
    updated.channelName = (s.uploaderName ?? s.uploader) ?? updated.channelName
    updated.channelHandle = s.uploaderUrl.map { $0.hasPrefix("@") ? $0 : $0.replacingOccurrences(of: "/@", with: "@") } ?? updated.channelHandle
    updated.channelId = s.uploaderId ?? updated.channelId
    if let duration = s.duration, duration > 0 { updated.durationSeconds = duration }
    updated.viewCount = s.views ?? updated.viewCount
    let explicit = (s.tags ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
    updated.tags = explicit
    let gate = LofiFilter.evaluate(
      title: updated.title,
      description: s.description ?? updated.bestDescription,
      tags: explicit,
      channelName: updated.channelName,
      durationSeconds: updated.durationSeconds
    )
    updated.gate = gate
    updated.tags = LofiFilter.deriveTags(for: updated, gate: gate)
    if updated.tracklist?.isEmpty != false {
      if let chapters = s.chapters, !chapters.isEmpty {
        updated.tracklist = chapters.compactMap { chapter -> TrackCredit? in
          guard let title = chapter.title, chapter.start != nil else { return nil }
          let parts = title.components(separatedBy: " - ")
          return TrackCredit(
            startSeconds: chapter.start ?? 0,
            artist: parts.first ?? title,
            title: parts.dropFirst().joined(separator: " - ")
          )
        }
      } else if let description = s.description {
        let parsed = TracklistParser.parse(description)
        if !parsed.isEmpty { updated.tracklist = parsed }
      }
    }
    updated.source = .piped
    return updated
  }

  func topComments(for track: LofiTrack, max: Int) async throws -> [YTComment] {
    let response: CommentsResponse = try await request(CommentsResponse.self, path: "/comments/\(track.videoId)")
    let items = (response.comments ?? []).map { c in
      YTComment(
        author: c.author ?? "anon",
        text: c.commentText ?? "",
        likes: c.likeCount ?? 0,
        time: c.uploadedDate,
        pinned: c.pinned,
        creatorReplied: c.creatorReplied,
        provenance: "youtube"
      )
    }
    // Piped hands back YouTube's ordering; sort by likes so the sheet really
    // reads as "top comments" when a mirror decides to return newest-first.
    return Array(items.sorted { lhs, rhs in
      if lhs.pinned == true, rhs.pinned != true { return true }
      if rhs.pinned == true, lhs.pinned != true { return false }
      return lhs.likes != rhs.likes ? lhs.likes > rhs.likes : lhs.text < rhs.text
    }.prefix(max))
  }

  func audioStreamURL(for track: LofiTrack) async throws -> URL? {
    let s: StreamsResponse = try await request(StreamsResponse.self, path: "/streams/\(track.videoId)")
    guard let best = s.audioStreams?.sorted(by: { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }).first,
          let string = best.url,
          let url = URL(string: string) else {
      throw ProviderError(.noStreams)
    }
    return url
  }
}
