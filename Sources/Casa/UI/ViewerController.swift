import AppKit

/// Wires the session, the canvas and the chrome together, and owns the
/// keyboard map.
final class ViewerController: NSViewController, NSMenuItemValidation {

    private let canvas = ImageCanvasView(frame: .zero)
    private var chrome: ChromeView!
    private var session: Session!
    private var environmentMonitor: EnvironmentMonitor?
    private var mouseIdleTracking: NSTrackingArea?

    /// Debounces the full-resolution escalation so a continuous pinch does not
    /// queue a 400 MB decode on every intermediate frame.
    private var escalationWork: DispatchWorkItem?

    private var thumbnailMirror: [URL: DecodedImage] = [:]
    private var thumbnailOrder: [URL] = []
    private var pendingThumbnails: Set<URL> = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        root.wantsLayer = true

        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)

        chrome = ChromeView(target: self)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chrome)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            chrome.topAnchor.constraint(equalTo: root.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        canvas.delegate = self
        chrome.filmstrip.delegate = self
        session = Session(canvas: canvas)
        session.onChange = { [weak self] session in
            self?.refreshChrome(for: session)
        }
        session.onThumbnailInvalidated = { [weak self] url in
            guard let self else { return }
            self.thumbnailMirror.removeValue(forKey: url)
            self.pendingThumbnails.remove(url)
            self.chrome.filmstrip.clearRotation(for: url)
            self.filmstripRequestThumbnail(for: url)
        }
        session.onRotationFailed = { [weak self] message in
            guard let self, let url = self.session.currentURL else { return }
            self.chrome.update(filename: url.lastPathComponent,
                               detail: self.detailDescription,
                               note: message)
            self.chrome.flash()
        }
        session.onUnreadable = { [weak self] url in
            guard let self else { return }
            self.chrome.update(filename: url.lastPathComponent,
                               detail: self.detailDescription,
                               note: "Can’t display this file")
            self.chrome.flash()
        }

        environmentMonitor = EnvironmentMonitor { [weak self] in
            self?.environmentChanged()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
        chrome.flash()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let existing = mouseIdleTracking { view.removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: view.bounds,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        view.addTrackingArea(area)
        mouseIdleTracking = area
    }

    // MARK: - Public entry

    /// Writes any rotation the user applied but hasn't navigated away from.
    func commitPendingRotation() { session?.commitRotation() }

    /// The photograph currently on screen, for the updater's relaunch.
    var currentFile: URL? { session?.currentURL }

    func open(_ url: URL) {
        session.open(url)
        refreshChrome(for: session)
        startBenchmarkIfRequested()
    }

    // MARK: - Benchmark

    private var benchmark: Benchmark?

    /// One benchmark step. Wraps at the end of the folder rather than
    /// advancing, because `advance(by:)` deliberately clamps — running off the
    /// end would leave the harness waiting forever for a paint that correctly
    /// never comes.
    private func benchmarkStep() {
        if session.index >= session.urls.count - 1 {
            session.go(to: 0)
        } else {
            session.advance(by: 1)
        }
    }

    private func startBenchmarkIfRequested() {
        guard benchmark == nil,
              let bench = Benchmark(arguments: CommandLine.arguments,
                                    advance: { [weak self] in self?.benchmarkStep() })
        else { return }
        benchmark = bench

        var started = false
        session.onPaint = { [weak self] tier in
            guard let self, let benchmark = self.benchmark else { return }
            if started {
                benchmark.recordPaint(tier: tier)
            } else if let tier, tier >= .display {
                // Wait until the opening image is final, so the run measures
                // navigation rather than launch.
                started = true
                benchmark.begin()
            }
        }
    }

    // MARK: - Environment

    func environmentChanged() {
        ChromeMetrics.adopt(view.window?.screen)
        (view.window as? ViewerWindow)?.applyGround()
        canvas.environmentChanged()
        chrome.applyMetrics()
        updateCanvasInsets()
        Log.render.debug("Environment changed; metrics rebuilt")
    }

    private func refreshChrome(for session: Session) {
        if let window = view.window as? ViewerWindow, window.presentation == .windowed {
            window.title = session.currentURL?.lastPathComponent ?? "Casa"
        }
        chrome.updatePlayback(canPlay: canvas.playable != .none, isPlaying: canvas.isPlaying)
        chrome.updateNavigation(index: session.index, count: session.urls.count)
        chrome.update(
            filename: session.currentURL?.lastPathComponent ?? "",
            detail: detailDescription
        )
        chrome.filmstrip.update(urls: session.urls,
                                currentIndex: session.index,
                                animated: true)
        updateCanvasInsets()
    }

    /// The line under the filename: where you are in the folder, the
    /// photograph's pixel dimensions, and its size on disk. Picasa showed the
    /// dimensions whenever a file opened, and people missed it — it answers
    /// "is this the big one?" without opening Get Info.
    var detailDescription: String {
        var parts = [session.positionDescription]
        let size = canvas.imageSize
        if size.width > 0 {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        if let url = session.currentURL,
           let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "   ·   ")
    }

    /// Hands the canvas the area the chrome is using, so a fitted photograph
    /// is composed in the space that is actually free rather than centred
    /// behind the rail.
    private func updateCanvasInsets() {
        chrome.showsFilmstrip = session.urls.count > 1

        // In a window the photograph fills the frame and the chrome floats over
        // it, so there are no insets to reserve. Full-screen keeps them,
        // because there the surround is deliberate space rather than a bar.
        if (view.window as? ViewerWindow)?.presentation == .windowed {
            canvas.contentInsets = NSEdgeInsets()
            return
        }

        canvas.contentInsets = NSEdgeInsets(
            top: chrome.topInset,
            left: ChromeMetrics.spacing(2),
            bottom: chrome.bottomInset,
            right: ChromeMetrics.spacing(2)
        )
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        chrome.flash()
    }

    // MARK: - Actions

    @objc func goNext(_ sender: Any?) { step(by: 1) }
    @objc func goPrevious(_ sender: Any?) { step(by: -1) }
    @objc func zoomToFit(_ sender: Any?) { canvas.fit(animated: true) }
    @objc func zoomToActual(_ sender: Any?) { canvas.actualSize(animated: true) }
    @objc func zoomIn(_ sender: Any?) { zoomAboutCentre(1.25) }
    @objc func zoomOut(_ sender: Any?) { zoomAboutCentre(1 / 1.25) }

    /// Picasa's `1`: to actual size, and back to fit if already there.
    @objc func toggleActualSize(_ sender: Any?) {
        if canvas.isAtActualSize { canvas.fit(animated: true) } else { canvas.actualSize(animated: true) }
    }

    private func zoomAboutCentre(_ factor: CGFloat) {
        canvas.zoom(by: factor, at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
    }

    /// A step the user asked for. It restarts a running slideshow's clock, so
    /// stepping back to look again is not immediately overruled.
    private func step(by offset: Int) {
        session.advance(by: offset)
        if slideshowTimer != nil { scheduleSlideshowStep() }
    }

    // MARK: - Slideshow

    /// The round button in the middle of the toolbar. Picasa's did the same:
    /// the chrome gets out of the way and the folder plays forward.
    private var slideshowTimer: Timer?
    private static let slideshowInterval: TimeInterval = 3.5

    @objc func toggleSlideshow(_ sender: Any?) {
        if slideshowTimer != nil {
            stopSlideshow()
            chrome.flash()
            return
        }
        // At the end of the folder, a slideshow starts from the beginning
        // rather than stopping the instant it begins.
        if session.index >= session.urls.count - 1 { session.go(to: 0) }
        scheduleSlideshowStep()
        chrome.updateSlideshow(isRunning: true)
        chrome.setVisible(false)
    }

    private func scheduleSlideshowStep() {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: Self.slideshowInterval,
                                              repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.slideshowStep() }
        }
    }

    private func slideshowStep() {
        guard session.index < session.urls.count - 1 else {
            stopSlideshow()
            chrome.flash()
            return
        }
        session.advance(by: 1)
        scheduleSlideshowStep()
    }

    func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        chrome.updateSlideshow(isRunning: false)
    }
    @objc func rotateLeft(_ sender: Any?) { rotate(by: -1) }
    @objc func rotateRight(_ sender: Any?) { rotate(by: 1) }

    /// Turns the picture on screen and records the turn. The write happens when
    /// the user moves on, which is when Picasa committed one too.
    private func rotate(by turns: Int) {
        canvas.rotate(by: turns)
        session.noteRotation(turns)
        if let url = session.currentURL {
            chrome.filmstrip.setRotation(canvas.quarterTurns, for: url)
        }
        guard let url = session.currentURL, !ImageRotator.canRotate(url) else { return }
        chrome.update(filename: url.lastPathComponent,
                      detail: detailDescription,
                      note: "Rotation won't be saved for this file")
        chrome.flash()
    }
    @objc func dismissViewer(_ sender: Any?) { dismissWindow() }

    /// Play or pause the current animation or video.
    @objc func togglePlayback(_ sender: Any?) {
        canvas.togglePlayback()
    }

    /// One menu item per playback outcome, behaving as a radio group.
    @objc func setPlaybackPolicy(_ sender: NSMenuItem) {
        guard let policy = PlaybackPolicy(rawValue: sender.representedObject as? String ?? "") else { return }
        Preferences.playbackPolicy = policy
        // Apply immediately to whatever is on screen rather than making the
        // user navigate away and back to see what they chose.
        if canvas.playable != .none, policy.autoplays, !canvas.isPlaying {
            canvas.togglePlayback()
        }
    }

    /// Turns trait 07 on or off.
    ///
    /// Switching it on is the one place the app asks for permission to
    /// automate Finder, and it is a menu action precisely so that the modal
    /// consent dialog is something the user asked for rather than something
    /// that ambushes them mid-launch.
    @objc func toggleFinderSort(_ sender: Any?) {
        if Preferences.followsFinderSort {
            Preferences.followsFinderSort = false
            session.setSortOrder(.name, ascending: true)
            return
        }

        switch FinderSort.permission(askingIfNeeded: true) {
        case .granted:
            Preferences.followsFinderSort = true
            if let url = session.currentURL { session.reapplyFinderSort(for: url) }
        case .denied:
            explainDeniedPermission()
        case .notDetermined, .unavailable:
            // The user dismissed the dialog, or Finder is not running. Leave
            // the setting off; there is nothing to apologize for.
            break
        }
    }

    /// The alternate, full-bleed look: cover the Dock and menu bar.
    @objc func toggleHidesDock(_ sender: Any?) {
        Preferences.hidesDock.toggle()
        (view.window as? ViewerWindow)?.applyScreenFrame(hidingDock: Preferences.hidesDock)
    }

    private func explainDeniedPermission() {
        let alert = NSAlert()
        alert.messageText = "Casa can’t read Finder’s sort order"
        alert.informativeText = "To match the order of the Finder window a photo was opened from, allow Casa to control Finder in System Settings › Privacy & Security › Automation."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFinderSort(_:)) {
            menuItem.state = Preferences.followsFinderSort ? .on : .off
        }
        if menuItem.action == #selector(toggleHidesDock(_:)) {
            menuItem.state = Preferences.hidesDock ? .on : .off
        }
        if menuItem.action == #selector(setPlaybackPolicy(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == Preferences.playbackPolicy.rawValue ? .on : .off
        }
        if menuItem.action == #selector(toggleSlideshow(_:)) {
            menuItem.title = slideshowTimer != nil ? "Stop Slideshow" : "Start Slideshow"
            return session.urls.count > 1
        }
        if menuItem.action == #selector(togglePlayback(_:)) {
            menuItem.title = canvas.isPlaying ? "Pause" : "Play"
            return canvas.playable != .none
        }
        return true
    }

    // MARK: - Clipboard

    /// Copies the photograph itself, plus its file URL.
    ///
    /// Both representations go on the pasteboard together, because different
    /// destinations want different things: a chat window wants the bitmap, a
    /// Finder window or a terminal wants the file. Offering both means the
    /// paste does the obvious thing wherever it lands.
    @objc func copyImage(_ sender: Any?) {
        guard let url = session.currentURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var items: [NSPasteboardWriting] = [url as NSURL]
        if let image = NSImage(contentsOf: url) {
            items.insert(image, at: 0)
        }
        pasteboard.writeObjects(items)
        chrome.update(filename: url.lastPathComponent,
                      detail: detailDescription,
                      note: "Copied")
        chrome.flash()
    }

    /// Copies the POSIX path as text — what you want when the destination is a
    /// terminal or a text field rather than an image view.
    @objc func copyPath(_ sender: Any?) {
        guard let url = session.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        chrome.update(filename: url.lastPathComponent,
                      detail: detailDescription,
                      note: "Path copied")
        chrome.flash()
    }

    /// Reveals the photograph in Finder, which is the other thing people reach
    /// for constantly and every viewer should have.
    @objc func revealInFinder(_ sender: Any?) {
        guard let url = session.currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Jump by a screenful of images, mirroring the Option-arrow convention
        // other Mac viewers use for the same idea.
        let jump = modifiers.contains(.option) ? 10 : 1

        switch event.specialKey {
        case .leftArrow:  step(by: -jump); return
        case .rightArrow: step(by: jump); return
        // Up and down zoom, as they did in Picasa — beside left and right, so
        // one hand on the arrows both walks the folder and looks closer.
        case .upArrow:    zoomAboutCentre(1.25); return
        case .downArrow:  zoomAboutCentre(1 / 1.25); return
        case .home:       step(by: -session.index); return
        case .end:        step(by: session.urls.count - 1 - session.index); return
        case .pageUp:     step(by: -10); return
        case .pageDown:   step(by: 10); return
        case .carriageReturn, .enter:
            canvasDidRequestWindowedToggle(canvas); return
        default: break
        }

        switch event.charactersIgnoringModifiers {
        case "\u{1b}":            // Escape — trait 06, the app is disposable.
            dismissWindow()
        case " ":
            // Space means "play" wherever something can play, and "next"
            // everywhere else — the two never compete because a still image
            // has nothing to play.
            if canvas.playable != .none { canvas.togglePlayback() } else { step(by: 1) }
        case "0":
            canvas.fit(animated: true)
        case "1":
            toggleActualSize(nil)
        case "+", "=":
            zoomAboutCentre(1.25)
        case "-":
            zoomAboutCentre(1 / 1.25)
        case "s", "S":
            toggleSlideshow(nil)
        default:
            super.keyDown(with: event)
        }
    }
}

