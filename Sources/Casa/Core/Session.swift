import AppKit

/// One browsing session: an ordered list of images and a position in it.
///
/// The ordering rule that makes trait 01 achievable is encoded in `open`:
/// **show the opened image before scanning its folder.** Directory enumeration
/// is fast but it is still I/O, and putting it in front of the first paint
/// would put a variable, folder-size-dependent delay between the double-click
/// and the photo. The folder arrives a few milliseconds later, by which time
/// the user is already looking at their picture.
@MainActor
final class Session {

    private(set) var urls: [URL] = []
    private(set) var index = 0
    private(set) var sortOrder: SortOrder = .name
    private(set) var sortAscending = true

    private let pipeline = ImagePipeline()
    private weak var canvas: ImageCanvasView?

    /// Generation counter. Every navigation bumps it, and any decode that
    /// completes carrying a stale generation is discarded — this is what stops
    /// a slow decode from slamming an old photo onto the screen after the user
    /// has already arrowed past it.
    private var generation = 0

    var onChange: ((Session) -> Void)?
    /// Fired every time a rung reaches the screen. The benchmark harness uses
    /// this to time navigation; nothing in the shipping UI depends on it.
    /// Fired once per navigation with the best rung that reached the screen,
    /// or `nil` when the file could not be displayed at all.
    var onPaint: ((DecodeTier?) -> Void)?
    /// Fired when a rotation could not be written.
    var onRotationFailed: ((String) -> Void)?
    /// Fired when a file cannot be displayed, so the chrome can say so.
    var onUnreadable: ((URL) -> Void)?

    var currentURL: URL? {
        urls.indices.contains(index) ? urls[index] : nil
    }

    var positionDescription: String {
        urls.isEmpty ? "" : "\(index + 1) of \(urls.count)"
    }

    init(canvas: ImageCanvasView) {
        self.canvas = canvas
    }

    // MARK: - Opening

    func open(_ rawURL: URL) {
        commitRotation()
        // Normalize once, here, and never think about path identity again.
        //
        // A URL arrives from Finder or the command line as `/tmp/photo.jpg`
        // while `FolderScanner` re-lists the same file as
        // `/private/tmp/photo.jpg`. Both open fine, and the scanner matches
        // them because it compares standardized paths — but everything keyed
        // *by URL* downstream then has two different keys for one photograph.
        // The visible symptom was the filmstrip: every thumbnail loaded except
        // the one image the user had actually opened.
        let url = rawURL.resolvingSymlinksInPath().standardizedFileURL
        urls = [url]
        index = 0
        generation += 1
        let generation = self.generation

        // First paint, before anything else touches the disk.
        loadCurrent(generation: generation, isFirstPaint: true)

        // Folder discovery, deliberately behind the first paint.
        let order = sortOrder
        let ascending = sortAscending
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(siblingsOf: url, sortedBy: order, ascending: ascending)
            }.value

