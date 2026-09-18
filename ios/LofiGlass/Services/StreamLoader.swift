import AVFoundation
import Foundation

// MARK: - Stream loader
//
// The boost engine needs PCM it can actually touch, which means it needs a file
// or bytes — not a cross-origin player. This class is the only place in the app
// that fetches audio, and it only talks to a resolver *you* run (see
// docs/DATA-SOURCES.md for why nothing here hard-codes a YouTube scraper).
//
//   GET {resolverBase}/resolve?videoId=…            → { "url": "https://…", "expiresIn": 21600 }
//   Authorization: Bearer {resolverToken}           (optional)
//
// Bytes are cached under Caches/LoFiAudio/<videoId>.<ext>, keyed by video id, so
// a disc you already swiped re-boosts instantly and offline.

actor StreamLoader {
  enum LoadError: LocalizedError {
    case noResolver
    case badResponse(Int)
    case noURL
    case cancelled

    var errorDescription: String? {
      switch self {
      case .noResolver: return "no resolver configured · Settings → Local boost → Resolver base URL"
      case .badResponse(let code): return "resolver returned HTTP \(code)"
      case .noURL: return "resolver returned no playable url"
      case .cancelled: return "cancelled"
      }
    }
  }

  struct Resolved: Codable {
    var url: String? = nil
    var expiresIn: Int? = nil
    var title: String? = nil
    var durationSeconds: Int? = nil
    var mimeType: String? = nil
  }

  struct Loaded {
    var url: URL
    var fromCache: Bool
    var bytes: Int64
  }

  private let config: AppConfig
  private let session: URLSession
  private var inFlight: [String: Task<Loaded, Error>] = [:]

  private static let cacheDir: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = base.appendingPathComponent("LoFiAudio", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  init(config: AppConfig = .shared) {
    self.config = config
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForResource = 120
    cfg.waitsForConnectivity = true
    cfg.httpAdditionalHeaders = ["User-Agent": "LofiGlass/1.0 (iOS)"]
    session = URLSession(configuration: cfg)
  }

  private func cachedURL(for videoId: String) -> URL? {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: Self.cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
    return entries.first { $0.lastPathComponent.hasPrefix(videoId) && $0.pathExtension != "part" }
  }

  func cachedSize(for videoId: String) -> Int64 {
    guard let url = cachedURL(for: videoId) else { return 0 }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    return Int64(size)
  }

  /// Cache-first. `progress` is 0…1 and only fires for a cold download.
  func audio(for track: LofiTrack, progress: ((Double) -> Void)? = nil) async throws -> Loaded {
    if let hit = cachedURL(for: track.videoId) {
      return Loaded(url: hit, fromCache: true, bytes: cachedSize(for: track.videoId))
    }
    if let existing = inFlight[track.videoId] { return try await existing.value }

    let task = Task<Loaded, Error> { [config] in
      let base = config.resolverBase.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !base.isEmpty else { throw LoadError.noResolver }
      guard var components = URLComponents(string: base.hasSuffix("/") ? String(base.dropLast()) : base) else {
        throw LoadError.badResponse(-1)
      }
      components.path += "/resolve"
      components.queryItems = [URLQueryItem(name: "videoId", value: track.videoId)]
      guard let resolveURL = components.url else { throw LoadError.badResponse(-1) }
      var request = URLRequest(url: resolveURL)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      let token = config.resolverToken.trimmingCharacters(in: .whitespacesAndNewlines)
      if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

      let (resolveBytes, resolveResponse) = try await session.data(for: request)
      if let http = resolveResponse as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
        throw LoadError.badResponse(http.statusCode)
      }
      let resolved = (try? JSONDecoder().decode(Resolved.self, from: resolveBytes)) ?? Resolved()
      guard let string = resolved.url, let streamURL = URL(string: string) else { throw LoadError.noURL }

      var downloadRequest = URLRequest(url: streamURL)
      downloadRequest.timeoutInterval = 120
      let (tempURL, response) = try await session.download(from: downloadRequest)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw LoadError.badResponse(http.statusCode)
      }
      let ext = streamURL.pathExtension.isEmpty ? (resolved.mimeType?.contains("mp4") == true ? "m4a" : "bin") : streamURL.pathExtension
      let dest = Self.cacheDir.appendingPathComponent("\(track.videoId).\(ext)")
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.moveItem(at: tempURL, to: dest)
      let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      progress?(1)
      return Loaded(url: dest, fromCache: false, bytes: Int64(bytes))
    }

    inFlight[track.videoId] = task
    defer { inFlight[track.videoId] = nil }
    return try await task.value
  }

  /// Keep the cache from eating the device: newest 20 discs, everything else gone.
  func trimCache(keeping: Int = 20) {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(at: Self.cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    let sorted = urls
      .sorted { lhs, rhs in
        let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return l > r
      }
    for url in sorted.dropFirst(keeping) { try? fm.removeItem(at: url) }
  }

  func cacheBytes() -> Int64 {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(at: Self.cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    return urls.reduce(Int64(0)) { total, url in total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
  }

  func clearCache() {
    let fm = FileManager.default
    try? fm.removeItem(at: Self.cacheDir)
    try? fm.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
  }
}
