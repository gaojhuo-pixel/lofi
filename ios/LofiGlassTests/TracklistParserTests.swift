import XCTest
@testable import LofiGlass

/// Real description shapes from the seed corpus, so the parser is tested
/// against what lofi channels actually write rather than an ideal.
final class TracklistParserTests: XCTestCase {
  func test_plain_colon_timecodes() {
    let text = """
    0:00 Surf
    3:40 Woods
    7:45 Blue World
    11:00 Right
    """
    let list = TracklistParser.parse(text)
    XCTAssertEqual(list.count, 4)
    XCTAssertEqual(list[0].startSeconds, 0)
    XCTAssertEqual(list[1].startSeconds, 220)
    XCTAssertEqual(list[2].title, "Blue World")
    // No "Artist - Title" separator means the whole label is the title, and the
    // channel is the credit — the UI falls back to channelName for that case.
    XCTAssertEqual(list[2].artist, "Blue World")
  }

  func test_artist_dash_title() {
    let text = """
    0:00 No Spirit - Memories We Made
    6:20 Yasumu - We Met
    8:42 HM Surf - Sugar Haze
    11:09 Blurred Figures, another silent weekend - snowfall
    13:45 trxxshed, Jhove - Ivory
    """
    let list = TracklistParser.parse(text)
    XCTAssertEqual(list.count, 5)
    XCTAssertEqual(list[1].artist, "Yasumu")
    XCTAssertEqual(list[1].title, "We Met")
    XCTAssertEqual(list[1].startSeconds, 380)
    XCTAssertEqual(list[3].artist, "Blurred Figures, another silent weekend")
    XCTAssertEqual(list[4].title, "Ivory")
  }

  func test_en_dash_and_full_width_titles() {
    let text = """
    0:00 Sutton – Lunch Break
    1:47 Noji – Exhale
    9:28 Thymes – Free as a Bird
    """
    let list = TracklistParser.parse(text)
    XCTAssertEqual(list.count, 3)
    XCTAssertEqual(list[1].artist, "Noji")
    XCTAssertEqual(list[1].title, "Exhale")
    XCTAssertEqual(list[2].startSeconds, 568)
  }

  func test_bracketed_hour_timecodes_and_prod_prefix() {
    let text = """
    [01:02:03] kudasai - when i see you
    Prod. kudasai
    0:00 Lilac - Perfume
    """
    let list = TracklistParser.parse(text)
    XCTAssertEqual(list.map(\.startSeconds), [0, 3723])
    XCTAssertEqual(list.last?.artist, "kudasai")
  }

  func test_marketing_lines_are_not_credits() {
    let text = """
    0:00 the actual track
    0:12 Listen on Spotify → https://x.co/music
    0:20 Follow me: @somebody
    0:31 Tracklist below
    """
    let list = TracklistParser.parse(text)
    XCTAssertEqual(list.count, 1, "promo lines that happen to start with a timestamp must not become credits")
    XCTAssertEqual(list[0].title, "the actual track")
  }

  func test_out_of_order_lines_are_sorted_not_eaten() {
    let text = """
    2:00 B Track
    1:00 A Track
    1:30 C Track
    1:15 Backwards Track
    1:15 Backwards Again Track
    """
    let list = TracklistParser.parse(text)
    XCTAssertEqual(list.map(\.startSeconds), [60, 90, 120, 220])
    XCTAssertEqual(list.map(\.title), ["A Track", "Backwards Track", "C Track", "B Track"])
    XCTAssertEqual(list, list.sorted { $0.startSeconds < $1.startSeconds })
  }

  func test_credit_lookup_follows_the_playhead() {
    let list = [
      TrackCredit(startSeconds: 0, artist: "A", title: "one"),
      TrackCredit(startSeconds: 100, artist: "B", title: "two"),
      TrackCredit(startSeconds: 200, artist: "C", title: "three"),
    ]
    XCTAssertEqual(list.credit(at: 0)?.artist, "A")
    XCTAssertEqual(list.credit(at: 99.5)?.artist, "A")
    XCTAssertEqual(list.credit(at: 150)?.artist, "B")
    XCTAssertEqual(list.credit(at: 9_000)?.artist, "C")
    XCTAssertEqual(list.next(after: 50)?.artist, "B")
    XCTAssertNil(list.next(after: 250))
  }

  func test_hashtags_come_through_in_order_without_the_hash() {
    let text = "lofi #chill #lofimusic #lofistudy #chillbeats #studymusic #summer #summer again"
    XCTAssertEqual(TracklistParser.hashtags(in: text), ["chill", "lofimusic", "lofistudy", "chillbeats", "studymusic", "summer"])
  }

  func test_tags_merge_explicit_then_gate() {
    let gate = GateVerdict(lofi: true, score: 9, threshold: 4, hits: ["lofi", "tape"], moods: ["rain"])
    let tags = TracklistParser.tags(explicit: ["#chillhop"], description: "#vhs lofi mix", gate: gate)
    XCTAssertEqual(tags.first, "chillhop")
    XCTAssertTrue(tags.contains("vhs"))
    XCTAssertTrue(tags.contains("tape"))
    XCTAssertLessThanOrEqual(tags.count, 12)
  }

  func test_seed_descriptions_yield_credits() {
    guard let url = SeedProvider.seedURL, let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(SeedFile.self, from: data) else { return XCTFail("no seed json") }
    let withLists = file.tracks.filter { ($0.tracklist?.isEmpty == false) }
    XCTAssertFalse(withLists.isEmpty, "seed should carry hand-written tracklists to compare against")
    // The hand-written lists and the parser must agree on the first entry's start.
    for track in withLists.prefix(5) {
      let parsed = TracklistParser.parse(track.bestDescription)
      if let first = track.tracklist?.first, let parsedFirst = parsed.first {
        XCTAssertEqual(first.startSeconds, parsedFirst.startSeconds, "parser drifted on \(track.title)")
      }
    }
  }
}
