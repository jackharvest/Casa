import AppKit
import AVFoundation
import QuartzCore

/// Displays one image and owns the zoom, pan and rotation interaction.
///
/// Rendering is a single `CALayer` with a `CGImage` in its `contents`. That is
/// not a compromise for lack of Metal — it is the cheapest correct thing. Core
/// Animation uploads the bitmap to the GPU once and every subsequent zoom, pan
/// or rotation is a matrix change on the compositor, costing no CPU and no
/// additional memory. A hand-rolled Metal pipeline would do the same work
/// while requiring a command queue, a shader library and a drawable pool we
/// would have to keep resident for the life of the process.
///
/// **Geometry model.** The layer is positioned by `bounds` + `position` +
/// `transform`, never by `frame`. A layer's `frame` is *derived* from those
/// three, and assigning it while a rotation transform is applied produces
/// undefined results — a bug that shows up only once someone rotates a
/// non-square image, which is exactly the kind of thing that survives to
/// release. Keeping the rotated footprint as a computed value means the
/// pan-constraint and zoom-anchor maths read the same whether the image is
/// upright or on its side.
final class ImageCanvasView: NSView {

    weak var delegate: ImageCanvasDelegate?

    private let imageLayer = CALayer()
    private var accommodations = Accommodations.current

    /// Points per image pixel.
    private(set) var scale: CGFloat = 1
    /// Unrotated native pixel size of the image on screen.
    private var imagePixelSize: CGSize = .zero
    /// Clockwise quarter turns applied for display. Not written to the file.
    private(set) var quarterTurns = 0
    /// On-screen center of the image, in view coordinates.
    private var center: CGPoint = .zero
    /// True while in fit mode, which re-fits on resize and rotation.
    private(set) var isFitted = true

    private var panOrigin: CGPoint?
    private let zoomBadge = ZoomBadge(frame: .zero)
    /// Last place the pointer was, so the badge can sit beside it even when the
    /// zoom came from a pinch rather than a wheel.
    private var lastPointer: CGPoint = .zero