extension ViewerController: ImageCanvasDelegate {

    func canvas(_ canvas: ImageCanvasView, didChangeZoomTo scale: CGFloat, isFitted: Bool) {
        chrome.updateZoom(isActualSize: canvas.isAtActualSize)
        // A zoom during a slideshow means the user wants to look; the show
        // stops rather than yanking the photo away mid-inspection.
        if slideshowTimer != nil, !isFitted { stopSlideshow() }
        if slideshowTimer == nil { chrome.flash() }

        escalationWork?.cancel()
        guard canvas.needsFullResolution else { return }

        // Wait for the gesture to settle. Escalating mid-pinch would decode a
        // full-resolution bitmap for a zoom level the user passes through in
        // 40 ms and never sees.
        let work = DispatchWorkItem { [weak self] in
            self?.session.escalateToFullResolution()
        }
        escalationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func canvasDidChangeBackingScale(_ canvas: ImageCanvasView, to scale: CGFloat) {
        Log.render.debug("Backing scale now \(scale, privacy: .public)x")
        session?.refreshForResolutionChange()
    }

    func canvas(_ canvas: ImageCanvasView, requestsStep offset: Int) {
        session.advance(by: offset)
    }

    /// Drives a zoom toward a corner, so the badge can be captured.
    func demoZoom() {
        let rect = canvas.bounds
        let corner = CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.36)
        for _ in 0..<9 { canvas.zoom(by: 1.16, at: corner) }
    }

