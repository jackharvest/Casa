import AppKit

/// A chrome control: an SF Symbol on a transparent ground, or on a pearl disc
/// for the one control that should draw the eye.
///
/// Exists so that no view controller ever writes a size. The button asks
/// `ChromeMetrics` for its glyph and its hit target, both derived from the
/// user's text-size setting and the display, and rebuilds both when either
/// changes.
final class IconButton: NSButton {

    enum Style {
        /// A glyph that lights a soft circle under the pointer.
        case plain
        /// A filled disc with a dark glyph — the centrepiece of the toolbar,
        /// after Picasa's round play button, which was the only thing in its
        /// chrome that was not flat.
        case disc
    }

    private var symbolName: String
    private let role: Metrics.Role
    private let style: Style
    /// Edge relative to the role's standard hit target.
    private let sizeFactor: CGFloat

    /// Lit controls are drawn at full strength, the rest slightly dimmed —
    /// how the original showed whether Fit or 1:1 was in force, without
    /// adding a separate indicator.
    var isLit = false {
        didSet { if isLit != oldValue { applyTint() } }
    }

    /// A control with nothing to do stays in place but recedes, so the
    /// toolbar's shape never changes under the pointer.
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            applyTint()
            applyGround(animated: false)
        }
    }

    init(symbol: String,
         role: Metrics.Role = .control,
         style: Style = .plain,
         sizeFactor: CGFloat = 1,
         label: String,
         keyEquivalentHint: String? = nil,
         action: Selector,
         target: AnyObject) {
        self.symbolName = symbol
        self.role = role
        self.style = style
        self.sizeFactor = sizeFactor
        super.init(frame: .zero)

        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous

        // VoiceOver reads this; the tooltip shows it plus its shortcut. An icon
        // button with neither is unusable to anyone who does not already know
        // what the glyph means.
        setAccessibilityLabel(label)
        toolTip = keyEquivalentHint.map { "\(label)  \($0)" } ?? label

        refreshForEnvironment()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Swaps the glyph, for controls whose meaning flips — play and pause.
    func setSymbol(_ symbol: String, label: String) {
        guard symbol != symbolName else { return }
        symbolName = symbol
        setAccessibilityLabel(label)
        if let hint = toolTip?.components(separatedBy: "  ").dropFirst().first {
            toolTip = "\(label)  \(hint)"
        } else {
            toolTip = label
        }
        refreshGlyph()
    }

    var edge: CGFloat { (ChromeMetrics.hitTarget(role) * sizeFactor).rounded() }

    /// Rebuilds the glyph and the hit target from current system settings.
    /// Called on creation and whenever the environment changes.
    func refreshForEnvironment() {
        refreshGlyph()

        let edge = self.edge
        if let existing = sizeConstraints {
            existing.width.constant = edge
            existing.height.constant = edge
        } else {
            let width = widthAnchor.constraint(equalToConstant: edge)
            let height = heightAnchor.constraint(equalToConstant: edge)
            NSLayoutConstraint.activate([width, height])
            sizeConstraints = (width, height)
        }

        // Circles, not rounded squares: the toolbar's pills are capsules, and
        // a square hover inside a capsule reads as a different design system.
        layer?.cornerRadius = edge / 2
        if style == .disc {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.35
            layer?.shadowRadius = edge * 0.12
            layer?.shadowOffset = CGSize(width: 0, height: -edge * 0.04)
        }
        applyGround(animated: false)
        needsDisplay = true
    }

    private func refreshGlyph() {
        let weight: NSFont.Weight = style == .disc ? .bold : .medium
        let symbolRole: Metrics.Role = style == .disc ? .title : role
        let glyph = ChromeMetrics.icon(symbolName, role: symbolRole, weight: weight,
                                       describedAs: accessibilityLabel() ?? symbolName)
        image = symbolName.hasPrefix("play") ? glyph.map(Self.opticallyCentred) : glyph
        applyTint()
    }

    /// A play triangle's mass sits left of its bounding box's centre, so a
    /// mathematically centred one looks like it is drifting left inside a
    /// circle. Padding the left edge by a tenth of the width moves the
    /// centroid to where the eye expects it.
    private static func opticallyCentred(_ glyph: NSImage) -> NSImage {
        let nudge = (glyph.size.width * 0.1).rounded()
        let padded = NSImage(size: NSSize(width: glyph.size.width + nudge * 2,
                                          height: glyph.size.height),
                             flipped: false) { rect in
            glyph.draw(in: NSRect(x: nudge * 2, y: 0,
                                  width: glyph.size.width, height: glyph.size.height))
            return true
        }
        padded.isTemplate = true
        padded.accessibilityDescription = glyph.accessibilityDescription
        return padded
    }

    private func applyTint() {
        let contrast = Accommodations.current.increaseContrast
        switch style {
        case .disc:
            contentTintColor = NSColor(white: 0.08, alpha: isEnabled ? 1 : 0.5)
        case .plain:
            let resting: CGFloat = contrast ? 1 : (isLit ? 1 : 0.8)
            contentTintColor = NSColor(white: 1, alpha: isEnabled ? resting : 0.28)
        }
    }

    private var sizeConstraints: (width: NSLayoutConstraint, height: NSLayoutConstraint)?

    // MARK: - States

    private var isHovered = false
    private var isPressed = false

    private func applyGround(animated: Bool) {
        let ground: NSColor
        switch style {
        case .disc:
            let white: CGFloat = isPressed ? 0.78 : (isHovered && isEnabled ? 1 : 0.92)
            ground = NSColor(white: white, alpha: isEnabled ? 1 : 0.3)
        case .plain:
            let alpha: CGFloat = !isEnabled ? 0 : (isPressed ? 0.26 : (isHovered ? 0.14 : 0))
            ground = NSColor(white: 1, alpha: alpha)
        }

        let duration = animated ? Accommodations.current.duration(0.12) : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setDisableActions(duration == 0)
        layer?.backgroundColor = ground.cgColor
        CATransaction.commit()
    }

    // MARK: - Hover

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyGround(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyGround(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyGround(animated: false)
        // `super` runs the tracking loop and fires the action on release.
        super.mouseDown(with: event)
        isPressed = false
        applyGround(animated: true)
    }

    override func drawFocusRingMask() {
        // Keyboard focus must be visible, and follows the control's circle.
        NSBezierPath(ovalIn: bounds).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
