# Casa

**A fast, chromeless photo viewer for macOS.**


A macOS image viewer in the shape of Google's Picasa Photo Viewer: it appears
instantly over whatever you were doing, lets you walk a folder with the arrow
keys, and gets out of the way.

Working name — Picasa is Google's trademark and this cannot ship under it.

## Status

Early. The core loop works: open, navigate, zoom, rotate, dismiss.

| Trait | State |
|---|---|
| 01 Instant cold start | Partial — ~465 ms; see `docs/performance-log.md` |
| 02 Chromeless translucent overlay | Done |
| 03 Preloaded arrow navigation | Done — 1 ms median to first pixels |
| 04 Zoom to cursor | Done |
| 05 Filmstrip | Done — centred on the current image, click to jump, scroll to scrub |
| — Formats | 62 ImageIO types + PDF + SVG + video; **33/33** in the self-test |
| — Playback | Animated GIF/APNG/WebP/HEICS and video, with one three-state policy |
| — Multi-monitor | Opens on the invoking display; re-decodes on density change |
| 06 Disposable dismiss | Done |
| 07 Follows Finder sort order | **Done** — list and icon views; off by default (needs Automation consent) |

Trait 07 is the differentiator: no other macOS viewer does it. Turn it on in
View › Use Finder's Sort Order. Finder exposes the sort for list and icon views
only; column and gallery views fall back to name order, which is also Finder's
own default there.

> **Picking this up again?** Start with [`docs/NOTES.md`](docs/NOTES.md) — full
> handoff: state, environment, commands, open items, and the traps that cost
> time the first round.

## Build

No Xcode project. SwiftPM produces the binary; `Scripts/build-app.sh` wraps it
in the bundle layout Launch Services needs.

```sh
Scripts/build-app.sh release      # -> build/Casa.app
open -a build/Casa.app ~/Pictures/some.jpg
```

## Test

The corpus is synthesized from files macOS already ships, so nothing large is
committed and it reproduces on any Mac:

```sh
Scripts/make-corpus.sh            # -> build/corpus, build/corpus-large

# Format coverage. Exits non-zero on regression.
build/Casa.app/Contents/MacOS/Casa --selftest build/corpus

# Navigation benchmark
build/Casa.app/Contents/MacOS/Casa build/corpus-large/IMG_1.heic --bench 40

log show --last 2m --info --debug \
    --predicate 'subsystem == "com.jackharvest.casa"' --style compact
```

Debug flags: `--bench <n>`, `--selftest <dir>`, `--keep-chrome`, `--screen <n>`,
`--migrate-screens <a>,<b>`, `--finder-sort-probe <dir>`.

## Layout

```
Sources/Casa/
  App/       main, AppDelegate, menu bar
  Core/      no AppKit below this line
    ImageSource      the four-rung decode ladder (ImageIO)
    ImagePipeline    the only place bitmaps are held; an actor
    FolderScanner    sibling enumeration and ordering
    Session          navigation state machine
    SupportedTypes   what we can open, asked of ImageIO at runtime
  UI/        ViewerWindow, ImageCanvasView, ChromeView, IconButton
  Support/   Metrics, Accommodations, Log, LaunchClock, Benchmark
```

## Principles

**Paint both sides of the fence.** The internals get the same care as what's
visible. There is no part of this app that is "just" plumbing.

**Nothing hardcodes a size.** Every dimension derives from the user's resolved
text size, so display density, system text size and SF Symbol optical scaling
all move together. Accommodate, accommodate, accommodate.

**Gobs of convenience, not gobs of knobs.** Where a setting is needed it gets
one control with named outcomes, never a matrix of booleans the user has to
assemble the behaviour out of.

## Three ideas the code is organized around

**The decode ladder.** Never decode more than you are about to show. Four rungs,
cheapest first — the camera's embedded preview, a small real decode, the
screen-resolution decode, and the full bitmap only once someone zooms past it.
`Session.loadCurrent` walks them in order and paints each as it lands, so the
window is never blank and the picture sharpens in place.

**Memory is bounded by shape, not by accounting.** `ImagePipeline` has one slot
for the sharp image and a count-bounded set of cheap previews. A budget you have
to remember to enforce is a budget that leaks; this one cannot be exceeded
without changing the type. See finding 6 in the performance log for what the
accounting version actually did.

**Nothing hardcodes a size.** Every dimension comes from `Metrics`, derived from
the user's resolved text size, so display resolution, system text size and SF
Symbol optical scaling all move together. `Accommodations` does the same for
Reduce Transparency, Reduce Motion, Increase Contrast and Differentiate Without
Color — an app whose entire premise is a translucent overlay has to treat the
setting that disables translucency as a layout input, not an afterthought.

## Formats

Everything ImageIO decodes — 62 types, 70 extensions, including ~30 camera RAW
formats, HEIC, AVIF, WebP, JPEG XL, PSD, TGA, EXR and DICOM — plus **PDF** and
**SVG** (rendered by `VectorSource`, and re-rendered rather than magnified when
you zoom) and **video** (poster-framed into the ladder by `VideoSource`, so the
filmstrip and preloader need no knowledge of it).

Verify with the self-test, which exits non-zero on a regression:

```sh
build/Casa.app/Contents/MacOS/Casa --selftest <folder>
# 33/33 displayable · 2 animated · 2 video · 4/4 malformed rejected safely
```

## Playback

Animated images and video share one setting with three outcomes — View ›
Playback: **Click to Play** (default), **Play Automatically (Muted)**, **Play
Automatically (With Sound)**. Deliberately not three switches: "autoplay?" and
"muted?" as independent booleans produce a nonsense combination and make the
user assemble the behaviour they wanted out of parts.

Animations are driven by a single discrete `CAKeyframeAnimation`, so a looping
GIF runs on the render server at no CPU cost and keeps moving while the main
thread decodes the next photo.

## Docs

- [`docs/NOTES.md`](docs/NOTES.md) — **start here**: full project handoff
- `docs/performance-log.md` — 20 measured findings, each one a thing that
  sounded obviously true and was not
- `docs/keyboard.md` — the full keyboard and pointer map
- `docs/landscape.html` — competitive research: why this exists, the macOS
  viewer landscape, and a running log of what measurement changed

---

## Author

Built by **Jack Harvest**.

Software developer by day. Casa is a personal project, built with heavy use of
AI coding tools — the architecture, the measurements and the decisions are mine,
and the tooling helped me move a lot faster than I would have alone. Every
finding in `docs/performance-log.md` was measured on real hardware, not assumed.

Licensed under the [MIT License](LICENSE).
