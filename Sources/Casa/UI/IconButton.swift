import AppKit

/// A chrome control: an SF Symbol on a transparent ground.
///
/// Exists so that no view controller ever writes a size. The button asks
/// `Metrics` for its glyph and its hit target, both derived from the user's
/// text-size setting, and rebuilds both when that setting changes.
final class IconButton: NSButton {

    private let symbolName: String
    private let role: Metrics.Role

    init(symbol: String,
         role: Metrics.Role = .control,
         label: String,
         keyEquivalentHint: String? = nil,
         action: Selector,
         target: AnyObject) {
        self.symbolName = symbol
        self.role = role
        super.init(frame: .zero)

        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // VoiceOver reads this; the tooltip shows it plus its shortcut. An icon
        // button with neither is unusable to anyone who does not already know
        // what the glyph means.
        setAccessibilityLabel(label)
        toolTip = keyEquivalentHint.map { "\(label)  \($0)" } ?? label

        refreshForEnvironment()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rebuilds the glyph and the hit target from current system settings.
    /// Called on creation and whenever the environment changes.
    func refreshForEnvironment() {
        image = Metrics.icon(symbolName, role: role, describedAs: accessibilityLabel() ?? symbolName)
        contentTintColor = Accommodations.current.increaseContrast ? .white : NSColor(white: 1, alpha: 0.88)

        let edge = Metrics.hitTarget(role)
        if let existing = sizeConstraints {
            existing.width.constant = edge
            existing.height.constant = edge
        } else {
            let width = widthAnchor.constraint(equalToConstant: edge)
            let height = heightAnchor.constraint(equalToConstant: edge)
            NSLayoutConstraint.activate([width, height])
            sizeConstraints = (width, height)
        }
        layer?.cornerRadius = Metrics.cornerRadius(role)
        needsDisplay = true
    }

    private var sizeConstraints: (width: NSLayoutConstraint, height: NSLayoutConstraint)?

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
        setHighlighted(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    private func setHighlighted(_ highlighted: Bool) {
        let duration = Accommodations.current.duration(0.12)
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setDisableActions(duration == 0)
        layer?.backgroundColor = highlighted
            ? NSColor(white: 1, alpha: 0.16).cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func drawFocusRingMask() {
        // Keyboard focus must be visible. The default ring is drawn around the
        // full square, which reads correctly against a photograph.
        NSBezierPath(roundedRect: bounds,
                     xRadius: Metrics.cornerRadius(role),
                     yRadius: Metrics.cornerRadius(role)).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
