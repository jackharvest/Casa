import AppKit
import UniformTypeIdentifiers

/// The window Casa opens when you launch it without a photo.
///
/// Built on `NSGlassEffectView` where the OS has it. The sidebar and every card
/// are separate glass panels inside one `NSGlassEffectContainerView`, so they
/// merge rather than each drawing its own hard edge.
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
            case .defaults: "square.grid.2x2"
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
    private var sidebarRows: [Tab: SidebarRow] = [:]
    private var contentContainer: NSView!
    private var panes: [Tab: NSView] = [:]
    private var paneStacks: [Tab: NSStackView] = [:]

    private var rows: [(group: DefaultHandler.Group, toggle: NSSwitch, chip: StatusChip)] = []
    private var claimButton: NSButton!
    private var defaultsStatus: NSTextField!
    private var notesText: NSTextView!
    private var notesSpinner: NSProgressIndicator!
    private var hasLoadedNotes = false

    private static let inset: CGFloat = 14
    private static let cardRadius: CGFloat = 18
    private static let sidebarWidth: CGFloat = 188

    // MARK: - Presentation

    func present(selecting tab: Tab = .defaults) {
        if window == nil { build() }
        select(tab, animated: false)
        refreshDefaults()
        // The window has to lay out before any pane can report a sensible
        // fitting height; before that the stacks have zero width and the
        // wrapping labels answer nonsense.
        window?.contentView?.layoutSubtreeIfNeeded()
        fitWindow(to: tab, animated: false)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.orderOut(nil) }
    var isVisible: Bool { window?.isVisible ?? false }
    func windowWillClose(_ notification: Notification) {}

    // MARK: - Shell

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 516),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "Casa"
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // The ground the glass refracts. Without something behind it, glass has
        // nothing to be glass *of*.
        let ground = DropReceivingView()
        ground.material = .underWindowBackground
        ground.blendingMode = .behindWindow
        ground.state = .active
        ground.onDrop = { [weak self] url in self?.handleOpen(url) }
        window.contentView = ground

        // --- sidebar -----------------------------------------------------
        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 2
        sidebarStack.edgeInsets = NSEdgeInsets(top: 44, left: 10, bottom: 12, right: 10)

        for tab in Tab.allCases {
            let row = SidebarRow(tab: tab, target: self, action: #selector(selectTab(_:)))
            sidebarRows[tab] = row
            sidebarStack.addView(row, in: .top)
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -20).isActive = true
        }

        let sidebar = Glass.panel(sidebarStack, cornerRadius: Self.cardRadius)

        // --- content -----------------------------------------------------
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSView()
        layout.translatesAutoresizingMaskIntoConstraints = false
        layout.addSubview(sidebar)
        layout.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: layout.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: layout.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: layout.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            contentContainer.topAnchor.constraint(equalTo: layout.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: layout.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 14),
            contentContainer.trailingAnchor.constraint(equalTo: layout.trailingAnchor),
        ])

        // One container so the sidebar and the cards merge instead of each
        // rendering an isolated pane of frosted glass.
        let container = Glass.container(layout, spacing: 22)
        ground.addSubview(container)
        Glass.pin(container, to: ground, inset: Self.inset)

        for (tab, make) in [(Tab.defaults, buildDefaultsPane),
                            (Tab.whatsNew, buildWhatsNewPane),
                            (Tab.about, buildAboutPane),
                            (Tab.support, buildSupportPane)] {
            panes[tab] = make()
            paneStacks[tab] = lastBuiltStack
        }

        // Deliberately NOT added to the hierarchy here. A hidden view still
        // participates in Auto Layout, so leaving all four installed made the
        // tallest pane dictate the window's height on every tab. Only the
        // visible pane is a subview.
        for pane in panes.values {
            pane.translatesAutoresizingMaskIntoConstraints = false
        }

        self.window = window
    }

    @objc private func selectTab(_ sender: SidebarRow) { select(sender.tab, animated: true) }

    private func select(_ tab: Tab, animated: Bool) {
        let previous = selected
        selected = tab
        for (key, row) in sidebarRows { row.isSelected = key == tab }
        guard previous != tab || !animated else { return }

        let duration = Accommodations.current.reduceMotion ? 0 : 0.16

        for subview in contentContainer.subviews { subview.removeFromSuperview() }
        guard let incoming = panes[tab] else { return }
        incoming.alphaValue = animated ? 0 : 1
        contentContainer.addSubview(incoming)
        Glass.pin(incoming, to: contentContainer)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                incoming.animator().alphaValue = 1
            }
        }
        if tab == .whatsNew { loadReleaseNotesIfNeeded() }
        if window?.isVisible == true { fitWindow(to: tab, animated: animated) }
    }

    /// Sizes the window to the pane being shown.
    ///
    /// The panes differ by a couple of hundred points, and a window sized for
    /// the tallest leaves the shortest sitting in a field of nothing. Resizing
    /// costs one animation and removes the dead space entirely.
    private func fitWindow(to tab: Tab, animated: Bool) {
        guard let window else { return }
        guard let stack = paneStacks[tab] else { return }
        stack.layoutSubtreeIfNeeded()

        window.contentView?.layoutSubtreeIfNeeded()
        let content = max(stack.fittingSize.height, 260)
        let target = content + Self.inset * 2
        var frame = window.frame
        let delta = target - frame.height
        guard abs(delta) > 1 else { return }

        frame.size.height = target
        // Grow downward from the title bar so the window's top edge stays put.
        frame.origin.y -= delta
        window.setFrame(frame, display: true,
                        animate: animated && !Accommodations.current.reduceMotion)
    }

    // MARK: - Pane scaffolding

    /// Every pane: a large title, a line of context, then content.
    func pane(title: String, subtitle: String, content: [NSView],
              contentSpacing: CGFloat = 14) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = Typography.largeTitle

        let sub = NSTextField(wrappingLabelWithString: subtitle)
        sub.font = Typography.body
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 480

        let stack = NSStackView(views: [heading, sub] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = contentSpacing
        stack.setCustomSpacing(6, after: heading)
        stack.setCustomSpacing(26, after: sub)
        stack.edgeInsets = NSEdgeInsets(top: 42, left: 10, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        lastBuiltStack = stack
        return container
    }

    /// Set by `pane(...)` so `build()` can associate each stack with its tab —
    /// the stack's fitting height is what the window resizes to.
    private var lastBuiltStack: NSStackView?

    func card(_ content: NSView, tint: NSColor? = nil, padding: CGFloat = 16) -> NSView {
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(content)
        Glass.pin(content, to: padded, inset: padding)
        return Glass.panel(padded, cornerRadius: Self.cardRadius, tint: tint)
    }

    private func handleOpen(_ url: URL) {
        close()
        onOpen?(url)
    }
}

