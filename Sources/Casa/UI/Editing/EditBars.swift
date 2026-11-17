import AppKit

/// A worded button for the chrome: Done, Cancel, Crop.
///
/// The toolbar gets by on glyphs because its actions are reversible and
/// familiar. Committing an edit is neither, so those buttons say what they do.
final class ChromeTextButton: NSButton {

    enum Style {
        case plain
        /// The one that finishes the job: a pearl pill, like the play disc.
        case prominent
    }

    private let style: Style
    private var isHovered = false
    private var heightConstraint: NSLayoutConstraint?

    init(_ title: String, style: Style = .plain, keyEquivalentHint: String? = nil,
         action: Selector, target: AnyObject) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        toolTip = keyEquivalentHint.map { "\(title)  \($0)" }
        setContentHuggingPriority(.required, for: .horizontal)
        refreshForEnvironment()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setTitle(_ title: String) {
        self.title = title
        refreshForEnvironment()
    }

    func refreshForEnvironment() {
        let font = ChromeMetrics.font(.control, weight: style == .prominent ? .semibold : .medium)
        let colour: NSColor = style == .prominent
            ? NSColor(white: 0.08, alpha: isEnabled ? 1 : 0.5)
            : NSColor(white: 1, alpha: isEnabled ? 0.92 : 0.3)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: colour,
        ])
        let height = (ChromeMetrics.hitTarget() * 0.86).rounded()
        if let heightConstraint {
            heightConstraint.constant = height
        } else {
            heightConstraint = heightAnchor.constraint(equalToConstant: height)
            heightConstraint?.isActive = true
        }
        layer?.cornerRadius = height / 2
        applyGround()
        invalidateIntrinsicContentSize()
    }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { refreshForEnvironment() } }
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + ChromeMetrics.spacing(5),
                      height: heightConstraint?.constant ?? ceil(text.height))
    }

    private func applyGround() {
        let ground: NSColor = switch style {
        case .prominent: NSColor(white: isHovered ? 1 : 0.92, alpha: isEnabled ? 1 : 0.3)
        case .plain: NSColor(white: 1, alpha: isHovered && isEnabled ? 0.14 : 0)
        }
        layer?.backgroundColor = ground.cgColor
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; applyGround() }
    override func mouseExited(with event: NSEvent) { isHovered = false; applyGround() }
}

/// A glass capsule holding a row of controls, centred along the bottom of the
/// viewer. The bars that replace the toolbar while a tool is in use are all
/// one of these, so they sit where the toolbar sat and look like its kin.
class EditBar: NSView {

    let row = NSStackView()
    private var pill: NSView!
    private var heightConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        pill = Glass.panel(row, cornerRadius: 24, tint: NSColor(white: 0, alpha: 0.28))
        addSubview(pill)
        Glass.pin(pill, to: self)
        heightConstraint = pill.heightAnchor.constraint(equalToConstant: 44)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func applyMetrics() {
        let unit = ChromeMetrics.spacing(1)
        row.spacing = (unit * 0.5).rounded()
        row.edgeInsets = NSEdgeInsets(top: unit * 0.75, left: unit * 1.25, bottom: unit * 0.75, right: unit * 1.25)
        for case let button as IconButton in row.arrangedSubviews { button.refreshForEnvironment() }
        for case let button as ChromeTextButton in row.arrangedSubviews { button.refreshForEnvironment() }
        let height = ChromeMetrics.hitTarget() + unit * 1.5
        heightConstraint.constant = height
        Glass.setCornerRadius(pill, height / 2)
    }

    /// A hairline between groups of controls.
    func addDivider() {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(line)
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalTo: row.heightAnchor, multiplier: 0.45),
        ])
        row.setCustomSpacing(ChromeMetrics.spacing(1.5), after: line)
        if let before = row.arrangedSubviews.dropLast().last {
            row.setCustomSpacing(ChromeMetrics.spacing(1.5), after: before)
        }
    }

    func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeMetrics.font(.caption)
        label.textColor = NSColor(white: 1, alpha: 0.7)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

// MARK: - Markup

