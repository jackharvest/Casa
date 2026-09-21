import AppKit

@MainActor
protocol FilmstripDelegate: AnyObject {
    func filmstrip(_ strip: FilmstripView, didSelect index: Int)
    func filmstripThumbnail(for url: URL) -> DecodedImage?
    func filmstripRequestThumbnail(for url: URL)
}

/// The thumbnail rail — trait 05.
///
/// Laid out so the current image is always centred and the strip slides
/// underneath it, rather than the strip standing still while a selection box
/// travels along it. That is what Picasa did, and it is the better behaviour:
/// your eye never has to hunt for where you are, because where you are is
/// always the middle.
///
/// Only the visible cells exist. A folder of ten thousand photos creates the
/// same dozen layers as a folder of twelve.
final class FilmstripView: NSView {

    weak var delegate: FilmstripDelegate?

    private(set) var urls: [URL] = []
    private(set) var currentIndex = 0

    /// Layers by image index, for the visible window only.
    private var cells: [Int: CALayer] = [:]
    /// Which URL each live cell is currently showing.
    ///
    /// Indices are *not* stable: adopting Finder's sort order re-lists the
    /// folder underneath us, and an image can move from slot 4 to slot 7. A
    /// cell that only ever loaded its picture when it was first created then
    /// keeps the old slot's thumbnail while the new occupant shows nothing —
    /// which is exactly how the current image ended up as the one blank cell
    /// in the rail. Contents follow the URL, never the slot.
    private var cellURL: [Int: URL] = [:]
    /// Display rotations the user has applied but not yet committed to disk.
    ///
    /// The rail should agree with the photograph immediately — seeing the big
    /// picture turn while its thumbnail stays put reads as a bug. Cleared once
    /// the file itself is rewritten and the thumbnail re-decoded.
    private var rotations: [URL: Int] = [:]
    private var accommodations = Accommodations.current

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Order matters: a layer assigned *before* `wantsLayer` makes this a
        // layer-hosting view that AppKit leaves alone. The other way round
        // makes it layer-backed, and AppKit will overwrite what we set.
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: - Metrics

    /// Cell edge, from the user's text size like everything else.
    private var cellEdge: CGFloat { Metrics.filmstripThumb }
    private var gap: CGFloat { Metrics.spacing(1) }
    private var step: CGFloat { cellEdge + gap }

