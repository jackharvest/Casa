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
        session.onUnreadable = { [weak self] url in
            guard let self else { return }
            self.chrome.update(filename: url.lastPathComponent,
                               position: self.session.positionDescription,
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

    private func environmentChanged() {
        (view.window as? ViewerWindow)?.applyGround()
        canvas.environmentChanged()
        chrome.applyMetrics()
        updateCanvasInsets()
        Log.render.debug("Environment changed; metrics rebuilt")
    }

    private func refreshChrome(for session: Session) {
        chrome.updatePlayback(canPlay: canvas.playable != .none, isPlaying: canvas.isPlaying)
        chrome.update(
            filename: session.currentURL?.lastPathComponent ?? "",
            position: session.positionDescription
        )
        chrome.filmstrip.update(urls: session.urls,
                                currentIndex: session.index,
                                animated: true)
        updateCanvasInsets()
    }

    /// Hands the canvas the area the chrome is using, so a fitted photograph
    /// is composed in the space that is actually free rather than centred
    /// behind the rail.
    private func updateCanvasInsets() {
        let showsFilmstrip = session.urls.count > 1
        chrome.filmstrip.isHidden = !showsFilmstrip
        canvas.contentInsets = NSEdgeInsets(
            top: chrome.topInset,
            left: Metrics.spacing(2),
            bottom: showsFilmstrip ? chrome.bottomInset : Metrics.hitTarget(.control) + Metrics.spacing(4),
            right: Metrics.spacing(2)
        )
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        chrome.flash()
    }

    // MARK: - Actions

    @objc func goNext(_ sender: Any?) { session.advance(by: 1) }
    @objc func goPrevious(_ sender: Any?) { session.advance(by: -1) }
    @objc func zoomToFit(_ sender: Any?) { canvas.fit(animated: true) }
    @objc func zoomToActual(_ sender: Any?) { canvas.actualSize(animated: true) }
    @objc func rotateLeft(_ sender: Any?) { canvas.rotate(by: -1) }
    @objc func rotateRight(_ sender: Any?) { canvas.rotate(by: 1) }
    @objc func dismissViewer(_ sender: Any?) { view.window?.close() }

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
        if menuItem.action == #selector(togglePlayback(_:)) {
            menuItem.title = canvas.isPlaying ? "Pause" : "Play"
            return canvas.playable != .none
        }
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Jump by a screenful of images, mirroring the Option-arrow convention
        // other Mac viewers use for the same idea.
        let jump = modifiers.contains(.option) ? 10 : 1

        switch event.specialKey {
        case .leftArrow:  session.advance(by: -jump); return
        case .rightArrow: session.advance(by: jump); return
        case .upArrow:    session.advance(by: -jump); return
        case .downArrow:  session.advance(by: jump); return
        case .home:       session.go(to: 0); return
        case .end:        session.go(to: max(0, session.urls.count - 1)); return
        case .pageUp:     session.advance(by: -10); return
        case .pageDown:   session.advance(by: 10); return
        default: break
        }

        switch event.charactersIgnoringModifiers {
        case "\u{1b}":            // Escape — trait 06, the app is disposable.
            view.window?.close()
        case " ":
            // Space means "play" wherever something can play, and "next"
            // everywhere else — the two never compete because a still image
            // has nothing to play.
            if canvas.playable != .none { canvas.togglePlayback() } else { session.advance(by: 1) }
        case "0":
            canvas.fit(animated: true)
        case "1":
            canvas.actualSize(animated: true)
        case "+", "=":
            canvas.zoom(by: 1.25, at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        case "-":
            canvas.zoom(by: 1 / 1.25, at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        default:
            super.keyDown(with: event)
        }
    }
}

extension ViewerController: ImageCanvasDelegate {

    func canvas(_ canvas: ImageCanvasView, didChangeZoomTo scale: CGFloat, isFitted: Bool) {
        chrome.flash()

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
