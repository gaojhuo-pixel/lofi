# SPEC — what lofi.glass is, in enough detail to build it twice

Two deliverables, one behaviour, one corpus:

| surface | path | stack |
| --- | --- | --- |
| mobile web prototype | `prototype/` | Vite + vanilla TS-flavoured JS, CSS custom properties, YouTube IFrame API |
| native iOS app | `ios/` | SwiftUI, iOS 18 min, `glassEffect` when iOS 26 is present, AVAudioEngine, WebKit |
| shared corpus | `shared/seed/lofi-feed.json` | 21 real discs + 4 counter-examples + 12 query seeds |
| executable checks | `tools/` | gate parity, seed schema, Swift symbols, XcodeGen manifest |

## 1. Product rules

1. **The deck is the app.** One vinyl disc at a time; swipe left = next lofi, swipe right =
   back through history. No grid-first browsing, no infinite list.
2. **Only YouTube lofi.** Nothing reaches the deck without passing the gate
   ([DATA-SOURCES.md §6](DATA-SOURCES.md#6-the-lofi-gate--a-score-you-can-defend)). The
   score, the matched signals and the penalties are shown in the sleeve, not hidden.
3. **Credit is UI, not footer.** Channel name, `@handle`, publish label, view count,
   licence note and the timestamped tracklist are on the disc or one flip away.
4. **The boost is a VLC port.** 0 dB is unity, +12 dB is the ceiling, a limiter sits behind
   it, and the app says which route can actually apply gain (§4).
5. **The user can always tell where data came from.** `seed cache · piped · invidious ·
   youtube data api` is a visible badge; `live` vs `sample` comments are labelled.
6. **Nothing is disabled by a dead network.** Every live source is an upgrade over the
   bundled corpus, never a requirement.

## 2. Screen map

```
RootView
├─ StatusBar            wordmark · source badge · clock(VT323) · scanline toggle
├─ DeckView             the card stack, drag mechanics, stamps, seeking veil
│   └─ VinylDiscCard    face: cover + label + tonearm · flip: sleeve notes
├─ NowPlayingBar        credit-at-timecode, tap to seek
├─ Dock                 ♡ crate · ⌾ info · ✦ boost · ⌕ hunt · ⚙ settings
└─ .sheet(item: DeckSheet)
    ├─ TrackInfoSheet   tabs: description · credits · comments
    ├─ BoostSheet       gain, EQ, presets, guards, slowed, route honesty
    ├─ SearchSheet      query + mood chips → accepted / rejected lists
    ├─ CrateSheet       kept discs, tap to play, empty
    └─ SettingsSheet    source, key, route, gate, look, cache, the fine print
```

Prototype equivalents: `deck.js` (card + drag), `sheets.js` (all five sheets),
`player.js`, `boost.js`, `state.js`, `main.js`.

## 3. Deck mechanics (must match on both surfaces)

| behaviour | value | notes |
| --- | --- | --- |
| swipe commit | `|dx| > 92` | pt on iOS, css px in the prototype — same number by intent |
| flip commit | vertical drag past 64 pt (iOS) / 66 px (web) | vertical-dominant drags flip the sleeve |
| flick shortcut | prototype only: ≥ 0.55 px/ms commits a swipe | a real divergence: `DragGesture` gives no timestamps, so the iOS deck commits on distance alone. Noted in the design doc |
| disc rotation while dragging | `dx / 16` degrees | the record turns inside the sleeve |
| stamp fade | `1 − drag/threshold` | `SPIN → next lofi` / `SKIP not this one` burn off as you commit |
| lookahead | 2 cards behind the active one | `AppState.pool` / prototype `queue` |
| debounce | 180 ms | one flick, one change of record |
| spin period | `clamp(duration / 700, 2.2, 7.5)` s, frozen while paused | one revolution per side; a 6-hour mix crawls |
| autoplay on swipe | setting, default on | skipped when the route needs a user gesture |
| rewind | index −1 over `history`, then `seen` | the crate is not the only memory |

Swipe left past the last loaded disc triggers a **hunt**: `pool` first, else a gated
search (`CompositeProvider.hunt` / prototype `hunt()`), so a search never blocks a flick.
Nothing lofi matched → the deck says so and keeps the record on the platter.

## 4. Audio

Two routes, one setting (`AppConfig.PlaybackRoute`):

| | `.embedded` (default) | `.boostedLocal` |
| --- | --- | --- |
| decode | YouTube's iframe player | `StreamLoader` → cached file → `AVAudioEngine` |
| graph | n/a | `player → trim → EQ(low shelf 130 · peak 900 Q0.9 · high shelf 3600) → mixer(+dB) → varispeed → distortion(soft clip) → limiter tap → mainMixer` |
| boost | mapped to `setVolume(22…100 %)` and **labelled as such** | real, −12…+12 dB, clamped at 4× linear |
| meter | iframe time/ended events | RMS/peak/gain-reduction at the limiter tap |
| ToS | sanctioned | only legal with audio you may touch (your files, your resolver) |

Chain details and the Web Audio twin: [Y2K-LIQUID-GLASS-DESIGN.md §5](Y2K-LIQUID-GLASS-DESIGN.md#5-boost-chain-exactly-as-implemented-in-both-languages).

Presets (`Preset`, same raw values as the prototype's `PRESETS`): `flat`, `tape warm`,
`rain shelf`, `bass head`, `voice / pod`, `club (+12)`, `3am no-limiter`. The last one is
the only preset that switches the limiter off — deliberate, and the sheet says so in the
same colour as the warning.

## 5. Sheets: what each one must contain

* **Info** — description (with a re-pull button that says which source it is asking),
  credits (channel, `@handle`, licence, `creditOverride`, tags, gate rationale),
  timestamped tracklist (tap = seek), comments (top-order, PINNED / ARTIST REPLIED,
  `live` or `sample` provenance).
* **Boost** — big dB readout, gain slider, live meter with gain reduction and a clipping
  flash, presets, three EQ sliders with a reset, limiter + soft-clip toggles, slowed
  (0.85 / 1.00 / 1.15 + continuous), output trim, and the route note that explains which
  of these are currently wired to sound.
* **Hunt** — query field (the app prepends `lofi` if you didn't), mood chips, accepted
  results, **and the rejected ones with their score** — the gate has to show its work.
* **Crate** — kept discs, tap to play, `empty`. Stored as one JSON file in Application
  Support on iOS (`crate.json`), `localStorage` in the prototype.
* **Settings** — metadata source, API key (secure field), route, resolver base + token,
  gate on/off + strictness, recently rejected, look toggles, sleep timer, audio cache
  size + clear, and the fine print with links to the terms.

## 6. Persistence

| key | prototype | iOS |
| --- | --- | --- |
| settings, boost, crate | `localStorage["lofiglass.v1"]` | `UserDefaults["lofiglass.config.v1"]` (crate → `Application Support/LofiGlass/crate.json`) |
| API key | never stored | `AppConfig` for dev; **Keychain** before shipping (README says so) |
| resolved audio | n/a | `Library/Caches/LoFiAudio/<videoId>.<ext>`, LRU-capped at 20 files |

## 7. Verification

```bash
npm --prefix tools test          # gate parity · seed schema · swift symbols · xcodegen manifest
npm --prefix prototype run dev   # http://localhost:5173
cd ios && xcodegen generate && xcodebuild -project LofiGlass.xcodeproj -scheme LofiGlass \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

### Manual pass the sandbox cannot do

- [ ] `xcodegen generate` succeeds; app builds for a device running iOS 18 and iOS 26.
- [ ] Lottie-free cold start: status bar, one disc, `feed · seed` badge, no network call.
- [ ] Flick left three times → the queue advances, spin pauses with the play button.
- [ ] Flip vertical → sleeve shows tracklist; tapping a credit seeks (boosted route) or
      shows the timecode it would seek to (embed).
- [ ] `NOT LOFI` stamp appears when Settings raises strictness above a disc's score.
- [ ] Boost +12 dB on a downloaded file: meter pins, limiter pulls, no crackle on a 6-hour
      mix (memory is constant by construction: 384-frame chunks, 4 ahead).
- [ ] Same slider on the embed route: label says `player volume 100 %`, never `+12 dB live`.
- [ ] Airplane mode: deck still playable from the seed; hunt reports the refusal in one line.
- [ ] `node tools/gate-check.mjs` still prints `GATE OK` after any table edit.
