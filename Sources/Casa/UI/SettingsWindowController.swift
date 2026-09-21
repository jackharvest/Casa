import AppKit
import UniformTypeIdentifiers

/// The window you get when you launch Casa without a photo.
///
/// Casa's job begins when you double-click a file, so an empty viewer would be
/// pointless — but "set the defaults" is not enough to justify a window either,
/// and once that's done it has nothing to say. So it's a small settings window
/// with a source list: defaults, what changed, where the project lives, and a
/// way to say thanks.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    enum Tab: String, CaseIterable {
        case defaults, whatsNew, about, support

        var title: String {
            switch self {
            case .defaults: "File Types"
            case .whatsNew: "What's New"
            case .about: "About"
            case .support: "Support"
            }
        }

        var symbol: String {
            switch self {
            case .defaults: "doc.on.doc"
            case .whatsNew: "sparkles"
            case .about: "info.circle"
            case .support: "heart"
            }
        }
    }

    var onOpen: ((URL) -> Void)?
    var onCheckForUpdates: (() -> Void)?

    private var window: NSWindow?
    private var selected: Tab = .defaults
    private var sidebarButtons: [Tab: SidebarButton] = [:]
    private var contentContainer: NSView!
    private var panes: [Tab: NSView] = [:]

    // Defaults pane
    private var rows: [(group: DefaultHandler.Group, toggle: NSButton, status: NSTextField)] = []
    private var claimButton: NSButton!
    private var defaultsStatus: NSTextField!

    // What's New pane
    private var notesText: NSTextView!
    private var notesSpinner: NSProgressIndicator!
    private var hasLoadedNotes = false

    // MARK: - Presentation

    func present(selecting tab: Tab = .defaults) {
        if window == nil { build() }
        select(tab)
        refreshDefaults()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.orderOut(nil) }
    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Shell

    private func build() {
        let width: CGFloat = 660, height: CGFloat = 470

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "Casa"
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let root = DropReceivingView()
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.onDrop = { [weak self] url in self?.handleOpen(url) }
        window.contentView = root

        // --- sidebar ---
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = Metrics.spacing(0.5)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        for tab in Tab.allCases {
            let button = SidebarButton(tab: tab, target: self, action: #selector(selectTab(_:)))
            sidebarButtons[tab] = button
            sidebarStack.addView(button, in: .top)
            button.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }

        // --- content ---
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)

        let sidebarWidth = max(170, Metrics.pointSize(.control) * 12)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),

            // Clear of the traffic lights.
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: Metrics.spacing(9)),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: Metrics.spacing(2)),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -Metrics.spacing(2)),

            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        panes[.defaults] = buildDefaultsPane()
        panes[.whatsNew] = buildWhatsNewPane()
        panes[.about] = buildAboutPane()
        panes[.support] = buildSupportPane()

        for pane in panes.values {
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = true
            contentContainer.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                pane.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            ])
        }

        self.window = window
    }

    @objc private func selectTab(_ sender: SidebarButton) { select(sender.tab) }

    private func select(_ tab: Tab) {
        selected = tab
        for (key, button) in sidebarButtons { button.isSelected = key == tab }
        for (key, pane) in panes { pane.isHidden = key != tab }
        if tab == .whatsNew { loadReleaseNotesIfNeeded() }
    }

    /// A titled section, used to give every pane the same rhythm.
    private func pane(title: String, subtitle: String, content: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.systemFont(ofSize: Metrics.pointSize(.title) * 1.25, weight: .semibold)

        let sub = NSTextField(wrappingLabelWithString: subtitle)
        sub.font = Metrics.font(.caption)
        sub.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, sub] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.spacing(2)
        stack.setCustomSpacing(Metrics.spacing(4), after: sub)
        stack.edgeInsets = NSEdgeInsets(top: Metrics.spacing(8), left: Metrics.spacing(5),
                                        bottom: Metrics.spacing(4), right: Metrics.spacing(5))
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    func windowWillClose(_ notification: Notification) {}

    private func handleOpen(_ url: URL) {
        close()
        onOpen?(url)
    }
}

// MARK: - File types

extension SettingsWindowController {

    private var totalTypeCount: Int {
        DefaultHandler.groups.reduce(0) { $0 + $1.types.count }
    }

