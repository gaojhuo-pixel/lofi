import SwiftUI

// MARK: - App
//
// Two environment objects and that's the whole dependency graph: `AppConfig`
// for settings, `AppState` for the deck + audio. Kept this way so the views in
// this folder are the same shapes the prototype renders.

@main
struct LofiGlassApp: App {
  @StateObject private var config: AppConfig
  @StateObject private var app: AppState
  @Environment(\.scenePhase) private var scenePhase

  init() {
    let config = AppConfig.shared
    self._config = StateObject(wrappedValue: config)
    self._app = StateObject(wrappedValue: AppState(config: config))
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(app)
        .environmentObject(config)
        .preferredColorScheme(.dark)
        .onOpenURL { url in handle(url) }
        .background(BackgroundFixer())
    }
    .defaultSize(width: 420, height: 880)
    .commands {
      CommandGroup(replacing: .undoRedo) {
        Button("Next lofi") { Task { await app.swipe(1) } }
          .keyboardShortcut(.rightArrow, modifiers: [])
        Button("Previous") { Task { await app.swipe(-1) } }
          .keyboardShortcut(.leftArrow, modifiers: [])
        Divider()
        Button("Louder (+1 dB)") { app.nudgeBoost(by: 1) }
          .keyboardShortcut("+", modifiers: .command)
        Button("Quieter (−1 dB)") { app.nudgeBoost(by: -1) }
          .keyboardShortcut("-", modifiers: .command)
      }
      CommandGroup(after: .appInfo) {
        Button("Boost panel") { app.sheet = .boost }
          .keyboardShortcut("b", modifiers: .command)
        Button("Sleeve notes") { app.sheet = .info }
          .keyboardShortcut("i", modifiers: .command)
      }
    }
  }

  /// `lofiglass://play/<videoId>` and plain youtube links from Share Sheets.
  private func handle(_ url: URL) {
    guard let host = url.host else { return }
    if host == "play" {
      let id = url.lastPathComponent
      guard id.count == 11 else { return }
      var track = LofiTrack(videoId: id, title: "from share sheet", source: .seed)
      track.tags = ["imported"]
      Task { await app.playFromCrate(track) }
    } else if url.path.contains("watch"), let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name == "v" })?.value {
      let track = LofiTrack(videoId: query, title: url.absoluteString, source: .seed)
      Task { await app.playFromCrate(track) }
    }
  }
}

/// Kills the white flash under the sheet on iOS 18/26.
private struct BackgroundFixer: UIViewRepresentable {
  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = UIColor(red: 0.043, green: 0.027, blue: 0.125, alpha: 1)
    DispatchQueue.main.async {
      var next: UIView? = view.superview
      while let current = next {
        current.backgroundColor = view.backgroundColor
        next = current.superview
      }
    }
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}
