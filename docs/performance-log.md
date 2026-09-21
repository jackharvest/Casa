# Performance log

Findings that cost real measurement to discover. Each entry is here because it
was *not* obvious from the documentation, and because a future change could
silently undo it.

Reproduce any of it with the built-in harness:

```sh
Scripts/build-app.sh release
build/Casa.app/Contents/MacOS/Casa <image> --bench 40
log show --last 2m --info --debug \
    --predicate 'subsystem == "com.jackharvest.casa"' --style compact
```

Test corpus: 6016 × 6016 HEIC (~25 MB) and the same images transcoded to JPEG.
Machine: M1 Pro, macOS 26.6.2.

---

## 1. `CGImageSourceCreateThumbnailAtIndex` without a size cap returns the full image

The cheap rung of the ladder was decoding a 9000 × 9000 JPEG in its entirety —
324 MB and ~860 ms — from the call whose whole purpose was to avoid decoding.

`kCGImageSourceThumbnailMaxPixelSize` is what makes a thumbnail a thumbnail.
Omit it and you get native size, whatever the other flags say.

| | before | after |
|---|---|---|
| RSS | 1.05 GB | 307 MB |

## 2. `kCGImageSourceThumbnailMaxPixelSize` bounds the *output*, not the *decode*

Asking for 3840 px from a 6016 px source still transiently allocated the full
145 MB bitmap, then resampled it. True in JPEG as well as HEIC, so it is not a
codec quirk — it is what resampling to an arbitrary target costs.

`kCGImageSourceSubsampleFactor` reduces the decode itself. Powers of two only,
maximum 8; anything else falls back to a full decode.

| | before | after |
|---|---|---|
| JPEG sharp, median | 325 ms | **121 ms** |
| JPEG peak footprint | 595 MB | 297 MB |
| HEIC peak footprint | 380 MB | 295 MB |

## 3. `CGImageSourceCreateImageAtIndex` is lazy, and ignores EXIF orientation

It returned a 6016 × 6016 image in 1.3 ms because it had not decoded anything.
The work reappears on the render thread at first draw — a visible hitch,
relocated rather than avoided. It also skips the orientation transform every
other rung applies, so a rotated photo was correct until you zoomed in and then
turned sideways.

The full rung now uses the thumbnail API at native size, with
`kCGImageSourceShouldCacheImmediately` and `...WithTransform`.

## 4. Preloading during the foreground decode makes the foreground decode slower

Neighbor warm-up at `.utility` priority still competes for cores. Four HEIC
decodes alongside the one the user was waiting for stretched it from ~140 ms to
~390 ms. Preloading now starts only once the current image is sharp.

## 5. Sizing the display tier to the window over-asks by the aspect ratio

A 6016 × 6016 photo fitted into a wide window is only ever displayed as tall as
the window is *short*. Budgeting from the window's longest edge decoded detail
that was discarded on every frame, and pushed the subsample factor down a step.
Budgeting from what fit actually shows dropped the decode from 3840 px to
2680 px.

## 6. A byte-ceiling cache leaks; a shaped cache cannot

The first cache was one dictionary plus a 192 MB ceiling. It drifted to 310 MB
over a dozen navigations: every image passed through kept its ~60 MB screen
bitmap, and Core Animation's GPU-side copies were invisible to the accounting.

Replaced with two stores whose *shape* is the budget — one slot for the sharp
image, a count-bounded set of ~4 MB previews. Exceeding it now requires changing
the type, not forgetting a call.

## 7. `fit()` runs before any image is loaded

During window setup, with `imagePixelSize` still zero, `fit()` left `scale` at
its initial 1.0 and reported that as a zoom change — convincing the controller
the user had zoomed to 1:1 and triggering a full-resolution decode of a photo
that was not on screen yet.

---

## Current numbers

| Measure | HEIC 36 MP | JPEG 36 MP |
|---|---|---|
| Navigation → first pixels, median | **0.2 ms** | **0.2 ms** |
| Navigation → sharp, median | 165 ms | 121 ms |
| Steady-state footprint | ~120 MB | ~160 MB |
| Peak footprint (synthetic scrub) | 295 MB | 297 MB |

