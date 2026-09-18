import AVFoundation
import Combine
import Foundation
import SwiftUI

// MARK: - AppState
//
// One observable object owning the deck, the hunt, the boost routing and the
// crate. Views stay dumb: they read `current`, call `swipeNext()`, and render
// whatever `LofiFilter` said.

@MainActor
final class AppState: ObservableObject {
  // Deck
  @Published var queue: [LofiTrack] = []
  @Published var index = 0
  @Published var history: [LofiTrack] = []
  @Published var pool: [LofiTrack] = []
  @Published var poolCursor = 0
  @Published var rejectedRecently: [LofiTrack] = []
  @Published var crate: [LofiTrack] = []

  // Transport
  @Published var isPlaying = false
  @Published var position: TimeInterval = 0
  @Published var duration: TimeInterval = 0
  @Published var busy = false
  @Published var status: String = "booting…"
  @Published var meter = AudioBoostEngine.Metering()
  @Published var sheet: DeckSheet? = nil

  // Enrichment
  @Published var comments: [String: [YTComment]] = [:]
  @Published var commentsOrigin: [String: String] = [:]
  @Published var loadingComments = Set<String>()
  @Published var loadingDetails = Set<String>()

  let config: AppConfig
  private(set) var provider: CompositeProvider
  let engine = AudioBoostEngine()
  private let loader = StreamLoader()
  private let seed = SeedProvider.shared

  private var seen = Set<String>()
  private var enrichTask: Task<Void, Never>?
  private var tickTimer: Timer?
  private var sleepTask: Task<Void, Never>?
  private var lastSwipe = Date.distantPast
  private var lastHunt: LofiSearchResults = .empty
  private var cancellables: Set<AnyCancellable> = []

  init(config: AppConfig = .shared) {
    self.config = config
    self.provider = AppState.makeProvider(config: config, seed: SeedProvider.shared)
    self.crate = AppState.readCrate()
    wireEngine()
    // Any settings mutation lands in the engine, whether it came from the boost
    // sheet, a keyboard shortcut or a restored UserDefaults value.
    config.$source
      .dropFirst()
      .sink { [weak self] _ in self?.rebuildProvider("source") }
      .store(in: &cancellables)
    config.$pipedHosts
      .dropFirst()
      .sink { [weak self] _ in self?.rebuildProvider("mirrors") }
      .store(in: &cancellables)
    config.$boost
      .dropFirst()
      .sink { [weak self] _ in self?.applyBoost() }
      .store(in: &cancellables)
    config.$route
      .dropFirst()
      .sink { [weak self] _ in Task { @MainActor in await self?.reroute() } }
      .store(in: &cancellables)
  }

  /// Switching routes mid-track: hand the same playhead to the other player.
  func reroute() async {
    let resumeAt = position
    let wasPlaying = isPlaying
    if config.route == .boostedLocal {
      if let track = current { await loadBoostedAudio(for: track) }
      position = resumeAt
      engine.seek(to: resumeAt)
      if wasPlaying { play() }
    } else {
      engine.pause()
      status = "embed player · boost maps to device volume"
      if wasPlaying { play() }
    }
  }

  // MARK: Derived