    /// Public entry so the debug flag can drive it too.
    func toggleWindowedPresentation() { canvasDidRequestWindowedToggle(canvas) }

    func canvasDidRequestWindowedToggle(_ canvas: ImageCanvasView) {
        guard let window = view.window as? ViewerWindow else { return }
        let screen = window.screen ?? NSScreen.main
        let room = screen.map { CGSize(width: $0.visibleFrame.width * 0.86,
                                       height: $0.visibleFrame.height * 0.86) }
            ?? CGSize(width: 1200, height: 800)

        let next: ViewerWindow.Presentation = window.presentation == .fullBleed ? .windowed : .fullBleed
        window.setPresentation(next, contentSize: canvas.preferredWindowedContentSize(maximum: room))
        window.title = session.currentURL?.lastPathComponent ?? "Casa"
        // Insets differ between the two modes, and the free-pan offset belongs
        // to the old geometry.
        updateCanvasInsets()
        canvas.fit(animated: !Accommodations.current.reduceMotion)
    }

    /// Goes through `performClose` rather than `close` so the window delegate
    /// can run the shrink-to-centre first.
    private func dismissWindow() {
        if let viewer = view.window as? ViewerWindow {
            viewer.dismissAnimated()
        } else {
            view.window?.close()
        }
    }

