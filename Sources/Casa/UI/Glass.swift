import AppKit

/// Liquid Glass surfaces, with a graceful fall back.
///
/// macOS 26 added `NSGlassEffectView`, which is the real thing: it refracts and
/// tints what is behind it and responds to what is around it. Casa still runs
/// on macOS 14, so every surface goes through here and degrades to
/// `NSVisualEffectView` where glass does not exist. The call sites never see
/// the difference.
///
/// Glass panels in proximity are wrapped in an `NSGlassEffectContainerView`
/// where possible. That is not only a performance matter — the container lets
/// neighbouring panels merge rather than each rendering its own hard edge,
/// which is most of what separates this from a stack of frosted rectangles.
@MainActor
enum Glass {

    enum Style {
        /// Standard glass. The default for panels holding content.
        case regular
        /// Clearer, for surfaces that should mostly disappear.
        case clear
    }

    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// A rounded glass panel wrapping `content`.
    static func panel(_ content: NSView,
                      cornerRadius: CGFloat,
                      tint: NSColor? = nil,
                      style: Style = .regular) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            glass.style = style == .clear ? .clear : .regular
            glass.contentView = content
            glass.translatesAutoresizingMaskIntoConstraints = false
            return glass
        }

        // Pre-26: a vibrancy view with a masked corner radius is the closest
        // equivalent the platform offers.
        let effect = NSVisualEffectView()
        effect.material = style == .clear ? .underWindowBackground : .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        if let tint {
            let wash = NSView()
            wash.wantsLayer = true
            wash.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
            wash.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(wash)
            pin(wash, to: effect)
        }
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        pin(content, to: effect)
        return effect
    }

    /// Re-rounds a panel made by `panel(_:cornerRadius:)`, for surfaces whose
    /// size follows the user's text setting.
    static func setCornerRadius(_ panel: NSView, _ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = panel as? NSGlassEffectView {
            glass.cornerRadius = radius
            return
        }
        panel.layer?.cornerRadius = radius
    }

    /// Groups panels so they can merge when close together.
    static func container(_ content: NSView, spacing: CGFloat = 18) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = spacing
            container.contentView = content
            container.translatesAutoresizingMaskIntoConstraints = false
            return container
        }

        let plain = NSView()
        plain.translatesAutoresizingMaskIntoConstraints = false
        plain.addSubview(content)
        pin(content, to: plain)
        return plain
    }

    static func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        ])
    }
}

/// Type scale for the settings window.
///
/// Separate from `Metrics`, which sizes the viewer's chrome against a
/// photograph. A settings window is read rather than glanced at, so it wants a
/// wider range and more air.
@MainActor
enum Typography {
    static var largeTitle: NSFont { .systemFont(ofSize: 28, weight: .bold) }
    static var title: NSFont { .systemFont(ofSize: 20, weight: .semibold) }
    static var heading: NSFont { .systemFont(ofSize: 14, weight: .semibold) }
    static var body: NSFont { .systemFont(ofSize: 13.5, weight: .regular) }
    static var caption: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static var mono: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
}
