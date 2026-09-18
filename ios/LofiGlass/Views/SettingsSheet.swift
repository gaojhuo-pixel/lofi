import SwiftUI

// MARK: - Settings
//
// Where the tradeoffs get made, in the open: which source feeds metadata, how
// audio is routed, how strict the lofi gate is. Nothing here is hidden behind a
// default that "just works" without telling you what it did.

struct SettingsSheet: View {
  @EnvironmentObject private var config: AppConfig
  @EnvironmentObject private var app: AppState
  @Environment(\.dismiss) private var dismiss

  @State private var cacheBytes: Int64 = 0
  @State private var probe: String = ""
  @State private var probing = false

  var body: some View {
    ZStack {
      Y2K.voidBackdrop.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text("source & feel").font(Y2K.display(12)).foregroundStyle(Y2K.chrome)
            Spacer()
            Button { dismiss() } label: {
              Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.borderless)
          }
          .padding(.top, 8)

          sourceBlock
          gateBlock
          lookBlock
          storageBlock
          legalBlock
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 26)
      }
    }
    .task { cacheBytes = await app.cacheSize() }
  }

  // MARK: Source

  private var sourceBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader("metadata source")
      Picker("", selection: $config.source) {
        ForEach(AppConfig.MetadataSource.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)

      if config.source.needsKey {
        SecureField("youtube data api key", text: $config.apiKey)
          .font(Y2K.pixel(15))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))
        Text(config.hasUsableKey ? "key present · quota 10 000 units/day · search + videos + commentThreads" : "no key yet · 100 units per search, 1 per comment page")
          .font(Y2K.pixel(12))
          .foregroundStyle(config.hasUsableKey ? Y2K.lime : Y2K.butter)
      }

      if config.source != .seed {
        SectionHeader("piped mirrors")
        TextField("hosts, comma separated · blank = built-in rotation", text: $config.pipedHosts)
          .font(Y2K.pixel(13))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .padding(9)
          .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))
        Text("tried in order · " + config.pipedHostList.joined(separator: " → "))
          .font(Y2K.pixel(11))
          .foregroundStyle(Y2K.inkDim)
          .lineLimit(2)
      }

      if config.source != .seed {
        Button { probeSource() } label: {
          HStack {
            Text(probing ? "probing…" : "probe mirrors now")
              .font(Y2K.pixel(16))
            Spacer()
            Text(probe).font(Y2K.pixel(12)).foregroundStyle(Y2K.inkDim).lineLimit(1)
          }
          .padding(.vertical, 7)
          .padding(.horizontal, 10)
        }
        .lofiGlassButton()
      }

      SectionHeader("playback route")
      Picker("", selection: $config.route) {
        ForEach(AppConfig.PlaybackRoute.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      Text(config.routeWarning).font(Y2K.pixel(12)).foregroundStyle(Y2K.inkDim)

      if config.route == .boostedLocal {
        TextField("resolver base url · https://lofi.example.com", text: $config.resolverBase)
          .font(Y2K.pixel(14))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        SecureField("resolver bearer token (optional)", text: $config.resolverToken)
          .font(Y2K.pixel(14))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Text("the resolver contract · GET <base>/resolve?videoId=… → {\"url\": \"https://…\"} · your server, your terms")
          .font(Y2K.pixel(11))
          .foregroundStyle(Y2K.inkDim)
      }
    }
    .textFieldStyle(.plain)
    .padding(12)
    .lofiGlass(corner: Y2K.cornerL, tint: .clear)
  }

  private func probeSource() {
    probing = true
    Task {
      let results = await app.runSearch(query: "lofi hip hop", mood: nil)
      await MainActor.run {
        probe = "\(results.origin) · \(results.accepted.count) in / \(results.rejected.count) out"
        probing = false
      }
    }
  }

  // MARK: Gate

  private var gateBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("lofi gate")
      Toggle(isOn: $config.gateEnabled) {
        VStack(alignment: .leading, spacing: 1) {
          Text("only lofi").font(Y2K.pixel(16))
          Text("score a video's title, description and hashtags · drop anything under the line")
            .font(Y2K.body(10.5))
            .foregroundStyle(Y2K.inkDim)
        }
      }
      .tint(Y2K.lime)

      if config.gateEnabled {
        HStack {
          Text("strictness").font(Y2K.pixel(13)).foregroundStyle(Y2K.inkDim)
          Slider(value: $config.gateThreshold, in: LofiFilter.threshold...9, step: 0.5)
            .tint(Y2K.pink)
          Text(String(format: "%.1f", config.gateThreshold)).font(Y2K.pixel(15)).foregroundStyle(Y2K.butter)
        }
        Text("4 catches most lofi · 6.5 wants an explicit lofi/chillhop signal · 9 only the obvious ones")
          .font(Y2K.pixel(11))
          .foregroundStyle(Y2K.inkDim)
      }

      if !app.rejectedRecently.isEmpty {
        Text("recently rejected").font(Y2K.pixel(13)).foregroundStyle(Y2K.pink)
        ForEach(app.rejectedRecently.prefix(4)) { track in
          HStack(alignment: .top, spacing: 6) {
            Text(String(format: "%.1f", track.gate?.score ?? 0)).font(Y2K.pixel(14)).foregroundStyle(Y2K.pink).frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
              Text(track.title).font(Y2K.body(11.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
              Text(track.gate.map { $0.explain } ?? "no lofi signal").font(Y2K.pixel(11)).foregroundStyle(Y2K.inkDim).lineLimit(2)
            }
          }
          .padding(7)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.28)))
        }
      }
    }
    .toggleStyle(.switch)
    .padding(12)
    .lofiGlass(corner: Y2K.cornerL, tint: config.gateEnabled ? .pink : .clear)
  }

  // MARK: Look

  private var lookBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("look")
      Toggle(isOn: $config.scanlines) { Text("crt scanlines").font(Y2K.pixel(16)) }
      Toggle(isOn: $config.refraction) { Text("glass refraction (ios 26)").font(Y2K.pixel(16)) }
      Toggle(isOn: $config.autoplayOnSwipe) { Text("autoplay on swipe").font(Y2K.pixel(16)) }
      Toggle(isOn: $config.radioMode) { Text("endless radio · re-query on every swipe").font(Y2K.pixel(16)) }
      HStack {
        Text("sleep timer").font(Y2K.pixel(16))
        Spacer()
        Stepper(value: $config.sleepTimerMinutes, in: 0...240, step: 15) {
          Text(config.sleepTimerMinutes == 0 ? "off" : "\(config.sleepTimerMinutes)m").font(Y2K.pixel(16)).foregroundStyle(Y2K.butter)
        }
      }
      if config.sleepTimerMinutes > 0 {
        Button { app.setSleepTimer(minutes: config.sleepTimerMinutes) } label: {
          Text("arm timer").font(Y2K.pixel(15)).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .lofiGlassButton()
      }
    }
    .toggleStyle(.switch)
    .tint(Y2K.cyan)
    .padding(12)
    .lofiGlass(corner: Y2K.cornerL, tint: .clear)
  }

  // MARK: Storage

  private var storageBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("audio cache")
      Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file) + " of resolved streams (only used by the local boost route)")
        .font(Y2K.pixel(13))
        .foregroundStyle(Y2K.inkDim)
      Button {
        Task {
          await app.clearAudioCache()
          cacheBytes = await app.cacheSize()
        }
      } label: {
        Text("clear cache").font(Y2K.pixel(15)).frame(maxWidth: .infinity).padding(.vertical, 6)
      }
      .lofiGlassButton()
    }
    .padding(12)
    .lofiGlass(corner: Y2K.cornerL, tint: .clear)
  }

  // MARK: Legal

  private var legalBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader("the fine print")
      Text(
        """
        this app talks to youtube, and youtube's terms decide what that means:
        · metadata (title, description, tags, comments) via the data api or a
          public mirror — fine
        · playback through youtube's own player — the route this app defaults to
        · downloading or stripping audio out of youtube streams to feed a local
          engine — not allowed by the terms. the boost route is built for *your*
          files and *your* resolver, and it's off by default
        credit is part of the design: every disc shows the channel, the handle,
        and whatever timestamped tracklist the description carries, because lofi
        lives on clearing and crediting artists.
        """
      )
      .font(Y2K.pixel(12.5))
      .foregroundStyle(Y2K.ink.opacity(0.86))
      .lineSpacing(3)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.30)))

      HStack {
        Link("youtube terms", destination: URL(string: "https://www.youtube.com/t/terms")!)
        Spacer()
        Link("api services terms", destination: URL(string: "https://developers.google.com/youtube/terms/api-services-terms-of-service")!)
      }
      .font(Y2K.pixel(14))
      .tint(Y2K.cyan)
    }
    .padding(12)
    .lofiGlass(corner: Y2K.cornerL, tint: .chrome)
  }
}
