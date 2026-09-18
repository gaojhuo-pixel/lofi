import AVFoundation
import Foundation

// MARK: - Audio boost, the iOS way
//
// VLC on Windows gets past 100% with one trick: a pre-gain in front of a
// limiter. AVAudioEngine has the same three ingredients, so the graph is:
//
//   playerNode → EQ(4 bands) → booster(+12 dB mixer) → varispeed → softClip → mainMixer → output
//                                   ↑                                                    │
//                                   └────────── AdaptiveLimiter (render tap) ←───────────┘
//
// There is no compressor/limiter AVAudioUnit on iOS (that's macOS), so the
// ceiling is done the honest way: a tap after the booster measures peak, and
// when peaks approach full scale the booster's own volume is pulled down with a
// timed release. Same feedback loop as hardware, ~60 lines of Swift.

final class AudioBoostEngine {
  enum EngineError: LocalizedError {
    case cannotOpenFile(String)
    case incompatibleFormat(String)
    case engineFailed(String)
    case sessionFailed(String)

    var errorDescription: String? {
      switch self {
      case .cannotOpenFile(let why): return "can't open that audio · \(why)"
      case .incompatibleFormat(let why): return "format won't decode · \(why)"
      case .engineFailed(let why): return "audio engine said no · \(why)"
      case .sessionFailed(let why): return "audio session refused · \(why)"
      }
    }
  }

  struct Metering: Equatable {
    var rmsDb: Double = -80
    var peakDb: Double = -80
    var gainReductionDb: Double = 0
    var clipping: Bool = false
    var requestedDb: Double = 0
    var deliveredDb: Double = 0
  }

  /// Boost ceiling. +12 dB ≈ 4× amplitude, which is where VLC's slider stops.
  static let maxLinearBoost = 4.0

  let engine = AVAudioEngine()
  let player = AVAudioPlayerNode()
  let eq = AVAudioUnitEQ(numberOfBands: 4)
  let booster = AVAudioMixerNode()
  let varispeed = AVAudioUnitVarispeed()
  let softClip = AVAudioUnitDistortionNode()

  /// Latest requested settings, copied in on the render thread.
  private struct Snapshot {
    var boostDb = 0.0
    var limiter = true
    var output = 0.85
  }

  private let lock = NSLock()
  private var snapshot = Snapshot()
  private let limiterNode = AdaptiveLimiter()

  private(set) var file: AVAudioFile?
  private(set) var fileURL: URL?
  private(set) var isLoaded = false
  private var playOriginFilePos: AVAudioFramePosition = 0
  private var playStartClock: TimeInterval?
  private var pausedPosition: TimeInterval = 0
  private var lookAheadChunks = 4
  private var scheduledChunks = 0
  private var looping = true
  private var format: AVAudioFormat?
  private let chunkFrames: AVAudioFrameCount = 16_384

  var onMeter: ((Metering) -> Void)?
  var onTrackEnd: (() -> Void)?

  var settings = BoostSettings() {
    didSet { applySettings() }
  }

  // MARK: - Init

  init() {
    configureEQ()
    // Soft clip is a *guard*, not a sound: pick the gentlest preset so it only
    // bends the very tops of transients when you push past +6 dB.
    softClip.preset = .sloppyCrunch
    softClip.enableBypass = true
    softClip.bypass = true
    booster.outputVolume = 1
    engine.mainMixerNode.outputVolume = 0.85

    for node in [player, eq, booster, varispeed, softClip] as [AVAudioNode] {
      engine.attach(node)
    }
  }

  private func configureEQ() {
    // band 0: highpass — kills rumble on rain/ambience tracks
    eq.bands[0].filterType = .highPass
    eq.bands[0].frequency = 24
    eq.bands[0].bypass = false
    // band 1: low shelf — "tape warm"
    eq.bands[1].filterType = .lowShelf
    eq.bands[1].frequency = 130
    eq.bands[1].bypass = false
    // band 2: parametric — mud / presence
    eq.bands[2].filterType = .parametric
    eq.bands[2].frequency = 900
    eq.bands[2].bandwidth = 0.9
    eq.bands[2].bypass = false
    // band 3: high shelf — air / rain hiss
    eq.bands[3].filterType = .highShelf
    eq.bands[3].frequency = 3600
    eq.bands[3].bypass = false
    eq.bypass = false
  }

  // MARK: - Session

  @discardableResult
  func activateSession() -> Bool {
    let session = AVAudioSession.sharedInstance()
    do {
      // .playback keeps the deck going with the silent switch on; .measurement
      // turns off the system's own EQ so +12 dB means +12 dB.
      try session.setCategory(.playback, mode: .measurement, options: [])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      return true
    } catch {
      NSLog("lofi.glass: audio session refused — %@", error.localizedDescription)
      return false
    }
  }

