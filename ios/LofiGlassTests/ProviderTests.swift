import XCTest
@testable import LofiGlass

/// Plumbing around the three metadata sources: id parsing, the query that goes
/// out, and the rule that nothing reaches the deck without a gate stamp.
final class ProviderTests: XCTestCase {
  // MARK: ids

  func test_video_id_parsing_covers_every_share_shape() {
    let expected = "P31G_H6domU"
    for raw in [
      "https://www.youtube.com/watch?v=P31G_H6domU",
      "https://youtu.be/P31G_H6domU?t=61",
      "https://m.youtube.com/watch?v=P31G_H6domU&list=RDMM",
      "https://www.youtube.com/embed/P31G_H6domU?start=61",
      "https://www.youtube.com/shorts/P31G_H6domU",
      "https://music.youtube.com/watch?v=P31G_H6domU",
      "P31G_H6domU",
      "  watch?v=P31G_H6domU ",
    ] {
      XCTAssertEqual(PipedProvider.videoId(from: raw), expected, "failed on \(raw)")
    }
  }

  func test_non_videos_and_garbage_return_nil() {
    XCTAssertNil(PipedProvider.videoId(from: ""))
    XCTAssertNil(PipedProvider.videoId(from: nil))
    XCTAssertNil(PipedProvider.videoId(from: "https://youtube.com/playlist?list=PLx0sYbCqOb8Q"))
    XCTAssertNil(PipedProvider.videoId(from: "watch?v=short"))
    XCTAssertNil(PipedProvider.videoId(from: "https://youtube.com/@chillhopmusic"))
    // A valid-looking token after `v=` is taken at face value; the API's 404 is
    // the honest answer, not a parser that silently drops half the deck.
    XCTAssertEqual(PipedProvider.videoId(from: "https://example.com/watch?v=notavideoID!!"), "notavideoID")
  }

  func test_iso8601_duration() {
    XCTAssertEqual(YouTubeDataProvider.seconds(in: "PT1H1M"), 3_660)
    XCTAssertEqual(YouTubeDataProvider.seconds(in: "PT45M"), 2_700)
    XCTAssertEqual(YouTubeDataProvider.seconds(in: "PT2H"), 7_200)
    XCTAssertEqual(YouTubeDataProvider.seconds(in: "PT56S"), 56)
    XCTAssertEqual(YouTubeDataProvider.seconds(in: "PT1H2M3S"), 3_723)
    XCTAssertEqual(YouTubeDataProvider.seconds(in: "PT0S"), 0, "live streams report PT0S")
    XCTAssertEqual(YouTubeDataProvider.seconds(in: "garbage"), 0)
    XCTAssertEqual(YouTubeDataProvider.seconds(in: nil), 0)
  }

  // MARK: the query that leaves the device

  func test_bare_queries_get_the_genre_word() {
    XCTAssertEqual(CompositeProvider.lofiQuery("rain sounds"), "lofi rain sounds")
    XCTAssertEqual(CompositeProvider.lofiQuery(""), "lofi hip hop", "an empty query still means the thing the app is for")
    XCTAssertEqual(CompositeProvider.lofiQuery("   "), "lofi hip hop")
    XCTAssertEqual(CompositeProvider.lofiQuery("kudasai lofi mix"), "kudasai lofi mix", "don't double it up")
    XCTAssertEqual(CompositeProvider.lofiQuery("chillhop radio"), "chillhop radio")
    XCTAssertEqual(CompositeProvider.lofiQuery("Lo-Fi Study Beats"), "Lo-Fi Study Beats", "case-insensitive check, original text kept")
  }

  func test_hunt_passes_the_augmented_query_down() async {
    let stub = StubProvider(results: .empty)
    let composite = CompositeProvider(primary: stub, mirror: nil, seed: SeedProvider(loadImmediately: false))
    _ = await composite.hunt(query: "sleep beats", mood: nil, limit: 10)
    XCTAssertEqual(stub.lastQuery, "lofi sleep beats")
  }

  // MARK: the gate is not optional

