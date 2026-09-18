# lofi.glass

A Y2K liquid-glass lofi player: a vinyl deck you flick through, a VLC-style boost chain, and
a lofi-only gate between you and YouTube's search results. Two surfaces, one corpus, one set
of rules.

```
prototype/   mobile-web build (Vite, no framework) — the design lives here first
ios/         SwiftUI app, iOS 18+, Liquid Glass on iOS 26
shared/      the one seed corpus both surfaces read
docs/        spec, data-source research, design system
tools/       executable checks (gate parity, seed schema, swift symbols, xcodegen manifest)
```

## Run the prototype

```bash
npm --prefix prototype install
npm --prefix prototype dev        # → http://localhost:5173  (phone-sized, try device mode)
```

It works with no key and no network: the deck plays `shared/seed/lofi-feed.json` (21 real
discs) through YouTube's iframe player, and every control is live. Adding a YouTube Data API
v3 key in **Settings** turns search + comments real; choosing the `piped` source turns search
real without a key (the community-instance rotation is used, or paste your own hosts — public
instances die weekly).

## Build the iOS app

```bash
brew install xcodegen
cd ios && xcodegen generate && open LofiGlass.xcodeproj
```

`ios/README.md` covers the two routes (embed vs local boost engine), the resolver contract,
the API-key decision, and what is *not* verified.

## Checks

```bash
npm --prefix tools test
```

| check | guards |
| --- | --- |
| `tools/gate-check.mjs` | the lofi gate accepts 21/21 seed discs, rejects 4/4 non-lofi, 6 adversarial cases — **and** that `LofiFilter.swift` carries byte-identical tables to `lofi-filter.js` |
| `tools/seed-schema-check.mjs` | every non-optional field in `LofiModels.swift` exists in the seed JSON (a missing key is a Decodable crash at boot) |
| `tools/swift-symbol-check.mjs` | no undeclared `Y2K.token`, no duplicate top-level type |
| `tools/project-check.mjs` | `ios/project.yml` parses, source paths exist, Info.plist keys the code reads are set |

## What "only lofi" means in code

`score = Σ w(term)` over `title | description | tags | channel`, where terms are regexes with
weights (`lo[.\-\s]?fi` +5, `beats? ?to ?(relax|study|…)` +4, `deep house` −4,
`subliminal|affirmation|solfeggio|\d{3} ?hz` −3.5 …), `+2` for 15 curated channels, `+4` once
for 34 scene producers, ±duration nudges, **accept ≥ 4.0**. Settings can raise the floor,
never lower it, and the sleeve shows the score with the matched signals.
Full table: [docs/DATA-SOURCES.md §6](docs/DATA-SOURCES.md#6-the-lofi-gate--a-score-you-can-defend).

## Credit & terms

Metadata comes from the YouTube Data API (or a public mirror, or this repo's seed file);
playback goes through YouTube's own player. Scraping or ripping audio streams is not
sanctioned, so the app's "local boost engine" route plays **your** files via **your**
resolver and says so in the UI. Every disc shows the channel, the handle, and the timestamped
tracklist from the description, because lofi lives on crediting producers — see
[docs/DATA-SOURCES.md](docs/DATA-SOURCES.md) for what was actually fetched, and what is still
unverified.
