import AppKit

/// A glass panel standing at the right-hand edge of the viewer.
///
/// The photograph is re-fitted into the space beside it rather than covered,
/// so opening the inspector never hides the thing being inspected.
class SidePanel: NSView {

    let stack = NSStackView()
    private var glass: NSView!
    private var widthConstraint: NSLayoutConstraint!

    /// Width in points, from the same scale as the rest of the chrome.
    static var preferredWidth: CGFloat { (ChromeMetrics.pointSize(.control) * 19).rounded() }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        let holder = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        Glass.pin(stack, to: holder)
        glass = Glass.panel(holder, cornerRadius: 22, tint: NSColor(white: 0, alpha: 0.32))
        addSubview(glass)
        Glass.pin(glass, to: self)
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.preferredWidth)
        widthConstraint.isActive = true
        applyMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func applyMetrics() {
        let unit = ChromeMetrics.spacing(1)
        widthConstraint.constant = Self.preferredWidth
        stack.spacing = unit * 2
        stack.edgeInsets = NSEdgeInsets(top: unit * 3, left: unit * 3, bottom: unit * 3, right: unit * 3)
        Glass.setCornerRadius(glass, unit * 4)
    }

    /// Width available to content inside the panel's padding.
    var contentWidth: CGFloat { Self.preferredWidth - ChromeMetrics.spacing(6) }

    func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeMetrics.font(.title)
        label.textColor = .white
        return label
    }
}

// MARK: - Inspector

/// What the file says about itself: dimensions, camera, exposure, place.
final class InspectorPanel: SidePanel {

    private let scroll = NSScrollView()
    private let sections = NSStackView()
    private var coordinate: (latitude: Double, longitude: Double)?

    override init() {
        super.init()
        stack.addArrangedSubview(heading("Info"))

        sections.orientation = .vertical
        sections.alignment = .leading
        sections.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sections)
        Glass.pin(sections, to: document)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scroll)

        let fitted = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        fitted.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: contentWidth),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // As tall as its contents when there is room, scrolling when not.
            fitted,
        ])
    }

    func show(_ metadata: ImageMetadata) {
        sections.arrangedSubviews.forEach { $0.removeFromSuperview() }
        coordinate = metadata.coordinate
        let unit = ChromeMetrics.spacing(1)
        sections.spacing = unit * 2.5

        for section in metadata.sections {
            let title = NSTextField(labelWithString: section.title.uppercased())
            title.font = .systemFont(ofSize: ChromeMetrics.pointSize(.caption) * 0.9, weight: .semibold)
            title.textColor = NSColor(white: 1, alpha: 0.5)

            let rows: [[NSView]] = section.rows.map { row in
                let label = NSTextField(labelWithString: row.label)
                label.font = ChromeMetrics.font(.caption, weight: .regular)
                label.textColor = NSColor(white: 1, alpha: 0.6)
                label.alignment = .right

                let value = NSTextField(wrappingLabelWithString: row.value)
                value.font = ChromeMetrics.font(.caption, weight: .regular)
                value.textColor = .white
                value.isSelectable = true
                value.lineBreakMode = .byCharWrapping
                value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return [label, value]
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = (unit * 0.75).rounded()
            grid.columnSpacing = unit * 1.5
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = (contentWidth * 0.36).rounded()
            grid.rowAlignment = .firstBaseline
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

            let block = NSStackView(views: [title, grid])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = unit
            sections.addArrangedSubview(block)

            if section.title == "Location", metadata.coordinate != nil {
                let maps = ChromeTextButton("Show in Maps", action: #selector(openMaps(_:)), target: self)
                sections.addArrangedSubview(maps)
            }
        }
    }

    @objc private func openMaps(_ sender: Any?) {
        guard let coordinate,
              let url = URL(string: "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)&q=Photo")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Colour

/// The colour sliders.
///
/// Every slider rests in the middle at "unchanged", and the photograph
/// behind the panel updates as they move, so there is no preview thumbnail
/// to squint at — the preview is the picture.
final class AdjustPanel: SidePanel {

    var onChange: ((Adjustments) -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?

    private(set) var adjustments = Adjustments()

    private struct Control {
        let title: String
        let path: WritableKeyPath<Adjustments, Double>
        let range: ClosedRange<Double>
    }

    private static let controls: [Control] = [
        Control(title: "Exposure", path: \.exposure, range: -2...2),
        Control(title: "Contrast", path: \.contrast, range: -1...1),
        Control(title: "Highlights", path: \.highlights, range: -1...1),
        Control(title: "Shadows", path: \.shadows, range: -1...1),
        Control(title: "Saturation", path: \.saturation, range: -1...1),
        Control(title: "Temperature", path: \.temperature, range: -1...1),
        Control(title: "Tint", path: \.tint, range: -1...1),
        Control(title: "Sharpness", path: \.sharpness, range: 0...1),
        Control(title: "Sepia", path: \.sepia, range: 0...1),
    ]

    private var sliders: [NSSlider] = []
    private var auto: NSButton!

    override init() {
        super.init()
        let unit = ChromeMetrics.spacing(1)
        stack.addArrangedSubview(heading("Adjust Color"))

        auto = NSButton(checkboxWithTitle: "Auto Enhance", target: self, action: #selector(toggleAuto(_:)))
        auto.font = ChromeMetrics.font(.caption, weight: .regular)
        stack.addArrangedSubview(auto)

        for (index, control) in Self.controls.enumerated() {
            let label = NSTextField(labelWithString: control.title)
            label.font = ChromeMetrics.font(.caption, weight: .regular)
            label.textColor = NSColor(white: 1, alpha: 0.75)

            let slider = NSSlider(value: 0, minValue: control.range.lowerBound,
                                  maxValue: control.range.upperBound,
                                  target: self, action: #selector(sliderMoved(_:)))
            slider.tag = index
            slider.isContinuous = true
            slider.controlSize = .small
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            sliders.append(slider)

            let row = NSStackView(views: [label, slider])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = (unit * 0.4).rounded()
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(unit * 1.4, after: row)
        }

        let reset = ChromeTextButton("Reset", action: #selector(reset(_:)), target: self)
        let cancel = ChromeTextButton("Cancel", keyEquivalentHint: "Esc", action: #selector(cancel(_:)), target: self)
        let done = ChromeTextButton("Done", style: .prominent, keyEquivalentHint: "Return",
                                    action: #selector(commit(_:)), target: self)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer, cancel, done])
        buttons.orientation = .horizontal
        buttons.spacing = unit
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(unit * 3, after: last) }
        stack.addArrangedSubview(buttons)
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let control = Self.controls[sender.tag]
        var value = sender.doubleValue
        // A soft detent at the resting point, so "back to how it was" does
        // not need a steady hand.
        let span = control.range.upperBound - control.range.lowerBound
        if control.range.lowerBound < 0, abs(value) < span * 0.02 {
            value = 0
            sender.doubleValue = 0
        }
        adjustments[keyPath: control.path] = value
        onChange?(adjustments)
    }

    @objc private func toggleAuto(_ sender: NSButton) {
        adjustments.autoEnhance = sender.state == .on
        onChange?(adjustments)
    }

    @objc private func reset(_ sender: Any?) {
        adjustments = Adjustments()
        sliders.forEach { $0.doubleValue = 0 }
        auto.state = .off
        onChange?(adjustments)
    }

    @objc private func cancel(_ sender: Any?) { onCancel?() }
    @objc private func commit(_ sender: Any?) { onCommit?() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}": onCommit?()
        case "\u{1b}": onCancel?()
        default: super.keyDown(with: event)
        }
    }
}