    /// The first bitmap is what opens the window.
    func canvasDidShowImage(_ canvas: ImageCanvasView) {
        (view.window as? ViewerWindow)?.revealIfWaiting()
        // Dimensions are known only once a bitmap has landed.
        if let url = session.currentURL, !chrome.isShowingNote {
            chrome.update(filename: url.lastPathComponent, detail: detailDescription)
        }
    }

    func canvasPlaybackStateChanged(_ canvas: ImageCanvasView) {
        chrome.updatePlayback(canPlay: canvas.playable != .none, isPlaying: canvas.isPlaying)
    }
}

// MARK: - Filmstrip

extension ViewerController: FilmstripDelegate {

    func filmstrip(_ strip: FilmstripView, didSelect index: Int) {
        session.go(to: index)
    }

    /// Synchronous because the rail asks for every visible cell on every
    /// layout pass. Answers only from what has already been decoded; a miss
    /// schedules the work and the cell fills in when it lands.
    func filmstripThumbnail(for url: URL) -> DecodedImage? {
        thumbnailMirror[url]
    }

    func filmstripRequestThumbnail(for url: URL) {
        Log.render.debug("strip request \(url.lastPathComponent, privacy: .public)")
        guard !pendingThumbnails.contains(url) else { return }
        pendingThumbnails.insert(url)

        Task { [weak self] in
            guard let self else { return }
            let decoded = await self.session.stripThumbnail(for: url)
            self.pendingThumbnails.remove(url)
            guard let decoded else { return }
            self.rememberThumbnail(decoded, for: url)
            self.chrome.filmstrip.thumbnailArrived(for: url)
        }
    }

    /// A main-thread mirror of the pipeline's thumbnail store, because layout
    /// cannot await an actor. It holds references, not extra bitmaps, and is
    /// bounded to the same count so it cannot keep evicted images alive.
    private func rememberThumbnail(_ image: DecodedImage, for url: URL) {
        thumbnailMirror[url] = image
        thumbnailOrder.removeAll { $0 == url }
        thumbnailOrder.append(url)
        while thumbnailOrder.count > 60, let oldest = thumbnailOrder.first {
            thumbnailMirror.removeValue(forKey: oldest)
            thumbnailOrder.removeFirst()
        }
    }
}