@MainActor
protocol MarkupBarDelegate: AnyObject {
    func markupBar(_ bar: MarkupBar, didChoose tool: MarkupTool)
    func markupBar(_ bar: MarkupBar, didChange style: MarkupStyle)
    /// Highlight, underline or strike through the selected text. PDFs only.
    func markupBar(_ bar: MarkupBar, didRequestTextMark mark: MarkupBar.TextMark)
    func markupBarDidFinish(_ bar: MarkupBar)
}

/// The drawing tools, the ink, and the way out.
final class MarkupBar: EditBar {

    enum Flavor {
        /// Shapes that will be flattened into a photograph.
        case image
        /// Annotations on a PDF, which also offers marks on selected text and
        /// does not offer a cover-up — drawing a black box over a PDF's text
        /// leaves the text underneath, and calling that redaction would be a
        /// lie someone eventually relies on.
        case document
    }

    enum TextMark: Int {
        case highlight, underline, strikethrough

        var symbol: String {
            switch self {
            case .highlight: "highlighter"
            case .underline: "underline"
            case .strikethrough: "strikethrough"
            }
        }

        var label: String {
            switch self {
            case .highlight: "Highlight Selection"
            case .underline: "Underline Selection"
            case .strikethrough: "Strike Through Selection"
            }
        }
    }

    weak var delegate: MarkupBarDelegate?

    private(set) var tool: MarkupTool
    private(set) var style = MarkupStyle()

    private var toolButtons: [MarkupTool: IconButton] = [:]
    private var swatch: IconButton!
    private var weightButton: IconButton!