    private let minScale: CGFloat = 0.02
    private let maxScale: CGFloat = 32

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Order matters: a layer assigned *before* `wantsLayer` makes this a
        // layer-hosting view that AppKit leaves alone. The other way round
        // makes it layer-backed, and AppKit will overwrite what we set.
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)

        imageLayer.isOpaque = true
        imageLayer.allowsEdgeAntialiasing = false
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // An implicit animation on every geometry change is the single most
        // common reason a viewer feels sluggish. Disable them at the source;
        // the two places that genuinely want animation opt back in explicitly.
        addSubview(zoomBadge)
        imageLayer.actions = [
            "contents": NSNull(), "bounds": NSNull(),
            "position": NSNull(), "transform": NSNull(),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Space claimed by chrome — the filename band above, the rail and control
    /// cluster below. The photograph is fitted and centred inside what is left,
    /// not inside the raw window.
    ///
    /// Without this the image is centred on the window and the rail sits on top
    /// of its lower edge, so a landscape photo is always slightly obscured and
    /// always looks a little off-centre. Fitting to the free area is most of
    /// the difference between "a picture in a window" and something that looks
    /// composed.
    var contentInsets = NSEdgeInsets() {
        didSet {
            guard contentInsets.top != oldValue.top || contentInsets.bottom != oldValue.bottom
                || contentInsets.left != oldValue.left || contentInsets.right != oldValue.right
            else { return }
            if isFitted { fit(animated: false) } else { applyGeometry(animated: false) }
        }
    }

    /// The area a fitted photograph may occupy: the window, less the chrome,
    /// less a margin proportional to the user's text size.
    ///
    /// The margin is deliberately generous. An image pushed hard against the
    /// window edge reads as cramped no matter how good it is, and the cost of
    /// the padding — a few percent of linear size — is invisible next to what
    /// it buys.
    private var contentRect: CGRect {
        let margin = Metrics.spacing(4)
        let left = contentInsets.left + margin
        let top = contentInsets.top + margin
        let width = bounds.width - left - contentInsets.right - margin
        let height = bounds.height - top - contentInsets.bottom - margin
        return CGRect(x: left, y: top, width: max(width, 1), height: max(height, 1))
    }

    // MARK: - Playback

    /// What the canvas is currently able to play, if anything.
    enum Playable: Equatable {
        case none
        case animation
        case video
    }

    private(set) var playable: Playable = .none
    private(set) var isPlaying = false

    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?

    /// Plays an animated image.
    ///
    /// Driven by a single discrete `CAKeyframeAnimation` on the layer's
    /// `contents` rather than by a timer. Core Animation advances the frames on
    /// the render server, so a looping GIF costs no CPU at all and keeps
    /// running smoothly while the main thread is busy decoding the next photo.
    func presentAnimation(_ animation: Animation, autoplay: Bool) {
        clearPlayback()
        playable = .animation
        pendingAnimation = animation
        if autoplay { startAnimation() } else { isPlaying = false }
        delegate?.canvasPlaybackStateChanged(self)
    }

    private var pendingAnimation: Animation?

    private func startAnimation() {
        guard let animation = pendingAnimation else { return }

        // Keyframe times are cumulative fractions of the total, which is how
        // per-frame delays of differing lengths are honoured.
        var elapsed: TimeInterval = 0
        let total = animation.totalDuration
        var keyTimes: [NSNumber] = []
        for duration in animation.durations {
            keyTimes.append(NSNumber(value: elapsed / total))
            elapsed += duration
        }

        let keyframes = CAKeyframeAnimation(keyPath: "contents")
        keyframes.values = animation.frames
        keyframes.keyTimes = keyTimes
        keyframes.duration = total
        keyframes.repeatCount = .greatestFiniteMagnitude
        // Frames replace one another; they do not cross-fade.
        keyframes.calculationMode = .discrete
        imageLayer.add(keyframes, forKey: Self.playbackKey)
        isPlaying = true
    }

    private func stopAnimation() {
        imageLayer.removeAnimation(forKey: Self.playbackKey)
        isPlaying = false
    }

    /// Plays a movie.
    func presentVideo(_ url: URL, autoplay: Bool, muted: Bool) {
        clearPlayback()
        playable = .video

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        // Videos in a viewer are looked at repeatedly; stopping dead at the end
        // and requiring a rewind is the wrong default for a lightbox.
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            MainActor.assumeIsolated {
                player?.seek(to: .zero)
                player?.play()
            }
        }

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = false
        self.player = player

        if autoplay {
            player.play()
            isPlaying = true
        }
        applyGeometry(animated: false)
        delegate?.canvasPlaybackStateChanged(self)
    }

    /// Play or pause, whichever applies to the current item.
    func togglePlayback() {
        switch playable {
        case .none:
            return
        case .animation:
            if isPlaying { stopAnimation() } else { startAnimation() }
        case .video:
            guard let player else { return }
            if isPlaying { player.pause(); isPlaying = false }
            else { player.play(); isPlaying = true }
        }
        delegate?.canvasPlaybackStateChanged(self)
    }

    /// Tears down whatever was playing. Called on every navigation — a video
    /// left running after the user has moved on is the single rudest thing a
    /// viewer can do.
    func clearPlayback() {
        stopAnimation()
        pendingAnimation = nil

        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        player?.pause()
        player = nil
        playerLayer.player = nil
        playerLayer.isHidden = true

        playable = .none
        isPlaying = false
    }

    private static let playbackKey = "casa.playback"

    // MARK: - Resolution

    /// Without this, moving the window between displays of differing pixel
    /// density leaves the layer on the old scale factor and a Retina image
    /// renders at half resolution — the classic silent Retina bug.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let backing = window?.backingScaleFactor ?? 2
        imageLayer.contentsScale = backing
        layer?.contentsScale = backing
        updateFilters()
        delegate?.canvasDidChangeBackingScale(self, to: backing)
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Longest-edge pixel budget for the display-tier decode, before the
    /// image's own proportions are known. Deliberately the view's longest edge
    /// — an upper bound that is always safe.
    var displayPixelBudget: Int {
        let points = max(bounds.width, bounds.height)
        return max(Int((points * backingScale).rounded()), 512)
    }

    /// Longest-edge pixel budget for an image of known size.
    ///
    /// Sizing from the window's longest edge over-asks by the entire aspect
    /// ratio: a 6016 x 6016 photo fitted into a wide window is only ever shown
    /// as tall as the window is *short*, so decoding it to the window's *width*
    /// produces detail that is thrown away on every frame. Asking for what fit
    /// actually displays is both a smaller bitmap and, via the subsample
    /// factor it enables, a cheaper decode.
    func displayBudget(for nativeSize: CGSize) -> Int {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return displayPixelBudget }
        let available = contentRect.size
        let fit = min(1, min(available.width / nativeSize.width,
                             available.height / nativeSize.height))
        let longestPoints = max(nativeSize.width, nativeSize.height) * fit
        // A little headroom so a modest zoom does not immediately look soft;
        // past that the full-resolution rung takes over anyway.
        let pixels = Int((longestPoints * backingScale * 1.25).rounded())
        return max(min(pixels, Int(max(nativeSize.width, nativeSize.height))), 512)
    }

    // MARK: - Content

    func display(_ image: DecodedImage, preservingZoom: Bool) {
        let isDifferentImage = imagePixelSize != image.nativePixelSize
        imagePixelSize = image.nativePixelSize

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image.cgImage
        CATransaction.commit()

        if isDifferentImage || !preservingZoom {
            quarterTurns = 0
            fit(animated: false)
        } else {
            applyGeometry(animated: false)
        }
        updateFilters()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
        imagePixelSize = .zero
    }

    // MARK: - Geometry

    /// The image's footprint after rotation, at the current scale.
    private var displayedSize: CGSize {
        let width = imagePixelSize.width * scale
        let height = imagePixelSize.height * scale
        return quarterTurns % 2 == 0
            ? CGSize(width: width, height: height)
            : CGSize(width: height, height: width)
    }

    /// The on-screen rect the image occupies. Derived, never assigned.
    var displayedRect: CGRect {
        let size = displayedSize
        return CGRect(x: center.x - size.width / 2,
                      y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        // Nothing useful to compute while the window is squeezed into a line.
        if (window as? ViewerWindow)?.isAnimatingPresentation == true { return }
        if isFitted {
            fit(animated: false)
        } else {
            applyGeometry(animated: false)
        }
    }

    /// Scale that fits the rotated image inside the view. Never upscales — a
    /// 200 px thumbnail opens at 200 px rather than blown up across a 5K
    /// display, which is how Picasa behaved and is almost always right.
    private var fitScale: CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return 1 }
        let available = contentRect.size
        // Compare against the rotated footprint, so a portrait image turned
        // sideways fits its new orientation rather than the old one.
        let rotated = quarterTurns % 2 == 0
            ? imagePixelSize
            : CGSize(width: imagePixelSize.height, height: imagePixelSize.width)
        return min(1, min(available.width / rotated.width, available.height / rotated.height))
    }

    func fit(animated: Bool) {
        endSmoothZoom()
        isFitted = true
        scale = fitScale
        targetScale = fitScale
        center = CGPoint(x: contentRect.midX, y: contentRect.midY)
        applyGeometry(animated: animated)
        notifyZoom()
    }

    /// One image pixel per *screen* pixel — which on a Retina display is half
    /// the point size. That is the honest reading of "actual size" for a photo.
    func actualSize(animated: Bool) {
        endSmoothZoom()
        isFitted = false
        targetScale = 1 / backingScale
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        setScale(targetScale, anchoredAt: middle, animated: animated)
        announceZoom(at: middle)
    }

    // MARK: - Zoom

    /// The core interaction. The image point under the cursor stays under the
    /// cursor: we scale about `anchor` rather than about the image's own
    /// center. That is the entire difference between zoom that feels
    /// intentional and zoom that feels like it is fighting you.
    private func setScale(_ target: CGFloat, anchoredAt anchor: CGPoint, animated: Bool) {
        guard imagePixelSize.width > 0 else { return }
        let clamped = min(max(target, minScale), maxScale)
        guard clamped != scale else { return }

        // Offset from anchor to center scales by exactly the same factor the
        // image does, which keeps the anchored point stationary.
        let factor = clamped / scale
        center = CGPoint(x: anchor.x + (center.x - anchor.x) * factor,
                         y: anchor.y + (center.y - anchor.y) * factor)
        scale = clamped

        applyGeometry(animated: animated)
        updateFilters()
        notifyZoom()
    }

    /// Stepped zoom, for the keyboard and the chrome buttons. Anchored on the
    /// centre, which is what those controls imply.
    func zoom(by factor: CGFloat, at anchor: CGPoint) {
        endSmoothZoom()
        isFitted = false
        targetScale = scale * factor
        setScale(targetScale, anchoredAt: anchor, animated: !accommodations.reduceMotion)
        announceZoom(at: anchor)
    }

    /// Toggles fit ⇄ 1:1 anchored where the user clicked, so double-clicking a
    /// face zooms to that face rather than to the middle of the photo.
    func toggleZoom(at anchor: CGPoint) {
        let animated = !accommodations.reduceMotion
        if isFitted {
            isFitted = false
            setScale(1 / backingScale, anchoredAt: anchor, animated: animated)
            announceZoom(at: anchor)
        } else {
            fit(animated: animated)
        }
    }

    // MARK: - Rotation

    func rotate(by turns: Int) {
        guard imagePixelSize.width > 0 else { return }
        quarterTurns = ((quarterTurns + turns) % 4 + 4) % 4
        if isFitted {
            fit(animated: !accommodations.reduceMotion)
        } else {
            applyGeometry(animated: !accommodations.reduceMotion)
        }
    }

    // MARK: - Pan

    private func pan(byX dx: CGFloat, y dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        isFitted = false
        center.x += dx
        center.y += dy
        applyGeometry(animated: false)
    }

    /// Keeps the image from being dragged off screen. On an axis where the
    /// image already fits, it stays centered rather than drifting — that is
    /// what makes panning a tall image feel guided instead of loose.
    private func constrainedCenter() -> CGPoint {
        let size = displayedSize
        var result = center

        // Two limits, and the permitted range is the union of them.
        //
        // *Cover* says the image may sit anywhere that still fills the view.
        // *Keep* says a reasonable share of the image must remain on screen,
        // which is what lets you drag a fitted photo off to one side and have
        // it stay there — Picasa did that because you are usually lining up a
        // zoom.
        //
        // Taking whichever is more permissive matters more than either rule.
        // Applied separately they disagree violently at the moment the image
        // grows past the viewport: at exactly that size the cover rule permits
        // a *single* centre position, the dead middle, so zooming into a corner
        // snapped to the middle the instant it crossed fit and only regained
        // freedom slowly. The union is continuous in size, so it does not.
        let keptOnScreen: CGFloat = 0.30

        func clamp(_ value: CGFloat, size: CGFloat, viewport: CGFloat) -> CGFloat {
            let half = size / 2
            let keep = size * keptOnScreen
            let lower = min(viewport - half, keep - half)
            let upper = max(half, viewport - keep + half)
            return min(max(value, lower), upper)
        }

        result.x = clamp(result.x, size: size.width, viewport: bounds.width)
        result.y = clamp(result.y, size: size.height, viewport: bounds.height)
        return result
    }

    // MARK: - Commit

    private func applyGeometry(animated: Bool) {
        guard imagePixelSize.width > 0 else { return }
        center = constrainedCenter()

        // Unrotated bounds; the transform supplies the rotation, and
        // `displayedSize` accounts for it everywhere else.
        let unrotated = CGSize(width: imagePixelSize.width * scale,
                               height: imagePixelSize.height * scale)
        let angle = CGFloat(quarterTurns) * .pi / 2

        CATransaction.begin()
        if animated, !accommodations.reduceMotion {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        imageLayer.bounds = CGRect(origin: .zero, size: unrotated)
        playerLayer.bounds = imageLayer.bounds
        // Rounding to the backing grid keeps edges crisp instead of landing on
        // a half pixel and getting a soft seam.
        let grid = backingScale
        imageLayer.position = CGPoint(x: (center.x * grid).rounded() / grid,
                                      y: (center.y * grid).rounded() / grid)
        imageLayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        playerLayer.position = imageLayer.position
        playerLayer.transform = imageLayer.transform
        CATransaction.commit()

        window?.invalidateCursorRects(for: self)
    }

    /// Puts the percentage beside the pointer. Skipped while fitted, because
    /// "this is the whole picture" is not news.
    private func announceZoom(at pointer: CGPoint) {
        guard imagePixelSize.width > 0 else { return }
        lastPointer = pointer
        zoomBadge.show(scale: scale, backingScale: backingScale, pointer: pointer, in: self)
    }

    private func notifyZoom() {
        // Silent until there is something to zoom. `fit()` runs during window
        // setup with no image loaded, where `scale` is still its initial 1.0 —
        // reporting that as a zoom level convinced the controller the user had
        // zoomed to 1:1 and triggered a full-resolution decode of a photo that
        // was not even on screen yet.
        guard imagePixelSize.width > 0 else { return }
        delegate?.canvas(self, didChangeZoomTo: scale, isFitted: isFitted)
    }

    /// The content size a window should take to hug this photograph.
    ///
    /// Capped to a sensible share of the screen: a 6016 px photo would
    /// otherwise ask for a window nobody has a display for.
    func preferredWindowedContentSize(maximum: CGSize) -> CGSize {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return CGSize(width: min(960, maximum.width), height: min(680, maximum.height))
        }
        let rotated = quarterTurns % 2 == 0
            ? imagePixelSize
            : CGSize(width: imagePixelSize.height, height: imagePixelSize.width)

        // Points, not pixels: a Retina display shows a 4000 px photo in 2000
        // points, and the window is measured in points.
        var size = CGSize(width: rotated.width / backingScale, height: rotated.height / backingScale)

        // No allowance for chrome. In a window the photograph fills the frame
        // edge to edge and the controls float over it — a letterboxed bar at
        // the bottom to hold a rail is exactly the black band this is meant to
        // avoid.
        let shrink = min(1, min(maximum.width / size.width, maximum.height / size.height))
        size = CGSize(width: (size.width * shrink).rounded(),
                      height: (size.height * shrink).rounded())

        return CGSize(width: max(size.width, 420), height: max(size.height, 300))
    }

    /// Whether the user has zoomed past the point where the display-tier proxy
    /// visibly softens, making a full decode worth its memory.
    var needsFullResolution: Bool {
        guard imagePixelSize.width > 0 else { return false }
        return scale * backingScale > 0.9
    }

    private func updateFilters() {
        let effective = scale * backingScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Trilinear is mipmapped and markedly better when shrinking a large
        // photo; linear is correct and cheaper when enlarging.
        imageLayer.minificationFilter = .trilinear
        // Past 8:1 the honest thing is to show the pixels rather than invent
        // smooth gradients between them.
        imageLayer.magnificationFilter = effective > 8 ? .nearest : .linear
        CATransaction.commit()
    }

    func environmentChanged() {
        accommodations = Accommodations.current
        if isFitted { fit(animated: false) }
        updateFilters()
    }

    // MARK: - Smooth zoom

    /// Where the zoom is heading. The wheel moves this; a display link walks
    /// `scale` toward it.
    private var targetScale: CGFloat = 1
    private var zoomAnchor: CGPoint = .zero
    private var zoomLink: CADisplayLink?

    /// Picasa's zoom was continuous, not stepped once per wheel click, and that
    /// is most of why it felt better than everything else. Each notch nudges a
    /// target and the view eases toward it every frame, so a flick of the wheel
    /// reads as one smooth movement instead of a stack of jumps.
    private func zoomSmoothly(by factor: CGFloat, at anchor: CGPoint) {
        guard imagePixelSize.width > 0 else { return }

        // A gesture that has settled starts again from where the view actually
        // is, not from a stale target.
        if zoomLink == nil { targetScale = scale }

        targetScale = min(max(targetScale * factor, minScale), maxScale)
        zoomAnchor = anchor
        isFitted = false

        guard !accommodations.reduceMotion else {
            setScale(targetScale, anchoredAt: anchor, animated: false)
            return
        }

        if zoomLink == nil {
            let link = displayLink(target: self, selector: #selector(stepZoom))
            link.add(to: .main, forMode: .common)
            zoomLink = link
        }
    }

    @objc private func stepZoom() {
        let remaining = targetScale - scale
        // Close enough: land exactly and stop, rather than easing forever.
        guard abs(remaining) > scale * 0.002 else {
            setScale(targetScale, anchoredAt: zoomAnchor, animated: false)
            endSmoothZoom()
            return
        }
        setScale(scale + remaining * 0.30, anchoredAt: zoomAnchor, animated: false)
        announceZoom(at: zoomAnchor)
    }

    private func endSmoothZoom() {
        zoomLink?.invalidate()
        zoomLink = nil
    }

    // MARK: - Events

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Control plus wheel walks the folder. Picasa did this, and it means
        // you can browse and zoom without moving your hand.
        if modifiers.contains(.control) {
            let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
                ? event.scrollingDeltaY : event.scrollingDeltaX
            navigationAccumulator += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 28 : 1
            let steps = Int((navigationAccumulator / threshold).rounded(.towardZero))
            guard steps != 0 else { return }
            navigationAccumulator -= CGFloat(steps) * threshold
            delegate?.canvas(self, requestsStep: -steps)
            return
        }

        // A mouse wheel and a trackpad are different instruments and must not
        // map to the same gesture. Precise deltas mean a trackpad, where
        // two-finger scroll universally means pan on macOS; coarse deltas mean
        // a wheel, where Picasa's users reach for zoom.
        if event.hasPreciseScrollingDeltas {
            pan(byX: event.scrollingDeltaX, y: event.scrollingDeltaY)
        } else {
            let steps = event.scrollingDeltaY
            guard steps != 0 else { return }
            // Small per-notch factor, because the easing is what carries the
            // distance rather than the notch itself.
            let pointer = convert(event.locationInWindow, from: nil)
            zoomSmoothly(by: pow(1.085, steps), at: pointer)
            announceZoom(at: pointer)
        }
    }

    private var navigationAccumulator: CGFloat = 0

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        // A pinch is already continuous, so it goes straight in.
        endSmoothZoom()
        targetScale = scale
        isFitted = false
        let pointer = convert(event.locationInWindow, from: nil)
        setScale(scale * (1 + event.magnification), anchoredAt: pointer, animated: false)
        announceZoom(at: pointer)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2 {
            toggleZoom(at: point)
            panOrigin = nil
            return
        }

        // Clicking the empty surround beside the photograph dismisses, the way
        // Picasa's viewer did. It reads as "put this down" and it is the
        // gesture people reach for before they remember Escape.
        //
        // Deliberately excludes the bands the chrome occupies: someone aiming
        // for the thumbnail rail and missing by a few pixels should not have
        // the window close on them.
        if isPointInDismissableSurround(point) {
            delegate?.canvasDidRequestWindowedToggle(self)
            return
        }

        // A single click on a playable item plays it — the same gesture every
        // other video surface on the platform uses.
        if playable != .none {
            togglePlayback()
            panOrigin = point
            return
        }

        panOrigin = point
        NSCursor.closedHand.push()
    }

    /// Whether a click landed on the ground rather than on anything.
    ///
    /// True only outside the photograph *and* outside the chrome's bands. When
    /// the image is zoomed in far enough to overflow the window there is no
    /// surround at all, so this naturally stops applying.
    func isPointInDismissableSurround(_ point: CGPoint) -> Bool {
        guard imagePixelSize.width > 0 else { return false }
        if displayedRect.insetBy(dx: -2, dy: -2).contains(point) { return false }

        let topBand = contentInsets.top
        let bottomBand = bounds.height - contentInsets.bottom
        return point.y > topBand && point.y < bottomBand
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = panOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        pan(byX: point.x - origin.x, y: point.y - origin.y)
        panOrigin = point
    }

    override func mouseUp(with event: NSEvent) {
        if panOrigin != nil { NSCursor.pop() }
        panOrigin = nil
    }

    override func resetCursorRects() {
        let rect = displayedRect
        let overflows = rect.width > bounds.width || rect.height > bounds.height
        addCursorRect(bounds, cursor: overflows ? .openHand : .arrow)
    }
}

@MainActor
protocol ImageCanvasDelegate: AnyObject {
    /// Control-scroll: walk the folder without leaving the wheel.
    func canvas(_ canvas: ImageCanvasView, requestsStep offset: Int)

    /// The user clicked the ground beside the photograph. Picasa took that as
    /// "put this in a window", not "close it".
    func canvasDidRequestWindowedToggle(_ canvas: ImageCanvasView)
    func canvas(_ canvas: ImageCanvasView, didChangeZoomTo scale: CGFloat, isFitted: Bool)
    func canvasDidChangeBackingScale(_ canvas: ImageCanvasView, to scale: CGFloat)
    func canvasPlaybackStateChanged(_ canvas: ImageCanvasView)
}
