import AVFoundation
import XCTest
@testable import LofiGlass

/// The math and the graph-level decisions, without needing a device speaker.
final class AudioBoostEngineTests: XCTestCase {
  func test_db_maps_to_vlc_like_linear_gains() {
    XCTAssertEqual(AudioBoostEngine.linear(for: 0), 1.0, accuracy: 0.0001)
    XCTAssertEqual(AudioBoostEngine.linear(for: 6), 1.9953, accuracy: 0.01)
    XCTAssertEqual(AudioBoostEngine.linear(for: 12), AudioBoostEngine.maxLinearBoost, accuracy: 0.01)
    XCTAssertEqual(AudioBoostEngine.linear(for: -12), 0.2512, accuracy: 0.01)
    // Past the ceiling we clamp instead of letting the caller square the wave.
    XCTAssertEqual(AudioBoostEngine.linear(for: 30), AudioBoostEngine.maxLinearBoost, accuracy: 0.001)
  }

  func test_round_trip_db_to_linear_to_db() {
    for db in stride(from: -12.0, through: 12.0, by: 1.5) {
      XCTAssertEqual(AudioBoostEngine.db(forLinear: AudioBoostEngine.linear(for: db)), db, accuracy: 0.02)
    }
  }

  func test_settings_window_is_the_same_range_as_the_ui() {
    XCTAssertEqual(BoostSettings.minDb, -12)
    XCTAssertEqual(BoostSettings.maxDb, 12)
    XCTAssertEqual(BoostSettings().db, 0, "default is unity, never a surprise")
    XCTAssertTrue(BoostSettings().limiterEnabled, "limiter ships on")
  }

  func test_system_volume_mapping_is_monotonic_and_in_range() {
    var previous = -1
    for db in stride(from: BoostSettings.minDb, through: BoostSettings.maxDb, by: 0.5) {
      var s = BoostSettings()
      s.db = db
      let pct = s.systemVolumePercent
      XCTAssertTrue((0...100).contains(pct), "player volume out of range at \(db) dB")
      XCTAssertGreaterThanOrEqual(pct, previous, "volume must never fall as you raise the boost")
      previous = pct
    }
    var zero = BoostSettings(); zero.db = 0
    var max = BoostSettings(); max.db = 12
    XCTAssertLessThan(zero.systemVolumePercent, max.systemVolumePercent)
  }

  func test_presets_move_the_eq_and_the_limiter() {
    var s = BoostSettings()
    Preset.bassHead.applied(to: &s)
    XCTAssertGreaterThan(s.lowShelfDb, 4)
    XCTAssertEqual(s.preset, Preset.bassHead.rawValue)
    XCTAssertTrue(s.limiterEnabled)

    Preset.night.applied(to: &s)
    XCTAssertFalse(s.limiterEnabled, "the 3am preset is the deliberate no-limiter one")
    XCTAssertEqual(s.preset, Preset.night.rawValue)
  }

  // MARK: Limiter behaviour

  func test_limiter_pulls_gain_when_peaks_exceed_the_ceiling() {
    let limiter = AdaptiveLimiter()
    limiter.enabled = true
    let buffer = Self.buffer(peak: 1.0, frames: 4096)
    let reading = limiter.process(buffer: buffer, ceilingDb: -1, enabled: true)
    XCTAssertGreaterThan(reading.peakDb, -1, "test buffer must actually be hot")
    // 0 dBFS against a −1 dB ceiling is 1 dB of overshoot, so that is the pull.
    XCTAssertGreaterThan(limiter.reductionDb, 0.5, "a hot buffer must produce reduction")
    XCTAssertLessThanOrEqual(limiter.reductionDb, limiter.maxReductionDb)
  }

  func test_limiter_releases_back_to_zero_on_quiet_audio() {
    let limiter = AdaptiveLimiter()
    limiter.enabled = true
    _ = limiter.process(buffer: Self.buffer(peak: 1.0, frames: 4096), ceilingDb: -1, enabled: true)
    let before = limiter.reductionDb
    for _ in 0..<6 {
      _ = limiter.process(buffer: Self.buffer(peak: 0.02, frames: 4096), ceilingDb: -1, enabled: true)
    }
    XCTAssertLessThan(limiter.reductionDb, before, "reduction must decay when the signal calms down")
  }

  func test_disabled_limiter_reports_no_reduction() {
    let limiter = AdaptiveLimiter()
    limiter.enabled = false
    _ = limiter.process(buffer: Self.buffer(peak: 1.0, frames: 2048), ceilingDb: -1, enabled: false)
    XCTAssertEqual(limiter.reductionDb, 0)
  }

  func test_metering_reads_the_buffer_it_was_given() {
    let limiter = AdaptiveLimiter()
    let quiet = limiter.process(buffer: Self.buffer(peak: 0.1, frames: 2048), ceilingDb: 0.5, enabled: true)
    let loud = limiter.process(buffer: Self.buffer(peak: 0.99, frames: 2048), ceilingDb: 0.5, enabled: true)
    XCTAssertGreaterThan(loud.peakDb, quiet.peakDb)
    XCTAssertGreaterThan(loud.rmsDb, quiet.rmsDb)
  }

  func test_engine_graph_is_assembled_before_any_file_loads() {
    let engine = AudioBoostEngine()
    // Three EQ bands carry the tone controls + one highpass for rumble.
    XCTAssertEqual(engine.eq.bands.count, 4)
    XCTAssertEqual(engine.eq.bands[1].filterType, .lowShelf)
    XCTAssertEqual(engine.eq.bands[2].filterType, .parametric)
    XCTAssertEqual(engine.eq.bands[3].filterType, .highShelf)
    XCTAssertEqual(engine.booster.outputVolume, 1, accuracy: 0.001, "booster starts at unity")
    // Applying a wild setting must not produce a wild gain.
    engine.settings = { var s = BoostSettings(); s.db = 99; return s }()
    XCTAssertLessThanOrEqual(Double(engine.booster.outputVolume), AudioBoostEngine.maxLinearBoost + 0.001)
  }

  func test_settings_clamp_instead_of_trusting_the_ui() {
    let engine = AudioBoostEngine()
    var s = BoostSettings()
    s.db = -40
    s.lowShelfDb = 90
    engine.settings = s
    XCTAssertEqual(
      Double(engine.booster.outputVolume),
      AudioBoostEngine.linear(for: BoostSettings.minDb),
      accuracy: 0.001,
      "out-of-range requests land on the window edge, not below it"
    )
    XCTAssertTrue(engine.eq.bands[1].gain <= 24, "EQ gain must clamp to the unit's range")
  }

  // MARK: Helpers

  private static func buffer(peak: Float, frames: Int) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channelCount: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(format.channelCount) {
      let data = buffer.floatChannelData![channel]
      for i in 0..<frames { data[i] = (i % 2 == 0 ? peak : -peak) * (i % 7 == 0 ? 1 : 0.6) }
    }
    return buffer
  }
}
