import AppKit

/// A view laid over the canvas that follows the photograph as it is zoomed
/// and panned. The crop frame and the markup layer are both one of these.
///
/// It takes the mouse — that is the point of a tool — but hands the wheel and
/// the pinch straight back to the canvas, so zooming in to place a crop edge
/// precisely works exactly as it does when nothing is being edited.
class CanvasOverlayView: NSView {

    unowned let canvas: ImageCanvasView

    init(canvas: ImageCanvasView) {
        self.canvas = canvas
        super.init(frame: canvas.frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) { canvas.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { canvas.magnify(with: event) }

    /// The photograph moved underneath us.
    func geometryChanged() { needsDisplay = true }

    func viewRect(forImageRect rect: CGRect) -> CGRect {
        let origin = canvas.viewPoint(forImagePoint: rect.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: rect.width * canvas.scale, height: rect.height * canvas.scale)
    }
}

/// The crop frame.
///
/// Opens around the whole picture, the way Photos does, rather than asking
/// for a rectangle to be dragged out from nothing: the common crop is "a bit
/// off this edge", and that is one drag when the frame is already there.
final class CropOverlayView: CanvasOverlayView {

    /// Pixel size of the picture being cropped.
    let imageSize: CGSize
    /// The frame, in image pixels.
    private(set) var cropRect: CGRect
    /// Width over height, when the shape is locked.
    private(set) var aspect: CGFloat?

    var onChange: ((CGRect) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    private enum Drag {
        case resize(Edges, from: CGRect)
        case move(from: CGRect, grab: CGPoint)
        case draw(anchor: CGPoint)
    }

    private var drag: Drag?
    private static let minimumEdge: CGFloat = 8

    init(canvas: ImageCanvasView, imageSize: CGSize) {
        self.imageSize = imageSize
        self.cropRect = CGRect(origin: .zero, size: imageSize)
        super.init(canvas: canvas)
    }

    private var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// True when the frame is still the whole picture, so applying it would
    /// change nothing.
    var isWholeImage: Bool { cropRect.integral == imageBounds }

    /// Locks the frame's shape, or frees it with `nil`. The frame becomes the
    /// largest one of that shape inside what was already selected.
    func setAspect(_ ratio: CGFloat?) {
        aspect = ratio
        guard let ratio else { return }
        var width = cropRect.width
        var height = width / ratio
        if height > cropRect.height {
            height = cropRect.height
            width = height * ratio
        }
        cropRect = CGRect(x: cropRect.midX - width / 2, y: cropRect.midY - height / 2,
                          width: width, height: height)
        changed()
    }

    private func changed() {
        needsDisplay = true
        onChange?(cropRect)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = viewRect(forImageRect: cropRect)

        // Everything outside the frame recedes; the part being kept does not.
        context.setFillColor(NSColor(white: 0, alpha: 0.6).cgColor)
        context.addRect(bounds)
        context.addRect(frame)
        context.fillPath(using: .evenOdd)

        // Thirds, only while the frame is being moved — a composition aid
        // while composing, and out of the way otherwise.
        if drag != nil {
            context.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
            context.setLineWidth(1)
            for step in 1...2 {
                let x = (frame.minX + frame.width * CGFloat(step) / 3).rounded() + 0.5
                let y = (frame.minY + frame.height * CGFloat(step) / 3).rounded() + 0.5
                context.move(to: CGPoint(x: x, y: frame.minY))
                context.addLine(to: CGPoint(x: x, y: frame.maxY))
                context.move(to: CGPoint(x: frame.minX, y: y))
                context.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.strokePath()
        }

        context.setStrokeColor(NSColor(white: 1, alpha: 0.9).cgColor)
        context.setLineWidth(1)
        context.stroke(frame.insetBy(dx: -0.5, dy: -0.5))

        // Corner brackets: where to grab, without drawing eight boxes over
        // the photograph.
        let reach = min(ChromeMetrics.spacing(5), frame.width / 3, frame.height / 3)
        let weight: CGFloat = 3
        let outer = frame.insetBy(dx: -weight / 2, dy: -weight / 2)
        context.setLineWidth(weight)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setShadow(offset: .zero, blur: 3, color: NSColor(white: 0, alpha: 0.5).cgColor)
        for (corner, dx, dy) in [(CGPoint(x: outer.minX, y: outer.minY), 1.0, 1.0),
                                 (CGPoint(x: outer.maxX, y: outer.minY), -1.0, 1.0),
                                 (CGPoint(x: outer.maxX, y: outer.maxY), -1.0, -1.0),
                                 (CGPoint(x: outer.minX, y: outer.maxY), 1.0, -1.0)] {
            context.move(to: CGPoint(x: corner.x + reach * dx, y: corner.y))
            context.addLine(to: corner)
            context.addLine(to: CGPoint(x: corner.x, y: corner.y + reach * dy))
        }
        context.strokePath()
    }

    // MARK: - Mouse

    /// Which edges a point is close enough to grab.
    private func edges(at point: CGPoint) -> Edges {
        let frame = viewRect(forImageRect: cropRect)
        let reach = max(ChromeMetrics.spacing(2), 10)
        guard frame.insetBy(dx: -reach, dy: -reach).contains(point) else { return [] }
        var edges: Edges = []
        if abs(point.x - frame.minX) <= reach { edges.insert(.left) }
        if abs(point.x - frame.maxX) <= reach { edges.insert(.right) }
        if abs(point.y - frame.minY) <= reach { edges.insert(.top) }
        if abs(point.y - frame.maxY) <= reach { edges.insert(.bottom) }
        // A frame too small to have a middle is grabbed by its far edge.
        if edges.contains([.left, .right]) { edges.remove(.left) }
        if edges.contains([.top, .bottom]) { edges.remove(.top) }
        return edges
    }

    private func clampedImagePoint(_ event: NSEvent) -> CGPoint {
        let point = canvas.imagePoint(forViewPoint: convert(event.locationInWindow, from: nil))
        return CGPoint(x: min(max(point.x, 0), imageSize.width),
                       y: min(max(point.y, 0), imageSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2, viewRect(forImageRect: cropRect).contains(point) {
            onCommit?()
            return
        }

        let grabbed = edges(at: point)
        if !grabbed.isEmpty {
            drag = .resize(grabbed, from: cropRect)
        } else if viewRect(forImageRect: cropRect).contains(point) {
            drag = .move(from: cropRect, grab: canvas.imagePoint(forViewPoint: point))
        } else {
            drag = .draw(anchor: clampedImagePoint(event))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = clampedImagePoint(event)

        switch drag {
        case .resize(let edges, let start):
            cropRect = resized(start, edges: edges, to: point)

        case .move(let start, let grab):
            let free = canvas.imagePoint(forViewPoint: convert(event.locationInWindow, from: nil))
            var origin = CGPoint(x: start.minX + free.x - grab.x, y: start.minY + free.y - grab.y)
            origin.x = min(max(origin.x, 0), imageSize.width - start.width)
            origin.y = min(max(origin.y, 0), imageSize.height - start.height)
            cropRect = CGRect(origin: origin, size: start.size)

        case .draw(let anchor):
            let seed = CGRect(origin: anchor, size: .zero)
            var edges: Edges = []
            edges.insert(point.x >= anchor.x ? .right : .left)
            edges.insert(point.y >= anchor.y ? .bottom : .top)
            cropRect = resized(seed, edges: edges, to: point)
        }
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        // A click on the surround with no drag would leave a speck of a frame.
        if cropRect.width < Self.minimumEdge || cropRect.height < Self.minimumEdge {
            cropRect = imageBounds
            if let aspect { setAspect(aspect) }
        }
        changed()
    }

    /// The frame after dragging some of its edges to `point`.
    private func resized(_ start: CGRect, edges: Edges, to point: CGPoint) -> CGRect {
        let least = Self.minimumEdge
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) { minX = min(point.x, maxX - least) }
        if edges.contains(.right) { maxX = max(point.x, minX + least) }
        if edges.contains(.top) { minY = min(point.y, maxY - least) }
        if edges.contains(.bottom) { maxY = max(point.y, minY + least) }
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        guard let aspect else { return rect.intersection(imageBounds) }

        let horizontal = !edges.isDisjoint(with: [.left, .right])
        let vertical = !edges.isDisjoint(with: [.top, .bottom])

        // The edge or corner opposite the one being dragged stays put, and
        // the locked shape is fitted into whatever room that leaves.
        let anchorX: CGFloat = edges.contains(.left) ? start.maxX : (edges.contains(.right) ? start.minX : start.midX)
        let anchorY: CGFloat = edges.contains(.top) ? start.maxY : (edges.contains(.bottom) ? start.minY : start.midY)
        let roomX: CGFloat = edges.contains(.left) ? anchorX
            : (edges.contains(.right) ? imageSize.width - anchorX : 2 * min(anchorX, imageSize.width - anchorX))
        let roomY: CGFloat = edges.contains(.top) ? anchorY
            : (edges.contains(.bottom) ? imageSize.height - anchorY : 2 * min(anchorY, imageSize.height - anchorY))

        var width = horizontal ? rect.width : rect.height * aspect
        if horizontal, vertical { width = max(rect.width, rect.height * aspect) }
        width = min(width, roomX, roomY * aspect)
        let height = width / aspect

        rect.size = CGSize(width: width, height: height)
        rect.origin.x = edges.contains(.left) ? anchorX - width : (edges.contains(.right) ? anchorX : anchorX - width / 2)
        rect.origin.y = edges.contains(.top) ? anchorY - height : (edges.contains(.bottom) ? anchorY : anchorY - height / 2)
        return rect
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}": onCommit?()
        case "\u{1b}": onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        addCursorRect(viewRect(forImageRect: cropRect).intersection(bounds), cursor: .openHand)
    }

    override func geometryChanged() {
        super.geometryChanged()
        window?.invalidateCursorRects(for: self)
    }
}