Cold launch, `open` → first pixels: ~530 ms, of which ~219 ms is process start
and AppKit, and the rest is the first decode. See *Open questions*.

## Open questions

- **~219 ms before we control anything.** 56 ms is `NSApplication.shared`; a
  further ~120 ms elapses between `applicationWillFinishLaunching` and the
  open-file event arriving. Not yet attributed. This is the main obstacle to a
  sub-100 ms cold launch, and may only be solvable with a resident helper —
  which trades exactly the memory frugality the app is for.
- **Peak footprint is still ~2.5× steady state** under synthetic scrubbing.
  Serializing screen-resolution decodes did not move it, so the remaining
  transient is inside a single decode.
- The preview rung is capped at 1024 px. Untested against 5K displays, where it
  may be visibly soft during the sharpen.

---

# Round two: the filmstrip, Finder sort, and the chrome

## 8. A dozen background decodes is not "background"

The rail asks for every visible thumbnail at once. Issued concurrently at
`.background` priority, each 320 px thumbnail took **3.2 s** instead of ~150 ms,
and dragged the foreground image the user was waiting for from 150 ms to
3259 ms with it.

Priority decides who wins a scheduling contest; it does not reduce the number of
contestants. Only bounding concurrency bounds the damage. Filmstrip decodes are
now strictly serial and yield to any screen-resolution decode first.

| | before | after |
|---|---|---|
| Strip decode | 3200 ms | 81–260 ms |
| Foreground preview | 3259 ms | 241 ms |

## 9. `wantsLayer` before `layer` silently discards your layer

The backdrop reported a correct frame and a correct background colour and never
appeared — the desktop showed straight through around the photograph.

Setting `wantsLayer = true` *first* makes a view layer-**backed**: AppKit owns
the layer and refreshes it, discarding properties set behind its back. A view
that hosts its own layer must assign `layer` **before** `wantsLayer`.

The actual fix was to delete the view. A non-opaque `NSWindow` with a
translucent `backgroundColor` is the same effect in one line, with no view, no
layer, and no geometry to keep in sync.

## 10. Cells keyed by index break the moment the list re-sorts

The filmstrip loaded a cell's thumbnail once, when the cell was created, and
kept it keyed by slot. Adopting Finder's sort order then re-lists the folder
underneath it and an image moves from slot 4 to slot 7 — so the thumbnail was
applied to whatever now occupied slot 4, and the real current image was the one
blank cell in the rail.

Anything cached against a position in a list that can be re-ordered has this
bug. Contents are now bound to the URL, and re-bound whenever the URL at a slot
changes.

## 11. One file, two URLs

A file opened from Finder arrives as `/tmp/photo.jpg` while `FolderScanner`
re-lists it as `/private/tmp/photo.jpg`. Both open correctly, and the scanner
matched them because it compared standardized paths — but every URL-keyed cache
downstream then held two keys for one photograph.

`Session.open` now normalizes once, at the boundary, and the scanner emits the
same form. Path identity is not a thing to reason about twice.

## 12. Testing Automation permission from a terminal gives false positives

TCC attributes Automation consent to the *responsible process*. A build launched
from a shell inherits the terminal's existing permission to control Finder and
cheerfully reports `granted` when the app itself has no such right; launched
with `open -a`, the same binary correctly reports `notDetermined`.

Verify anything TCC-gated the way a user launches it. Ad-hoc signatures also
change on every rebuild, so grants do not survive a build — a stable self-signed
identity is worth having for development.

## 13. Promoting an image to sharp made the preloader re-decode it

Storing the screen-resolution bitmap drops the image's cheap preview as
redundant. The preloader then saw a gap in its window and immediately decoded
the very image already on screen — a whole wasted decode per navigation.

## 14. A bottom-anchored rail lands under the Dock

A borderless window at `.normal` level sits under the Dock, so chrome pinned to
the bottom edge is partly unusable. The window now sizes to `visibleFrame` by
default; "Hide Dock for Larger Preview" (⇧⌘D) opts into the full-bleed look via
presentation options rather than a full-screen Space.

---

## Numbers after round two

| Measure | Value |
|---|---|
| Navigation → first pixels, median | **1.0 ms** (40 steps) |
| Navigation → sharp, median | 190 ms |
| Cold launch → first pixels | ~465 ms |
| Steady-state footprint | ~230 MB |
| Peak footprint (synthetic scrub) | 567 MB |

