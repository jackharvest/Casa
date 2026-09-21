import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticUpdates(_:)) {
            menuItem.state = Preferences.automaticUpdateChecks ? .on : .off
        }
        return true
    }


    private var window: ViewerWindow?
    private var controller: ViewerController?
    private let windowDelegate = ViewerWindowDelegate()

    let updates = UpdateController()
    private lazy var updatePanel = UpdateWindowController(controller: updates)

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchClock.mark("will-finish-launching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchClock.mark("did-finish-launching")
        installMenuIfNeeded()

        let arguments = CommandLine.arguments
        let positional = arguments.dropFirst().filter { !$0.hasPrefix("-") }

        // Diagnostic mode: report what Finder says about a folder's sort order
        // and exit without ever showing a window.
        if let flag = arguments.firstIndex(of: "--finder-sort-probe"), let path = positional.first {
            _ = flag
            FinderSort.runProbe(directory: URL(fileURLWithPath: path))
        }

        if arguments.contains("--selfcheck") {
            SelfCheck.run()
        }

        if arguments.contains("--selftest"), let path = positional.first {
            // Async because movies are, so the run loop has to keep turning;
            // `run` exits the process when it is done.
            Task { await FormatSelfTest.run(directory: URL(fileURLWithPath: path)) }
            return
        }

        // Files passed on the command line, for development and for `open -a`.
        if let first = positional.first {
            present(URL(fileURLWithPath: first))
        }

        configureUpdates()
    }

    /// Finder double-click and drag-onto-icon both land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        present(first)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Trait 06: the viewer is disposable. Closing the window is the whole
        // interaction ending, not a document being put away — leaving a
        // process resident with no window would be exactly the kind of quiet
        // memory tenancy this app exists not to have.
        true
    }

    // MARK: - Updates

    private func configureUpdates() {
        // Reopen the photograph that was on screen, so an update costs the
        // user their place for a second rather than losing it.
        updates.currentlyViewedFile = { [weak self] in self?.controller?.currentFile }

        let panel = updatePanel
        updates.onStateChange = { [weak panel] state in
            panel?.presentIfNoteworthy(state)
        }

        // Deferred past launch. The first seconds belong to getting a
        // photograph on screen; a network request competing for them is the
        // opposite of what this app is for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.updates.checkInBackgroundIfDue()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updatePanel.present()
        updates.check(userInitiated: true)
    }

    @objc func toggleAutomaticUpdates(_ sender: Any?) {
        Preferences.automaticUpdateChecks.toggle()
    }

    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let alert = NSAlert()
        alert.messageText = "Casa \(version)"
        alert.informativeText = "Build \(build)\n\nA fast, chromeless photo viewer for macOS.\nBuilt by Jack Harvest."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Check for Updates\u{2026}")
        if alert.runModal() == .alertSecondButtonReturn {
            checkForUpdates(nil)
        }
    }

    // MARK: - Presentation

    /// The display the photo was opened from.
    ///
    /// The pointer is the best available signal: a double-click in Finder, a
    /// drag onto the Dock icon and a contextual-menu open all happen where the
    /// cursor is. `--screen <n>` overrides it, for testing across displays of
    /// differing pixel density.
    private func invokingScreen() -> NSScreen {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--screen"),
           arguments.indices.contains(flag + 1),
           let index = Int(arguments[flag + 1]),
           NSScreen.screens.indices.contains(index) {
            return NSScreen.screens[index]
        }
        return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// When the app is launched *by* a file — the normal case — Launch Services
    /// delivers `application(_:open:)` before `applicationDidFinishLaunching`.
    /// The menu bar therefore has to be installable from either entry point,
    /// or ⌘Q silently does nothing for the first window.
    private var menuInstalled = false

    private func installMenuIfNeeded() {
        guard !menuInstalled else { return }
        menuInstalled = true
        MenuBuilder.install()
    }

    private func present(_ url: URL) {
        installMenuIfNeeded()
        let screen = invokingScreen()

        if let controller, let window {
            // Follow the user to the display they invoked this from. Opening a
            // photo on the laptop screen when they double-clicked it on the
            // external monitor is exactly the kind of thing that makes an app
            // feel like it is not paying attention.
            if window.screen !== screen {
                window.setFrame(Preferences.hidesDock ? screen.frame : screen.visibleFrame, display: false)
            }
            controller.open(url)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        LaunchClock.mark("present-begin")
        let window = ViewerWindow(screen: screen, hidesDock: Preferences.hidesDock)
        let controller = ViewerController()
        window.contentViewController = controller
        window.delegate = windowDelegate
        LaunchClock.mark("view-loaded")

        // Order the window in *before* decoding, so the ground is already on
        // screen when the first bitmap lands. The perceived launch time is the
        // time to something appearing, not the time to the final image.
        window.applyScreenFrame(hidingDock: Preferences.hidesDock)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        LaunchClock.mark("window-visible")

        controller.open(url)

        self.window = window
        self.controller = controller
        scheduleScreenMigrationTestIfRequested(window)
    }

    /// `--migrate-screens a,b` opens on display *a*, then moves to display *b*.
    ///
    /// Exists because the bug it tests — a photograph left at half resolution
    /// after moving from a 1x to a 2x display — is invisible in a screenshot
    /// and impossible to trigger from a script otherwise.
    private func scheduleScreenMigrationTestIfRequested(_ window: ViewerWindow) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--migrate-screens"),
              arguments.indices.contains(flag + 1) else { return }
        let indices = arguments[flag + 1].split(separator: ",").compactMap { Int($0) }
        guard indices.count == 2, NSScreen.screens.indices.contains(indices[1]) else { return }

        let destination = NSScreen.screens[indices[1]]
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Log.render.notice("migrating to screen \(indices[1], privacy: .public) (\(destination.backingScaleFactor, privacy: .public)x)")
            window.setFrame(Preferences.hidesDock ? destination.frame : destination.visibleFrame,
                            display: true)
        }
    }
}