// MARK: - File types

extension SettingsWindowController {

    func buildDefaultsPane() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false

        for (index, group) in DefaultHandler.groups.enumerated() {
            if index > 0 {
                let rule = NSBox()
                rule.boxType = .separator
                rule.translatesAutoresizingMaskIntoConstraints = false
                list.addView(rule, in: .bottom)
                rule.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }

            let badge = BadgeView(symbol: group.symbol, tint: group.tint)

            let title = NSTextField(labelWithString: group.title)
            title.font = Typography.heading

            let detail = NSTextField(labelWithString: group.detail)
            detail.font = Typography.caption
            detail.textColor = .tertiaryLabelColor
            detail.lineBreakMode = .byTruncatingTail

            let labels = NSStackView(views: [title, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1

            let chip = StatusChip()
            let toggle = NSSwitch()
            toggle.state = group.recommended ? .on : .off
            toggle.controlSize = .small

            let row = NSStackView(views: [badge, labels, NSView(), chip, toggle])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
            list.addView(row, in: .bottom)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true

            rows.append((group, toggle, chip))
        }

        defaultsStatus = NSTextField(labelWithString: "")
        defaultsStatus.font = Typography.caption
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

        let footer = NSStackView(views: [defaultsStatus, NSView(), openButton, claimButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let hint = NSTextField(wrappingLabelWithString:
            "macOS asks you to confirm each type separately. Casa tells you how many "
            + "dialogs to expect before it starts.\n\n"
            + "You can also drop a photo anywhere on this window to open it.")
        hint.font = Typography.caption
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 500

        let listCard = card(list)
        let container = pane(
            title: "File Types",
            subtitle: "Until Casa is the default, double-clicking a photo still opens Preview.",
            content: [listCard, footer, hint]
        )
        NSLayoutConstraint.activate([
            listCard.widthAnchor.constraint(equalToConstant: 520),
            footer.widthAnchor.constraint(equalTo: listCard.widthAnchor),
        ])
        return container
    }

    func refreshDefaults() {
        guard !rows.isEmpty else { return }
        var anyToClaim = false
        for row in rows {
            let ours = DefaultHandler.owns(row.group)
            row.chip.set(text: DefaultHandler.summary(for: row.group), isGood: ours)
            row.toggle.isEnabled = !ours
            if ours { row.toggle.state = .on }
            if row.toggle.state == .on && !ours { anyToClaim = true }
        }
        claimButton.isEnabled = anyToClaim
        if !anyToClaim {
            defaultsStatus.stringValue = "Casa opens your photos."
            defaultsStatus.textColor = .systemGreen
        }
    }

    @objc func claimDefaults() {
        let selected = rows.filter { $0.toggle.state == .on && !DefaultHandler.owns($0.group) }
            .map(\.group)
        guard !selected.isEmpty else { return }
        let count = selected.reduce(0) { $0 + $1.types.count }

        // macOS confirms every file type separately. Thirteen dialogs with no
        // warning is a bad surprise; thirteen dialogs you were told about is
        // just a task.
        let alert = NSAlert()
        alert.messageText = "macOS will ask \(count) times"
        alert.informativeText = """
            It confirms each file type separately, so expect \(count) dialogs in a row. \
            Click "Use Casa" on each one.

            Turn off groups first if you'd rather do fewer.
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
            defaultsStatus.stringValue = "Done. Casa opens \(count) file types."
            defaultsStatus.textColor = .systemGreen
            if let root = window?.contentView { Confetti.burst(over: root) }
            // Then get out of the way. A window of greyed-out controls is a
            // poor reward for work the user just did.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
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
        let width: CGFloat = 468
        notesText = NSTextView()
        notesText.frame = NSRect(x: 0, y: 0, width: width, height: 320)
        notesText.minSize = .zero
        notesText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        notesText.isVerticallyResizable = true
        notesText.isHorizontallyResizable = false
        notesText.autoresizingMask = [.width]
        notesText.textContainer?.containerSize = NSSize(width: width,
                                                        height: CGFloat.greatestFiniteMagnitude)
        notesText.textContainer?.widthTracksTextView = true
        notesText.isEditable = false
        notesText.isSelectable = true
        notesText.drawsBackground = false
        notesText.textContainerInset = NSSize(width: 4, height: 6)

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

        let notesCard = card(scroll, padding: 12)
        let container = pane(title: "What's New",
                             subtitle: "Release notes, straight from GitHub.",
                             content: [notesSpinner, notesCard])
        NSLayoutConstraint.activate([
            notesCard.widthAnchor.constraint(equalToConstant: 520),
            scroll.heightAnchor.constraint(equalToConstant: 296),
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
                let markdown = releases
                    .map { "## \($0.title)\n\n\($0.notes)" }
                    .joined(separator: "\n\n---\n\n")
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

    private func link(_ title: String, _ symbol: String, _ urlString: String,
                      primary: Bool = false) -> NSButton {
        let button = NSButton(title: "  " + title, target: self, action: #selector(openLink(_:)))
        button.bezelStyle = .push
        button.controlSize = .large
        button.image = Metrics.icon(symbol, role: .caption, describedAs: title)
        button.imagePosition = .imageLeading
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
        name.font = Typography.title

        let meta = NSTextField(labelWithString: "Build \(build)   ·   by Jack Harvest   ·   MIT")
        meta.font = Typography.mono
        meta.textColor = .secondaryLabelColor

        let blurb = NSTextField(wrappingLabelWithString:
            "A fast photo viewer for macOS, in the shape of the one Picasa used to ship.")
        blurb.font = Typography.body
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 300

        let text = NSStackView(views: [name, meta, blurb])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(10, after: meta)

        let masthead = NSStackView(views: [icon, text])
        masthead.orientation = .horizontal
        masthead.alignment = .top
        masthead.spacing = 18

        let updateButton = NSButton(title: "  Check for Updates…", target: self,
                                    action: #selector(checkUpdatesTapped))
        updateButton.bezelStyle = .push
        updateButton.controlSize = .large
        updateButton.image = Metrics.icon("arrow.triangle.2.circlepath", role: .caption,
                                          describedAs: "Check for updates")
        updateButton.imagePosition = .imageLeading

        let links = NSStackView(views: [
            link("GitHub", "chevron.left.forwardslash.chevron.right",
                 "https://github.com/jackharvest/Casa"),
            link("Releases", "shippingbox", "https://github.com/jackharvest/Casa/releases"),
            updateButton,
        ])
        links.orientation = .horizontal
        links.spacing = 10

        let mastheadCard = card(masthead)
        let container = pane(title: "About",
                             subtitle: "Version, source, and where to find the rest.",
                             content: [mastheadCard, links])
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 92),
            icon.heightAnchor.constraint(equalToConstant: 92),
            mastheadCard.widthAnchor.constraint(equalToConstant: 520),
        ])
        return container
    }

    func buildSupportPane() -> NSView {
        let heart = BadgeView(symbol: "cup.and.saucer.fill",
                              tint: NSColor(red: 0.898, green: 0.412, blue: 0.122, alpha: 1),
                              edge: 46)

        let title = NSTextField(labelWithString: "Casa is free, and stays free")
        title.font = Typography.heading

        let body = NSTextField(wrappingLabelWithString:
            "If it saved you some time, a coffee is a nice way to say so. Bug reports count too.")
        body.font = Typography.body
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 360

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        let inner = NSStackView(views: [heart, text])
        inner.orientation = .horizontal
        inner.alignment = .top
        inner.spacing = 14

        let buttons = NSStackView(views: [
            link("Buy Me a Coffee", "cup.and.saucer",
                 "https://buymeacoffee.com/jackharvest", primary: true),
            link("Report an Issue", "ladybug", "https://github.com/jackharvest/Casa/issues"),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let supportCard = card(inner)
        let container = pane(title: "Support",
                             subtitle: "Thanks for trying it.",
                             content: [supportCard, buttons])
        supportCard.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return container
    }
}
