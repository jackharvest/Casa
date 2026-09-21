import AppKit
import UniformTypeIdentifiers

/// What you get when you launch Casa without a photo.
///
/// An empty viewer would be pointless: this is an app whose whole job begins
/// when you double-click a file, so the one useful thing a bare launch can do
/// is get itself wired up as the app that receives those double-clicks. Hence
/// the default-handler card, which is the screen's real content rather than a
/// preference buried three menus deep.
///
/// It also accepts a dropped photo, because a window sitting open is somewhere
/// people will try to drop things.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    /// Called when the user picks or drops a photo.
    var onOpen: ((URL) -> Void)?

    private var window: NSWindow?
    private var rows: [(group: DefaultHandler.Group, toggle: NSButton, status: NSTextField)] = []
    private var primaryButton: NSButton!
    private var statusLine: NSTextField!
    private var rootStack: NSStackView!

    // MARK: - Presentation

    func present() {
        if window == nil { build() }
        refreshStatuses()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.orderOut(nil) }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Construction

    private func build() {
        let width = max(520, Metrics.pointSize(.control) * 38)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 460),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "Welcome to Casa"
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let material = DropReceivingView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.onDrop = { [weak self] url in self?.handleOpen(url) }
        window.contentView = material

        // --- masthead ---
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let name = NSTextField(labelWithString: "Casa")
        name.font = NSFont.systemFont(ofSize: Metrics.pointSize(.title) * 1.7, weight: .semibold)

        let tagline = NSTextField(labelWithString: "A fast, chromeless photo viewer.  Version \(version)")
        tagline.font = Metrics.font(.caption)
        tagline.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [name, tagline])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = Metrics.spacing(0.5)

        let masthead = NSStackView(views: [iconView, titleStack])
        masthead.orientation = .horizontal
        masthead.alignment = .centerY
        masthead.spacing = Metrics.spacing(3)

        // --- the default-handler card ---
        let cardTitle = NSTextField(labelWithString: "Open these with Casa")
        cardTitle.font = NSFont.systemFont(ofSize: Metrics.pointSize(.control), weight: .semibold)

        let cardHint = NSTextField(wrappingLabelWithString:
            "Until Casa is the default, double-clicking a photo still opens Preview.")
        cardHint.font = Metrics.font(.caption)
        cardHint.textColor = .secondaryLabelColor
        cardHint.preferredMaxLayoutWidth = width - Metrics.spacing(14)

        let cardStack = NSStackView(views: [cardTitle, cardHint])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = Metrics.spacing(1)

        for group in DefaultHandler.groups {
            let toggle = NSButton(checkboxWithTitle: group.title, target: nil, action: nil)
            toggle.state = group.recommended ? .on : .off
            toggle.font = Metrics.font(.control)

            let detail = NSTextField(labelWithString: group.detail)
            detail.font = Metrics.font(.caption)
            detail.textColor = .tertiaryLabelColor

            let status = NSTextField(labelWithString: "")
            status.font = NSFont.monospacedDigitSystemFont(
                ofSize: Metrics.pointSize(.caption), weight: .regular)
            status.textColor = .secondaryLabelColor
            status.alignment = .right

            let labels = NSStackView(views: [toggle, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1

            let row = NSStackView(views: [labels, NSView(), status])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            cardStack.addView(row, in: .bottom)
            row.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

            rows.append((group, toggle, status))
        }

        let card = InsetCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        let pad = Metrics.spacing(3)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
        ])

        // --- actions ---
        statusLine = NSTextField(labelWithString: "")
        statusLine.font = Metrics.font(.caption)
        statusLine.textColor = .secondaryLabelColor

        primaryButton = NSButton(title: "Make Casa the Default", target: self,
                                 action: #selector(claimDefaults))
        primaryButton.bezelStyle = .push
        primaryButton.controlSize = .large
        primaryButton.keyEquivalent = "\r"
        primaryButton.bezelColor = .controlAccentColor

        let openButton = NSButton(title: "Open a Photo…", target: self, action: #selector(openPhoto))
        openButton.bezelStyle = .push
        openButton.controlSize = .large

        let buttonRow = NSStackView(views: [openButton, NSView(), primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fill

        let footnote = NSTextField(wrappingLabelWithString:
            "You can also drop a photo here, or onto Casa in the Dock.")
        footnote.font = Metrics.font(.caption)
        footnote.textColor = .tertiaryLabelColor

        rootStack = NSStackView(views: [masthead, card, statusLine, buttonRow, footnote])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = Metrics.spacing(3)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.edgeInsets = NSEdgeInsets(top: Metrics.spacing(6), left: Metrics.spacing(5),
                                            bottom: Metrics.spacing(4), right: Metrics.spacing(5))
        material.addSubview(rootStack)

        let iconEdge = Metrics.hitTarget(.hero) * 1.5
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: material.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconEdge),
            iconView.heightAnchor.constraint(equalToConstant: iconEdge),
            card.widthAnchor.constraint(equalTo: rootStack.widthAnchor,
                                        constant: -Metrics.spacing(10)),
            buttonRow.widthAnchor.constraint(equalTo: card.widthAnchor),
            footnote.widthAnchor.constraint(equalTo: card.widthAnchor),
        ])

        self.window = window
        resize()
    }

    // MARK: - State

    private func refreshStatuses() {
        var allOurs = true
        for row in rows {
            let summary = DefaultHandler.summary(for: row.group)
            row.status.stringValue = summary
            let ours = DefaultHandler.owns(row.group)
            row.status.textColor = ours ? .systemGreen : .secondaryLabelColor
            // Nothing to do for a group we already own.
            row.toggle.isEnabled = !ours
            if ours { row.toggle.state = .on }
            if row.group.recommended && !ours { allOurs = false }
        }
        primaryButton.isEnabled = !allOurs
        if allOurs {
            statusLine.stringValue = "Casa already opens your photos."
            statusLine.textColor = .systemGreen
        } else {
            statusLine.stringValue = ""
        }
    }

    private func resize() {
        guard let window, let content = window.contentView else { return }
        rootStack.layoutSubtreeIfNeeded()
        let fitted = rootStack.fittingSize
        guard fitted.height > 0 else { return }
        var frame = window.frame
        let delta = fitted.height - content.frame.height
        guard abs(delta) > 0.5 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: !Accommodations.current.reduceMotion)
    }

    // MARK: - Actions

    @objc private func claimDefaults() {
        let selected = rows.filter { $0.toggle.state == .on && !DefaultHandler.owns($0.group) }
            .map(\.group)
        guard !selected.isEmpty else { return }

        primaryButton.isEnabled = false
        statusLine.stringValue = "Asking macOS…"
        statusLine.textColor = .secondaryLabelColor

        Task { [weak self] in
            let outcome = await DefaultHandler.claim(selected)
            guard let self else { return }
            self.refreshStatuses()

            switch outcome {
            case .claimed(let count):
                self.statusLine.stringValue = "Casa now opens \(count) file types."
                self.statusLine.textColor = .systemGreen
            case .partiallyClaimed(let claimed, let failed):
                self.statusLine.stringValue = "Claimed \(claimed); macOS refused \(failed)."
                self.statusLine.textColor = .systemOrange
            case .failed(let message):
                self.statusLine.stringValue = message
                self.statusLine.textColor = .systemOrange
                DefaultHandler.explainManualRoute()
            }
        }
    }

    @objc private func openPhoto() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a photo. Casa will walk the rest of the folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        handleOpen(url)
    }

    private func handleOpen(_ url: URL) {
        close()
        onOpen?(url)
    }
}

// MARK: - Supporting views

/// A rounded well that groups the default-handler rows without becoming a
/// second competing surface.
private final class InsetCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let layer = CALayer()
        layer.cornerRadius = Metrics.cornerRadius(.control) * 1.4
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        layer.borderWidth = 1
        self.layer = layer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The welcome window's background, which also accepts a dropped photo.
private final class DropReceivingView: NSVisualEffectView {

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
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
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
        // A ring rather than a tint, so the highlight reads at a glance
        // without washing out everything underneath it.
        let inset = Metrics.spacing(2)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                xRadius: Metrics.cornerRadius(.control) * 2,
                                yRadius: Metrics.cornerRadius(.control) * 2)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = max(3, Metrics.spacing(0.75))
        path.stroke()
    }
}
