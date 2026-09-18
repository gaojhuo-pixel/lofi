# Y2K liquid glass — the design system, and how each surface realises it

The brief was a contradiction on purpose: **1999 optimism about the future, rendered with
2025's material language.** Translucent candy plastic, chrome that catches a light source
that isn't there, a CRT overlay you can switch off — laid out with Liquid Glass depth,
refraction and tint instead of skeuomorphic bevels.

Two implementations share one token set:

| | web prototype | iOS app |
| --- | --- | --- |
| tokens | `prototype/src/styles.css` `:root` | `ios/LofiGlass/Theme/Y2KTheme.swift` |
| material | `backdrop-filter` + masked pseudo-rings | `GlassStyle.swift` → `glassEffect(.regular.tint().interactive())` on iOS 26, `Material` fallback on 18/19 |
| ornaments | CSS gradients + keyframes | `Y2KComponents.swift` (Canvas / TimelineView) |
| refraction | SVG `feDisplacementMap` behind `@supports` | iOS 26 glass; nothing on 18/19 (documented, not faked) |

Every number below appears in both files; `tools/swift-symbol-check.mjs` keeps the Swift
side from referencing a token nobody declared.

## 1. Palette

| token | hex | role |
| --- | --- | --- |
| `void` | `#0b0720` | base field. Not black: a violet-black keeps neon from looking cheap |
| `void-2` | `#170c38` | top of the radial wash |
| `plum` | `#2b0b4a` | the plasma blob behind the disc |
| `pink` | `#ff37d3` | action, LIVE, boost-hot, rejection |
| `magenta` | `#d6009c` | lower half of pink gradients only |
| `cyan` | `#46f8ff` | data, links, glass edge highlight, "cool" half of every chrome bevel |
| `lime` | `#b7ff2e` | the `LOFI ✓` / limiter-on / accepted signal |
| `butter` | `#ffe9a8` | numbers you read at a glance: clock, dB, counts |
| `chrome-hi/mid/lo` | `#ffffff / #b9c4f5 / #4a5296` | the bevel ramp — mid is periwinkle, not grey, so it reads "space" not "Excel 97" |
| `ink` | `#eaf0ff` | body text on glass |
| `ink-dim` | `#99a1d6` | secondary; the only grey-blue allowed |

Contrast: `ink` on `void` ≈ 13.5:1, `ink-dim` on `void` ≈ 6.6:1, `cyan`/`lime`/`butter` on
`void` all ≥ 10:1. Pink is never used for body text — only ≥ 15 px display type or as a
stroke/glow, because `#ff37d3` on violet sits around 4.5:1.

Backgrounds are never flat. `Y2K.voidBackdrop` / `body` reproduce the same three-part stack:

1. radial wash `120% 90% at 50% -10%` → `#350f5c → void-2 → void`;
2. starfield — six 1–1.5 px radial dots, `twinkle 5.5s steps(4)`. Steps, not ease: it must
   flicker like a bad CRT, not breathe like a screensaver app;
3. horizon grid — `repeating-linear-gradient` 1 px lines at 46 px/34 px, masked to fade at
   78 % height, `gridrun 9s linear infinite`. The perspective grid is the single most
   loaded Y2K signifier, so it sits *behind* everything at ~20 % alpha and moves slowly.

## 2. Type

| role | web | iOS | why |
| --- | --- | --- | --- |
| display | Michroma | `Y2K.display(–)` → Michroma, fallback **SF Rounded Semi Bold** | wide-tracked geometric caps ≈ Eurostile, the Y2K face. `tracking = size × 0.08` |
| pixel readout | VT323 | `Y2K.pixel(–)` → VT323, fallback SF Rounded Mono | clock, timecode, dB, counts: the terminal is the era's other half |
| body | Titillium Web | **SF Rounded** (`Y2K.body`) | iOS never ships Titillium; SF Rounded is the closest native face and beats a license headache for body copy |

Rules that matter more than the faces:

* **Digits get the pixel face; sentences never do.** VT323 at 11 px is illegible as prose
  and perfect as `3:41`.
* Both `display()` and `pixel()` use `relativeTo:` so Dynamic Type still scales them —
  the Y2K look is not allowed to break accessibility.
* Tracking on display type is positive (`0.06–0.1 em`); negative tracking reads 2014.
* If the fonts are absent (they are, unless you add the `.ttf`s per
  `ios/LofiGlass/Resources/Fonts/README.md`), the fallbacks keep the *rhythm* — sizes and
  tracking are unchanged, so the layout is identical.

