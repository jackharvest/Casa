import AppKit

/// The borderless overlay window.
///
/// Traits 02 and 06 live here: no title bar, no shadow, a translucent ground,
/// and dismissal on Escape. It is deliberately a plain window rather than a
/// real full-screen space — entering a Space costs an animation the user has
/// to watch, and leaving it costs another, which is the opposite of
/// disposable.
///
/// **The ground is the window's own `backgroundColor`,** not a view.
/// The first version used a layer-hosting `BackdropView`, which reported a
/// correct frame and a correct colour and never drew: assigning a layer to a
/// view means owning that layer's geometry, and an unsized layer paints
/// nothing. A non-opaque window with a translucent background colour does
/// exactly the same job in one line, with no view, no layer and no geometry to
/// keep in sync.
final class ViewerWindow: NSWindow {

    /// Whether to take the whole screen, covering the Dock and menu bar.
    /// Off by default — see `ViewerWindowDelegate`.
    private(set) var hidesDock = false

    init(screen: NSScreen, hidesDock: Bool) {
        self.hidesDock = hidesDock
        super.init(
            contentRect: hidesDock ? screen.frame : screen.visibleFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // A borderless window refuses key status unless it says otherwise, and
        // without key status it receives no keyboard events at all — so arrow
        // navigation silently does nothing. This is the single most common
        // way a borderless viewer ships broken.
        isReleasedWhenClosed = false
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        level = .normal
        collectionBehavior = [.fullScreenAuxiliary, .managed]
        // Tabbing makes no sense for an overlay and adds a menu item we would
        // then have to explain.
        tabbingMode = .disallowed
        animationBehavior = .none
        acceptsMouseMovedEvents = true

        applyGround()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Reduce Transparency exists precisely to switch off effects like ours.
    /// Honoring it is not optional: translucency over arbitrary desktop
    /// content is a legibility problem before it is a preference.
    func applyGround() {
        let opaque = Accommodations.current.reduceTransparency
        backgroundColor = NSColor(white: 0.06, alpha: opaque ? 1.0 : 0.88)
    }

    /// Resizes for the current Dock preference.
    func applyScreenFrame(hidingDock: Bool) {
        hidesDock = hidingDock
        guard let screen = screen ?? NSScreen.main else { return }
        NSApp.presentationOptions = hidingDock ? [.autoHideDock, .autoHideMenuBar] : []
        // `visibleFrame` is recomputed after the presentation options change,
        // so it is read here rather than cached above.
        setFrame(hidingDock ? screen.frame : screen.visibleFrame, display: true)
    }
}

/// Applies and withdraws the full-screen presentation options as the window
/// gains and loses key status.
///
/// The default is to leave the Dock and menu bar alone. A rail of thumbnails
/// pinned to the bottom of the screen sits *under* the Dock otherwise, which
/// is both ugly and unusable — the cost of a slightly smaller photograph is
/// well worth a rail you can actually click. "Hide Dock for Larger Preview" in
/// the View menu takes the whole screen for anyone who prefers it.
@MainActor
final class ViewerWindowDelegate: NSObject, NSWindowDelegate {

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? ViewerWindow else { return }
        NSApp.presentationOptions = window.hidesDock ? [.autoHideDock, .autoHideMenuBar] : []
    }

    func windowDidResignKey(_ notification: Notification) {
        // Never leave the Dock hidden behind our back.
        NSApp.presentationOptions = []
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.presentationOptions = []
    }

    /// Follows the window to a different display, and tracks resolution
    /// changes on the current one.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? ViewerWindow else { return }
        window.applyScreenFrame(hidingDock: window.hidesDock)
    }
}
