import AppKit

/// A row in the source list.
///
/// Custom rather than `NSTableView`: four static rows do not need a data
/// source, and a hand-drawn row can carry the selected pill and the symbol
/// tinting without fighting a cell view.
@MainActor
final class SidebarRow: NSButton {

    let tab: SettingsWindowController.Tab
    var isSelected = false { didSet { refresh() } }
    private var isHovering = false { didSet { refresh() } }
    private var trackingArea: NSTrackingArea?

    init(tab: SettingsWindowController.Tab, target: AnyObject, action: Selector) {
        self.tab = tab
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageLeading
        alignment = .left
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        title = "  " + tab.title
        font = Typography.heading
        image = Metrics.icon(tab.symbol, role: .caption, describedAs: tab.title)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func refresh() {
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        let background: NSColor
        if isSelected {
            background = .controlAccentColor
        } else if isHovering {
            background = NSColor.labelColor.withAlphaComponent(0.08)
        } else {
            background = .clear
        }

        let duration = Accommodations.current.reduceMotion ? 0 : 0.12
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setDisableActions(duration == 0)
        layer?.backgroundColor = background.cgColor
        CATransaction.commit()

        contentTintColor = isSelected ? .white : .labelColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Typography.heading,
            .foregroundColor: isSelected ? NSColor.white : NSColor.labelColor,
        ])
    }
}

/// A rounded, tinted symbol badge. Gives each row an anchor for the eye and
/// ties the window to the app icon's palette.
@MainActor
final class BadgeView: NSView {

    init(symbol: String, tint: NSColor, edge: CGFloat = 34) {
        super.init(frame: NSRect(x: 0, y: 0, width: edge, height: edge))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = edge * 0.28
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = tint.withAlphaComponent(0.22).cgColor

        let image = NSImageView()
        image.image = Metrics.icon(symbol, role: .control, describedAs: symbol)
        image.contentTintColor = tint
        image.imageScaling = .scaleProportionallyDown
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: edge),
            heightAnchor.constraint(equalToConstant: edge),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: edge * 0.62),
            image.heightAnchor.constraint(equalToConstant: edge * 0.62),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A capsule showing which app currently owns a file type. Green when it's us.
@MainActor
final class StatusChip: NSView {

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func set(text: String, isGood: Bool) {
        label.stringValue = text
        label.textColor = isGood ? .systemGreen : .secondaryLabelColor
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (isGood ? NSColor.systemGreen : NSColor.labelColor)
            .withAlphaComponent(isGood ? 0.14 : 0.07).cgColor
    }
}

/// The window background, which also accepts a dropped photo.
@MainActor
final class DropReceivingView: NSVisualEffectView {

    var onDrop: ((URL) -> Void)?
    private var isTargeted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return nil }
        return urls.first { SupportedTypes.canOpen($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargeted = droppedURL(sender) != nil
        return isTargeted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        guard let url = droppedURL(sender) else { return false }
        onDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isTargeted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 10),
                                xRadius: 22, yRadius: 22)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}
