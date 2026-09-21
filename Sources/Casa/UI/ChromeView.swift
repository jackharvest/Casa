import AppKit

/// The overlay: filename above, controls below, nothing in the middle.
///
/// Chrome over a photograph is a legibility problem — white text on an unknown
/// image. The answer used here is a soft scrim behind each cluster rather than
/// a shadow on the glyphs, because a scrim is one compositing pass for the
/// whole group while per-glyph shadows are a pass each and look muddy at small
/// sizes.
///
/// Everything auto-hides. Trait 06 is that the app is disposable; chrome that
/// persists makes it feel like a document window.
final class ChromeView: NSView {

    weak var actionTarget: AnyObject?

    private let topScrim = ScrimView(edge: .top)
    private let bottomScrim = ScrimView(edge: .bottom)
    private let filenameLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private var buttons: [IconButton] = []
    private var stack: NSStackView!
    let filmstrip = FilmstripView(frame: .zero)
    private var playButton: IconButton!
    private var idleTimer: Timer?
    private var isChromeVisible = true

    // MARK: - Build

    init(target: AnyObject) {
        self.actionTarget = target
        super.init(frame: .zero)
        wantsLayer = true

        addSubview(topScrim)
        addSubview(bottomScrim)

        configure(filenameLabel, role: .title)
        configure(positionLabel, role: .caption)
        addSubview(filenameLabel)
        addSubview(positionLabel)

        buttons = [
            IconButton(symbol: "chevron.left", label: "Previous", keyEquivalentHint: "←",
                       action: #selector(ViewerController.goPrevious(_:)), target: target),
            IconButton(symbol: "chevron.right", label: "Next", keyEquivalentHint: "→",
                       action: #selector(ViewerController.goNext(_:)), target: target),
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Fit to Window",
                       keyEquivalentHint: "0", action: #selector(ViewerController.zoomToFit(_:)), target: target),
            IconButton(symbol: "1.magnifyingglass", label: "Actual Size",
                       keyEquivalentHint: "1", action: #selector(ViewerController.zoomToActual(_:)), target: target),
            IconButton(symbol: "rotate.left", label: "Rotate Left",
                       keyEquivalentHint: "⌘[", action: #selector(ViewerController.rotateLeft(_:)), target: target),
            IconButton(symbol: "rotate.right", label: "Rotate Right",
                       keyEquivalentHint: "⌘]", action: #selector(ViewerController.rotateRight(_:)), target: target),
        ]

        stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filmstrip)

        // A large centred play button, because that is where everyone on every
        // platform has learned to look for one. It appears only when there is
        // something to play and it is not already playing.
        playButton = IconButton(symbol: "play.circle.fill", role: .hero, label: "Play",
                                keyEquivalentHint: "Space",
                                action: #selector(ViewerController.togglePlayback(_:)), target: target)
        playButton.isHidden = true
        addSubview(playButton)

        installConstraints()
        applyMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(_ label: NSTextField, role: Metrics.Role) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Metrics.font(role)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
    }

    private var metricConstraints: [NSLayoutConstraint] = []

    private func installConstraints() {
        NSLayoutConstraint.activate([
            topScrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            topScrim.topAnchor.constraint(equalTo: topAnchor),

            bottomScrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomScrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomScrim.bottomAnchor.constraint(equalTo: bottomAnchor),

            filenameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            positionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            positionLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 2),

            stack.centerXAnchor.constraint(equalTo: centerXAnchor),

            filmstrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: bottomAnchor),

            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            filenameLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
        ])
    }

    /// Re-derives every spacing value from the current text size. Called on
    /// creation and on any environment change, so raising the system text size
    /// moves the labels, the buttons, and the gaps between them together.
    func applyMetrics() {
        NSLayoutConstraint.deactivate(metricConstraints)

        let margin = Metrics.spacing(3)
        let gap = Metrics.spacing(1)

        stack.spacing = gap
        stack.edgeInsets = NSEdgeInsets(top: gap / 2, left: gap, bottom: gap / 2, right: gap)

        // The rail is anchored to the bottom edge and the controls sit above
        // it, so the two never overlap however the text size changes.
        metricConstraints = [
            filenameLabel.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            stack.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -gap),
            filmstrip.heightAnchor.constraint(equalToConstant: filmstrip.intrinsicHeight),
            topScrim.heightAnchor.constraint(equalToConstant: topInset),
            bottomScrim.heightAnchor.constraint(equalToConstant: bottomInset),
        ]
        NSLayoutConstraint.activate(metricConstraints)

        filenameLabel.font = Metrics.font(.title)
        positionLabel.font = Metrics.font(.caption)
        positionLabel.textColor = NSColor(white: 1, alpha: Accommodations.current.increaseContrast ? 1.0 : 0.72)

        for button in buttons { button.refreshForEnvironment() }
        playButton.refreshForEnvironment()
        filmstrip.environmentChanged()

        stack.wantsLayer = true
        stack.layer?.cornerRadius = Metrics.cornerRadius(.control) * 1.4
        stack.layer?.backgroundColor = NSColor(white: 0, alpha: 0.32).cgColor

        topScrim.refresh()
        bottomScrim.refresh()
        needsLayout = true
    }

    // MARK: - Insets

    /// Height the top chrome claims: filename, counter, and their scrim.
    var topInset: CGFloat {
        Metrics.spacing(3) * 2 + Metrics.pointSize(.title) + Metrics.pointSize(.caption) + 8
    }

    /// Height the bottom chrome claims: the rail, the control cluster, and the
    /// gaps around them. The canvas fits the photograph above this.
    var bottomInset: CGFloat {
        filmstrip.intrinsicHeight + Metrics.hitTarget(.control) + Metrics.spacing(1) * 2
    }

    // MARK: - Content

    /// Shows or hides the centred play button.
    func updatePlayback(canPlay: Bool, isPlaying: Bool) {
        playButton.isHidden = !canPlay || isPlaying
    }

    func update(filename: String, position: String, note: String? = nil) {
        filenameLabel.stringValue = filename
        positionLabel.stringValue = note ?? position
        positionLabel.textColor = note == nil
            ? NSColor(white: 1, alpha: Accommodations.current.increaseContrast ? 1.0 : 0.72)
            : NSColor(red: 1, green: 0.72, blue: 0.62, alpha: 1)
    }

    // MARK: - Auto-hide

    /// Shows the chrome and restarts the idle countdown. Driven by mouse
    /// movement from the controller.
    func flash() {
        setVisible(true)
        idleTimer?.invalidate()
        // `--keep-chrome` pins the controls open. Reviewing the chrome's
        // design is otherwise a race against its own auto-hide.
        guard !CommandLine.arguments.contains("--keep-chrome") else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setVisible(false) }
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isChromeVisible else { return }
        isChromeVisible = visible

        let duration = Accommodations.current.duration(0.22)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Chrome must never swallow clicks meant for the image. Only the actual
    /// controls are interactive; everything else falls through to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isChromeVisible else { return nil }
        // The centred play button stays live even when the rest of the chrome
        // has faded — it is the item's primary action, not decoration.
        if !playButton.isHidden, let hit = playButton.hitTest(convert(point, to: playButton)) {
            return hit
        }
        let hit = super.hitTest(point)
        if hit is IconButton { return hit }
        // The rail is interactive too: click to jump, scroll to scrub.
        if hit === filmstrip || hit?.isDescendant(of: filmstrip) == true {
            return filmstrip.urls.count > 1 ? filmstrip : nil
        }
        return nil
    }
}

/// A vertical gradient from transparent to black, used behind the chrome
/// clusters so white text stays legible over an unknown photograph.
private final class ScrimView: NSView {
    enum Edge { case top, bottom }
    private let edge: Edge
    private let gradient = CAGradientLayer()

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer = gradient
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() {
        let strength = Accommodations.current.increaseContrast ? 0.85 : 0.6
        let opaque = NSColor(white: 0, alpha: strength).cgColor
        let clear = NSColor(white: 0, alpha: 0).cgColor
        gradient.colors = edge == .top ? [opaque, clear] : [clear, opaque]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
}
