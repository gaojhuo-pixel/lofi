import SwiftUI

// MARK: - Boost
//
// The VLC slider, ported: 0 dB is unity, the handle keeps going to +12 dB, and a
// limiter keeps that from turning into fuzz. Everything here writes straight into
// AppConfig.boost, which AppState forwards to AudioBoostEngine.

struct BoostSheet: View {
  @EnvironmentObject private var app: AppState
  @EnvironmentObject private var config: AppConfig
  @Environment(\.dismiss) private var dismiss

  @State private var rate: Double = 1.0

  var body: some View {
    ZStack {
      Y2K.voidBackdrop.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          header
          gainBlock
          meterBlock
          presetBlock
          eqBlock
          guardBlock
          rateBlock
          routeNote
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 24)
      }
    }
    .onAppear { rate = Double(app.engine.rate) }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 0) {
        Text(String(format: "%+.1f dB", config.boost.db))
          .font(Y2K.pixel(46))
          .foregroundStyle(.white)
          .neon(config.boost.db > 0 ? Y2K.lime : Y2K.cyan, radius: 14)
          .contentTransition(.value)
          .animation(.spring(duration: 0.25), value: config.boost.db)
        Text(app.boostCaption)
          .font(Y2K.pixel(15))
          .tracking(2)
          .foregroundStyle(config.boost.db > 0 ? Y2K.lime : Y2K.inkDim)
      }
      Spacer()
      Button { dismiss() } label: {
        Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
      }
      .buttonStyle(.borderless)
    }
    .padding(.top, 8)
  }

  // MARK: The slider

  private var gainBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      SectionHeader("boost · pre-gain")
      Slider(
        value: Binding(get: { config.boost.db }, set: { config.boost.db = $0 }),
        in: BoostSettings.minDb...BoostSettings.maxDb,
        step: 0.5
      ) {
        Text("Boost")
      } minimumValueLabel: {
        Text("−12").font(Y2K.pixel(14)).foregroundStyle(Y2K.inkDim)
      } maximumValueLabel: {
        Text("+12").font(Y2K.pixel(14)).foregroundStyle(Y2K.pink)
      }
      .tint(config.boost.db > 0 ? Y2K.pink : Y2K.cyan)

      HStack {
        Text("unity 0 dB · 4× amplitude at +12").font(Y2K.pixel(12)).foregroundStyle(Y2K.inkDim)
        Spacer()
        Text(String(format: "%.2f× linear", AudioBoostEngine.linear(for: config.boost.db)))
          .font(Y2K.pixel(14))
          .foregroundStyle(Y2K.butter)
      }
    }
    .padding(12)
    .lofiGlass(corner: Y2K.cornerM, tint: config.boost.db > 0 ? .pink : .clear)
  }

  // MARK: Meter

  private var meterBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionHeader("output")
      BoostMeter(
        level: max(0, min(1, (app.meter.rmsDb + 60) / 60)),
        reductionDb: app.meter.gainReductionDb,
        clipping: app.meter.clipping
      )
      HStack {
        Label(String(format: "%.1f dBFS rms", app.meter.rmsDb), systemImage: "waveform")
        Spacer()
        if abs(app.meter.gainReductionDb) > 0.15 {
          Label(String(format: "limiter −%.1f dB", abs(app.meter.gainReductionDb)), systemImage: "shield.lefthalf.filled")
            .foregroundStyle(Y2K.lime)
        }
        Label(String(format: "%.1f / %.1f dB", app.meter.deliveredDb, app.meter.requestedDb), systemImage: "scalemass")
      }
      .font(Y2K.pixel(13))
      .foregroundStyle(Y2K.inkDim)

      Slider(
        value: Binding(get: { config.boost.output }, set: { config.boost.output = $0 }),
        in: 0...1
      ) {
        Text("Output")
      } minimumValueLabel: {
        Image(systemName: "speaker.fill").font(.system(size: 10))
      } maximumValueLabel: {
        Image(systemName: "speaker.wave.3.fill").font(.system(size: 10))
      }
      .tint(Y2K.butter)
    }
    .padding(12)
    .lofiGlass(corner: Y2K.cornerM, tint: .clear)
  }

  // MARK: Presets

  private var presetBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionHeader("presets")
      FlowLayout(spacing: 7) {
        ForEach(Preset.allCases) { preset in
          Button {
            app.setPreset(preset)
          } label: {
            Text(preset.rawValue)
              .font(Y2K.pixel(15))
              .padding(.horizontal, 4)
          }
          .buttonStyle(GlassChipButtonStyle())
          .overlay(alignment: .topTrailing) {
            if config.boost.preset == preset.rawValue {
              Circle().fill(Y2K.lime).frame(width: 5, height: 5).offset(x: 2, y: -2).neon(Y2K.lime, radius: 5)
            }
          }
        }
      }
    }
    .padding(12)
    .lofiGlass(corner: Y2K.cornerM, tint: .clear)
  }

  // MARK: EQ

  private var eqBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("equaliser")
      eqRow("low shelf · 130hz", \.lowShelfDb)
      eqRow("mid peak · 900hz", \.midPeakDb)
      eqRow("high shelf · 3.6khz", \.highShelfDb)
      Button {
        var s = config.boost
        s.lowShelfDb = 0
        s.midPeakDb = 0
        s.highShelfDb = 0
        s.db = 0
        s.preset = Preset.flat.rawValue
        config.boost = s
      } label: {
        Text("reset everything").font(Y2K.pixel(15)).frame(maxWidth: .infinity).padding(.vertical, 6)
      }
      .lofiGlassButton()
    }
    .padding(12)
    .lofiGlass(corner: Y2K.cornerM, tint: .clear)
  }

  private func eqRow(_ label: String, _ keyPath: WritableKeyPath<BoostSettings, Double>) -> some View {
    HStack(spacing: 8) {
      Text(label).font(Y2K.pixel(13)).foregroundStyle(Y2K.inkDim).frame(width: 118, alignment: .leading)
      Slider(
        value: Binding(
          get: { config.boost[keyPath: keyPath] },
          set: {
            var s = config.boost
            s[keyPath: keyPath] = $0
            s.preset = ""
            config.boost = s
          }
        ),
        in: -6...6,
        step: 0.5
      )
      .tint(Y2K.cyan)
      Text(String(format: "%+.1f", config.boost[keyPath: keyPath]))
        .font(Y2K.pixel(15))
        .foregroundStyle(Y2K.butter)
        .frame(width: 44, alignment: .trailing)
    }
  }

  // MARK: Guards

  private var guardBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader("clipping guards")
      Toggle(isOn: Binding(get: { config.boost.limiterEnabled }, set: {
        var s = config.boost
        s.limiterEnabled = $0
        config.boost = s
      })) {
        VStack(alignment: .leading, spacing: 1) {
          Text("limiter").font(Y2K.pixel(16))
          Text("pulls the +dB back when peaks near full scale — same job as VLC's volume-maximum switch")
            .font(Y2K.body(10.5))
            .foregroundStyle(Y2K.inkDim)
        }
      }
      .tint(Y2K.lime)

      Toggle(isOn: Binding(get: { config.boost.softClipEnabled }, set: {
        var s = config.boost
        s.softClipEnabled = $0
        config.boost = s
      })) {
        VStack(alignment: .leading, spacing: 1) {
          Text("soft clip").font(Y2K.pixel(16))
          Text("tanh curve on the tops of transients, so a boosted snare knocks instead of crackling")
            .font(Y2K.body(10.5))
            .foregroundStyle(Y2K.inkDim)
        }
      }
      .tint(Y2K.pink)
    }
    .toggleStyle(.switch)
    .padding(12)
    .lofiGlass(corner: Y2K.cornerM, tint: config.boost.limiterEnabled ? .lime : .clear)
  }

  // MARK: Rate

  private var rateBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionHeader("slowed")
      HStack {
        Button { app.setRate(0.85); rate = 0.85 } label: { Text("0.85×").font(Y2K.pixel(15)).frame(maxWidth: .infinity).padding(.vertical, 6) }
          .lofiGlassButton()
        Button { app.setRate(1.0); rate = 1.0 } label: { Text("1.00×").font(Y2K.pixel(15)).frame(maxWidth: .infinity).padding(.vertical, 6) }
          .lofiGlassButton()
        Button { app.setRate(1.15); rate = 1.15 } label: { Text("1.15×").font(Y2K.pixel(15)).frame(maxWidth: .infinity).padding(.vertical, 6) }
          .lofiGlassButton()
      }
      Slider(value: Binding(get: { rate }, set: { rate = $0; app.setRate(Float($0)) }), in: 0.7...1.3)
        .tint(Y2K.butter)
      Text("varispeed only — pitch holds, tempo moves. 0.85× is the classic misheard-tape sound.")
        .font(Y2K.body(10.5))
        .foregroundStyle(Y2K.inkDim)
    }
    .padding(12)
    .lofiGlass(corner: Y2K.cornerM, tint: .clear)
  }

  // MARK: Route honesty

  private var routeNote: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("where the gain actually lands")
      Text(config.routeWarning)
        .font(Y2K.body(11.5))
        .foregroundStyle(Y2K.ink.opacity(0.9))
      Button {
        config.route = config.route == .boostedLocal ? .embedded : .boostedLocal
        Task { await app.reroute() }
      } label: {
        Text(config.route == .boostedLocal ? "switch to youtube embed" : "switch to local boost engine")
          .font(Y2K.pixel(16))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
      .lofiGlassButton()
      Text(
        config.route == .boostedLocal
          ? "audio is decoded through AVAudioEngine: EQ → +12 dB mixer → varispeed → soft clip → limiter tap. what you dial is what plays."
          : "youtube's player owns the audio path, so the slider maps onto its 0…100 volume and the +dB half reports as armed. honest, not magic."
      )
      .font(Y2K.pixel(12))
      .foregroundStyle(Y2K.inkDim)
    }
    .padding(12)
    .lofiGlass(corner: Y2K.cornerM, tint: config.route == .boostedLocal ? .lime : .chrome)
  }
}
