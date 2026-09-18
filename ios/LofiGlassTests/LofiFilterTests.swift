import XCTest
@testable import LofiGlass

/// Executable twin of `node tools/gate-check.mjs`. If the two ever disagree,
/// whichever side changed is the one that owes a fix.
final class LofiFilterTests: XCTestCase {
  private func seed() -> SeedFile {
    guard let url = SeedProvider.seedURL, let data = try? Data(contentsOf: url) else {
      XCTFail("lofi-feed.json is not in the test bundle — run xcodegen generate"); return SeedFile()
    }
    return (try? JSONDecoder().decode(SeedFile.self, from: data)) ?? SeedFile()
  }

  func test_every_seed_track_passes_the_gate() {
    let file = seed()
    XCTAssertFalse(file.tracks.isEmpty, "seed corpus is empty")
    var refused: [String] = []
    for track in file.tracks {
      let verdict = LofiFilter.evaluate(
        title: track.title,
        description: track.bestDescription,
        tags: track.tags,
        channelName: track.channelName,
        durationSeconds: track.durationSeconds
      )
      if !verdict.lofi { refused.append("\(track.title) → \(verdict.score)") }
    }
    XCTAssertTrue(refused.isEmpty, "gate refused real lofi:\n" + refused.joined(separator: "\n"))
  }

  func test_non_lofi_examples_are_refused() {
    for example in seed().excludedExamples {
      let verdict = LofiFilter.evaluate(title: example.title, description: "", channelName: example.channelName, durationSeconds: 5400)
      XCTAssertFalse(verdict.lofi, "gate accepted non-lofi: \(example.title) (\(verdict.score))")
    }
  }

  func test_genre_impostors_are_rejected() {
    let cases = [
      ("Deep House Festival Mix 2026 — EDM mainstage", ""),
      ("6AM MOTIVATION WORKOUT MIX — GYM HITS", ""),
      ("Binaural beats for focus • solfeggio 432hz", ""),
    ]
    for (title, description) in cases {
      let verdict = LofiFilter.evaluate(title: title, description: description, tags: [], channelName: "", durationSeconds: 3600)
      XCTAssertFalse(verdict.lofi, "should refuse: \(title) (score \(verdict.score))")
      XCTAssertFalse(verdict.penalties.isEmpty, "expected a penalty to fire for: \(title)")
    }
  }

  func test_obvious_lofi_is_accepted() {
    let cases = [
      ("lofi beats to study to ☕ 1 hour", ""),
      ("Ｎｉｇｈｔ Ｄｒｉｖｅ ~ lofi hip hop mix ~ beats to chill / drive to", ""),
      ("lofi hip hop radio 📚 beats to relax/study to", ""),
      ("Chill Lofi Mix [chill lo-fi hip hop beats]", "Tracklist: Noji – Exhale"),
    ]
    for (title, description) in cases {
      let verdict = LofiFilter.evaluate(title: title, description: description, tags: [], channelName: "", durationSeconds: 6300)
      XCTAssertTrue(verdict.lofi, "should accept: \(title) (score \(verdict.score))")
    }
  }

  func test_bare_artist_upload_passes_on_the_known_acts_list() {
    // No genre words at all — only the producer's name. This is why the list exists.
    let verdict = LofiFilter.evaluate(title: "Nymano - Solitude", description: "", tags: [], channelName: "somebody's playlist", durationSeconds: 149)
    XCTAssertTrue(verdict.lofi, "known-act boost should carry this (score \(verdict.score))")
  }

  func test_trusted_channel_boosts_weak_titles() {
    let verdict = LofiFilter.evaluate(title: "september tape", description: "", tags: [], channelName: "Lofi Girl", durationSeconds: 7200)
    XCTAssertGreaterThan(verdict.score, LofiFilter.threshold - 3, "trusted channel should move the number")
  }

  func test_derived_tags_merge_uploader_hashtags_with_gate_hits() {
    var track = LofiTrack(videoId: "x", title: "lofi rain mix", channelName: "c")
    track.tags = ["#chillbeats", "#studymusic"]
    let gate = LofiFilter.evaluate(title: track.title, description: "lofi hip hop", tags: track.tags, channelName: "c")
    let tags = LofiFilter.deriveTags(for: track, gate: gate)
    XCTAssertTrue(tags.contains("chillbeats"))
    XCTAssertTrue(tags.contains("studymusic"))
    XCTAssertTrue(tags.contains("lofi"))
    XCTAssertEqual(tags, Array(Set(tags)), "tags must be unique")
    XCTAssertLessThanOrEqual(tags.count, 12)
  }

  func test_seed_provider_filters_its_own_corpus_through_the_gate() {
    let provider = SeedProvider(loadImmediately: false)
    guard let url = SeedProvider.seedURL, let data = try? Data(contentsOf: url) else { return XCTFail("no seed json") }
    XCTAssertTrue(provider.ingest(data))
    XCTAssertTrue(provider.isReady)
    XCTAssertTrue(provider.tracks.allSatisfy { $0.gate?.lofi == true })
    XCTAssertFalse(provider.rejected.isEmpty, "the seed file ships non-lofi examples; they should be kept as evidence")
  }

  func test_mood_is_inferred_from_the_description() {
    let verdict = LofiFilter.evaluate(
      title: "lofi hip hop radio - beats to sleep to",
      description: "rain outside, 8 hours, for studying and exams",
      tags: [],
      channelName: ""
    )
    XCTAssertTrue(verdict.moods.contains("sleep"))
    XCTAssertTrue(verdict.moods.contains("study"))
    XCTAssertTrue(verdict.moods.contains("rain"))
  }
}
