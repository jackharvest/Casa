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
    private var notesScroll: NSScrollView?
    private var hasLoadedNotes = false

    // Layout, in one place. The window used to be built from 10–14 pt gaps
    // and fixed 520 pt cards, and every pane read as cramped: buttons nearly
    // touching the bottom edge, the close button jammed against the sidebar,
    // one-line descriptions truncated. The content column now has real
    // margins on both sides and every card fills it.
    private static let inset: CGFloat = 10          // window edge → glass
    private static let cardRadius: CGFloat = 20
    private static let sidebarWidth: CGFloat = 212
    private static let columnGap: CGFloat = 36      // sidebar → content
    private static let paneInsets = NSEdgeInsets(top: 62, left: 8, bottom: 40, right: 44)
    /// The width every card and footer fills.
    static let contentWidth: CGFloat = 600
    private static var windowWidth: CGFloat {
        inset * 2 + sidebarWidth + columnGap + paneInsets.left + contentWidth + paneInsets.right
    }

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 540),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar taller, which moves the
        // close button down and in — inside the sidebar's glass, the way
        // System Settings sits, instead of jammed against its corner.
        let toolbar = NSToolbar(identifier: "casa.settings")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
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
        sidebarStack.spacing = 4
        sidebarStack.edgeInsets = NSEdgeInsets(top: 58, left: 12, bottom: 16, right: 12)

        for tab in Tab.allCases {
            let row = SidebarRow(tab: tab, target: self, action: #selector(selectTab(_:)))
            sidebarRows[tab] = row
            sidebarStack.addView(row, in: .top)
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -24).isActive = true
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
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor,
                                                      constant: Self.columnGap),
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
        syncNotesWidth()
        let content = max(stack.fittingSize.height, 340)
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
              contentSpacing: CGFloat = 20) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = Typography.largeTitle

        let sub = NSTextField(wrappingLabelWithString: subtitle)
        sub.font = Typography.body
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = Self.contentWidth

        let stack = NSStackView(views: [heading, sub] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = contentSpacing
        stack.setCustomSpacing(8, after: heading)
        stack.setCustomSpacing(30, after: sub)
        stack.edgeInsets = Self.paneInsets
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

    /// A glass card the full width of the content column.
    func card(_ content: NSView, tint: NSColor? = nil,
              padding: NSEdgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)) -> NSView {
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: padded.topAnchor, constant: padding.top),
            content.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -padding.bottom),
            content.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -padding.right),
        ])
        let panel = Glass.panel(padded, cornerRadius: Self.cardRadius, tint: tint)
        panel.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return panel
    }

    /// A row of buttons as wide as the content column, so its edges line up
    /// with the cards above it.
    func buttonRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
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

            let badge = BadgeView(symbol: group.symbol, tint: group.tint, edge: 40)

            let title = NSTextField(labelWithString: group.title)
            title.font = Typography.heading

            let detail = NSTextField(labelWithString: group.detail)
            detail.font = Typography.caption
            detail.textColor = .tertiaryLabelColor
            detail.lineBreakMode = .byTruncatingTail

            let labels = NSStackView(views: [title, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 3

            let chip = StatusChip()
            let toggle = NSSwitch()
            toggle.state = group.recommended ? .on : .off
            toggle.controlSize = .regular

            let row = NSStackView(views: [badge, labels, NSView(), chip, toggle])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 16
            row.setCustomSpacing(12, after: chip)
            list.addView(row, in: .bottom)
            // An explicit height rather than edge insets: a horizontal stack
            // nested in a vertical one ignored its insets, and every badge sat
            // flush against the separators above and below it.
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: list.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 40 + 30),
            ])

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

        let footer = buttonRow([defaultsStatus, NSView(), openButton, claimButton])

        let hint = NSTextField(wrappingLabelWithString:
            "macOS asks you to confirm each type separately. Casa tells you how many "
            + "dialogs to expect before it starts.\n\n"
            + "You can also drop a photo anywhere on this window to open it.")
        hint.font = Typography.caption
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = Self.contentWidth

        // Rows carry their own vertical padding, so the card adds only a
        // little above and below them.
        let listCard = card(list, padding: NSEdgeInsets(top: 6, left: 24, bottom: 6, right: 22))
        let container = pane(
            title: "File Types",
            subtitle: "Until Casa is the default, double-clicking a photo still opens Preview.",
            content: [listCard, footer, hint]
        )
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
        let width = Self.contentWidth - 48
        notesText = NSTextView()
        notesText.frame = NSRect(x: 0, y: 0, width: width, height: 320)
        notesText.minSize = .zero
        notesText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        notesText.isVerticallyResizable = true
        notesText.isHorizontallyResizable = false
        // No autoresizing mask: the scroll view starts at zero size, so
        // autoresizing added its whole eventual width on top of this frame
        // and lines ran off the right edge. `syncNotesWidth()` sets it from
        // the scroll view's real width after layout instead.
        notesText.textContainer?.containerSize = NSSize(width: width,
                                                        height: CGFloat.greatestFiniteMagnitude)
        notesText.textContainer?.widthTracksTextView = false
        notesText.isEditable = false
        notesText.isSelectable = true
        notesText.drawsBackground = false
        notesText.textContainerInset = NSSize(width: 2, height: 4)

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
        // Hidden, not merely stopped: a stopped spinner still claims its row
        // in the stack and left a gap above the notes.
        notesSpinner.isHidden = true

        let notesCard = card(scroll, padding: NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 14))
        let container = pane(title: "What's New",
                             subtitle: "Release notes, straight from GitHub.",
                             content: [notesSpinner, notesCard])
        scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
        notesScroll = scroll
        return container
    }

    /// Sizes the notes to the scroll view's real width — see the comment on
    /// the missing autoresizing mask.
    func syncNotesWidth() {
        guard let notesScroll, let notesText else { return }
        let available = notesScroll.contentSize.width
        guard available > 20 else { return }
        notesText.setFrameSize(NSSize(width: available, height: notesText.frame.height))
        notesText.textContainer?.containerSize = NSSize(width: available - 4,
                                                        height: CGFloat.greatestFiniteMagnitude)
    }

    func loadReleaseNotesIfNeeded() {
        guard !hasLoadedNotes else { return }
        hasLoadedNotes = true
        notesSpinner.isHidden = false
        notesSpinner.startAnimation(nil)

        Task { [weak self] in
            guard let self, let checker = UpdateChecker() else { return }
            defer {
                self.notesSpinner.stopAnimation(nil)
                self.notesSpinner.isHidden = true
            }
            do {
                let releases = try await checker.recentReleases()
                let markdown = releases
                    .map { "## \($0.title)\n\n\($0.notes)" }
                    .joined(separator: "\n\n---\n\n")
                self.syncNotesWidth()
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
        button.image = Self.buttonIcon(symbol, title)
        button.imagePosition = .imageLeading
        button.identifier = NSUserInterfaceItemIdentifier(urlString)
        if primary { button.bezelColor = .controlAccentColor }
        return button
    }

    /// A symbol sized to sit beside large-button text rather than below it.
    static func buttonIcon(_ symbol: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
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
        blurb.preferredMaxLayoutWidth = 380

        let text = NSStackView(views: [name, meta, blurb])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        text.setCustomSpacing(12, after: meta)

        let masthead = NSStackView(views: [icon, text])
        masthead.orientation = .horizontal
        masthead.alignment = .centerY
        masthead.spacing = 24

        let updateButton = NSButton(title: "  Check for Updates…", target: self,
                                    action: #selector(checkUpdatesTapped))
        updateButton.bezelStyle = .push
        updateButton.controlSize = .large
        updateButton.image = Self.buttonIcon("arrow.triangle.2.circlepath", "Check for updates")
        updateButton.imagePosition = .imageLeading

        let links = buttonRow([
            link("GitHub", "chevron.left.forwardslash.chevron.right",
                 "https://github.com/jackharvest/Casa"),
            link("Releases", "shippingbox", "https://github.com/jackharvest/Casa/releases"),
            NSView(),
            updateButton,
        ])

        let mastheadCard = card(masthead, padding: NSEdgeInsets(top: 24, left: 22, bottom: 24, right: 24))
        let container = pane(title: "About",
                             subtitle: "Version, source, and where to find the rest.",
                             content: [mastheadCard, links])
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 104),
            icon.heightAnchor.constraint(equalToConstant: 104),
        ])
        return container
    }

    func buildSupportPane() -> NSView {
        let heart = BadgeView(symbol: "cup.and.saucer.fill",
                              tint: NSColor(red: 0.898, green: 0.412, blue: 0.122, alpha: 1),
                              edge: 52)

        let title = NSTextField(labelWithString: "Casa is free, and stays free")
        title.font = Typography.heading

        let body = NSTextField(wrappingLabelWithString:
            "If it saved you some time, a coffee is a nice way to say so. Bug reports count too.")
        body.font = Typography.body
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 440

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6

        let inner = NSStackView(views: [heart, text])
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 20

        let buttons = buttonRow([
            link("Buy Me a Coffee", "cup.and.saucer",
                 "https://buymeacoffee.com/jackharvest", primary: true),
            link("Report an Issue", "ladybug", "https://github.com/jackharvest/Casa/issues"),
            NSView(),
        ])

        let supportCard = card(inner)
        let container = pane(title: "Support",
                             subtitle: "Thanks for trying it.",
                             content: [supportCard, buttons])
        return container
    }
}