    /// Total height the rail wants, including its breathing room.
    var intrinsicHeight: CGFloat { cellEdge + Metrics.spacing(2) * 2 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: intrinsicHeight)
    }

    // MARK: - Content

    func update(urls: [URL], currentIndex: Int, animated: Bool) {
        let indexChanged = self.currentIndex != currentIndex
        self.urls = urls
        self.currentIndex = currentIndex
        layoutCells(animated: animated && indexChanged)
    }

    func environmentChanged() {
        accommodations = Accommodations.current
        invalidateIntrinsicContentSize()
        // Cell size derives from text size, so every layer is stale.
        cells.values.forEach { $0.removeFromSuperlayer() }
        cells.removeAll()
        cellURL.removeAll()
        layoutCells(animated: false)
    }

    override func layout() {
        super.layout()
        layoutCells(animated: false)
    }

    /// Turns the cell for `url` to match the photograph.
    func setRotation(_ turns: Int, for url: URL) {
        let normalized = ((turns % 4) + 4) % 4
        if normalized == 0 { rotations.removeValue(forKey: url) } else { rotations[url] = normalized }
        for (index, shown) in cellURL where shown == url {
            guard let cell = cells[index] else { continue }
            applyRotation(to: cell, url: url, animated: true)
        }
    }

    /// Forgets a rotation, for when the file has been rewritten and the
    /// thumbnail now carries the turn itself.
    func clearRotation(for url: URL) {
        rotations.removeValue(forKey: url)
        for (index, shown) in cellURL where shown == url {
            guard let cell = cells[index] else { continue }
            applyRotation(to: cell, url: url, animated: false)
        }
    }

    private func applyRotation(to cell: CALayer, url: URL, animated: Bool) {
        let angle = CGFloat(rotations[url] ?? 0) * .pi / 2
        CATransaction.begin()
        if animated, !accommodations.reduceMotion {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        cell.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
    }

    /// Called when a thumbnail finishes decoding. Refreshes every cell
    /// currently showing that image, by URL rather than by slot.
    func thumbnailArrived(for url: URL) {
        for (index, shown) in cellURL where shown == url {
            guard let cell = cells[index] else { continue }
            applyContents(to: cell, index: index, animated: true)
        }
    }

    // MARK: - Layout

    private func layoutCells(animated: Bool) {
        Log.render.debug("strip layoutCells urls=\(self.urls.count, privacy: .public) w=\(self.bounds.width, privacy: .public) hidden=\(self.isHidden, privacy: .public) delegate=\(self.delegate != nil, privacy: .public)")
        guard !urls.isEmpty, bounds.width > 0 else { return }

        // Origin of index 0 such that `currentIndex` sits in the middle.
        let originX = bounds.midX - CGFloat(currentIndex) * step - cellEdge / 2
        let y = ((bounds.height - cellEdge) / 2).rounded()

        // One cell of overscan each side, so a cell is never seen popping in.
        let first = max(0, Int((-originX) / step) - 1)
        let last = min(urls.count - 1, Int((bounds.width - originX) / step) + 1)
        guard first <= last else { return }
        let visible = Set(first...last)

        for (index, cell) in cells where !visible.contains(index) {
            cell.removeFromSuperlayer()
            cells.removeValue(forKey: index)
            cellURL.removeValue(forKey: index)
        }

        CATransaction.begin()
        if animated, !accommodations.reduceMotion {
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }

        for index in first...last {
            let cell = cells[index] ?? makeCell(at: index)
            // Re-bind whenever the image at this slot has changed under us.
            if cellURL[index] != urls[index] {
                applyContents(to: cell, index: index, animated: false)
            }
            cell.frame = CGRect(x: (originX + CGFloat(index) * step).rounded(),
                                y: y, width: cellEdge, height: cellEdge)
            style(cell, isCurrent: index == currentIndex)
            applyRotation(to: cell, url: urls[index], animated: false)
        }

        CATransaction.commit()
    }

    private func makeCell(at index: Int) -> CALayer {
        let cell = CALayer()
        cell.contentsGravity = .resizeAspectFill
        cell.masksToBounds = true
        cell.cornerRadius = Metrics.cornerRadius(.caption)
        cell.cornerCurve = .continuous
        cell.contentsScale = window?.backingScaleFactor ?? 2
        cell.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        cell.borderColor = NSColor.white.cgColor
        layer?.addSublayer(cell)
        cells[index] = cell
        applyContents(to: cell, index: index, animated: false)
        return cell
    }

    private func applyContents(to cell: CALayer, index: Int, animated: Bool) {
        guard urls.indices.contains(index) else { return }
        let url = urls[index]

        cellURL[index] = url
        if let thumbnail = delegate?.filmstripThumbnail(for: url) {
            CATransaction.begin()
            CATransaction.setDisableActions(!animated || accommodations.reduceMotion)
            if animated, !accommodations.reduceMotion { CATransaction.setAnimationDuration(0.2) }
            cell.contents = thumbnail.cgImage
            CATransaction.commit()
        } else {
            cell.contents = nil
            delegate?.filmstripRequestThumbnail(for: url)
        }
    }

    /// The current cell is marked by a ring and a brighter ground, never by
    /// colour alone — Differentiate Without Color exists because colour alone
    /// is not a signal for everyone.
    private func style(_ cell: CALayer, isCurrent: Bool) {
        cell.borderWidth = isCurrent ? max(2, (cellEdge * 0.035).rounded()) : 0
        cell.opacity = isCurrent ? 1 : (accommodations.increaseContrast ? 0.85 : 0.55)
        cell.shadowOpacity = isCurrent ? 0.45 : 0
        cell.shadowRadius = isCurrent ? 6 : 0
        cell.shadowOffset = .zero
        cell.shadowColor = NSColor.black.cgColor
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return }
        delegate?.filmstrip(self, didSelect: index)
    }

    override func scrollWheel(with event: NSEvent) {
        // Horizontal intent wins; otherwise a vertical wheel scrubs too, which
        // is what a mouse user will try first.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        guard abs(delta) > 0 else { return }
        scrubAccumulator += delta
        let stepsToMove = Int(scrubAccumulator / (event.hasPreciseScrollingDeltas ? step : 1))
        guard stepsToMove != 0 else { return }
        scrubAccumulator = 0
        let target = min(max(0, currentIndex - stepsToMove), urls.count - 1)
        guard target != currentIndex else { return }
        delegate?.filmstrip(self, didSelect: target)
    }

    private var scrubAccumulator: CGFloat = 0

    private func index(at point: CGPoint) -> Int? {
        for (index, cell) in cells where cell.frame.contains(point) {
            return index
        }
        return nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