  var current: LofiTrack? { queue.indices.contains(index) ? queue[index] : nil }
  var upcoming: LofiTrack? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }

  var headlineCredit: String { current?.headline(at: position) ?? "no disc loaded" }

  var currentCredit: TrackCredit? {
    guard let list = current?.tracklist, !list.isEmpty else { return nil }
    return list.credit(at: position)
  }

  var nextCredit: TrackCredit? { current?.tracklist?.next(after: position) }

  var progress: Double {
    guard duration > 1 else { return 0 }
    return min(1, max(0, position / duration))
  }

  var routeLabel: String {
    switch config.route {
    case .embedded: return "youtube embed · boost → device volume"
    case .boostedLocal: return "boost engine · \(String(format: "%+.1f", config.boost.db)) dB live"
    }
  }

  var boostCaption: String {
    config.boost.db > 0
      ? (config.route == .boostedLocal ? "boost live" : "boost armed · iframe-capped")
      : (config.boost.db < 0 ? "trimmed" : "unity")
  }

  /// Building the providers is a *function*, not a line in `init`: they capture
  /// their hosts and their settings closures, so a source switch in Settings has
  /// to rebuild them instead of waiting for a relaunch. Static, because `init`
  /// cannot call an instance method before every stored property is set.
  private static func makeProvider(config: AppConfig, seed: SeedProvider) -> CompositeProvider {
    let primary: LofiProviding?
    let mirror: LofiProviding?
    let hosts = config.pipedHostList
    switch config.source {
    case .youtube:
      primary = YouTubeDataProvider(apiKey: { config.apiKey })
      mirror = PipedProvider(hosts: hosts)
    case .piped:
      primary = PipedProvider(hosts: hosts)
      mirror = nil
    case .seed:
      primary = nil
      mirror = nil
    }
    return CompositeProvider(
      primary: primary,
      mirror: mirror,
      seed: seed,
      gateEnabled: { config.gateEnabled },
      thresholdOverride: { config.gateThreshold }
    )
  }

  private func rebuildProvider(_ why: String) {
    provider = AppState.makeProvider(config: config, seed: seed)
    status = "providers rebuilt · \(why) · \(config.source.label)"
  }

  // MARK: - Boot

  func boot() async {
    let hadSeed = seed.load()
    pool = hadSeed ? seed.rotation(seen: seen) : []
    poolCursor = 0
    status = hadSeed ? "\(seed.tracks.count) lofi discs · gate \(config.gateEnabled ? "on" : "off")" : "no seed corpus · going straight to search"
    await hunt(reason: "boot")
    applyBoost()
  }

  /// The swipe entry point. `direction` 1 = find a new song, -1 = rewind.
  func swipe(_ direction: Int) async {
    // Guard against a fling registering twice (drag + tap).
    if Date().timeIntervalSince(lastSwipe) < 0.18 { return }
    lastSwipe = Date()
    if direction < 0 { await rewind() } else { await hunt(reason: "swipe") }
  }

  private func rewind() async {
    guard let previous = history.popLast() else {
      status = "that was the first disc"
      return
    }
    queue.insert(previous, at: max(0, index))
    status = "rewound ↺"
    await select(previous, autoplay: config.autoplayOnSwipe)
  }

  /// Pull the next lofi disc: pool first, then a fresh gated search.
  func hunt(reason: String) async {
    guard !busy else { return }
    busy = true
    status = "seeking lofi…"
    defer { busy = false }

    var candidate: LofiTrack?
    while poolCursor < pool.count {
      let next = pool[poolCursor]
      poolCursor += 1
      if seen.contains(next.videoId) { continue }
      if config.gateEnabled, next.gate?.lofi == false {
        rejectedRecently.insert(next, at: 0)
        continue
      }
      candidate = next
      break
    }

    if candidate == nil {
      let radio = config.radioMode ? seed.randomRadioSeed() : nil
      let results = await provider.hunt(query: radio?.text ?? "", mood: radio?.mood, limit: 24)
      lastHunt = results
      rejectedRecently = results.rejected + rejectedRecently
      rejectedRecently = Array(rejectedRecently.prefix(12))
      let fresh = results.accepted.filter { !seen.contains($0.videoId) }
      if !fresh.isEmpty {
        pool = fresh + pool[poolCursor...]
        poolCursor = 0
        candidate = pool[poolCursor]
        poolCursor += 1
      }
    }

    guard let found = candidate else {
      status = "nothing lofi matched · loosen the gate or check the source"
      return
    }
    status = "· \(found.channelName)"
    push(found)
    await select(found, autoplay: config.autoplayOnSwipe)
  }

  private func push(_ track: LofiTrack) {
    seen.insert(track.videoId)
    if let existing = queue.firstIndex(where: { $0.videoId == track.videoId }) {
      index = existing
      return
    }
    queue.insert(track, at: 0)
    index = 0
    if queue.count > 40 { queue.removeLast(queue.count - 40) }
  }

  private func select(_ track: LofiTrack, autoplay: Bool) async {
    position = 0
    duration = Double(track.durationSeconds)
    isPlaying = false

    switch config.route {
    case .embedded:
      // The embed view reloads on videoId change; nothing to do here.
      break
    case .boostedLocal:
      await loadBoostedAudio(for: track)
    }

    if autoplay { play() } else { engine.pause() }
    scheduleEnrichment(for: track)
  }

  /// Resolve + download audio, then hand the file to the engine. Any failure
  /// falls back to the embed route rather than showing a dead disc.
  func loadBoostedAudio(for track: LofiTrack) async {
    do {
      status = "buffering audio for boost…"
      let loaded = try await loader.audio(for: track) { [weak self] fraction in
        Task { @MainActor in self?.status = "buffering \(Int(fraction * 100))%" }
      }
      try engine.load(url: loaded.url)
      engine.loopingEnabled = !track.isLive
      status = loaded.fromCache ? "boost engine · cached" : "boost engine · \(ByteCountFormatter.string(fromByteCount: loaded.bytes, countStyle: .file))"
    } catch {
      config.route = .embedded
      status = "no local stream (\(error.localizedDescription)) → embed player"
    }
  }

  // MARK: - Transport

  func play() {
    switch config.route {
    case .embedded: isPlaying = true
    case .boostedLocal:
      engine.activateSession()
      engine.play(from: position)
      isPlaying = engine.isPlaying
    }
  }

  func pause() {
    isPlaying = false
    if config.route == .boostedLocal { engine.pause() }
  }

  func toggle() {
    isPlaying ? pause() : play()
  }

  func seek(to seconds: TimeInterval) {
    position = max(0, seconds)
    if config.route == .boostedLocal { engine.seek(to: position) }
  }

  /// Jump to a description tracklist entry — "credits" becomes navigation.
  func jump(to credit: TrackCredit) {
    seek(to: TimeInterval(credit.startSeconds))
    status = "→ \(credit.display)"
    if !isPlaying { play() }
  }

  /// Called by the embed bridge and by the engine tick.
  func report(time: TimeInterval, duration: TimeInterval) {
    self.position = time
    if duration > 1 { self.duration = duration }
    if let next = currentCredit, next.startSeconds > position {
      status = "· \(next.artist)"
    }
  }

  private func wireEngine() {
    engine.onMeter = { [weak self] reading in
      Task { @MainActor in
        guard let self else { return }
        self.meter = reading
        if self.config.route == .boostedLocal, self.engine.isPlaying {
          self.position = self.engine.position
          self.duration = self.engine.duration
        }
      }
    }
    engine.onTrackEnd = { [weak self] in
      Task { @MainActor in self?.awaitHuntOnEnd() }
    }
    tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.driftTick() }
    }
  }

  private func awaitHuntOnEnd() async {
    if config.radioMode { await hunt(reason: "ended") } else { pause() }
  }

  /// Live streams and 24-hour mixes report nothing useful from the player for
  /// minutes at a time, so the deck nudges the clock itself between events.
  private func driftTick() {
    guard isPlaying, config.route == .embedded else { return }
    position += 0.5
  }

  // MARK: - Boost

  /// Single routing decision, in one place:
  /// local engine → real gain; embed → the same dB number mapped onto the
  /// player's 0…100 volume, because cross-origin video has no tap-in.
  func applyBoost() {
    engine.settings = config.boost
    if config.route == .embedded {
      status = "volume \(config.boost.systemVolumePercent)%"
    }
  }

  func nudgeBoost(by delta: Double) {
    config.boost.db = min(BoostSettings.maxDb, max(BoostSettings.minDb, config.boost.db + delta))
    applyBoost()
  }

  func setPreset(_ preset: Preset) {
    var s = config.boost
    preset.applied(to: &s)
    config.boost = s
    applyBoost()
  }

  func setRate(_ rate: Float) {
    engine.setRate(rate)
  }

  // MARK: - Enrichment (description + top comments)

  private func scheduleEnrichment(for track: LofiTrack) {
    enrichTask?.cancel()
    enrichTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: 550_000_000)
      guard !Task.isCancelled else { return }
      await self.enrich(track)
      guard !Task.isCancelled else { return }
      await self.loadComments(track)
    }
  }

  func enrich(_ track: LofiTrack) async {
    guard config.source != .seed else {
      // Seed tracks already carry description + tracklist; parse if missing.
      if let idx = queue.firstIndex(where: { $0.videoId == track.videoId }), queue[idx].tracklist?.isEmpty != false {
        var updated = queue[idx]
        let parsed = TracklistParser.parse(updated.bestDescription)
        if !parsed.isEmpty { updated.tracklist = parsed }
        queue[idx] = updated
      }
      return
    }
    loadingDetails.insert(track.videoId)
    defer { loadingDetails.remove(track.videoId) }
    let updated = await provider.details(for: track)
    guard let idx = queue.firstIndex(where: { $0.videoId == track.videoId }) else { return }
    queue[idx] = updated
    status = "description via \(updated.source.label) · \(updated.tracklist?.count ?? 0) credits"
  }

  func loadComments(_ track: LofiTrack, force: Bool = false) async {
    guard force || comments[track.videoId] == nil else { return }
    loadingComments.insert(track.videoId)
    defer { loadingComments.remove(track.videoId) }
    let result = await provider.comments(for: track, max: 8)
    comments[track.videoId] = result.items
    commentsOrigin[track.videoId] = result.origin
    status = "\(result.items.count) top comments · \(result.origin)"
  }

  func visibleComments(for track: LofiTrack) -> [YTComment] {
    if let live = comments[track.videoId], !live.isEmpty { return live }
    return track.comments ?? []
  }

  func provenanceLabel(for track: LofiTrack) -> String {
    commentsOrigin[track.videoId] ?? "seed cache"
  }

  // MARK: - Crate

  static func readCrate() -> [LofiTrack] {
    guard let url = crateURL, let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([LofiTrack].self, from: data)) ?? []
  }

  static var crateURL: URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let dir = base.appendingPathComponent("LofiGlass", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("crate.json")
  }

  func isInCrate(_ track: LofiTrack) -> Bool {
    crate.contains { $0.videoId == track.videoId }
  }

  @discardableResult
  func toggleCrate(_ track: LofiTrack) -> Bool {
    if let i = crate.firstIndex(where: { $0.videoId == track.videoId }) {
      crate.remove(at: i)
      status = "dropped from crate"
      writeCrate()
      return false
    }
    crate.insert(track, at: 0)
    crate = Array(crate.prefix(120))
    status = "saved to crate ♥"
    writeCrate()
    return true
  }

  private func writeCrate() {
    guard let url = Self.crateURL else { return }
    if let data = try? JSONEncoder().encode(crate) { try? data.write(to: url, options: .atomic) }
    config.crate = crate.map(\.videoId)
  }

  /// Exposed because StreamLoader is an actor and views shouldn't own one.
  func clearAudioCache() async {
    await loader.clearCache()
    status = "audio cache cleared"
  }

  func cacheSize() async -> Int64 {
    await loader.cacheBytes()
  }

  func playFromCrate(_ track: LofiTrack) async {
    pool = [track] + pool
    poolCursor = 0
    await hunt(reason: "crate")
  }

  // MARK: - Search

  func runSearch(query: String, mood: String?) async -> LofiSearchResults {
    busy = true
    status = "hunting “\(query)”…"
    let results = await provider.hunt(query: query, mood: mood, limit: 24)
    lastHunt = results
    rejectedRecently = results.rejected
    pool = results.accepted.filter { !seen.contains($0.videoId) }
    poolCursor = 0
    busy = false
    status = "\(results.accepted.count) lofi · \(results.rejected.count) rejected · \(results.origin)"
    if !pool.isEmpty { await hunt(reason: "from-search") }
    return results
  }

  // MARK: - Sleep timer

  func setSleepTimer(minutes: Int) {
    sleepTask?.cancel()
    guard minutes > 0 else {
      status = "sleep timer off"
      return
    }
    status = "sleep timer · \(minutes)m"
    sleepTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000)
      guard !Task.isCancelled else { return }
      await self?.fadeAndPause()
    }
  }

  private func fadeAndPause() async {
    // ~3 s fade instead of a hard stop, because waking to silence is jarring.
    let start = config.boost.output
    let steps = 24
    for i in 1...steps {
      var s = config.boost
      s.output = max(0, start * (1 - Double(i) / Double(steps)))
      config.boost = s
      try? await Task.sleep(nanoseconds: 120_000_000)
    }
    pause()
    var back = config.boost
    back.output = start
    config.boost = back
    status = "sleep timer done · volume restored"
  }
}