**Memory regressed and is the open item.** Before the rail, steady state settled
around 90–120 MB. Thumbnails themselves only account for ~24 MB (60 × 320² × 4),
so the rest is unexplained and worth a pass with Instruments' Allocations
instrument now that Xcode is installed.

---

# Round three: formats, playback, multi-monitor

Format coverage is now a measurement, not a claim:

```sh
build/Casa.app/Contents/MacOS/Casa --selftest <folder>
```

It walks every file through the real `ImageSource` ladder and reports pixels,
frames, the best rung reached, and timing. Exit code is non-zero on any
regression, so it works as a CI gate. Fixtures named `bad_*` are deliberately
malformed and are expected to be *rejected*.

Current result on a 37-file corpus: **33/33 displayable · 2 animated · 2 video ·
4/4 malformed rejected safely**.

## 15. `CGImageSourceCreateThumbnailAtIndex` sizes the output, not the decode

See finding 2 — but it bears restating, because the same trap appears once per
new rung added.

## 16. Deliberately malformed files are worth keeping in the corpus

A zero-byte file, a truncated JPEG, 4 KB of `/dev/urandom` named `.png`, and an
empty file named `.jpg`. All four are rejected without incident.

Worth noting: `qlmanage` **abort-traps** on the zero-byte one. Apple's own
Quick Look crashes where this does not, which is a reasonable bar to hold.

## 17. A file that cannot be decoded left the previous photograph on screen

Navigating onto an unreadable file painted nothing, so the *previous* image
stayed up under the *new* filename — which looks exactly like a file that
opened fine. Found because the benchmark hung on it rather than by looking.

The canvas is now cleared and the chrome says so. The benchmark counts such a
file as a completed step and excludes it from the timings.

## 18. Priority is not concurrency, again

Filmstrip decodes at `.background` saturated the machine (finding 8). The same
shape recurred with video poster frames until they were routed through the same
serialized path.

## 19. Moving between displays of different density silently halves resolution

Nothing in the cache can detect this: the tier is unchanged and the bitmap is
still "valid" for that tier, but a 1x display needs half the pixels a 2x one
does for the same apparent size. Dragging the window from the 1x 4K panel to
the 2x built-in left the photograph at 2294 px where it needed 2713 px, for as
long as it stayed there.

`viewDidChangeBackingProperties` now triggers a forced re-decode, preserving
zoom and pan. Verified with `--migrate-screens 0,1`:

```
display IMG_1.heic -> 2294x2294     (opened on the 1x panel)
migrating to screen 1 (2.0x)
display IMG_1.heic -> 2713x2713     (re-decoded)
```

## 20. Memory tracks the display, which is not the same as tracking the panel

Measured across three attached displays, 30 navigations of 36 MP HEICs each:

| Display | Decode | Steady | Peak |
|---|---|---|---|
| 3840 × 2160 @ 1x | 2294² | 122 MB | 276 MB |
| 2056 × 1329 @ **2x** | **2713²** | 136 MB | 299 MB |
| 1200 × 1920 @ 1x portrait | **1440²** | 111 MB | 157 MB |

The Retina panel is physically the smallest and costs the *most*, which is
correct — it has the most pixels. The portrait panel costs least because the
aspect-aware budget (finding 5) notices that a square photograph fitted into a
tall narrow window is bounded by its width.

**The earlier memory regression did not survive scrutiny.** Round two measured
~230 MB steady; the same benchmark now measures 111–136 MB depending on display.
The difference is the single-slot cache and the serialized decodes settling —
the 230 MB reading was taken immediately after a synthetic hammer with several
decodes still unwinding.

---

## Numbers after round three

| Measure | Mixed corpus | 36 MP HEIC folder |
|---|---|---|
| Navigation → first pixels, median | **3.7 ms** | **0.8–1.6 ms** |
| Navigation → sharp, median | 15.7 ms | 196–207 ms |
| Steady-state footprint | 96 MB | 111–136 MB |
| Peak footprint | 161 MB | 157–299 MB |

Cold launch → first pixels: ~465 ms, of which ~200 ms is process start and
AppKit. Still the one number short of target.