  // MARK: - Loading

  /// AVAudioFile is the only sane way to feed AVAudioPlayerNode: it decodes
  /// m4a/mp3/wav/caf lazily from disk, which matters for 6-hour mixes.
  func load(url: URL) throws {
    let next: AVAudioFile
    do {
      next = try AVAudioFile(forReading: url)
    } catch {
      throw EngineError.cannotOpenFile(error.localizedDescription)
    }
    let processing = next.processingFormat
    guard processing.sampleRate > 0, processing.channelCount > 0 else {
      throw EngineError.incompatibleFormat(next.fileFormat.description)
    }

    stop()
    file = next
    fileURL = url
    format = processing
    playOriginFilePos = 0
    pausedPosition = 0

    wire(format: processing)
    engine.prepare()
    if !engine.isRunning {
      do { try engine.start() } catch { throw EngineError.engineFailed(error.localizedDescription) }
    }
    isLoaded = true
    applySettings()
  }

  private func wire(format: AVAudioFormat) {
    for node in [player, eq, booster, varispeed] as [AVAudioNode] {
      engine.disconnectNodeOutput(node)
    }
    engine.connect(player, to: eq, format: format)
    engine.connect(eq, to: booster, format: format)
    engine.connect(booster, to: varispeed, format: format)
    engine.connect(varispeed, to: softClip, format: format)
    engine.connect(softClip, to: engine.mainMixerNode, format: format)
    installMeteringAndLimiting(format: format)
  }

  /// The tap sits on varispeed's *input*, i.e. immediately after the booster:
  /// that is the exact signal a clipper must see.
  private func installMeteringAndLimiting(format: AVAudioFormat) {
    varispeed.removeTap(onBus: 0)
    varispeed.installTap(onBus: 0, bufferSize: chunkFrames, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      self.lock.lock()
      let snap = self.snapshot
      self.lock.unlock()

      let ceiling = snap.limiter ? -1.0 : 0.0
      let reading = self.limiterNode.process(buffer: buffer, ceilingDb: ceiling, enabled: snap.limiter)

      let wanted = Self.linear(for: snap.boostDb)
      let delivered = max(0, wanted * pow(10, -reading.reductionDb / 20))
      // Writing outputVolume from a render thread is the documented way to make
      // a mixer act as a ducking stage; it's a single atomic float set.
      self.booster.outputVolume = Float(delivered)

      let meter = Metering(
        rmsDb: reading.rmsDb,
        peakDb: reading.peakDb,
        gainReductionDb: reading.reductionDb,
        clipping: reading.peakDb > -0.1,
        requestedDb: snap.boostDb,
        deliveredDb: 20 * log10(max(1e-5, delivered))
      )
      DispatchQueue.main.async { self.onMeter?(meter) }
    }
  }

  static func linear(for db: Double) -> Double {
    min(maxLinearBoost, max(0, pow(10, db / 20)))
  }

  static func db(forLinear linear: Double) -> Double {
    20 * log10(max(1e-5, linear))
  }

  // MARK: - Settings

  private func applySettings() {
    lock.lock()
    snapshot.boostDb = min(BoostSettings.maxDb, max(BoostSettings.minDb, settings.db))
    snapshot.limiter = settings.limiterEnabled
    snapshot.output = min(1, max(0, settings.output))
    lock.unlock()

    eq.bands[1].gain = Float(max(-24, min(24, settings.lowShelfDb)))
    eq.bands[2].gain = Float(max(-24, min(24, settings.midPeakDb)))
    eq.bands[3].gain = Float(max(-24, min(24, settings.highShelfDb)))
    softClip.bypass = !settings.softClipEnabled
    engine.mainMixerNode.outputVolume = Float(snapshot.output)
    limiterNode.enabled = settings.limiterEnabled
    booster.outputVolume = Float(Self.linear(for: snapshot.boostDb))
    if !player.isPlaying { limiterNode.reset() }
  }

  // MARK: - Transport

  func play(from seconds: TimeInterval? = nil) {
    guard let file, let format else { return }
    let startSecond = max(0, min(seconds ?? pausedPosition, max(0, duration)))
    let startFrame = AVAudioFramePosition(startSecond * format.sampleRate)
    playOriginFilePos = startFrame
    do { try file.seek(toFrame: startFrame) } catch {
      NSLog("lofi.glass: seek failed — %@", error.localizedDescription)
    }
    player.reset()
    scheduledChunks = 0
    fillLookAhead()
    player.play()
    playStartClock = Date().timeIntervalSinceReferenceDate
    pausedPosition = startSecond
  }