    init(flavor: Flavor) {
        tool = flavor == .image ? .pen : .select
        super.init()

        let tools: [MarkupTool] = flavor == .image
            ? [.select, .pen, .highlighter, .line, .arrow, .rectangle, .ellipse, .text, .redact]
            : [.select, .pen, .line, .arrow, .rectangle, .ellipse, .text]
        for item in tools {
            let button = IconButton(symbol: item.symbol, label: item.label,
                                    action: #selector(chooseTool(_:)), target: self)
            button.tag = item.rawValue
            button.isOn = item == tool
            toolButtons[item] = button
            row.addArrangedSubview(button)
        }

        if flavor == .document {
            addDivider()
            for mark in [TextMark.highlight, .underline, .strikethrough] {
                let button = IconButton(symbol: mark.symbol, label: mark.label,
                                        action: #selector(markText(_:)), target: self)
                button.tag = mark.rawValue
                row.addArrangedSubview(button)
            }
        }

        addDivider()
        swatch = IconButton(symbol: "circle.fill", label: "Color",
                            action: #selector(showColours(_:)), target: self)
        swatch.tintOverride = style.color
        weightButton = IconButton(symbol: "lineweight", label: "Line Weight",
                                  action: #selector(showWeights(_:)), target: self)
        row.addArrangedSubview(swatch)
        row.addArrangedSubview(weightButton)

        addDivider()
        row.addArrangedSubview(ChromeTextButton("Done", style: .prominent, keyEquivalentHint: "Return",
                                                action: #selector(finish(_:)), target: self))
        applyMetrics()
    }

    func select(_ next: MarkupTool) {
        guard toolButtons[next] != nil else { return }
        tool = next
        for (item, button) in toolButtons { button.isOn = item == next }
    }

    @objc private func chooseTool(_ sender: IconButton) {
        guard let next = MarkupTool(rawValue: sender.tag) else { return }
        select(next)
        delegate?.markupBar(self, didChoose: next)
    }

    @objc private func markText(_ sender: IconButton) {
        guard let mark = TextMark(rawValue: sender.tag) else { return }
        delegate?.markupBar(self, didRequestTextMark: mark)
    }

    @objc private func finish(_ sender: Any?) {
        delegate?.markupBarDidFinish(self)
    }

    // MARK: - Ink

    @objc private func showColours(_ sender: IconButton) {
        let menu = NSMenu()
        for (index, entry) in MarkupStyle.palette.enumerated() {
            let item = NSMenuItem(title: entry.name, action: #selector(chooseColour(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = Self.dot(entry.color)
            item.state = entry.color == style.color ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other\u{2026}", action: #selector(showColourPanel(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func chooseColour(_ sender: NSMenuItem) {
        setColour(MarkupStyle.palette[sender.tag].color)
    }

    @objc private func showColourPanel(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colourPanelChanged(_:)))
        panel.color = style.color
        panel.orderFront(nil)
    }

    @objc private func colourPanelChanged(_ sender: NSColorPanel) {
        setColour(sender.color.usingColorSpace(.sRGB) ?? sender.color)
    }

    private func setColour(_ colour: NSColor) {
        style.color = colour
        swatch.tintOverride = colour
        delegate?.markupBar(self, didChange: style)
    }

    @objc private func showWeights(_ sender: IconButton) {
        let menu = NSMenu()
        for weight in MarkupStyle.Weight.allCases {
            let item = NSMenuItem(title: weight.label, action: #selector(chooseWeight(_:)), keyEquivalent: "")
            item.target = self
            item.tag = weight.rawValue
            item.state = weight == style.weight ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func chooseWeight(_ sender: NSMenuItem) {
        guard let weight = MarkupStyle.Weight(rawValue: sender.tag) else { return }
        style.weight = weight
        delegate?.markupBar(self, didChange: style)
    }

    private static func dot(_ colour: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            colour.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 0.5, alpha: 0.6).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }
}

// MARK: - Crop

/// Shape, size, and the two ways out of a crop.
final class CropBar: EditBar {

    var onAspect: ((CGFloat?) -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?

    private let imageSize: CGSize
    private var shapeButton: ChromeTextButton!
    private let sizeLabel: NSTextField
    private var isPortrait: Bool

    private static let shapes: [(String, CGFloat?)] = [
        ("Freeform", nil), ("Original", 0), ("Square", 1),
        ("3 : 2", 1.5), ("4 : 3", 4.0 / 3), ("5 : 4", 1.25), ("16 : 9", 16.0 / 9),
    ]
    private var shapeIndex = 0

    init(imageSize: CGSize) {
        self.imageSize = imageSize
        self.isPortrait = imageSize.height > imageSize.width
        sizeLabel = NSTextField(labelWithString: "")
        super.init()

        shapeButton = ChromeTextButton("Freeform", action: #selector(showShapes(_:)), target: self)
        sizeLabel.font = ChromeMetrics.font(.caption)
        sizeLabel.textColor = NSColor(white: 1, alpha: 0.7)
        sizeLabel.alignment = .center

        row.addArrangedSubview(shapeButton)
        row.addArrangedSubview(sizeLabel)
        addDivider()
        row.addArrangedSubview(ChromeTextButton("Cancel", keyEquivalentHint: "Esc",
                                                action: #selector(cancel(_:)), target: self))
        row.addArrangedSubview(ChromeTextButton("Crop", style: .prominent, keyEquivalentHint: "Return",
                                                action: #selector(commit(_:)), target: self))
        applyMetrics()
        sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: ChromeMetrics.pointSize(.caption) * 9).isActive = true
        update(CGRect(origin: .zero, size: imageSize))
    }

    func update(_ rect: CGRect) {
        sizeLabel.stringValue = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    @objc private func showShapes(_ sender: NSView) {
        let menu = NSMenu()
        for (index, shape) in Self.shapes.enumerated() {
            let item = NSMenuItem(title: shape.0, action: #selector(chooseShape(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == shapeIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let turn = NSMenuItem(title: isPortrait ? "Make Landscape" : "Make Portrait",
                              action: #selector(flipShape(_:)), keyEquivalent: "")
        turn.target = self
        menu.addItem(turn)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func chooseShape(_ sender: NSMenuItem) {
        shapeIndex = sender.tag
        applyShape()
    }

    @objc private func flipShape(_ sender: Any?) {
        isPortrait.toggle()
        applyShape()
    }

    private func applyShape() {
        let (name, ratio) = Self.shapes[shapeIndex]
        shapeButton.setTitle(name)
        guard var ratio else { onAspect?(nil); return }
        // The named shapes are written landscape; "Original" is whichever way
        // the picture already is.
        if ratio == 0 { ratio = max(imageSize.width, imageSize.height) / max(min(imageSize.width, imageSize.height), 1) }
        onAspect?(isPortrait ? 1 / ratio : ratio)
    }

    @objc private func cancel(_ sender: Any?) { onCancel?() }
    @objc private func commit(_ sender: Any?) { onCommit?() }
}