## 3. Glass

One recipe, three layers — the trick is that a real glass panel needs a **thickness**, not
just a blur.

```
┌ specular sheen   web `.glass::after`: radial 180×120 at --mx/--my, white 22 % → transparent 70 %
│                iOS: `specular` in GlassStyle.swift, same shape, driven by `onContinuousHover`
├ hairline rim     web `.glass::before`: 1 px white 55 %, masked with `mask-composite: exclude`
│   └ refraction   web: backdrop-filter url(#glass-refract) — feTurbulence + feDisplacementMap
│                  scale 14, then blur(0.6px) saturate(1.25) — only inside @supports
│                  iOS 26: `.glassEffect(…, in: shape)` gives the refractive rim for free
├ fill             white 10 % (GlassTint.clear) / 16 % when tinted, linear 150° 16 %→3 %→10 %
└ blur             backdrop-filter: blur(22px) saturate(165%) brightness(1.12)
```

* **Web** (`.glass` in `styles.css`): the ring is a masked border so it can catch light
  without a second element; `@supports (backdrop-filter: url(#a) blur(1px))` adds the SVG
  displacement refraction, and `body[data-refract="off"]` drops it (Settings toggle).
* **iOS**: `GlassPanel` applies the real thing when it exists —

  ```swift
  if #available(iOS 26.0, *) { view.glassEffect(.regular.tint(tint.fill).interactive(), in: shape) }
  else { view.background(.ultraThinMaterial, in: shape) … }   // 18/19
  ```

  The pre-26 fallback is material + tint + a `strokeBorder` gradient rim
  (`.white 0.55 → .white 0.06 → Y2K.cyan 0.30`, `Y2K.stroke = 1.2 pt`) plus
  `.shadow(color: .black.opacity(0.45), radius: 22, y: 14)` — the same drop the CSS
  `.glass` box-shadow casts. The fallback is deliberately *material + edge*, not a fake blur:
  no per-frame `UIGlassEffect` reimplementation, no Metal. The design doc records the loss
  instead of hiding it.
* Corner radii come from the token set — `Y2K.cornerXL 34`, `cornerL 26`, `cornerM 18`,
  `stroke 1.2 pt`. Sheets use `presentationCornerRadius(30)` (≈ 34 minus the safe-area
  squeeze). Small parts — chips 9, meters 7, marquee 6 — carry inline radii instead of a
  token: the web `--r-sm: 12px` reads too soft on a phone pixel grid, and that is the one
  place the two surfaces intentionally do not share a number.

`GlassTint` is a five-case enum (`clear, pink, cyan, lime, chrome`) rather than a
`Color`, because a tint is not the same thing as a fill: `clear` is the *structural* glass
(deck, big sheets), the coloured ones mean something (pink = you are changing sound,
lime = a guard is on, cyan = informational chrome, chrome = the metal bits).

## 4. Ornaments (`Y2KComponents.swift` ↔ CSS)

| component | looks like | note |
| --- | --- | --- |
| `Starburst` | 12-point mint star | the era's "new!" badge; used for LIVE and the 4× boost cap |
| `ScanlineOverlay` | 3 px lines at 6 % white + a corner-darkening vignette | static in both languages (lines that move are a headache, not a texture); `allowsHitTesting(false)`, opacity scales with the setting |
| `GridHorizon` | perspective grid | `Canvas` at 24 fps with a `pow(phase, 2.1)` floor; freezes under Reduce Motion, keeps the pattern |
| `ChromeMarquee` | the scrolling banner | scrolls only when the string is wider than its container (measured with a background GeometryReader), `16 s linear` — the same duration as the web `roll 16s linear infinite` |
| `PixelBadge` | tiny VT323 chip | source badges (`seed cache`, `piped`) |
| `TagPill` | glass capsule | gate-derived tags, `#` stripped by the parser |
| `BoostMeter` | bar + gain-reduction needle | driven by `AudioBoostEngine.Metering`, pink flash over −0.5 dB reduction |
| `VinylSurface` | grooves + label + cover, spinning | angle integrated from `TimelineView` dates so a pause keeps the needle position; `period = clamp(duration/700, 2.2, 7.5)` s, same curve as `deck.js`, frozen when paused and under Reduce Motion |