  func test_hunt_drops_what_the_gate_refuses_and_keeps_the_receipts() async {
    let stub = StubProvider(results: LofiSearchResults(
      query: "lofi",
      accepted: [
        ProviderTests.track("lofi hip hop radio 📚 beats to relax/study to", id: "a"),
        ProviderTests.track("Deep House Festival Mix 2026", id: "b"),
        ProviderTests.track("lofi mix - beats to chill / sleep to", id: "c"),
      ],
      rejected: [],
      origin: "stub"
    ))
    let composite = CompositeProvider(primary: stub, mirror: nil, seed: SeedProvider(loadImmediately: false))
    let results = await composite.hunt(query: "lofi", mood: nil, limit: 10)

    XCTAssertEqual(results.accepted.map(\.videoId), ["a", "c"], "the gate must run even when a provider says 'music'")
    XCTAssertEqual(results.rejected.map(\.videoId), ["b"])
    XCTAssertEqual(results.origin, "stub", "the badge has to say where the results came from")
    XCTAssertTrue(results.accepted.allSatisfy { $0.gate?.lofi == true })
    XCTAssertEqual(composite.stats.accepted, 2)
    XCTAssertEqual(composite.stats.rejected, 1)
    XCTAssertEqual(composite.stats.lastRejected.first?.videoId, "b", "recently-rejected is what Settings shows")
  }

  func test_settings_can_raise_the_floor_but_never_lower_it() async {
    let tracks = [
      ProviderTests.track("lofi type beat ~ chill", id: "weak"),
      ProviderTests.track("lofi hip hop radio 📚 beats to relax/study to ☔ rain", id: "strong"),
    ]
    let lenient = CompositeProvider(
      primary: StubProvider(results: LofiSearchResults(query: "lofi", accepted: tracks, rejected: [], origin: "stub")),
      mirror: nil,
      seed: SeedProvider(loadImmediately: false)
    )
    let lenientResults = await lenient.hunt(query: "lofi", mood: nil, limit: 10)
    XCTAssertEqual(lenientResults.accepted.count, 2)

    let strict = CompositeProvider(
      primary: StubProvider(results: LofiSearchResults(query: "lofi", accepted: tracks, rejected: [], origin: "stub")),
      mirror: nil,
      seed: SeedProvider(loadImmediately: false),
      thresholdOverride: { 12 }
    )
    let kept = await strict.hunt(query: "lofi", mood: nil, limit: 10).accepted
    XCTAssertEqual(kept.map(\.videoId), ["strong"], "at 12 only the obvious lofi survives")
  }

  func test_live_streams_survive_the_duration_rules() async {
    var live = ProviderTests.track("lofi hip hop radio - beats to relax/study to", id: "live-1")
    live.kind = "live"
    live.durationSeconds = 0
    let composite = CompositeProvider(
      primary: StubProvider(results: LofiSearchResults(query: "lofi", accepted: [live], rejected: [], origin: "stub")),
      mirror: nil,
      seed: SeedProvider(loadImmediately: false)
    )
    let results = await composite.hunt(query: "lofi", mood: nil, limit: 5)
    XCTAssertEqual(results.accepted.count, 1, "a 24/7 radio has no duration; that must not read as a short clip")
  }

  // MARK: fallback ladder

  func test_seed_is_the_final_fallback_when_live_sources_fail() async throws {
    let seed = SeedProvider()
    XCTAssertTrue(seed.load(), "the seed json has to be in the test bundle (xcodegen generate)")
    let composite = CompositeProvider(primary: ThrowingProvider(), mirror: ThrowingProvider(), seed: seed)
    let results = await composite.hunt(query: "lofi hip hop radio", mood: nil, limit: 10)
    XCTAssertEqual(results.origin, "seed corpus")
    XCTAssertFalse(results.accepted.isEmpty)
    XCTAssertTrue(results.accepted.allSatisfy { $0.source == .seed })
  }

  func test_hunt_never_throws_even_when_everything_is_down() async {
    let composite = CompositeProvider(primary: ThrowingProvider(), mirror: nil, seed: SeedProvider(loadImmediately: false))
    let results = await composite.hunt(query: "lofi", mood: nil, limit: 10)
    XCTAssertTrue(results.accepted.isEmpty, "nothing reachable means an empty deck, not an exception")
  }