    func buildDefaultsPane() -> NSView {
        let card = InsetCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = Metrics.spacing(2)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        let pad = Metrics.spacing(3)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
        ])

        for group in DefaultHandler.groups {
            let toggle = NSButton(checkboxWithTitle: group.title, target: nil, action: nil)
            toggle.state = group.recommended ? .on : .off
            toggle.font = Metrics.font(.control)

            let detail = NSTextField(labelWithString: group.detail)
            detail.font = Metrics.font(.caption)
            detail.textColor = .tertiaryLabelColor

            let status = NSTextField(labelWithString: "")
            status.font = Metrics.font(.caption)
            status.alignment = .right

            let labels = NSStackView(views: [toggle, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1

            let row = NSStackView(views: [labels, NSView(), status])
            row.orientation = .horizontal
            row.alignment = .centerY
            cardStack.addView(row, in: .bottom)
            row.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true

            rows.append((group, toggle, status))
        }

        defaultsStatus = NSTextField(labelWithString: "")
        defaultsStatus.font = Metrics.font(.caption)
        defaultsStatus.textColor = .secondaryLabelColor

        claimButton = NSButton(title: "Make Casa the Default", target: self,
                               action: #selector(claimDefaults))
        claimButton.bezelStyle = .push
        claimButton.controlSize = .large
        claimButton.keyEquivalent = "\r"
        claimButton.bezelColor = .controlAccentColor

        let openButton = NSButton(title: "Open a Photo…", target: self, action: #selector(openPhoto))
        openButton.bezelStyle = .push
        openButton.controlSize = .large

        let buttons = NSStackView(views: [openButton, NSView(), claimButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY

        card.translatesAutoresizingMaskIntoConstraints = false
        let container = pane(
            title: "File Types",
            subtitle: "Until Casa is the default, double-clicking a photo still opens Preview.",
            content: [card, defaultsStatus, buttons]
        )
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 420),
            buttons.widthAnchor.constraint(equalTo: card.widthAnchor),
        ])
        return container
    }

    func refreshDefaults() {
        guard !rows.isEmpty else { return }
        var pendingRecommended = false
        for row in rows {
            let ours = DefaultHandler.owns(row.group)
            row.status.stringValue = DefaultHandler.summary(for: row.group)
            row.status.textColor = ours ? .systemGreen : .secondaryLabelColor
            row.toggle.isEnabled = !ours
            if ours { row.toggle.state = .on }
            if row.group.recommended && !ours { pendingRecommended = true }
        }
        claimButton.isEnabled = rows.contains { $0.toggle.state == .on && !DefaultHandler.owns($0.group) }
        if !pendingRecommended && !claimButton.isEnabled {
            defaultsStatus.stringValue = "Casa opens your photos."
            defaultsStatus.textColor = .systemGreen
        }
    }

    @objc func claimDefaults() {
        let selected = rows.filter { $0.toggle.state == .on && !DefaultHandler.owns($0.group) }
            .map(\.group)
        guard !selected.isEmpty else { return }
        let count = selected.reduce(0) { $0 + $1.types.count }

        // Warn first. macOS asks separately for every single file type, and
        // being surprised by thirteen consecutive dialogs is a genuinely bad
        // few seconds — worse than being told it's coming.
        let alert = NSAlert()
        alert.messageText = "macOS will ask \(count) times"
        alert.informativeText = """
            It confirms each file type separately, so you'll get \(count) dialogs \
            in a row. Click "Use Casa" on each.

            Uncheck groups first if you'd rather do fewer.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        claimButton.isEnabled = false
        defaultsStatus.textColor = .secondaryLabelColor

        Task { [weak self] in
            guard let self else { return }
            let outcome = await DefaultHandler.claim(selected) { done, total in
                self.defaultsStatus.stringValue = "Confirming \(done) of \(total)…"
            }
            self.refreshDefaults()
            self.finish(outcome)
        }
    }

    private func finish(_ outcome: DefaultHandler.Outcome) {
        switch outcome {
        case .claimed(let count):
            defaultsStatus.stringValue = "Done — Casa opens \(count) file types."
            defaultsStatus.textColor = .systemGreen
            if let root = window?.contentView { Confetti.burst(over: root) }
            // Let the confetti land, then get out of the way. Leaving a window
            // of greyed-out controls sitting there is the least satisfying way
            // to end a job the user just did work for.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self, self.selected == .defaults else { return }
                self.close()
            }
        case .partiallyClaimed(let claimed, let failed):
            defaultsStatus.stringValue = "Set \(claimed). macOS refused \(failed)."
            defaultsStatus.textColor = .systemOrange
        case .failed(let message):
            defaultsStatus.stringValue = message
            defaultsStatus.textColor = .systemOrange
            DefaultHandler.explainManualRoute()
        }
    }

    @objc func openPhoto() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a photo. Casa will walk the rest of the folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        close()
        onOpen?(url)
    }
}

// MARK: - What's New

extension SettingsWindowController {

    func buildWhatsNewPane() -> NSView {
        notesText = NSTextView()
        let notesWidth: CGFloat = 430
        notesText.frame = NSRect(x: 0, y: 0, width: notesWidth, height: 300)
        notesText.minSize = .zero
        notesText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        notesText.isVerticallyResizable = true
        notesText.isHorizontallyResizable = false
        notesText.autoresizingMask = [.width]
        notesText.textContainer?.containerSize = NSSize(width: notesWidth,
                                                        height: CGFloat.greatestFiniteMagnitude)
        notesText.textContainer?.widthTracksTextView = true
        notesText.isEditable = false
        notesText.isSelectable = true
        notesText.drawsBackground = false
        notesText.textContainerInset = NSSize(width: Metrics.spacing(1), height: Metrics.spacing(1))

        let scroll = NSScrollView()
        scroll.documentView = notesText
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        notesSpinner = NSProgressIndicator()
        notesSpinner.style = .spinning
        notesSpinner.controlSize = .small
        notesSpinner.isDisplayedWhenStopped = false

        let container = pane(title: "What's New",
                             subtitle: "Release notes from GitHub.",
                             content: [notesSpinner, scroll])
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: notesWidth),
            scroll.heightAnchor.constraint(equalToConstant: 300),
        ])
        return container
    }

    func loadReleaseNotesIfNeeded() {
        guard !hasLoadedNotes else { return }
        hasLoadedNotes = true
        notesSpinner.startAnimation(nil)

        Task { [weak self] in
            guard let self, let checker = UpdateChecker() else { return }
            defer { self.notesSpinner.stopAnimation(nil) }
            do {
                let releases = try await checker.recentReleases()
                let markdown = releases.map { release in
                    "## \(release.title)\n\n\(release.notes)"
                }.joined(separator: "\n\n---\n\n")
                self.notesText.textStorage?.setAttributedString(
                    ReleaseNotes.rendered(markdown.isEmpty ? "No releases yet." : markdown))
                self.notesText.scroll(.zero)
            } catch {
                self.notesText.textStorage?.setAttributedString(
                    ReleaseNotes.rendered("Couldn't reach GitHub.\n\n\(error.localizedDescription)"))
                self.hasLoadedNotes = false
            }
        }
    }
}

// MARK: - About and Support

extension SettingsWindowController {

    private func link(_ title: String, _ urlString: String, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        button.bezelStyle = .push
        button.controlSize = .large
        button.identifier = NSUserInterfaceItemIdentifier(urlString)
        if primary { button.bezelColor = .controlAccentColor }
        return button
    }

    @objc func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func checkUpdatesTapped() { onCheckForUpdates?() }

    func buildAboutPane() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: "Casa \(version)")
        name.font = NSFont.systemFont(ofSize: Metrics.pointSize(.title) * 1.2, weight: .semibold)

        let buildLine = NSTextField(labelWithString: "Build \(build) · by Jack Harvest")
        buildLine.font = Metrics.font(.caption)
        buildLine.textColor = .secondaryLabelColor

        let names = NSStackView(views: [name, buildLine])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2

        let masthead = NSStackView(views: [icon, names])
        masthead.orientation = .horizontal
        masthead.alignment = .centerY
        masthead.spacing = Metrics.spacing(3)

        let updateButton = NSButton(title: "Check for Updates…", target: self,
                                    action: #selector(checkUpdatesTapped))
        updateButton.bezelStyle = .push
        updateButton.controlSize = .large

        let links = NSStackView(views: [
            link("GitHub", "https://github.com/jackharvest/Casa"),
            link("Releases", "https://github.com/jackharvest/Casa/releases"),
            updateButton,
        ])
        links.orientation = .horizontal
        links.spacing = Metrics.spacing(1.5)

        let container = pane(title: "About",
                             subtitle: "A fast, chromeless photo viewer for macOS. MIT licensed.",
                             content: [masthead, links])
        let edge = Metrics.hitTarget(.hero) * 1.4
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: edge),
            icon.heightAnchor.constraint(equalToConstant: edge),
        ])
        return container
    }

    func buildSupportPane() -> NSView {
        let body = NSTextField(wrappingLabelWithString: """
            Casa is free and always will be. If it saved you some time, \
            a coffee is a nice way to say so.
            """)
        body.font = Metrics.font(.control)
        body.preferredMaxLayoutWidth = 400

        let coffee = link("Buy Me a Coffee", "https://buymeacoffee.com/jackharvest", primary: true)
        let issues = link("Report an Issue", "https://github.com/jackharvest/Casa/issues")

        let buttons = NSStackView(views: [coffee, issues])
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.spacing(1.5)

        return pane(title: "Support",
                    subtitle: "Bug reports are worth as much as coffee.",
                    content: [body, buttons])
    }
}

// MARK: - Supporting views

/// A source-list row: symbol, title, and a selected background.
private final class SidebarButton: NSButton {
    let tab: SettingsWindowController.Tab
    var isSelected = false { didSet { refresh() } }

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
        title = " " + tab.title
        image = Metrics.icon(tab.symbol, role: .caption, describedAs: tab.title)
        font = Metrics.font(.control)
        heightAnchor.constraint(equalToConstant: Metrics.hitTarget(.control)).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        layer?.cornerRadius = Metrics.cornerRadius(.control)
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
        contentTintColor = isSelected ? .white : .labelColor
    }
}

/// A rounded well that groups rows without becoming a competing surface.
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

/// The window background, which also accepts a dropped photo.
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
        let inset = Metrics.spacing(2)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                xRadius: Metrics.cornerRadius(.control) * 2,
                                yRadius: Metrics.cornerRadius(.control) * 2)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = max(3, Metrics.spacing(0.75))
        path.stroke()
    }
}
