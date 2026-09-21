# Project notes

Written to make picking this up again cheap. Everything here is either
non-obvious, hard-won, or would cost an hour to rediscover.

Last worked on: **21 September 2026**.

Repo: <https://github.com/jackharvest/Casa> · Released through GitHub Releases,
signed, and installed in place by the app itself.

---

## 1. What this is

A macOS image viewer shaped like Google's **Picasa Photo Viewer** — the small
separate binary Google shipped alongside Picasa-the-library, not the library
itself. The nostalgia is specifically for the viewer: it appeared instantly over
whatever you were doing, let you walk a folder with the arrow keys, and got out
of the way.

macOS-only by choice. Cross-platform is explicitly not wanted.

`Casa` is a placeholder. **It cannot ship under that name** — Picasa is
Google's trademark. Naming directions worth exploring: the lightbox/loupe
vocabulary, or the disposability idea (it appears, you look, it's gone).

### The seven traits

Derived from what people actually miss, ranked by contribution to the feeling.
This list is the spec; `docs/landscape.html` has the full reasoning.

| # | Trait | State |
|---|---|---|
| 01 | Sub-100 ms cold start | **~465 ms** — the one number short |
| 02 | Borderless translucent overlay | done |
| 03 | Arrow keys with adjacent images preloaded | done — ~1 ms to first pixels |
| 04 | Scroll wheel zooms to the cursor | done |
| 05 | Toggleable filmstrip | done |
| 06 | Escape / double-click dismisses | done |
| 07 | Respects the file manager's sort order | **done — the differentiator** |

### Why trait 07 is the wedge

Researching the whole macOS field turned up exactly one prior attempt at a
Picasa-viewer clone ([Thecentury/picasa](https://github.com/Thecentury/picasa),
F#/Avalonia, 7 stars, abandoned, never packaged). Everything else is either a
Preview replacement or a library manager.

**No macOS viewer follows Finder's sort order.** Not one. If you've sorted a
folder by date-added and open the third photo, every other viewer walks it
alphabetically — quietly wrong, every time. That is the thing to defend.

---

## 2. Environment

| | |
|---|---|
| macOS | 26.6.2 (build 25G83) |
| Xcode | 27.0 (27A266a) — installed mid-project; license accepted |
| Swift | 6.3.3, **language mode 6**, strict concurrency, zero warnings |
| Hardware | M1 Pro |
| Target | macOS 14+ |

**No `.xcodeproj`.** SwiftPM builds the binary; `Scripts/build-app.sh` wraps it
in the bundle layout Launch Services needs. This started as a workaround for
having only Command Line Tools and stayed because it is simpler. Xcode is still
worth having for **Instruments**, which is the tool for the remaining
open items.

### Displays on the dev machine

Relevant because density bugs only appear across a mismatch, and **the main
display is 1×, not Retina** — easy to forget when reading old measurements.

| Index | Display | Size | Scale |
|---|---|---|---|
| 0 | HP Z32k G3 (main) | 3840 × 2160 | **1.0×** |
| 1 | Built-in Retina | 2056 × 1329 | **2.0×** |
| 2 | HP Z24n G3 | 1200 × 1920 portrait | 1.0× |

All three report `maxEDR = 1.0`, so **HDR cannot be developed honestly on this
machine** — there is no display that can show the result.

---

## 2b. Release and update pipeline

**Versioning.** `VERSION` at the repo root is the single source of truth.
`Scripts/build-app.sh` stamps it into `Info.plist` as
`CFBundleShortVersionString`, and `CFBundleVersion` becomes the git commit count
— monotonic, reproducible from any checkout, no state of its own.

**Signing.** `Scripts/keygen.sh` was run once. The Ed25519 public key is
compiled into `Update/UpdateSecurity.swift`; the private key lives at
`private/casa-update.key` (mode 600, gitignored).

> **The private key must be backed up.** If it is lost, every installed copy of
> Casa will correctly reject all future updates, and users will have to
> reinstall by hand. Rotating it has the same effect.

**Cutting a release.**

```sh
echo 0.4.0 > VERSION
git commit -am "…"            # release.sh refuses a dirty tree
Scripts/release.sh --dry-run  # build, package, sign — publishes nothing
Scripts/release.sh            # tags, pushes, creates the GitHub release
```

Three assets are published per release: `Casa-x.y.z.zip`, `.zip.sha256`, and
`.zip.sig`. The app finds the archive by extension rather than exact name, so
the naming scheme can change without stranding installed copies.

**How the update actually lands.** Verified end to end on 21 Sep (0.1.0 → 0.2.0
in a writable location, log evidence in the commit history):

1. Daily throttled check against `/repos/<repo>/releases`, silent unless it has
   something to offer
2. Download, streamed to `~/Library/Caches/<bundle-id>/Updates` with progress
3. SHA-256 digest compared, **and** Ed25519 signature verified against the
   compiled-in public key
4. `ditto -x -k` into an `.itemReplacementDirectory` on the same volume —
   `ditto`, not `unzip`, because `unzip` strips the code signature
5. Validated: bundle identifier matches, version is strictly newer, code
   signature intact
6. `FileManager.replaceItemAt` — atomic, same volume
7. A detached `/bin/sh` polls until this PID exits, then reopens the app *with
   the photograph that was on screen*

Everything that can fail does so before step 6, so a failed update leaves the
running app untouched.

**Known limitation.** `UpdateInstaller.canInstallInPlace` refuses when the
bundle or its parent is not writable, which is checked *before* offering the
update rather than after a download. A privileged install (`/Applications`
owned by root) would need `SMJobBless` or an admin prompt and is not built.

## 2d. Icon, DMG, and the welcome screen

**The icon is code**, not a file: `Scripts/IconTools/MakeIcon.swift` draws a
superellipse tray (`n = 5`, which is much closer to Apple's continuous-curvature
corners than a plain rounded rect) and eight multiply-blended blades fanned from
a pivot at 30%/13% of the well. `Scripts/make-icon.sh` renders all ten sizes and
runs `iconutil`. `Resources/Casa.icns` is gitignored and generated on demand by
`build-app.sh`.

Three things carried most of the likeness to the reference, in order: making the
blades wide enough to genuinely overlap (the overlap *is* the effect), a
two-tone edge so individual blades stay readable where three of them cross, and
uneven angles and lengths — evenly spaced equal blades read as a pie chart.

**The DMG** is built by `Scripts/make-dmg.sh`: staging directory, read-write
image, Finder driven over AppleScript to set the window and icon positions,
then converted to compressed read-only. Two traps, both hit:

- AppleScript `bounds` is `{left, top, right, bottom}`, **not**
  `{x, y, width, height}`. Passing the size directly makes a window far too
  small and the icon positions land outside it.
- The window *content* area is ~28 px shorter than the frame, so background
  artwork below roughly 0.19 of the height is clipped by Finder's chrome.

It needs Automation permission for Finder on the machine cutting the release.

**The welcome screen** (`UI/WelcomeWindowController.swift`) is what a bare
launch shows. `Core/DefaultHandler.swift` reads the current handler per group
via `NSWorkspace.urlForApplication(toOpen:)` and claims types with
`NSWorkspace.setDefaultApplication(at:toOpen:)` — note the label is `toOpen:`,
not `toOpenContentType:` as the older documentation suggests. There is **no**
System Settings pane for per-type image handlers, so the fallback explains
Finder's Get Info route rather than opening a pane that cannot help.

## 2c. Regenerating README media

```sh
swiftc -O Scripts/MediaTools/WindowList.swift -o build/media-tools/WindowList
swiftc -O Scripts/MediaTools/MakeGif.swift    -o build/media-tools/MakeGif

build/media-tools/WindowList Casa      # -> "<id> <x> <y> <w> <h> <name> | <title>"
screencapture -x -o -l <id> out.png    # captures exactly that window
build/media-tools/MakeGif out.gif 0.32 820 frames/*.png
```

`WindowList` exists because guessing crop offsets wasted several rounds —
`screencapture -l <windowid>` targets a window exactly and includes its shadow.
For the navigation GIF, launch with `--keep-chrome --bench 60` and capture in a
loop; the benchmark advances roughly every 180 ms, so consecutive captures are
genuinely different photographs.

## 3. Commands

```sh
# Build the app bundle (ad-hoc signed, Launch Services registered)
Scripts/build-app.sh release          # -> build/Casa.app

# Regenerate the test corpus (synthesized from system files; nothing committed)
Scripts/make-corpus.sh                # -> build/corpus, build/corpus-large

# Format coverage. Exits non-zero on regression — usable as a CI gate.
build/Casa.app/Contents/MacOS/Casa --selftest build/corpus

# Navigation benchmark
build/Casa.app/Contents/MacOS/Casa build/corpus-large/IMG_1.heic --bench 40

# Read the instrumentation
log show --last 2m --info --debug \
    --predicate 'subsystem == "com.jackharvest.casa"' --style compact
```

### Debug flags

| Flag | Purpose |
|---|---|
| `--bench <n>` | Auto-navigate *n* steps, report first-pixel and sharp latencies |
| `--selftest <dir>` | Decode every file, print a coverage table, exit non-zero on failure |
| `--selfcheck` | Assert zoom anchoring, the dismiss surround, version ordering and the digest against the real views; exits non-zero on failure |
| `--keep-chrome` | Pin the chrome open — design review otherwise races the auto-hide |
| `--screen <n>` | Open on a specific display, for density testing |
| `--migrate-screens <a>,<b>` | Open on *a*, move to *b* after 3 s — tests the density re-decode |
| `--finder-sort-probe <dir>` | Report what Finder says about a folder's sort order |

**`--finder-sort-probe` must be run via `open -a`, not by executing the binary.**
See the TCC trap in §6.

---

## 4. Architecture

```
Sources/Casa/
  App/       main, AppDelegate, MenuBuilder
  Core/      no AppKit below this line
    ImageSource      the decode ladder (ImageIO)
    VectorSource     PDF and SVG rendering
    VideoSource      poster frames and asset loading (async)
    Animation        multi-frame decoding
    ImagePipeline    the only place bitmaps are held; an actor
    FolderScanner    sibling enumeration and ordering
    FinderSort       trait 07 — reads Finder's sort order
    Session          navigation state machine
  Update/    the updater, top to bottom
    SemanticVersion  proper version comparison
    UpdateSecurity   SHA-256 + Ed25519; fails closed
    UpdateRelease    GitHub release JSON, decoded loosely on purpose
    UpdateChecker    the daily query
    UpdateDownloader streamed, with progress
    UpdateInstaller  stage, validate, atomic swap, relaunch
    UpdateController one state at a time
    SupportedTypes   what we can open, asked of ImageIO at runtime
    FormatSelfTest   the coverage harness
  UI/        ViewerWindow, ImageCanvasView, ChromeView, FilmstripView, IconButton
  Support/   Metrics, Accommodations, Preferences, Log, LaunchClock, Benchmark
```

### Four ideas the code is organised around

**1. The decode ladder.** Never decode more than you are about to show. Five
rungs, cheapest first: `strip` (320 px, filmstrip) → `thumbnail` (the camera's
embedded preview, free when present) → `preview` (1024 px, always succeeds) →
`display` (screen resolution) → `full` (only once someone zooms past it).
`Session.loadCurrent` walks them and paints each as it lands, so the window is
never blank and the picture sharpens in place.

**2. Memory is bounded by shape, not by accounting.** `ImagePipeline` has *one
slot* for the sharp image and count-bounded sets of cheap previews and strip
thumbnails. A budget you have to remember to enforce is a budget that leaks —
the first version was a byte ceiling and drifted to 310 MB, partly because Core
Animation's GPU-side copies are invisible to byte counting.

**3. Nothing hardcodes a size.** Every dimension comes from `Metrics`, derived
from the user's *resolved* text size, so display resolution, system text size
and SF Symbol optical scaling move together. `Accommodations` does the same for
Reduce Transparency, Reduce Motion, Increase Contrast and Differentiate Without
Color. An app whose entire premise is a translucent overlay must treat the
setting that disables translucency as a layout input.

**4. Concurrency is bounded, not merely prioritised.** Screen-resolution decodes
are serialised; filmstrip decodes are serialised *and* yield to them. `.utility`
and `.background` priorities decide who wins a scheduling contest — they do not
reduce the number of contestants. This was learned twice, expensively.

### Formats

Everything ImageIO decodes (62 types, 70 extensions — ~30 camera RAW formats,
HEIC, AVIF, WebP, JPEG XL, JPEG 2000, PSD, TGA, EXR, Radiance HDR, DICOM, PICT,
MPO) plus **PDF** and **SVG** via `VectorSource`, plus **video** via
`VideoSource`. Vectors re-render on zoom rather than magnifying, so a PDF is
crisp at 32×.

This **exceeds FlyPhotos**, the Windows benchmark, which has no PDF, no video,
and no JPEG XL / EXR / DICOM / HDR.

Current: `33/33 displayable · 2 animated · 2 video · 4/4 malformed rejected`.

### Playback

One setting, three outcomes (View › Playback): Click to Play (default), Play
Automatically (Muted), Play Automatically (With Sound). Deliberately **not**
three booleans — "autoplay?" and "muted?" as independent switches produce a
nonsense combination and make the user assemble the behaviour out of parts.

Animations run as a single discrete `CAKeyframeAnimation` on the layer's
`contents`, so a looping GIF costs **zero CPU**: Core Animation advances frames
on the render server while the main thread decodes the next photo.

---

## 5. Current numbers

Measured on this machine, 18 Sep 2026. Full history in
`docs/performance-log.md`.

| Measure | Mixed corpus | 36 MP HEIC folder |
|---|---|---|
| Navigation → first pixels, median | **3.7 ms** | **0.8 – 1.6 ms** |
| Navigation → sharp, median | 15.7 ms | 178 – 207 ms |
| Steady-state footprint | 96 MB | 111 – 136 MB |
| Peak footprint | 161 MB | 157 – 299 MB |

Memory by display, 30 navigations of 36 MP HEICs:

| Display | Decode | Steady | Peak |
|---|---|---|---|
| 3840 × 2160 @ 1× | 2294² | 122 MB | 276 MB |
| 2056 × 1329 @ 2× | 2713² | 136 MB | 299 MB |
| 1200 × 1920 @ 1× portrait | 1440² | 111 MB | 157 MB |

The Retina panel is physically smallest and costs the most, which is correct —
it has the most pixels. The portrait panel costs least because the aspect-aware
budget notices a square photo in a tall window is bounded by its width.

Cold launch breakdown (`open` → first pixels, ~465 ms):

```
main                  0 ms
nsapp-init           55 ms   AppKit initialisation — largely fixed cost
will-finish-launch    56 ms
present-begin        175 ms  <- ~120 ms unattributed, see open items
window-visible       199 ms
first-paint          465 ms  <- the first decode
```

---

## 6. Traps specific to this environment

These cost real time and will do so again.

**TCC attributes Automation consent to the *responsible process*.** A build
launched from a terminal inherits the terminal's existing right to control
Finder and cheerfully reports `granted` when the app has no such right. Launched
with `open -a`, the same binary correctly reports `notDetermined`. **Always test
permission-gated behaviour the way a user launches it.**

**Ad-hoc signatures change on every build, so TCC grants do not survive one.**
Every rebuild means re-approving the Automation dialog. A stable self-signed
codesigning identity fixes this permanently; creating one was blocked by the
permission classifier and was never done. It is three commands
(`openssl req -x509 …` → `openssl pkcs12 -export` → `security import`), or
Keychain Access → Certificate Assistant → Create a Certificate (type: Code
Signing). **Worth doing first thing next session.**

**The display sleeps during long polling loops** and `screencapture` then
returns a black frame. `caffeinate -u -t 2` wakes it. A black screenshot is
almost never an app bug.

**`pkill` immediately followed by `open -a` races** and fails with
`-600 procNotFound`. Retry, or pause between them.

**`open -a App --args <path>` does not go through `application(_:open:)`** — the
path arrives as a plain command-line argument instead. Both paths are handled,
but launch instrumentation differs between them.

**Launch Services delivers `application(_:open:)` *before*
`applicationDidFinishLaunching`** when the app is launched by a file, which is
the normal case. The menu bar must therefore be installable from either entry
point or ⌘Q silently does nothing for the first window.

---

## 7. Open items, in priority order

1. **Create a stable *codesigning* identity.** Separate from the update signing
   key, which is done. Ad-hoc signatures change every build, so TCC grants do
   not survive one — unblocks Finder-sort testing and removes a per-rebuild
   consent dialog. Ten minutes; see §6.

2. **Attribute the ~120 ms gap** between `applicationWillFinishLaunching` and
   the open-file event arriving. This is the bulk of what stands between ~465 ms
   and the sub-100 ms target, and it is unexplained. Instruments' Time Profiler
   with a launch trace is the tool. Beyond that, a resident helper process would
   make second launches instant — but it trades exactly the memory frugality
   this app exists to have, so it is a deliberate decision, not a default.

3. **Peak memory is ~2× steady state** under synthetic scrubbing. Serialising
   decodes did not move it, so the remaining transient is inside a single
   decode. Instruments' Allocations.

4. **Wishlist, validated from FlyPhotos' issue tracker** (their *completed*
   requests are almost all "chrome, get out of the way", which is trait 02
   restated):
   - Pointer should auto-hide along with the chrome. Currently the chrome fades
     and the cursor stays, which breaks the effect.
   - Delete to Trash and advance, with undo. Repeatedly requested, and it is
     what turns a viewer into a culling tool.
   - Copy image, and copy path, from the viewer.
   - HDR/EDR display — their top *open* request, unclaimed on macOS. **Needs
     hardware this machine does not have.**

5. **Notarization.** The app is ad-hoc signed, so a first launch on someone
   else's Mac hits Gatekeeper and needs a right-click → Open. Proper
   distribution needs a Developer ID and notarization — worth doing before
   telling anyone about this.

6. **Multi-page PDF navigation.** Page 1 renders; pages 2+ are unreachable.
   Needs a decision about how page navigation coexists with file navigation.

7. **Finder sort coverage.** List and icon views expose their sort order; column
   and gallery (`flow view`) expose nothing and fall back to name order, which
   is also Finder's own default there. Two of four, degrading sensibly. There is
   no further API — this is a ceiling, not a to-do.

8. **App Store vs. direct distribution** is still undecided, and it determines
   sandboxing, whether a global hotkey is possible, and whether unsandboxed
   folder access is on the table. Direct with Sparkle is the freer path;
   FlyPhotos does both and charges for the store build.

---

## 8. Decided against, deliberately

Recording these so they are not relitigated from scratch.

- **Metal shaders.** Core Animation composites on the GPU already; a Metal
  pipeline would need a command queue, shader library and drawable pool kept
  resident for the same result. Revisit only for colour management or textures
  beyond CA's limits.
- **`NSVisualEffectView` for the backdrop.** A live blur samples and filters
  everything behind the window every frame — a continuous GPU cost for an effect
  almost entirely hidden behind a photograph. Picasa's ground was flat.
- **A real full-screen Space.** Entering costs an animation the user must watch,
  and leaving costs another. The opposite of disposable. Presentation options
  give the same coverage instantly.
- **Hiding the Dock by default.** The rail is pinned to the bottom edge and the
  Dock sits on top of it. ⇧⌘D opts into the full-bleed look.
- **Editing, tagging, a library, face detection, cloud anything.** Picasa-the-
  library is a different product and it is what killed every previous attempt at
  Picasa-the-viewer.
- **Wrapping at folder ends.** Navigation clamps. Wrapping makes it impossible
  to tell you have reached the end.
- **Upscaling on fit.** A 200 px thumbnail opens at 200 px, not blown across a
  5K display.

---

## 9. Reading order for a cold start

1. `docs/landscape.html` — why this project exists, the
   competitive field, and a running log of what measurement changed.
2. This file.
3. `docs/performance-log.md` — 20 findings, each one a thing that sounded
   obviously true and was not.
4. `Core/ImagePipeline.swift` and `Core/ImageSource.swift` — the two files that
   carry most of the design.
