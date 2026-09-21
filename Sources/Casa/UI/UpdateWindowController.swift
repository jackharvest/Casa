import AppKit

/// The update panel.
///
/// A small, self-contained window rather than an alert, because an alert can
/// only say things — this has to show release notes, report progress, and
/// change shape as it moves through five states without ever looking like a
/// different window.
///
/// `NSVisualEffectView` is used here and deliberately *not* used for the
/// viewer's backdrop: behind a photograph a live blur is a continuous GPU cost
/// for an invisible effect, but on a small panel over arbitrary content it is
/// exactly the right material and the thing that makes this read as native.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {

    private let controller: UpdateController
    private var window: NSWindow?

    private let heroIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let notesView = NSTextView()
    private let notesScroll = NSScrollView()
    private var notesCard: NSView!
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private var rootStack: NSStackView!

    private var currentRelease: UpdateRelease?

    init(controller: UpdateController) {
        self.controller = controller
        super.init()
        controller.onStateChange = { [weak self] state in
            self?.render(state)
        }
    }

    // MARK: - Presentation

    /// Shows the panel, creating it on first use. Updates arrive rarely; there
    /// is no reason to hold this window's views for the life of the process.
    func present() {
        if window == nil { build() }
        render(controller.state)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }

    /// Called for background checks: appear only when there is something to
    /// say, never to report silence.
    func presentIfNoteworthy(_ state: UpdateController.State) {
        if case .available = state { present() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing mid-install would leave the user with no idea whether their
        // app had been replaced.
        !controller.state.isBusy
    }

    // MARK: - Construction

    private func build() {
        let width = max(460, Metrics.pointSize(.control) * 34)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 260),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.title = "Software Update"
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Same ground as the settings window, so the two read as one app.
        let material = NSVisualEffectView()
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        window.contentView = material

        // Header
        heroIcon.translatesAutoresizingMaskIntoConstraints = false
        heroIcon.imageScaling = .scaleProportionallyUpOrDown

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let heroBox = NSView()
        heroBox.translatesAutoresizingMaskIntoConstraints = false
        heroBox.addSubview(heroIcon)
        heroBox.addSubview(spinner)

        titleLabel.font = NSFont.systemFont(ofSize: Metrics.pointSize(.title) * 1.15, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = Metrics.font(.caption)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = Metrics.spacing(0.5)

        let header = NSStackView(views: [heroBox, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Metrics.spacing(3)

        // Release notes.
        //
        // An `NSTextView` created without a frame gets a zero-size text
        // container and never lays anything out — the panel showed a blank
        // white rectangle where the notes should be. The explicit frame,
        // container size and `widthTracksTextView` below are the minimum that
        // makes a text view inside a scroll view actually render.
        // The card's padding and the scroller both eat into the text's width.
        // Starting the container too wide leaves lines clipped on the right,
        // because `widthTracksTextView` only narrows from the frame it is given.
        let notesWidth = width - Metrics.spacing(10) - 20 - 18
        notesView.frame = NSRect(x: 0, y: 0, width: notesWidth, height: 240)
        notesView.minSize = .zero
        notesView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        notesView.isVerticallyResizable = true
        notesView.isHorizontallyResizable = false
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.containerSize = NSSize(width: notesWidth,
                                                        height: CGFloat.greatestFiniteMagnitude)
        notesView.textContainer?.widthTracksTextView = true
        notesView.isEditable = false
        notesView.isSelectable = true
        notesView.drawsBackground = false
        notesView.textContainerInset = NSSize(width: Metrics.spacing(2), height: Metrics.spacing(2))
        notesView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true
        // Both of these must be off. Leaving either on paints an opaque slab
        // over the panel's material.
        notesScroll.drawsBackground = false
        notesScroll.contentView.drawsBackground = false
        notesScroll.borderType = .noBorder
        notesScroll.translatesAutoresizingMaskIntoConstraints = false

        // Progress
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = Metrics.font(.caption)
        progressLabel.textColor = .secondaryLabelColor
        // Tabular figures so the byte counts do not jitter as they tick.
        progressLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: Metrics.pointSize(.caption), weight: .regular)

        let progressStack = NSStackView(views: [progressBar, progressLabel])
        progressStack.orientation = .vertical
        progressStack.alignment = .leading
        progressStack.spacing = Metrics.spacing(1)

        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = Metrics.spacing(2)

        let notesPadding = NSView()
        notesPadding.translatesAutoresizingMaskIntoConstraints = false
        notesPadding.addSubview(notesScroll)
        Glass.pin(notesScroll, to: notesPadding, inset: 10)
        notesCard = Glass.panel(notesPadding, cornerRadius: 14)

        rootStack = NSStackView(views: [header, notesCard, progressStack, buttonRow])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = Metrics.spacing(3)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.edgeInsets = NSEdgeInsets(top: Metrics.spacing(5), left: Metrics.spacing(5),
                                            bottom: Metrics.spacing(4), right: Metrics.spacing(5))
        material.addSubview(rootStack)

        let hero = Metrics.hitTarget(.hero)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: material.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: material.bottomAnchor),

            heroBox.widthAnchor.constraint(equalToConstant: hero),
            heroBox.heightAnchor.constraint(equalToConstant: hero),
            heroIcon.centerXAnchor.constraint(equalTo: heroBox.centerXAnchor),
            heroIcon.centerYAnchor.constraint(equalTo: heroBox.centerYAnchor),
            heroIcon.widthAnchor.constraint(equalToConstant: hero),
            heroIcon.heightAnchor.constraint(equalToConstant: hero),
            spinner.centerXAnchor.constraint(equalTo: heroBox.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: heroBox.centerYAnchor),

            notesCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor,
                                             constant: -Metrics.spacing(10)),
            notesScroll.heightAnchor.constraint(equalToConstant: Metrics.pointSize(.caption) * 12),
            progressBar.widthAnchor.constraint(equalTo: notesCard.widthAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: notesCard.trailingAnchor),
        ])

        self.window = window
    }

    // MARK: - Rendering

    private func render(_ state: UpdateController.State) {
        guard window != nil else { return }

        switch state {
        case .idle:
            close()
            return

        case .checking:
            showSpinner(true)
            titleLabel.stringValue = "Checking for updates…"
            subtitleLabel.stringValue = currentVersionLine()
            setNotes(nil)
            setProgress(nil)
            setButtons([])

        case .upToDate(let version):
            showIcon("checkmark.circle.fill", tint: .systemGreen, label: "Up to date")
            titleLabel.stringValue = "Casa \(version) is up to date"
            subtitleLabel.stringValue = "You’re on the latest version."
            setNotes(nil)
            setProgress(nil)
            setButtons([button("OK", primary: true, action: #selector(dismissPanel))])

        case .available(let release):
            currentRelease = release
            showIcon("arrow.down.circle.fill", tint: .controlAccentColor, label: "Update available")
            titleLabel.stringValue = "\(release.title) is available"
            subtitleLabel.stringValue = availabilityLine(release)
            setNotes(release.notes)
            setProgress(nil)
            setButtons([
                button("Skip This Version", action: #selector(skipVersion)),
                button("Later", action: #selector(dismissPanel)),
                button("Install and Relaunch", primary: true, action: #selector(installUpdate)),
            ])

        case .downloading(let release, let progress):
            showSpinner(false)
            showIcon("arrow.down.circle.fill", tint: .controlAccentColor, label: "Downloading")
            titleLabel.stringValue = "Downloading \(release.title)"
            subtitleLabel.stringValue = "Casa will relaunch when it’s ready."
            setNotes(release.notes)
            setProgress(progress)
            setButtons([button("Cancel", action: #selector(cancelUpdate))])

        case .verifying(let release):
            indeterminate("Verifying \(release.title)", detail: "Checking the download’s signature.")

        case .installing(let release):
            indeterminate("Installing \(release.title)", detail: "Replacing Casa in place.")

        case .relaunching(let release):
            indeterminate("Relaunching into \(release.version.description)",
                          detail: "Your photo will reopen where you left it.")

        case .failed(let release, let message, let recovery):
            currentRelease = release
            showIcon("exclamationmark.triangle.fill", tint: .systemOrange, label: "Update failed")
            titleLabel.stringValue = message
            subtitleLabel.stringValue = recovery
            setNotes(nil)
            setProgress(nil)
            var buttons = [button("Close", action: #selector(dismissPanel))]
            if release != nil {
                buttons.append(button("View on GitHub", action: #selector(openReleasePage)))
                buttons.append(button("Try Again", primary: true, action: #selector(installUpdate)))
            }
            setButtons(buttons)
        }

        resize()
    }

    private func indeterminate(_ title: String, detail: String) {
        showSpinner(true)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = detail
        setNotes(nil)
        progressBar.isHidden = false
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        progressLabel.isHidden = true
        setButtons([])
    }

    private func currentVersionLine() -> String {
        controller.currentVersion.map { "You have \($0)." } ?? ""
    }

    private func availabilityLine(_ release: UpdateRelease) -> String {
        var parts: [String] = []
        if let current = controller.currentVersion { parts.append("You have \(current)") }
        parts.append(byteCount(release.archiveBytes))
        if let date = release.publishedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("released \(formatter.localizedString(for: date, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Element helpers

    private func showIcon(_ symbol: String, tint: NSColor, label: String) {
        showSpinner(false)
        heroIcon.isHidden = false
        heroIcon.image = Metrics.icon(symbol, role: .hero, describedAs: label)
        heroIcon.contentTintColor = tint
    }

    private func showSpinner(_ spinning: Bool) {
        heroIcon.isHidden = spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func setNotes(_ markdown: String?) {
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notesCard.isHidden = true
            return
        }
        notesCard.isHidden = false
        notesView.textStorage?.setAttributedString(ReleaseNotes.rendered(markdown))
        notesView.scroll(.zero)
    }

    private func setProgress(_ progress: UpdateDownloader.Progress?) {
        guard let progress else {
            progressBar.stopAnimation(nil)
            progressBar.isHidden = true
            progressLabel.isHidden = true
            return
        }
        progressBar.isHidden = false
        progressBar.isIndeterminate = false
        progressBar.doubleValue = progress.fraction
        progressLabel.isHidden = false

        var detail = "\(byteCount(progress.received)) of \(byteCount(progress.expected))"
        if progress.bytesPerSecond > 0 {
            detail += " · \(byteCount(Int64(progress.bytesPerSecond)))/s"
        }
        if let remaining = progress.remaining, remaining > 1 {
            detail += " · \(Int(remaining.rounded()))s left"
        }
        progressLabel.stringValue = detail
    }

    private func setButtons(_ buttons: [NSButton]) {
        for view in buttonRow.views { buttonRow.removeView(view) }
        buttonRow.isHidden = buttons.isEmpty
        for button in buttons { buttonRow.addView(button, in: .trailing) }
    }

    private func button(_ title: String, primary: Bool = false, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        button.controlSize = .large
        button.font = Metrics.font(.control)
        if primary {
            button.keyEquivalent = "\r"
            // The native filled-accent treatment, which also means it follows
            // the user's chosen accent colour rather than one we invented.
            button.bezelColor = .controlAccentColor
        }
        return button
    }

    private func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// Matches the text container to the scroll view's actual width.
    ///
    /// `widthTracksTextView` only narrows the container to the text view's
    /// frame, and that frame does not reliably follow a clip view sized by
    /// Auto Layout — so long lines were being clipped on the right rather than
    /// wrapped. Setting it after layout is the reliable version.
    private func syncNotesWidth() {
        let available = notesScroll.contentSize.width
        guard available > 20 else { return }
        notesView.setFrameSize(NSSize(width: available, height: notesView.frame.height))
        notesView.textContainer?.containerSize = NSSize(width: available,
                                                        height: CGFloat.greatestFiniteMagnitude)
    }

    /// Fits the window to its content, animating unless Reduce Motion is on.
    private func resize() {
        guard let window, let content = window.contentView else { return }
        rootStack.layoutSubtreeIfNeeded()
        syncNotesWidth()
        let fitted = rootStack.fittingSize
        guard fitted.height > 0 else { return }

        var frame = window.frame
        let delta = fitted.height - content.frame.height
        guard abs(delta) > 0.5 else { return }
        frame.size.height += delta
        // Grow downward from the title bar rather than from the bottom edge,
        // so the header stays put as the panel changes shape.
        frame.origin.y -= delta
        window.setFrame(frame, display: true,
                        animate: !Accommodations.current.reduceMotion)
    }

    // MARK: - Actions

    @objc private func installUpdate() {
        guard let currentRelease else { return }
        controller.install(currentRelease)
    }

    @objc private func cancelUpdate() { controller.cancel() }

    @objc private func skipVersion() {
        guard let currentRelease else { return }
        controller.skip(currentRelease)
        close()
    }

    @objc private func dismissPanel() {
        controller.dismiss()
        close()
    }

    @objc private func openReleasePage() {
        guard let url = currentRelease?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }
}
