import Foundation
import SwiftUI

// MARK: - Configuration
//
// What the deck searches, where metadata comes from, and how audio is routed.
// Persisted in UserDefaults; the API key is only ever read from there or from
// Info.plist. (Move it to the Keychain before shipping — one-line swap, see
// docs/DATA-SOURCES.md.)

final class AppConfig: ObservableObject {
  static let shared = AppConfig()

  enum MetadataSource: String, CaseIterable, Identifiable {
    case seed
    case piped
    case youtube

    var id: String { rawValue }
    var label: String {
      switch self {
      case .seed: return "offline seed"
      case .piped: return "piped mirrors"
      case .youtube: return "youtube data api"
      }
    }
    var needsKey: Bool { self == .youtube }
  }

  enum PlaybackRoute: String, CaseIterable, Identifiable {
    /// YouTube's own player, embedded. Fully within the sandbox YouTube gives
    /// an app; the deck still gets artwork, description and comments.
    case embedded
    /// Our AVAudioEngine graph, fed by an audio-only file your own resolver
    /// handed us. This is the route where −12…+12 dB boost is real.
    case boostedLocal

    var id: String { rawValue }
    var label: String {
      switch self {
      case .embedded: return "youtube player (embed)"
      case .boostedLocal: return "local boost engine"
      }
    }
  }

  private let defaults: UserDefaults
  private let key = "lofiglass.config.v1"

  @Published var source: MetadataSource { didSet { save() } }
  @Published var route: PlaybackRoute { didSet { save() } }
  @Published var apiKey: String { didSet { save() } }
  @Published var resolverBase: String { didSet { save() } }
  /// Comma-separated Piped hosts. Blank means the built-in rotation — public
  /// instances die weekly, so the escape hatch is a setting, not a code edit.
  @Published var pipedHosts: String { didSet { save() } }
  @Published var resolverToken: String { didSet { save() } }
  @Published var gateEnabled: Bool { didSet { save() } }
  @Published var gateThreshold: Double { didSet { save() } }

  /// The hosts to try, in order — the shipped rotation unless the user overrode it.
  var pipedHostList: [String] {
    let hosts = pipedHosts
      .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return hosts.isEmpty ? PipedProvider.defaultHosts : hosts
  }

  /// What the composite provider will actually accept: gate off means 0
  /// (everything plays), gate on means the user may only raise the floor.
  var effectiveThreshold: Double {
    gateEnabled ? max(LofiFilter.threshold, gateThreshold) : 0
  }
  @Published var autoplayOnSwipe: Bool { didSet { save() } }
  @Published var radioMode: Bool { didSet { save() } }
  @Published var scanlines: Bool { didSet { save() } }
  @Published var refraction: Bool { didSet { save() } }
  @Published var sleepTimerMinutes: Int { didSet { save() } }
  @Published var boost = BoostSettings() { didSet { save() } }
  @Published var crate: [String] { didSet { save() } }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.dictionary(forKey: key) as? [String: Any] ?? [:]

    func value<T>(_ name: String, _ fallback: T) -> T {
      (stored[name] as? T) ?? fallback
    }

    source = MetadataSource(rawValue: value("source", "seed")) ?? .seed
    route = PlaybackRoute(rawValue: value("route", "embedded")) ?? .embedded
    apiKey = value("apiKey", "")
    resolverBase = value("resolverBase", "")
    pipedHosts = value("pipedHosts", "")
    resolverToken = value("resolverToken", "")
    gateEnabled = value("gateEnabled", true)
    gateThreshold = value("gateThreshold", LofiFilter.threshold)
    autoplayOnSwipe = value("autoplayOnSwipe", true)
    radioMode = value("radioMode", true)
    scanlines = value("scanlines", true)
    refraction = value("refraction", true)
    sleepTimerMinutes = value("sleepTimerMinutes", 0)
    crate = value("crate", [])

    if let data = stored["boost"] as? Data, let decoded = try? JSONDecoder().decode(BoostSettings.self, from: data) {
      boost = decoded
    } else {
      boost = BoostSettings()
    }

    // Info.plist is the dev fallback so the app runs without typing a key.
    if apiKey.isEmpty, let plistKey = Bundle.main.object(forInfoDictionaryKey: "YouTubeAPIKey") as? String, !plistKey.isEmpty {
      apiKey = plistKey
    }
  }

  private func save() {
    var payload: [String: Any] = [
      "source": source.rawValue,
      "route": route.rawValue,
      "apiKey": apiKey,
      "resolverBase": resolverBase,
      "pipedHosts": pipedHosts,
      "resolverToken": resolverToken,
      "gateEnabled": gateEnabled,
      "gateThreshold": gateThreshold,
      "autoplayOnSwipe": autoplayOnSwipe,
      "radioMode": radioMode,
      "scanlines": scanlines,
      "refraction": refraction,
      "sleepTimerMinutes": sleepTimerMinutes,
      "crate": crate,
    ]
    payload["boost"] = (try? JSONEncoder().encode(boost)) ?? Data()
    defaults.set(payload, forKey: key)
  }

  var hasUsableKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var hasResolver: Bool { !resolverBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// A short sentence the UI shows next to the route picker, because these
  /// tradeoffs are the user's to make, not ours.
  var routeWarning: String {
    switch (route, source) {
    case (.boostedLocal, _):
      return "boost works only on audio your own resolver returns — no resolver set: \(hasResolver ? "ok" : "missing")"
    case (.embedded, _):
      return "embedded player can't be tapped by AVAudioEngine, so boost maps to device volume"
    }
  }

  func resetCrate() {
    crate = []
  }
}
