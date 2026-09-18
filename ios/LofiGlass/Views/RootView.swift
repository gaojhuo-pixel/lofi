import SwiftUI

// MARK: - Root
//
// Layout is the same stack the prototype uses: void backdrop → player "TV" →
// disc deck → now-playing glass → dock. Sheets come up over the top, and every
// surface goes through `.lofiGlass` so iOS 26 refraction is opt-out, not opt-in.

enum DeckSheet: String, Identifiable {
  case info, boost, search, crate, settings
  var id: String { rawValue }
}

struct RootView: View {
  @EnvironmentObject private var app: AppState
  @EnvironmentObject private var config: AppConfig
  @State private var flip = false

  /// The sheet lives on AppState so ⌘B / the dock / a deep link all open the
  /// same surface.
  private var sheet: Binding<DeckSheet?> { Binding(get: { app.sheet }, set: { app.sheet = $0 }) }

  var body: some View {
    ZStack {
      Y2K.voidBackdrop
        .ignoresSafeArea()

      GridHorizon()
        .opacity(0.55)
        .ignoresSafeArea(edges: .bottom)

      VStack(spacing: 8) {
        StatusBar(sheet: sheet)
        DeckView(sheet: sheet, flip: $flip)
          .frame(maxHeight: .infinity)
        NowPlayingBar(sheet: sheet)
        Dock(sheet: sheet)
      }
      .padding(.horizontal, 10)
      .padding(.top, 4)

      if config.scanlines {
        ScanlineOverlay().ignoresSafeArea()
      }
    }
    .environment(\.colorScheme, .dark)
    .preferredColorScheme(.dark)
    .task { await app.boot() }
    .sheet(item: Binding(get: { app.sheet }, set: { app.sheet = $0 })) { which in
      Group {
        switch which {
        case .info: TrackInfoSheet()
        case .boost: BoostSheet()
        case .search: SearchSheet()
        case .crate: CrateSheet()
        case .settings: SettingsSheet()
        }
      }
      .environmentObject(app)
      .environmentObject(config)
      .presentationBackground { Color.black.opacity(0.35) }
      .presentationDragIndicator(.visible)
      .presentationCornerRadius(30)
    }
    .animation(.spring(duration: 0.42, bounce: 0.18), value: sheet)
  }
}

// MARK: - Status chrome

private struct StatusBar: View {
  @EnvironmentObject private var app: AppState
  @EnvironmentObject private var config: AppConfig
  @Binding var sheet: DeckSheet?

  private var clock: String {
    let f = DateFormatter()
    f.dateFormat = "H:mm"
    return f.string(from: Date())
  }

  var body: some View {
    HStack(spacing: 10) {
      Text(clock).font(Y2K.pixel(17))
      Spacer(minLength: 4)
      Text("lofi.glass")
        .font(Y2K.display(9))
        .tracking(2.4)
        .foregroundStyle(Y2K.chromeMid)
      Spacer(minLength: 4)
      Button {
        sheet = .settings
      } label: {
        HStack(spacing: 5) {
          Circle()
            .fill(app.busy ? Y2K.lime : Y2K.butter)
            .frame(width: 7, height: 7)
            .neon(app.busy ? Y2K.lime : Y2K.butter, radius: 6)
          Text(sourceLabel).font(Y2K.pixel(14))
        }
      }
      .lofiGlassButton()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .foregroundStyle(Y2K.ink)
    .lofiGlass(corner: 999, tint: .clear)
  }

  private var sourceLabel: String {
    switch (config.source, config.route) {
    case (.seed, _): return "SEED"
    case (.piped, _): return "PIPED"
    case (.youtube, _): return "API"
    }
  }
}

// MARK: - Dock

private struct Dock: View {
  @Binding var sheet: DeckSheet?

  private let items: [(DeckSheet?, String, String)] = [
    (nil, "✦", "deck"),
    (.info, "◈", "info"),
    (.boost, "◉", "boost"),
    (.crate, "♥", "crate"),
    (.search, "⌕", "hunt"),
  ]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(items, id: \.1) { item in
        Button {
          sheet = item.0
        } label: {
          VStack(spacing: 1) {
            Text(item.1).font(Y2K.pixel(19))
            Text(item.2).font(Y2K.pixel(12)).tracking(1)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 5)
          .background {
            if sheet == item.0 || (item.0 == nil && sheet == nil) {
              RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(0.14))
            }
          }
        }
        .buttonStyle(GlassTabButtonStyle(selected: sheet == item.0 || (item.0 == nil && sheet == nil)))
      }
    }
    .padding(6)
    .lofiGlass(corner: 22, tint: .clear)
    .padding(.bottom, 2)
  }
}
