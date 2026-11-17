import AppKit

/// The overlay: a caption above, a toolbar and the rail below, nothing in the
/// middle.
///
/// The toolbar is five glass capsules set in one container, so the glass reads
/// as one object that happens to be divided, not five stickers: zoom and
/// rotate to the left, the editing tools and the file-level actions to the
/// right, and between them Picasa's centrepiece — previous and next either
/// side of a round play button, which starts a slideshow. That capsule is
/// slightly taller than its neighbours and sits on the window's centre line,
/// so the eye lands on it first.
///
/// In a narrow window the outer capsules stand down, innermost last, rather
/// than the row being clipped. Everything they held is still in the menus.
///
/// Chrome over a photograph is a legibility problem — white text on an unknown
/// image. The main answer is a soft scrim behind each edge, one compositing
/// pass for the whole group; the caption adds only a wide, faint shadow for
/// the case a scrim cannot cover, white type over a white sky.
///
/// Everything auto-hides. Trait 06 is that the app is disposable; chrome that
/// persists makes it feel like a document window.
final class ChromeView: NSView {

    weak var actionTarget: AnyObject?

    private let topScrim = ScrimView(edge: .top)
    private let bottomScrim = ScrimView(edge: .bottom)
    private let filenameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var captionStack: NSStackView!

    private var groups: [NSStackView] = []
    private var pills: [NSView] = []
    private var toolbarRow: NSStackView!
    private var toolbar: NSView!
    private var buttons: [IconButton] = []
    private(set) var slideshowButton: IconButton!
    private var actualSizeButton: IconButton!
    private var previousButton: IconButton!
    private var nextButton: IconButton!
    private var editButtons: [IconButton] = []
    private var rotateButtons: [IconButton] = []
    private(set) var infoButton: IconButton!
    private(set) var shareButton: IconButton!
    private(set) var moreButton: IconButton!

    let filmstrip = FilmstripView(frame: .zero)
    private var playButton: IconButton!
    private var closeButton: IconButton!
    private var closePanel: NSView!
    private var idleTimer: Timer?
    private var isChromeVisible = true

    // MARK: - Build

    init(target: AnyObject) {
        self.actionTarget = target
        super.init(frame: .zero)
        wantsLayer = true

        addSubview(topScrim)
        addSubview(bottomScrim)

        buildCaption()
        buildToolbar(target: target)

        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filmstrip)

