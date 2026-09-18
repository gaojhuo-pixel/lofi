import Foundation

// MARK: - YouTube Data API v3 provider
//
// The blessed path. Needs a key (Info.plist `YouTubeAPIKey`, or paste it in
// Settings — the key is kept in UserDefaults for dev builds only; swap in
// Keychain before shipping, see docs/DATA-SOURCES.md).
//
// What it buys you that mirrors don't:
//   · search.list with type=video + videoCategoryId=10 (Music) and our lofi gate
//   · videos.list for the full description + official `tags`
//   · commentThreads?order=relevance for genuine "top comments"
//
// What it does NOT buy you: audio. The API never hands over streamable audio —
// playback must go through YouTube's own player (see YouTubePlayerLayer).

final class YouTubeDataProvider {
  private let apiKey: () -> String
  private let decoder = JSONDecoder()

  init(apiKey: @escaping () -> String) {
    self.apiKey = apiKey
  }

  private struct SearchList: Decodable {
    var items: [Item]?
    struct Item: Decodable {
      var id: Id
      struct Id: Decodable { var videoId: String }
    }
  }

  private struct VideoList: Decodable {
    var items: [Video]?
    struct Video: Decodable {
      var id: String
      var snippet: Snippet
      var contentDetails: Details?
      var statistics: Stats?

      struct Snippet: Decodable {
        var title: String?
        var description: String?
        var tags: [String]?
        var channelTitle: String?
        var channelId: String?
        var publishedAt: String?
        var liveBroadcastContent: String?
      }
      struct Details: Decodable { var duration: String? }
      struct Stats: Decodable { var viewCount: String? }
    }
  }

  private struct CommentThreads: Decodable {
    var items: [Thread]?
    struct Thread: Decodable {
      var snippet: Snippet
      struct Snippet: Decodable {
        var totalReplyCount: Int?
        var topLevelComment: Comment?
      }
      struct Comment: Decodable {
        var snippet: Snippet
        struct Snippet: Decodable {
          var authorDisplayName: String?
          var textDisplay: String?
          var textOriginal: String?
          var likeCount: Int?
          var publishedAt: String?
        }
      }
    }
  }

  private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
    let key = apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      throw ProviderError(.notConfigured, detail: "add a YouTube Data API key in Settings")
    }
    guard var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/" + path) else {
      throw ProviderError(.decoding("bad endpoint path"))
    }
    var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "key", value: key))
    components.queryItems = items
    guard let url = components.url else { throw ProviderError(.decoding("bad query")) }
    return try await HTTP.json(T.self, from: url)
  }

  /// ISO-8601 duration, e.g. PT2H50M41S → 10241
  static func seconds(in duration: String?) -> Int {
    guard let duration, duration.hasPrefix("PT") else { return 0 }
    let body = duration.dropFirst(2)
    var total = 0
    var number = ""
    for ch in body {
      if ch.isNumber { number.append(ch); continue }
      let value = Int(number) ?? 0
      number = ""
      switch ch {
      case "H": total += value * 3600
      case "M": total += value * 60
      case "S": total += value
      default: break
      }
    }
    return total
  }

  private func relative(_ publishedAt: String?) -> String {
    guard let publishedAt else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: publishedAt) ?? ISO8601DateFormatter().date(from: publishedAt) else { return "" }
    let df = DateFormatter()
    df.doesRelativeDateFormatting = true
    df.dateStyle = .medium
    df.timeStyle = .none
    return df.string(from: date)
  }
}

extension YouTubeDataProvider: LofiProviding {
  var name: String { "youtube data api" }