            guard let self, generation == self.generation else { return }
            self.urls = result.urls
            self.index = result.startIndex
            self.onChange?(self)
            // Deliberately no preload here. Warming neighbors while the
            // foreground decode is still running put four HEIC decodes on the
            // same cores and stretched the one the user was actually waiting
            // for from ~130 ms to ~390 ms. Preloading starts once the current
            // image is sharp, in `loadCurrent`.
        }
    }

    // MARK: - Navigation

    func advance(by offset: Int) {
        guard !urls.isEmpty else { return }
        let target = index + offset
        // Clamp rather than wrap. Wrapping silently loops a folder forever and
        // makes it impossible to tell you have reached the end.
        let clamped = min(max(0, target), urls.count - 1)
        guard clamped != index else { return }
        go(to: clamped)
    }

    func go(to newIndex: Int) {
        guard urls.indices.contains(newIndex) else { return }
        commitRotation()
        index = newIndex
        generation += 1
        loadCurrent(generation: generation, isFirstPaint: false)
        onChange?(self)
        schedulePreload()
    }

    /// Re-orders the folder to match the Finder window it came from.
    ///
    /// Runs *after* the image is on screen and the folder is listed, never
    /// before. The photo the user opened is already visible by this point, and
    /// it stays visible — only the list around it changes, so a re-order is
    /// invisible unless they navigate.
    private func adoptFinderSortOrder(for url: URL, generation: Int) async {
        guard Preferences.followsFinderSort, generation == self.generation else { return }

        let directory = url.deletingLastPathComponent()
        guard let finder = await FinderSort.order(forDirectory: directory) else {
            // Declining silently makes this impossible to diagnose from a bug
            // report, and there are four quite different reasons to decline.
            Log.folder.info("Finder sort unavailable (permission: \(String(describing: FinderSort.permission()), privacy: .public))")
            return
        }
        guard finder.order != sortOrder || finder.ascending != sortAscending else {
            Log.folder.info("Finder sort already matches")
            return
        }

        Log.folder.info("Adopting Finder sort: \(finder.order.rawValue, privacy: .public) ascending=\(finder.ascending, privacy: .public)")
        sortOrder = finder.order
        sortAscending = finder.ascending
        rescan(preserving: url, generation: generation)
    }

    /// Re-lists the folder under the current ordering, keeping the displayed
    /// photo displayed. Position is restored by URL rather than by index —
    /// the index means something different after a re-sort.
    private func rescan(preserving url: URL, generation: Int) {
        let order = sortOrder
        let ascending = sortAscending

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(siblingsOf: url, sortedBy: order, ascending: ascending)
            }.value

            guard let self, generation == self.generation else { return }
            self.urls = result.urls
            self.index = result.startIndex
            self.onChange?(self)
            self.schedulePreload()
        }
    }

    /// Public entry for the menu toggle: adopt Finder's order right now.
    func reapplyFinderSort(for url: URL) {
        let generation = self.generation
        Task { await adoptFinderSortOrder(for: url, generation: generation) }
    }

    /// Re-orders around the photo currently displayed, without reloading it.
    func setSortOrder(_ order: SortOrder, ascending: Bool = true) {
        guard order != sortOrder || ascending != sortAscending, let current = currentURL else {
            sortOrder = order
            sortAscending = ascending
            return
        }
        sortOrder = order
        sortAscending = ascending
        rescan(preserving: current, generation: generation)
    }

    // MARK: - Rotation

    /// The rotation the user has applied but not yet committed.
    ///
    /// Held rather than written per keypress: turning a photo four times should
    /// cost one write, not four, and writing while someone is still deciding
    /// which way up it goes is the wrong moment.
    private var pendingRotation: (url: URL, turns: Int)?

    func noteRotation(_ turns: Int) {
        guard let url = currentURL else { return }
        if let pending = pendingRotation, pending.url == url {
            pendingRotation = (url, pending.turns + turns)
        } else {
            commitRotation()
            pendingRotation = (url, turns)
        }
    }

    /// Writes the pending rotation to disk. Called on navigation and on close,
    /// which is exactly when Picasa committed one.
    func commitRotation() {
        guard let pending = pendingRotation else { return }
        pendingRotation = nil

        let turns = ((pending.turns % 4) + 4) % 4
        guard turns != 0 else { return }

        let url = pending.url
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try ImageRotator.apply(quarterTurns: turns, to: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            if let failure {
                Log.decode.error("rotation not saved: \(failure, privacy: .public)")
                self.onRotationFailed?(failure)
            } else {
                // The file changed underneath us, so anything cached for it is
                // now the old orientation.
                await self.pipeline.forget(url)
            }
        }
    }

    /// Decodes a filmstrip thumbnail. The rail drives this; the pipeline
    /// bounds how many are kept.
    func stripThumbnail(for url: URL) async -> DecodedImage? {
        await pipeline.stripThumbnail(url)
    }

    // MARK: - Loading

    private func loadCurrent(generation: Int, isFirstPaint: Bool) {
        guard let url = currentURL, let canvas else { return }
        // Whatever was playing belongs to the previous photograph. A video left
        // running after the user has moved on is the rudest thing a viewer can
        // do, so this happens before anything else.
        canvas.clearPlayback()
        let budget = canvas.displayPixelBudget

        Task { [weak self] in
            guard let self else { return }
            var hasPainted = false

            /// Paints a rung if this navigation is still current. Returns false
            /// once the user has moved on, which unwinds the whole ladder — a
            /// decode that finishes after the user has arrowed past its image
            /// must never reach the screen.
            @MainActor func paint(_ image: DecodedImage?, mark: String) -> Bool {
                guard generation == self.generation else { return false }
                guard let image else { return true }
                canvas.display(image, preservingZoom: hasPainted)
                if isFirstPaint, !hasPainted { LaunchClock.mark(mark) }
                hasPainted = true
                self.onPaint?(image.tier)
                return true
            }

            // Rung 0: already resident, because the preloader got here first.
            // On a folder walk this is the entire operation and the next photo
            // is up within a single frame.
            if let resident = await pipeline.anyCached(url) {
                guard paint(resident, mark: "first-paint-cached") else { return }
                if resident.tier >= .display {
                    self.schedulePreload()
                    return
                }
            }

            // Rung 1: the camera's own embedded preview. Effectively free when
            // the file has one, and plenty of files do not.
            if !hasPainted {
                let embedded = await pipeline.image(url, tier: .thumbnail, maxPixelSize: 0)
                guard paint(embedded, mark: "first-paint-embedded") else { return }
            }

            // Rung 2: a small real decode. This is the rung that actually
            // guarantees the window is not blank, because unlike rung 1 it does
            // not depend on what the photographer's camera chose to embed.
            if !hasPainted {
                let preview = await pipeline.image(url, tier: .preview, maxPixelSize: 0)
                guard paint(preview, mark: "first-paint-preview") else { return }
            }

            if isFirstPaint, hasPainted {
                Log.launch.notice("\(LaunchClock.summary(), privacy: .public)")
            }

            // Nothing readable. Clearing matters: leaving the previous
            // photograph up under the new filename is worse than showing
            // nothing, because it looks like the file opened fine.
            if !hasPainted {
                guard generation == self.generation else { return }
                canvas.clear()
                self.onUnreadable?(url)
                self.onPaint?(nil)
                self.schedulePreload()
                return
            }

            // Rung 3: screen resolution, which replaces whatever proxy is
            // showing without disturbing the user's zoom or pan. Now that a
            // proxy has told us the image's real proportions, ask for what fit
            // actually displays rather than the window's longest edge.
            let native = await pipeline.anyCached(url)?.nativePixelSize
            let sized = native.map { canvas.displayBudget(for: $0) } ?? budget
            let display = await pipeline.image(url, tier: .display, maxPixelSize: sized)
            guard paint(display, mark: "first-paint-display") else { return }
            if isFirstPaint { LaunchClock.mark("sharp") }

            self.schedulePreload()
            await self.preparePlayback(for: url, generation: generation)
            // Only now, with the photograph fully on screen, is it worth
            // spending anything on the sort order of a list the user has not
            // looked at yet.
            await self.adoptFinderSortOrder(for: url, generation: generation)
        }
    }

    /// Works out whether the current item can play, and hands it to the canvas.
    ///
    /// Runs after the still is already on screen. An animated GIF shows its
    /// first frame immediately and begins moving a moment later; a video shows
    /// its poster frame and then becomes playable. Neither makes the user wait
    /// on a blank window for something that might not even autoplay.
    private func preparePlayback(for url: URL, generation: Int) async {
        guard let canvas else { return }
        let policy = Preferences.playbackPolicy

        if VideoSource.isVideo(url) {
            guard generation == self.generation else { return }
            canvas.presentVideo(url, autoplay: policy.autoplays, muted: policy.muted)
            return
        }

        let animation = await Task.detached(priority: .utility) {
            ImageSource.animation(url)
        }.value

        guard generation == self.generation, let animation else { return }
        canvas.presentAnimation(animation, autoplay: policy.autoplays)
    }

    /// Re-decodes the current image for a changed target resolution.
    ///
    /// Dragging the window from a 1x display to a 2x one doubles the pixels
    /// needed for the same apparent size. Nothing in the cache can detect that
    /// — the tier is unchanged and the bitmap is still "valid" — so the move
    /// has to say so explicitly, or the photograph is quietly shown at half
    /// resolution for as long as it stays on that screen.
    ///
    /// Zoom and pan are preserved: this is the same picture, drawn better.
    func refreshForResolutionChange() {
        guard let url = currentURL, let canvas else { return }
        let generation = self.generation

        Task { [weak self] in
            guard let self else { return }
            let native = await pipeline.anyCached(url)?.nativePixelSize
            let budget = native.map { canvas.displayBudget(for: $0) } ?? canvas.displayPixelBudget

            guard let display = await pipeline.image(url, tier: .display,
                                                     maxPixelSize: budget, force: true),
                  generation == self.generation else { return }
            canvas.display(display, preservingZoom: true)
            Log.render.info("Re-decoded \(url.lastPathComponent, privacy: .private) at \(budget, privacy: .public)px for new display")
        }
    }

    /// Promotes the current image to a full decode. Called only when the canvas
    /// reports the user has zoomed past the proxy's useful resolution.
    func escalateToFullResolution() {
        guard let url = currentURL, let canvas else { return }
        let generation = self.generation

        Task { [weak self] in
            guard let self,
                  let full = await pipeline.image(url, tier: .full, maxPixelSize: 0),
                  generation == self.generation else { return }
            canvas.display(full, preservingZoom: true)
            Log.decode.debug("Escalated \(url.lastPathComponent, privacy: .private) to full resolution")
        }
    }

    private func schedulePreload() {
        let snapshot = urls
        let position = index
        Task { await pipeline.preload(around: position, in: snapshot) }
    }
}
