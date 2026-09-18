import Foundation

// MARK: - Provider contract
//
// Three implementations, one vocabulary: the seed corpus (offline), Piped /
// Invidious (no key, community JSON mirrors of YouTube), and the official
// YouTube Data API v3 (key required, the only blessed path). Every track that
// comes back — from any of them — has to pass LofiFilter before the deck sees
// it. That is what "only youtube lofi stuff" means in code.

struct ProviderError: LocalizedError {
  enum Kind { case notConfigured, unreachable, http(Int), decoding(String), embedDisabled, noStreams }
  let kind: Kind
  let detail: String?

  init(_ kind: Kind, detail: String? = nil) {
    self.kind = kind
    self.detail = detail
  }

  var errorDescription: String? {
    switch (kind, detail) {
    case (.notConfigured, let d?): return "not configured · \(d)"
    case (.notConfigured, nil): return "no API key configured — switch the source in Settings"
    case (.unreachable, let d?): return "every mirror refused · \(d)"
    case (.unreachable, nil): return "every mirror refused"
    case (.http(let code), let d): return "HTTP \(code)\(d.map { " · \($0)" } ?? "")"
    case (.decoding(let d)): return "unexpected JSON · \(d)"
    case (.embedDisabled, _): return "this uploader disabled playback outside YouTube"
    case (.noStreams, _): return "no playable audio stream for this video"
    }
  }
}

protocol LofiProviding {
  /// Search, already gated. `rejected` is kept so the UI can show what was dropped.
  func search(_ query: String, mood: String?, limit: Int) async throws -> LofiSearchResults
  /// Full description, live hashtags and a parsed tracklist.
  func details(for track: LofiTrack) async throws -> LofiTrack
  /// "top comments" = YouTube's own relevance ordering, not ours.
  func topComments(for track: LofiTrack, max: Int) async throws -> [YTComment]
  /// Audio-only URL for the boosted local route. nil = use the embed player.
  func audioStreamURL(for track: LofiTrack) async throws -> URL?
  var name: String { get }
}

extension LofiProviding {
  func audioStreamURL(for track: LofiTrack) async throws -> URL? { nil }
}

// MARK: - HTTP plumbing shared by the live providers

struct HTTP {
  static var session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 12
    cfg.timeoutIntervalForResource = 60
    cfg.waitsForConnectivity = true
    cfg.httpAdditionalHeaders = ["User-Agent": "LofiGlass/1.0 (lofi deck; iOS)"]
    return URLSession(configuration: cfg)
  }()

  static func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
    let (data, response) = try await session.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw ProviderError(.http(http.statusCode), detail: url.host)
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw ProviderError(.decoding(String("\(error)".prefix(160))))
    }
  }

  static func string(from url: URL) async throws -> String {
    let (data, _) = try await session.data(from: url)
    return String(decoding: data, as: UTF8.self)
  }
}

/// Rotates through mirrors so one dead instance doesn't kill the app.
actor InstanceRotator {
  private let hosts: [String]
  private var index = 0
  private var failing: [String: Date] = [:]
  private let cooldown: TimeInterval = 90

  init(hosts: [String]) {
    self.hosts = hosts
  }

  func current(excluding: String? = nil) -> String? {
    let now = Date()
    for offset in 0..<hosts.count {
      let host = hosts[(index + offset) % hosts.count]
      if host == excluding { continue }
      if let since = failing[host], now.timeIntervalSince(since) < cooldown { continue }
      index = (index + offset) % hosts.count
      return host
    }
    return hosts.first
  }

  func markFailure(_ host: String) {
    failing[host] = Date()
    index = (index + 1) % max(1, hosts.count)
  }

  func markSuccess(_ host: String) {
    failing[host] = nil
    if let pos = hosts.firstIndex(of: host) { index = pos }
  }
}