  func search(_ query: String, mood: String?, limit: Int) async throws -> LofiSearchResults {
    let q = [query, mood, "lofi"].filter { !$0.isEmpty && $0 != "all" }.joined(separator: " ")
    let response: SearchList = try await get(
      "search.list",
      query: [
        "part": "snippet",
        "type": "video",
        "videoCategoryId": "10", // Music
        "relevanceLanguage": "en",
        "safeSearch": "none",
        "maxResults": String(min(50, max(1, limit * 2))),
        "q": q.isEmpty ? "lofi hip hop" : q,
      ]
    )

    let ids = (response.items ?? []).map(\.id.videoId).filter { !$0.isEmpty }
    guard !ids.isEmpty else { return LofiSearchResults(query: q, accepted: [], rejected: [], origin: name) }

    let details: VideoList = try await get(
      "videos.list",
      query: ["part": "snippet,contentDetails,statistics", "id": ids.joined(separator: ","), "maxResults": String(ids.count)]
    )

    let stamped: [LofiTrack] = (details.items ?? []).map { video in
      var track = LofiTrack(
        videoId: video.id,
        title: video.snippet.title ?? "untitled",
        kind: (video.snippet.liveBroadcastContent == "live") ? "live" : "track",
        channelName: video.snippet.channelTitle ?? "",
        channelId: video.snippet.channelId,
        durationSeconds: Self.seconds(in: video.contentDetails?.duration),
        viewCount: Int(video.statistics?.viewCount ?? "") ?? 0,
        publishedLabel: relative(video.snippet.publishedAt),
        // declaration order matters: the model's init lists excerpt before full text
        descriptionExcerpt: String((video.snippet.description ?? "").prefix(280)),
        description: video.snippet.description,
        tags: video.snippet.tags ?? [],
        source: .youtubeAPI
      )
      if track.durationSeconds == 0 && track.kind != "live" { track.kind = "mix" }
      let gate = LofiFilter.evaluate(
        title: track.title,
        description: track.bestDescription,
        tags: track.tags,
        channelName: track.channelName,
        durationSeconds: track.durationSeconds
      )
      track.gate = gate
      track.mood = LofiFilter.deriveMood(for: track, gate: gate)
      track.tags = LofiFilter.deriveTags(for: track, gate: gate)
      let list = TracklistParser.parse(track.bestDescription)
      if !list.isEmpty { track.tracklist = list }
      return track
    }

    return LofiSearchResults(
      query: q,
      accepted: Array(stamped.filter { $0.gate?.lofi == true }.prefix(limit)),
      rejected: Array(stamped.filter { $0.gate?.lofi != true }.prefix(8)),
      origin: name
    )
  }

  func details(for track: LofiTrack) async throws -> LofiTrack {
    let response: VideoList = try await get(
      "videos.list",
      query: ["part": "snippet,contentDetails,statistics", "id": track.videoId]
    )
    guard let video = response.items?.first else { throw ProviderError(.http(404), detail: track.videoId) }
    var updated = track
    updated.title = video.snippet.title ?? updated.title
    updated.description = video.snippet.description ?? updated.description
    updated.channelName = video.snippet.channelTitle ?? updated.channelName
    updated.channelId = video.snippet.channelId ?? updated.channelId
    let duration = Self.seconds(in: video.contentDetails?.duration)
    if duration > 0 { updated.durationSeconds = duration }
    updated.viewCount = Int(video.statistics?.viewCount ?? "") ?? updated.viewCount
    updated.tags = video.snippet.tags ?? updated.tags
    let gate = LofiFilter.evaluate(
      title: updated.title,
      description: updated.bestDescription,
      tags: updated.tags,
      channelName: updated.channelName,
      durationSeconds: updated.durationSeconds
    )
    updated.gate = gate
    updated.tags = LofiFilter.deriveTags(for: updated, gate: gate)
    let list = TracklistParser.parse(updated.bestDescription)
    if !list.isEmpty { updated.tracklist = list }
    updated.source = .youtubeAPI
    return updated
  }

  func topComments(for track: LofiTrack, max: Int) async throws -> [YTComment] {
    let response: CommentThreads = try await get(
      "commentThreads.list",
      query: [
        "part": "snippet",
        "videoId": track.videoId,
        "order": "relevance", // this is literally "top comments"
        "maxResults": String(min(100, max(1, max))),
        "textFormat": "plainText",
      ]
    )
    return (response.items ?? []).compactMap { thread in
      guard let s = thread.snippet.topLevelComment?.snippet else { return nil }
      return YTComment(
        author: s.authorDisplayName ?? "anon",
        text: (s.textDisplay ?? s.textOriginal ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        likes: s.likeCount ?? 0,
        time: relative(s.publishedAt),
        pinned: nil,
        creatorReplied: nil,
        provenance: "youtube"
      )
    }
  }
}