        // A large centred play button for movies and animations, because that
        // is where everyone on every platform has learned to look for one. It
        // appears only when there is something to play and it is not already
        // playing.
        playButton = IconButton(symbol: "play.circle.fill", role: .hero, label: "Play",
                                keyEquivalentHint: "Space",
                                action: #selector(ViewerController.togglePlayback(_:)), target: target)
        playButton.isHidden = true
        addSubview(playButton)

        // The X in the corner. Picasa had one and almost nobody knew, which is
        // the point: Escape is the fast way out, and this is for people who
        // reach for a close button because every other window has one.
        closeButton = IconButton(symbol: "xmark", label: "Close",
                                 keyEquivalentHint: "Esc",
                                 action: #selector(ViewerController.dismissViewer(_:)),
                                 target: target)
        closePanel = Glass.panel(closeButton, cornerRadius: 20, style: .clear)
        addSubview(closePanel)

        installConstraints()
        applyMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildCaption() {
        for label in [filenameLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.cell?.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        // A soft shadow under the type as well as the scrim: over a white sky
        // the scrim alone is not quite enough, and a wide, faint shadow reads
        // as depth rather than as an outline.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = .zero
        filenameLabel.shadow = shadow
        detailLabel.shadow = shadow

        captionStack = NSStackView(views: [filenameLabel, detailLabel])
        captionStack.orientation = .vertical
        captionStack.alignment = .centerX
        captionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionStack)
    }

    private func buildToolbar(target: AnyObject) {
        func button(_ symbol: String, _ label: String, _ hint: String?, _ action: Selector,
                    style: IconButton.Style = .plain, size: CGFloat = 1) -> IconButton {
            IconButton(symbol: symbol, style: style, sizeFactor: size, label: label,
                       keyEquivalentHint: hint, action: action, target: target)
        }

        let zoomOut = button("minus.magnifyingglass", "Zoom Out", "−",
                             #selector(ViewerController.zoomOut(_:)))
        let zoomIn = button("plus.magnifyingglass", "Zoom In", "+",
                            #selector(ViewerController.zoomIn(_:)))
        actualSizeButton = button("1.magnifyingglass", "Actual Size / Fit", "1",
                                  #selector(ViewerController.toggleActualSize(_:)))

        previousButton = button("chevron.left", "Previous", "←",
                                #selector(ViewerController.goPrevious(_:)), size: 1.05)
        slideshowButton = button("play.fill", "Slideshow", "S",
                                 #selector(ViewerController.toggleSlideshow(_:)),
                                 style: .disc, size: 1.2)
        nextButton = button("chevron.right", "Next", "→",
                            #selector(ViewerController.goNext(_:)), size: 1.05)

        let rotateLeft = button("rotate.left", "Rotate Left", "⇧⌘[",
                                #selector(ViewerController.rotateLeft(_:)))
        let rotateRight = button("rotate.right", "Rotate Right", "⇧⌘]",
                                 #selector(ViewerController.rotateRight(_:)))
        rotateButtons = [rotateLeft, rotateRight]

        let crop = button("crop", "Crop", "⌘K", #selector(ViewerController.crop(_:)))
        let adjust = button("slider.horizontal.3", "Adjust Color", "⌥⌘A",
                            #selector(ViewerController.adjustColor(_:)))
        let markup = button("pencil.tip.crop.circle", "Markup", "⇧⌘A",
                            #selector(ViewerController.toggleMarkup(_:)))
        editButtons = [crop, adjust, markup]

        infoButton = button("info.circle", "Info", "⌘I", #selector(ViewerController.toggleInspector(_:)))
        shareButton = button("square.and.arrow.up", "Share", nil, #selector(ViewerController.share(_:)))
        moreButton = button("ellipsis", "More", nil, #selector(ViewerController.showMoreMenu(_:)))

        let sets: [[IconButton]] = [
            [zoomOut, zoomIn, actualSizeButton],
            [rotateLeft, rotateRight],
            [previousButton, slideshowButton, nextButton],
            editButtons,
            [infoButton, shareButton, moreButton],
        ]
        buttons = sets.flatMap { $0 }

        for set in sets {
            let stack = NSStackView(views: set)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            groups.append(stack)
            pills.append(Glass.panel(stack, cornerRadius: 24, tint: NSColor(white: 0, alpha: 0.2)))
        }

        toolbarRow = NSStackView(views: pills)
        toolbarRow.orientation = .horizontal
        toolbarRow.alignment = .centerY
        toolbar = Glass.container(toolbarRow)
        addSubview(toolbar)
    }

    private var metricConstraints: [NSLayoutConstraint] = []
    private var toolbarAboveRail: NSLayoutConstraint!
    private var toolbarAtEdge: NSLayoutConstraint!

    private func installConstraints() {
        NSLayoutConstraint.activate([
            topScrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            topScrim.topAnchor.constraint(equalTo: topAnchor),

            bottomScrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomScrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomScrim.bottomAnchor.constraint(equalTo: bottomAnchor),

            captionStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),

            // The play disc, not the row, is what sits on the centre line.
            // The two sides hold different numbers of controls, and centring
            // the row would leave its centrepiece visibly off to one side.
            slideshowButton.centerXAnchor.constraint(equalTo: centerXAnchor),

            filmstrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: bottomAnchor),

            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolbarAboveRail = toolbar.bottomAnchor.constraint(equalTo: filmstrip.topAnchor)
        toolbarAtEdge = toolbar.bottomAnchor.constraint(equalTo: bottomAnchor)
        toolbarAboveRail.isActive = true
    }

    /// Re-derives every spacing value from the current text size and display.
    /// Called on creation and on any environment change, so raising the
    /// system text size moves the type, the buttons, and the gaps between them
    /// together.
    func applyMetrics() {
        NSLayoutConstraint.deactivate(metricConstraints)
        metricConstraints = []

        let unit = ChromeMetrics.spacing(1)
        let margin = ChromeMetrics.spacing(3)

        filenameLabel.font = ChromeMetrics.font(.title)
        detailLabel.font = ChromeMetrics.font(.caption)
        detailLabel.textColor = detailColor(isNote: isShowingNote)
        captionStack.spacing = (unit * 0.5).rounded()

        // Buttons inside a capsule sit a little apart, and the capsule's end
        // padding matches the gap between buttons plus the hover circle's own
        // breathing room, so nothing feels jammed against the curve.
        for button in buttons { button.refreshForEnvironment() }
        for stack in groups {
            stack.spacing = (unit * 0.5).rounded()
            stack.edgeInsets = NSEdgeInsets(top: unit * 0.75, left: unit, bottom: unit * 0.75, right: unit)
        }
        // Each capsule is pinned to exactly its tallest control plus padding.
        // Left to the glass view's own sizing, all three came out the height
        // of the plain buttons and the play disc broke out of the middle one.
        for (pill, stack) in zip(pills, groups) {
            let height = (stack.arrangedSubviews.map { ($0 as? IconButton)?.edge ?? 0 }.max() ?? 0)
                + unit * 1.5
            Glass.setCornerRadius(pill, height / 2)
            metricConstraints.append(pill.heightAnchor.constraint(equalToConstant: height))
        }
        toolbarRow.spacing = unit * 2.5

        closeButton.refreshForEnvironment()
        Glass.setCornerRadius(closePanel, closeButton.edge / 2)
        playButton.refreshForEnvironment()
        filmstrip.environmentChanged()

        toolbarAboveRail.constant = -(unit * 0.5).rounded()
        toolbarAtEdge.constant = -margin

        metricConstraints += [
            captionStack.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            closePanel.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            closePanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            filmstrip.heightAnchor.constraint(equalToConstant: filmstrip.intrinsicHeight),
            topScrim.heightAnchor.constraint(equalToConstant: topInset + margin * 2),
            bottomScrim.heightAnchor.constraint(equalToConstant: bottomInset + margin * 2),
        ]
        NSLayoutConstraint.activate(metricConstraints)

        topScrim.refresh()
        bottomScrim.refresh()
        needsLayout = true
        fitToolbar()
    }

    // MARK: - Narrow windows

    /// Which capsules to give up as the window narrows, first to go first.
    /// Pairs, one from each side, so the play disc stays centred.
    private static let standDownOrder: [[Int]] = [[1, 3], [0, 4]]

    /// Hides outer capsules until the row fits the window.
    private func fitToolbar() {
        guard bounds.width > 0 else { return }
        for pill in pills { pill.isHidden = false }
        let room = bounds.width - ChromeMetrics.spacing(4)
        for group in Self.standDownOrder {
            guard sideOverflows(room: room) else { break }
            for index in group { pills[index].isHidden = true }
        }
    }

    /// Whether either half of the row, measured from the play disc, is wider
    /// than half the window.
    private func sideOverflows(room: CGFloat) -> Bool {
        let visible = zip(pills, groups).enumerated().filter { !$0.element.0.isHidden }
        let centre = visible.firstIndex { $0.offset == 2 } ?? 0
        func width(_ slice: ArraySlice<(offset: Int, element: (NSView, NSStackView))>) -> CGFloat {
            slice.reduce(0) { $0 + $1.element.1.fittingSize.width + toolbarRow.spacing }
        }
        let middle = groups[2].fittingSize.width / 2
        let left = width(visible[..<centre]) + middle
        let right = width(visible[(centre + 1)...]) + middle
        return max(left, right) > room / 2
    }

    override func layout() {
        super.layout()
        if bounds.width != fittedWidth {
            fittedWidth = bounds.width
            fitToolbar()
        }
    }

    private var fittedWidth: CGFloat = 0

    // MARK: - Insets

    /// Height of the toolbar, whose middle capsule is its tallest part.
    private var toolbarHeight: CGFloat {
        slideshowButton.edge + ChromeMetrics.spacing(1.5)
    }

    /// Height the top chrome claims: the caption and the margins around it.
    var topInset: CGFloat {
        let title = ChromeMetrics.font(.title)
        let caption = ChromeMetrics.font(.caption)
        let lines = ceil(title.ascender - title.descender + title.leading)
            + ceil(caption.ascender - caption.descender + caption.leading)
        return ChromeMetrics.spacing(3) + lines + ChromeMetrics.spacing(0.5) + ChromeMetrics.spacing(1)
    }

    /// Height the bottom chrome claims: the rail, the toolbar, and the gaps
    /// around them. The canvas fits the photograph above this.
    var bottomInset: CGFloat {
        let unit = ChromeMetrics.spacing(1)
        return showsFilmstrip
            ? filmstrip.intrinsicHeight + (unit * 0.5).rounded() + toolbarHeight
            : ChromeMetrics.spacing(3) + toolbarHeight
    }

    /// Whether the rail is shown. A folder of one has nothing to rail.
    var showsFilmstrip = true {
        didSet {
            guard showsFilmstrip != oldValue else { return }
            filmstrip.isHidden = !showsFilmstrip
            toolbarAboveRail.isActive = showsFilmstrip
            toolbarAtEdge.isActive = !showsFilmstrip
            applyMetrics()
        }
    }

    // MARK: - Content

    /// Shows or hides the centred play button.
    func updatePlayback(canPlay: Bool, isPlaying: Bool) {
        playButton.isHidden = !canPlay || isPlaying
    }

    /// Dims previous and next at the ends of the folder, and the slideshow
    /// when there is nothing to show.
    func updateNavigation(canGoBack: Bool, canGoForward: Bool, canPlay: Bool) {
        previousButton.isEnabled = canGoBack
        nextButton.isEnabled = canGoForward
        slideshowButton.isEnabled = canPlay
    }

    /// Dims the tools that change pixels, for things that have none to
    /// change — a movie, an animation.
    func updateEditing(canEdit: Bool, canMarkUp: Bool, canRotate: Bool) {
        for button in editButtons { button.isEnabled = canEdit }
        // Markup is the last of the three, and the one a document shares.
        editButtons.last?.isEnabled = canMarkUp
        for button in rotateButtons { button.isEnabled = canRotate }
    }

    /// Stands the whole overlay down while a tool has the floor. Its own bar
    /// takes the toolbar's place, and controls fading in and out around a
    /// crop frame would only be in the way.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            idleTimer?.invalidate()
            isHidden = isSuspended
            if !isSuspended { flash() }
        }
    }

    /// Reflects the slideshow in the toolbar's centrepiece.
    func updateSlideshow(isRunning: Bool) {
        slideshowButton.setSymbol(isRunning ? "pause.fill" : "play.fill",
                                  label: isRunning ? "Stop Slideshow" : "Slideshow")
    }

    /// Lights the 1:1 control while the photograph is at actual size.
    func updateZoom(isActualSize: Bool) {
        actualSizeButton.isLit = isActualSize
    }

    /// True while a transient note owns the detail line. Notes stay until
    /// the next navigation replaces them.
    private(set) var isShowingNote = false

    /// - Parameters:
    ///   - detail: position, dimensions and size, already formatted.
    ///   - note: a transient message that replaces the detail line.
    func update(filename: String, detail: String, note: String? = nil) {
        filenameLabel.stringValue = filename
        detailLabel.stringValue = note ?? detail
        isShowingNote = note != nil
        detailLabel.textColor = detailColor(isNote: isShowingNote)
    }

    private func detailColor(isNote: Bool) -> NSColor {
        if isNote { return NSColor(red: 1, green: 0.76, blue: 0.62, alpha: 1) }
        return NSColor(white: 1, alpha: Accommodations.current.increaseContrast ? 1.0 : 0.66)
    }

    // MARK: - Auto-hide

    /// Shows the chrome and restarts the idle countdown. Driven by mouse
    /// movement from the controller.
    func flash() {
        guard !isSuspended else { return }
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
        if !visible { idleTimer?.invalidate() }

        // The pointer goes with the chrome. Fading the controls while leaving
        // an arrow sitting on the photograph half-defeats the effect — and
        // `setHiddenUntilMouseMoves` pairs exactly with the flash-on-move that
        // brings the chrome back, so the two can never disagree.
        NSCursor.setHiddenUntilMouseMoves(!visible)

        // Out slower than in: arriving controls should be there the moment
        // you reach for them, leaving ones should not snap away mid-glance.
        let duration = Accommodations.current.duration(visible ? 0.18 : 0.45)
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
        if let button = hit as? IconButton { return button }
        if let hit, let button = sequence(first: hit, next: { $0.superview })
            .first(where: { $0 is IconButton }) {
            return button
        }
        // The rail is interactive too: click to jump, scroll to scrub.
        if hit === filmstrip || hit?.isDescendant(of: filmstrip) == true {
            return filmstrip.urls.count > 1 ? filmstrip : nil
        }
        return nil
    }
}

/// A vertical gradient from transparent to black, used behind the chrome
/// clusters so white text stays legible over an unknown photograph.
///
/// Eased rather than linear: a two-stop gradient has a visible edge where it
/// stops, and on a large display that edge is a long straight line across the
/// photograph. Extra stops along a smooth curve make it vanish.
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
        let strength: CGFloat = Accommodations.current.increaseContrast ? 0.85 : 0.55
        let steps = 8
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            // Smoothstep, so both ends of the fade meet their neighbours flat.
            let eased = 1 - t * t * (3 - 2 * t)
            colors.append(NSColor(white: 0, alpha: strength * eased).cgColor)
            locations.append(NSNumber(value: Double(t)))
        }
        if edge == .bottom { colors.reverse() }
        gradient.colors = colors
        gradient.locations = locations
        // Unit coordinates run bottom-up here, so the first colour — the
        // screen edge — is placed at y = 1. Getting this backwards puts the
        // darkest band at the inner edge, where it ends in a hard line across
        // the photograph.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
    }
}