Chrome text (`Y2K.chrome` / `.chromeText(_:)`):
`linear-gradient(#fff 8 %, chrome-mid 38 %, chrome-lo 52 %, #f2f7ff 60 %, chrome-mid 78 %,
#6f7ac4 100 %)` plus two zero-radius drop shadows (pink 1.5 px below, cyan 6 px above).
Letter-spacing is applied per call site (`.tracking(1.4…3)`) rather than inside the font
helper, because a wordmark and a section label want different values.
The hard stop at 52→60 % is the reflective line — soft chrome looks like grey, hard chrome
looks like plastic. On iOS the same gradient is a `foregroundStyle(LinearGradient)` with the
`.shadow` pair; that is the one place where text is *not* a solid colour, so the doc flags
it: never gradient-fill running text, only wordmarks and numbers.

## 5. Boost chain (exactly as implemented in both languages)

```
input → trim → low shelf 130 Hz → peaking 900 Hz Q0.9 → high shelf 3600 Hz
      → gain = 10^(dB/20)          (−12…+12 dB, clamped at 4×)
      → limiter                    (web: DynamicsCompressor −6→−24 dB, ratio 16, knee 3,
                                     atk 3 ms, rel 140 ms · iOS: feedback limiter tap,
                                     ceiling −1 dBFS, release 6 dB/s, max −24 dB)
      → soft clip                  (tanh curve / AVAudioUnitDistortion .sloppyCrunch)
      → output → analyser (fft 1024, smoothing 0.72)
```

Parity is at the *decibel and control surface* level, not the DSP internals — that is the
honest claim. The iOS limiter is a gain-pull feedback loop because iOS exposes no
lookahead limiter; the web one is a compressor WebAudio actually meters. Both report
`gain reduction` and a clipping flag, and both are documented in
[DATA-SOURCES.md §7](DATA-SOURCES.md#7-playback-and-the-boost-problem).

## 6. Motion

| motion | value | easing |
| --- | --- | --- |
| card change | `.spring(duration: 0.5, bounce: 0.22)` keyed on `track.videoId` | the record dropping onto the platter |
| swipe commit / reject | `.spring(duration: 0.4, bounce: 0.2)` | small bounce = it settles, it does not snap |
| flip | `.spring(duration: 0.45, bounce: 0.25)`, plus `.easeOut(0.3)` on the layer swap | a sleeve has mass |
| sheet | system `.presentationDetents` + `presentationCornerRadius 30` | don't fight the OS |
| spin | `linear`, duration from track length | nothing else may ease — a record does not accelerate |
| marquee | 26 s web / `speed` pt/s iOS | linear, and it pauses with reduce-motion |
| boost readout | `contentTransition(.value)` + 0.25 s spring | the number should feel like a dial |
| meter | 30 fps `TimelineView(.animation)` / rAF | the analyser already smooths at 0.72, so the view must not |
| CLIP lamp | `BoostMeter` shows `CLIP` in pink while `peak > 0.985` | the only red in the whole app |

Reduce-motion: CSS disables `twinkle`, `gridrun`, `float`, `roll` and `spin` under
`@media (prefers-reduced-motion: reduce)`; iOS reads `@Environment(\.accessibilityReduceMotion)`
inside `GridHorizon`, `ChromeMarquee` and `VinylSurface` — the ornaments freeze in place
rather than disappearing, because the grid and the chrome are identity, the drift is not.
Motion is decoration here, never information.

## 7. Divergences we chose (so nobody calls them bugs)

1. **No Metal refraction on iOS 18/19.** `.glassEffect` is the only sanctioned way to get
   it; reimplementing it with `CIColorKernel` would look worse and cost a frame budget.
   The material fallback keeps the rim + tint + shadow, which is 80 % of the read.
2. **Body font is SF Rounded on iOS**, Titillium on web (§2).
3. **The web deck commits on velocity** (`≥ 0.55 px/ms`); `DragGesture` on iOS has no
   timestamps, so the native deck commits on distance alone. Adding `TimelineView`-sampled
   positions was judged against a 92 pt threshold and not worth the complexity — but it is
   a real behavioural difference, so it is written down.
4. **Web audio is a real graph; the iOS embed route is not** — see `routeWarning`. The UI
   copy differs per route on purpose, so neither surface can imply the other's capability.
5. **Scanlines are a toggle, defaulting on in the prototype and off-safe on iOS** where the
   notch and Dynamic Type already compete for the pixels.
