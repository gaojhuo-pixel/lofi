# lofi.glass — iOS

SwiftUI port of the prototype in `../prototype`. Same deck, same gate, same boost curve,
rendered with Liquid Glass where the OS provides it.

> ## Nothing here has been compiled
>
> The sandbox that wrote this code has no Xcode, no `swiftc`, no simulator and no network
> beyond the npm registry. So, precisely:
>
> | | status |
> | --- | --- |
> | Swift compiles | **unverified** — 24 app files + 4 test files, ~6.3k lines, never type-checked |
> | `xcodegen generate` | **unverified** — `ios/project.yml` is validated textually by `tools/project-check.mjs` (parses, paths exist, Info.plist keys present) |
> | unit tests | **never run** — they are written against the real signatures in this repo and are the fastest way to find the first bugs |
> | lofi gate behaviour | **verified**: `tools/gate-check.mjs` proves `LofiFilter.swift` carries byte-identical tables to the JS reference, and that the reference accepts 21/21 seed discs and rejects 4/4 non-lofi |
> | seed data contract | **verified**: `tools/seed-schema-check.mjs` proves every non-optional Swift model field exists in `shared/seed/lofi-feed.json` |
> | theme/type surface | **verified** for undeclared/ambiguous symbols by `tools/swift-symbol-check.mjs`; **not** verified for signatures |
>
> Expect the first `xcodebuild` to produce a handful of ordinary Swift errors (signature
> drift between a view and a model, a `try` missing, an availability guard). They will be
> local, and the test targets are aimed at exactly the parts where a mistake would be
> silent rather than loud.

## Build

```bash
brew install xcodegen
cd ios
xcodegen generate                       # writes LofiGlass.xcodeproj (+ Info.plists)
open LofiGlass.xcodeproj                # pick any simulator, iOS 18 or 26
```

or

```bash
cd ios && xcodegen generate
xcodebuild -project LofiGlass.xcodeproj -scheme LofiGlass \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' build test
```

Requires iOS 18 SDK (Xcode 16+). On an iOS 26 device/simulator the panels get real
`glassEffect`; on 18/19 they fall back to materials with the same rim and shadow.

## Layout

```
project.yml                    XcodeGen manifest; the seed JSON is a resource from ../shared
LofiGlass/
  App/            LofiGlassApp (entry, deep links, ⌘ shortcuts) · AppState (deck + transport + crate)
  Views/          RootView · DeckView · VinylDiscCard(+NowPlayingBar) · PlayerLayer
                  TrackInfoSheet · BoostSheet · SearchAndCrateSheets · SettingsSheet
                  Components/Y2KComponents (starburst, scanlines, grid, marquee, meter, disc)
  Theme/          Y2KTheme (tokens, fonts, gradients) · GlassStyle (the material)
  Services/       LofiFilter · TracklistParser · LofiProviding (protocol+HTTP+rotator)
                  SeedProvider · PipedProvider · YouTubeDataProvider · CompositeProvider
                  AppConfig (UserDefaults) · StreamLoader (cache + resolver)
  Audio/          AudioBoostEngine (AVAudioEngine graph + limiter + metering)
  Models/         LofiModels (the wire contract, incl. the seed file)
  Resources/Fonts README — Michroma + VT323 are optional
LofiGlassTests/   gate parity · tracklist parsing · boost math & limiter · provider plumbing
```

## The two playback routes

**Embedded (default).** `EmbeddedPlayerView` hosts a `WKWebView` with a minimal YouTube IFrame
API harness (`LofiGlass/Views/PlayerLayer.swift`): the player does the decoding, and the app
gets `ready · time · ended · error` events back over `WKScriptMessageHandler`. Volume is the
only thing the app can move, so the boost sheet maps dB onto `22 + 78·((db+12)/24) %` player
volume and labels it `boost armed · iframe-capped`. Nothing pretends otherwise.

**Local boost engine.** `StreamLoader` asks *your* resolver for an audio URL,
caches the file in `Library/Caches/LoFiAudio/`, and `AudioBoostEngine` plays it through
`player → trim → 3-band EQ → mixer(+dB) → varispeed → soft clip → limiter tap → mainMixer`.
That is where the −12…+12 dB slider is real, where the meter's gain reduction comes from, and
where seeking/rate/looping work on six-hour mixes (the file is scheduled in 384-frame chunks,
four ahead, so memory stays flat).

**Terms of service, stated plainly.** Playback through YouTube's own player is fine. Metadata
(titles, descriptions, tags, comments) through the Data API or a public mirror is fine.
*Downloading or extracting YouTube audio* to feed the local engine is not sanctioned by
YouTube's terms — which is why the local route is opt-in, defaults to nothing, and reads from
a resolver endpoint you host yourself:

```
GET {resolverBase}/resolve?videoId=<id>          (optional: Authorization: Bearer <token>)
→ { "url": "https://…/audio.m4a", "expiresAt": 1725000000, "headers": {} }
```

The app never contacts YouTube for audio; whatever that `url` points at is your call. The
Settings sheet repeats this and links the terms.

## API key

Three places, in order of preference:

1. **Keychain** — not wired up here; do this before shipping, and note that `AppConfig` reads
   only UserDefaults/Info.plist.
2. **Settings → YouTube Data API key** — stored in UserDefaults under `lofiglass.config.v1`.
   Fine for development, extractable from the container on a device you own.
3. **`YouTubeAPIKey` in the generated Info.plist** (`ios/project.yml` → `info.properties`,
   shipped as `""`). A plist inside the app bundle is readable by anyone who pulls the IPA;
   it exists so a local build needs zero setup.

Budget: `search.list` costs 100 units, `videos.list`/`commentThreads.list` cost 1 each, so a
full search ≈ 102 of 10 000 daily units. The provider caches decoded objects an hour and raw
JSON ten minutes, and the gate is applied locally, so an exhausted quota degrades to the seed
corpus rather than an empty deck.

No key at all? `source = .seed` (the default) plays 21 real discs offline, and
`source = .piped` gets live search from community mirrors without one.

## Tests

`LofiGlassTests` are aimed at the parts a compiler can't warn you about:

* `LofiFilterTests` — the seed corpus (21/21), the counter-examples (4/4), six adversarial
  titles, mood inference, tag derivation. Mirrors `tools/gate-check.mjs`.
* `TracklistParserTests` — the actual description shapes: `h:mm:ss`, bracketed timecodes,
  en/em dashes, `Title by Artist`, `Prod. X`, link/promo lines to ignore, out-of-order sorts.
* `AudioBoostEngineTests` — dB↔linear clamp, system-volume mapping, preset effects, and the
  adaptive limiter's attack/release against synthetic buffers.
* `ProviderTests` — video-id parsing from every share shape, ISO-8601 durations, query
  rewriting, the gate actually dropping things, the mirror→seed fallback ladder, config
  defaults and the route warning's wording.

## Known divergences from the prototype (deliberate)

* No flick-velocity commit — `DragGesture` carries no timestamps, so iOS commits on distance
  (92 pt) where the web deck also accepts a fast swipe.
* Body type is SF Rounded on iOS vs Titillium Web on the web (see `Resources/Fonts/README.md`
  for the two optional faces that get the display/pixel half exact).
* Refraction only exists on iOS 26; there is no Core Image stand-in for 18/19.
* The web limiter is a `DynamicsCompressor`, the iOS one is a feedback gain tap with an
  attack/release envelope — same ceiling and readout, different DSP. iOS exposes no
  look-ahead limiter, and this does not claim to have one.
* iOS caches resolved audio to disk; the prototype has nothing to cache.
