import AppKit

/// A snapshot of the accessibility settings that change how this app renders.
///
/// Our entire visual premise is a translucent overlay floating over the desktop,
/// which is precisely the thing Reduce Transparency exists to switch off. An
/// app built on translucency has to treat that setting as a first-class layout
/// input, not an afterthought — so it lives here next to the other three and is
/// read on every paint.
@MainActor
struct Accommodations: Equatable {
    /// Draw the backdrop opaque. Translucency over arbitrary desktop content
    /// is a legibility problem before it is a preference.
    var reduceTransparency: Bool
    /// Skip crossfades and the zoom-settle animation; cut straight to the
    /// final state.
    var reduceMotion: Bool
    /// Thicken symbol strokes and raise chrome contrast against the photo.
    var increaseContrast: Bool
    /// Never encode meaning in hue alone — pair it with a glyph or a label.
    var differentiateWithoutColor: Bool

    static var current: Accommodations {
        let workspace = NSWorkspace.shared
        return Accommodations(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        )
    }

    /// Animation duration honoring Reduce Motion. Zero means "apply instantly",
    /// which Core Animation handles correctly inside a disabled transaction.
    func duration(_ preferred: TimeInterval) -> TimeInterval {
        reduceMotion ? 0 : preferred
    }
}

/// Broadcasts the environment changes that require a relayout: accessibility
/// settings, system text size, display arrangement, and appearance.
///
/// One observer object rather than scattered notification registrations, so
/// there is exactly one place to look when something fails to respond to a
/// system change — historically the most common source of "looks wrong on my
/// machine" bugs in this kind of app.
@MainActor
final class EnvironmentMonitor {

    private let bag = ObserverBag()

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        // Every one of these is posted on the main queue and registered with
        // `queue: .main`, so `assumeIsolated` is a statement of fact rather
        // than a hope.
        func observe(_ center: NotificationCenter, _ name: Notification.Name) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
            bag.add(token, from: center)
        }

        observe(workspaceCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        // Fires when the app moves between displays of differing scale factor,
        // or the resolution changes under it.
        observe(defaultCenter, NSApplication.didChangeScreenParametersNotification)
        // System text size changes arrive alongside the theme change
        // notification; `NSFont`'s caches are already invalidated by the time
        // this lands, so re-reading `preferredFont` here is correct.
        observe(defaultCenter, NSNotification.Name("AppleInterfaceThemeChangedNotification"))
    }
}

/// Holds notification tokens and unregisters them on dealloc.
///
/// This exists because a `@MainActor` type cannot touch its own non-Sendable
/// stored properties from `deinit`, which is nonisolated. Keeping the tokens in
/// an unchecked-Sendable box confines that exception to five lines whose
/// safety is easy to see: the array is only mutated during `init`, and only
/// read during `deinit`, so the two can never overlap.
private final class ObserverBag: @unchecked Sendable {
    private var entries: [(token: NSObjectProtocol, center: NotificationCenter)] = []

    func add(_ token: NSObjectProtocol, from center: NotificationCenter) {
        entries.append((token, center))
    }

    deinit {
        // `NotificationCenter` is documented thread-safe, so removing from a
        // nonisolated deinit is sound.
        for entry in entries {
            entry.center.removeObserver(entry.token)
        }
    }
}
