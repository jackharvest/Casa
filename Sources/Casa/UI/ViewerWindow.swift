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

    /// How the viewer is presented.
    ///
    /// Picasa's viewer opened filling the screen and dropped into an ordinary
    /// window when you clicked beside the photograph. Both are the same window
    /// with a different style mask, so the photo, the rail and the controls
    /// never have to be rebuilt.
    enum Presentation { case fullBleed, windowed }
    private(set) var presentation: Presentation = .fullBleed

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

    // MARK: - Open and close

    /// A CRT switching on: a bright horizontal line snaps across the middle of
    /// the screen, then opens vertically. Closing runs it backwards.
    ///
    /// Two phases rather than a plain scale, because the line is what sells it.
    /// It also buys a little time — roughly 90 ms where the window is on screen
    /// but only a few pixels tall — for the first decode and the chrome to be
    /// ready by the time there is anything to look at.
    private static let lineHeight: CGFloat = 3
    private static let widenDuration: TimeInterval = 0.085
    private static let openDuration: TimeInterval = 0.135
    private static let collapseDuration: TimeInterval = 0.105
    private static let pinchDuration: TimeInterval = 0.070

    /// True once a close animation has started, so the delegate lets the
    /// second `close()` through instead of animating forever.
    private(set) var isDismissing = false

    /// The frame the window belongs at, captured before the animation shrinks
    /// it to a line.
    private var restingFrame: NSRect = .zero

    func presentAnimated() {
        restingFrame = frame

        guard !Accommodations.current.reduceMotion else {
            makeKeyAndOrderFront(nil)
            return
        }

        let destination = restingFrame
        let middle = CGPoint(x: destination.midX, y: destination.midY)

        // A stub in the middle, the width of a cursor blink.
        setFrame(NSRect(x: middle.x - destination.width * 0.11,
                        y: middle.y - Self.lineHeight / 2,
                        width: destination.width * 0.22,
                        height: Self.lineHeight),
                 display: false)
        makeKeyAndOrderFront(nil)

        let line = NSRect(x: destination.minX, y: middle.y - Self.lineHeight / 2,
                          width: destination.width, height: Self.lineHeight)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.widenDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(line, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isDismissing else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.openDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.animator().setFrame(destination, display: true)
                }
            }
        })
    }

    /// The reverse, then actually close.
    func dismissAnimated() {
        guard !isDismissing else { return }
        isDismissing = true

        guard !Accommodations.current.reduceMotion else {
            close()
            return
        }

        let start = frame
        let middle = CGPoint(x: start.midX, y: start.midY)
        let line = NSRect(x: start.minX, y: middle.y - Self.lineHeight / 2,
                          width: start.width, height: Self.lineHeight)
        let dot = NSRect(x: middle.x - 1, y: middle.y - Self.lineHeight / 2,
                         width: 2, height: Self.lineHeight)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.collapseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(line, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = Self.pinchDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.animator().setFrame(dot, display: true)
                    self.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { self.close() }
                })
            }
        })
    }

    /// Reduce Transparency exists precisely to switch off effects like ours.
    /// Honoring it is not optional: translucency over arbitrary desktop
    /// content is a legibility problem before it is a preference.
    func applyGround() {
        let opaque = Accommodations.current.reduceTransparency
        // Picasa's ground was a light veil, not a blackout. At 0.88 the
        // desktop behind was effectively gone, which reads as a modal sheet
        // rather than as a viewer floating over your work.
        backgroundColor = NSColor(white: 0.06, alpha: opaque ? 1.0 : 0.45)
    }

    /// True while the open or close animation has the window squeezed into a
    /// line. The canvas skips fitting during that, because fitting a photo into
    /// a three-pixel-tall view is wasted work that also produces a visible
    /// flash of a wrongly scaled image at the end.
    var isAnimatingPresentation: Bool {
        frame.height < restingFrame.height * 0.5 && restingFrame.height > 0
    }

    /// Switches between full-bleed and a window hugging the photograph.
    func setPresentation(_ mode: Presentation, contentSize: CGSize) {
        guard mode != presentation else { return }
        presentation = mode
        guard let screen = screen ?? NSScreen.main else { return }

        switch mode {
        case .windowed:
            NSApp.presentationOptions = []
            styleMask = [.titled, .closable, .miniaturizable, .resizable]
            titlebarAppearsTransparent = false
            titleVisibility = .visible
            isMovableByWindowBackground = false
            hasShadow = true
            // Opaque in a window: a translucent titled window over the desktop
            // looks like a rendering fault rather than a choice.
            isOpaque = true
            backgroundColor = NSColor(white: 0.10, alpha: 1)

            let visible = screen.visibleFrame
            let size = CGSize(width: min(contentSize.width, visible.width - 80),
                              height: min(contentSize.height, visible.height - 80))
            let rect = NSRect(x: visible.midX - size.width / 2,
                              y: visible.midY - size.height / 2,
                              width: size.width, height: size.height)
            let framed = frameRect(forContentRect: rect)
            restingFrame = framed
            setFrame(framed, display: true,
                     animate: !Accommodations.current.reduceMotion)

        case .fullBleed:
            styleMask = [.borderless, .resizable]
            restingFrame = screen.visibleFrame
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            isMovableByWindowBackground = false
            hasShadow = false
            isOpaque = false
            applyGround()
            applyScreenFrame(hidingDock: hidesDock)
        }

        makeFirstResponder(contentViewController?.view.subviews.first { $0 is ImageCanvasView })
    }

    /// Resizes for the current Dock preference.
    func applyScreenFrame(hidingDock: Bool) {
        hidesDock = hidingDock
        guard presentation == .fullBleed else { return }
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
        NSApp.presentationOptions = window.presentation == .fullBleed && window.hidesDock
            ? [.autoHideDock, .autoHideMenuBar] : []
    }

    func windowDidResignKey(_ notification: Notification) {
        // Never leave the Dock hidden behind our back.
        NSApp.presentationOptions = []
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.presentationOptions = []
        // Last chance to write a rotation the user applied and never navigated
        // away from.
        if let controller = (notification.object as? NSWindow)?.contentViewController
            as? ViewerController {
            controller.commitPendingRotation()
        }
    }

    /// Intercepts every close — Escape, ⌘W, the surround click — so they all
    /// get the same shrink-to-centre rather than only the paths that happened
    /// to remember to ask for it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let window = sender as? ViewerWindow else { return true }
        if window.isDismissing { return true }
        window.dismissAnimated()
        return false
    }

    /// Follows the window to a different display, and tracks resolution
    /// changes on the current one.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? ViewerWindow else { return }
        window.applyScreenFrame(hidingDock: window.hidesDock)
    }
}