  func test_details_and_comments_fall_back_to_the_seed_too() async {
    let seed = SeedProvider()
    _ = seed.load()
    guard let first = seed.tracks.first else { return XCTFail("seed corpus unavailable") }
    let composite = CompositeProvider(primary: ThrowingProvider(), mirror: nil, seed: seed)

    let enriched = await composite.details(for: first)
    XCTAssertEqual(enriched.videoId, first.videoId)
    XCTAssertTrue(enriched.bestDescription.isEmpty == false, "the seed description should survive enrichment")

    let comments = await composite.comments(for: first, max: 4)
    XCTAssertEqual(comments.origin, "seed cache")
    XCTAssertEqual(comments.items.count, min(4, (first.comments ?? []).count))
  }

  func test_no_stream_url_without_a_resolver() async {
    let composite = CompositeProvider(primary: ThrowingProvider(), mirror: nil, seed: SeedProvider(loadImmediately: false))
    let url = await composite.streamURL(for: ProviderTests.track("lofi mix", id: "x"))
    XCTAssertNil(url, "the embed route is the default precisely because nobody hands us audio")
  }

  // MARK: config the UI reads

  func test_effective_threshold_follows_the_gate_switch() {
    let config = AppConfig()
    config.gateEnabled = true
    config.gateThreshold = LofiFilter.threshold
    XCTAssertEqual(config.effectiveThreshold, LofiFilter.threshold)
    config.gateEnabled = false
    XCTAssertEqual(config.effectiveThreshold, 0, "gate off means everything plays, and says so")
    config.gateEnabled = true
    config.gateThreshold = 9
    XCTAssertEqual(config.effectiveThreshold, 9)
    config.gateThreshold = 1
    XCTAssertEqual(config.effectiveThreshold, LofiFilter.threshold, "the floor is the floor")
  }

  func test_route_warning_tells_the_truth_about_gain() {
    let config = AppConfig()
    config.route = .embedded
    XCTAssertTrue(config.routeWarning.lowercased().contains("volume"), "embedded must admit it only moves the player's volume")
    config.route = .boostedLocal
    XCTAssertTrue(config.routeWarning.lowercased().contains("own"), "the local route must say whose audio it is")
  }

  func test_key_lookup_is_guarded_against_placeholder_values() {
    let config = AppConfig()
    config.apiKey = ""
    XCTAssertFalse(config.hasUsableKey)
    config.apiKey = "  AIza-not-real "
    XCTAssertTrue(config.hasUsableKey, "trimmed and non-empty is the whole local check")
  }

  func test_defaults_are_conservative() {
    let config = AppConfig()
    XCTAssertEqual(config.boost.db, 0)
    XCTAssertEqual(config.route, .embedded, "the embed route is the terms-friendly default")
    XCTAssertEqual(config.source, .seed, "no key, no network, still a working deck")
    XCTAssertTrue(config.gateEnabled, "the filter is on until you turn it off")
  }

  // MARK: fixtures

  static func track(_ title: String, id: String) -> LofiTrack {
    var track = LofiTrack(videoId: id, title: title, channelName: "test channel", source: .piped)
    track.descriptionExcerpt = title
    return track
  }
}

/// A class, not a struct: `lastQuery` has to survive being handed to the
/// composite, or the assertion about query rewriting proves nothing.
final class StubProvider: LofiProviding {
  let name = "stub"
  let results: LofiSearchResults
  private(set) var lastQuery: String?
  private(set) var lastMood: String?

  init(results: LofiSearchResults) { self.results = results }

  func search(_ query: String, mood: String?, limit: Int) async throws -> LofiSearchResults {
    lastQuery = query
    lastMood = mood
    return results
  }

  func details(for track: LofiTrack) async throws -> LofiTrack { track }
  func topComments(for track: LofiTrack, max: Int) async throws -> [YTComment] { [] }
  func audioStreamURL(for track: LofiTrack) async throws -> URL? { nil }
}

private struct ThrowingProvider: LofiProviding {
  let name = "down"
  func search(_ query: String, mood: String?, limit: Int) async throws -> LofiSearchResults {
    throw ProviderError(.unreachable, detail: "as if the mirrors were dead")
  }

  func details(for track: LofiTrack) async throws -> LofiTrack { throw ProviderError(.unreachable) }
  func topComments(for track: LofiTrack, max: Int) async throws -> [YTComment] { throw ProviderError(.unreachable) }
}