  func pause() {
    pausedPosition = position
    player.pause()
    playStartClock = nil
  }

  func togglePlayback() {
    player.isPlaying ? pause() : play()
  }

  func stop() {
    player.stop()
    playStartClock = nil
    scheduledChunks = 0
  }

  func seek(to seconds: TimeInterval) {
    if player.isPlaying { play(from: seconds) } else { pausedPosition = max(0, seconds) }
  }

  var isPlaying: Bool { player.isPlaying }

  var duration: TimeInterval {
    guard let file else { return 0 }
    return Double(file.length) / max(1, file.processingFormat.sampleRate)
  }

  var position: TimeInterval {
    guard let format else { return pausedPosition }
    if player.isPlaying, let started = playStartClock {
      let elapsed = (Date().timeIntervalSinceReferenceDate - started) * Double(varispeed.rate)
      return min(duration, max(0, Double(playOriginFilePos) / format.sampleRate + elapsed))
    }
    return pausedPosition
  }

  var currentFileURL: URL? { fileURL }

  // MARK: - The chunk scheduler
  //
  // AVAudioFile is read in fixed quanta and kept ~4 chunks ahead of the playhead.
  // A 6-hour mix therefore streams from disk in constant memory, and seeking is
  // just "drop the queue and read from a new frame".

  private func fillLookAhead() {
    guard let file, let format else { return }
    while scheduledChunks < lookAheadChunks {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return }
      do {
        try file.read(buffer)
      } catch {
        NSLog("lofi.glass: read error — %@", error.localizedDescription)
        return
      }
      if buffer.frameLength == 0 {
        if looping {
          do { try file.seek(toFrame: 0) } catch { return }
          continue
        }
        if scheduledChunks == 0 { onTrackEnd?() }
        return
      }
      scheduledChunks += 1
      player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
        DispatchQueue.main.async {
          guard let self else { return }
          self.scheduledChunks = max(0, self.scheduledChunks - 1)
          if self.player.isPlaying { self.fillLookAhead() }
        }
      })
    }
  }

  /// 0.75…1.25 — "slowed" is half of lofi's vocabulary. Rate only; pitch stays.
  func setRate(_ rate: Float) {
    varispeed.rate = max(0.5, min(2.0, rate))
  }

  var rate: Float { varispeed.rate }
  var loopingEnabled: Bool {
    get { looping }
    set { looping = newValue }
  }
}

// MARK: - Adaptive limiter

/// Peak-sensing ducking stage. Fast attack (immediate pull), timed release, and
/// it reports the reduction so the UI can show the limiter working, like VLC's
/// "volume safety" feedback.
final class AdaptiveLimiter {
  var enabled = true
  var releaseDbPerSecond: Double = 6
  var maxReductionDb: Double = 18
  private(set) var reductionDb: Double = 0

  struct Reading {
    var rmsDb: Double
    var peakDb: Double
    var reductionDb: Double
  }

  func reset() { reductionDb = 0 }

  func process(buffer: AVAudioPCMBuffer, ceilingDb: Double, enabled: Bool) -> Reading {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else {
      return Reading(rmsDb: -80, peakDb: -80, reductionDb: reductionDb)
    }
    let channels = min(2, Int(buffer.format.channelCount))
    let frames = Int(buffer.frameLength)
    var peak: Float = 0
    var sum: Float = 0
    var counted = 0

    // Stride over the buffer: a meter + slow ducking stage does not need every
    // sample, and skipping 3 of 4 quarters cuts the tap's CPU to noise.
    for ch in 0..<channels {
      let ptr = data[ch]
      var i = 0
      while i < frames {
        let v = abs(ptr[i])
        if v > peak { peak = v }
        sum += v * v
        counted += 1
        i += 4
      }
    }
    let rms = counted > 0 ? sqrt(sum / Float(counted)) : 0
    let peakDb = 20 * log10(max(1e-7, Double(peak)))
    let rmsDb = 20 * log10(max(1e-7, Double(rms)))

    if enabled {
      let over = peakDb - ceilingDb
      if over > 0 {
        reductionDb = min(maxReductionDb, reductionDb + over)
      } else {
        let seconds = Double(frames) / max(1, buffer.format.sampleRate)
        reductionDb = max(0, reductionDb - releaseDbPerSecond * seconds)
      }
    } else {
      reductionDb = 0
    }
    return Reading(rmsDb: rmsDb, peakDb: peakDb, reductionDb: reductionDb)
  }
}
