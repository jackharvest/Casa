import AppKit

/// The drawing tools, shared by photographs and PDFs.
///
/// The two are marked up through different machinery — a photograph gets
/// shapes that are flattened into its pixels, a PDF gets real annotations —
/// but the person holding the mouse should not have to know that, so there is
/// one set of tools and one bar for both.
enum MarkupTool: Int, CaseIterable {
    case select, pen, highlighter, line, arrow, rectangle, ellipse, text, redact

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .redact: "rectangle.fill"
        }
    }

    var label: String {
        switch self {
        case .select: "Select and Move"
        case .pen: "Draw"
        case .highlighter: "Highlighter"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Oval"
        case .text: "Text"
        case .redact: "Cover Up"
        }
    }
}

/// Colour and weight for whatever is drawn next.
struct MarkupStyle: Equatable {

    enum Weight: Int, CaseIterable {
        case fine, medium, bold

        var label: String {
            switch self {
            case .fine: "Fine"
            case .medium: "Medium"
            case .bold: "Bold"
            }
        }

        /// Relative stroke width; the caller supplies what "1" means.
        var multiple: CGFloat {
            switch self {
            case .fine: 1
            case .medium: 2
            case .bold: 4
            }
        }
    }

    var color: NSColor = MarkupStyle.palette[0].color
    var weight: Weight = .medium

    /// Eight colours that hold up against both a photograph and white paper.
    static let palette: [(name: String, color: NSColor)] = [
        ("Red", NSColor(srgbRed: 0.93, green: 0.19, blue: 0.19, alpha: 1)),
        ("Orange", NSColor(srgbRed: 0.98, green: 0.55, blue: 0.10, alpha: 1)),
        ("Yellow", NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.20, green: 0.74, blue: 0.30, alpha: 1)),
        ("Blue", NSColor(srgbRed: 0.10, green: 0.48, blue: 0.96, alpha: 1)),
        ("Purple", NSColor(srgbRed: 0.62, green: 0.32, blue: 0.87, alpha: 1)),
        ("Black", NSColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)),
        ("White", NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
    ]
}

/// One mark on a photograph, in image pixels with the origin at the top left.
///
/// A value, so the undo stack is just earlier copies of the array.
struct MarkupItem: Equatable {

    enum Shape: Equatable {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case redact(CGRect)
        case text(String, CGPoint)
    }

    var shape: Shape
    var color: NSColor
    /// Stroke width in image pixels.
    var lineWidth: CGFloat
    /// Cap height basis for text, in image pixels.
    var fontSize: CGFloat

    // MARK: - Geometry

    var font: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// The box the mark occupies, before stroke width.
    var bounds: CGRect {
        switch shape {
        case .pen(let points), .highlighter(let points):
            guard let first = points.first else { return .zero }
            return points.reduce(CGRect(origin: first, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
        case .line(let a, let b), .arrow(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .rectangle(let rect), .ellipse(let rect), .redact(let rect):
            return rect.standardized
        case .text(let string, let origin):
            let size = NSAttributedString(string: string.isEmpty ? " " : string,
                                          attributes: textAttributes).size()
            return CGRect(origin: origin, size: size)
        }
    }

    /// Points the user can drag to reshape the mark. Freehand strokes and
    /// text have none; they only move.
    var handles: [CGPoint] {
        switch shape {
        case .line(let a, let b), .arrow(let a, let b):
            return [a, b]
        case .rectangle(let rect), .ellipse(let rect), .redact(let rect):
            let r = rect.standardized
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        default:
            return []
        }
    }

    func moved(by delta: CGSize) -> MarkupItem {
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.width, y: p.y + delta.height) }
        var copy = self
        switch shape {
        case .pen(let points): copy.shape = .pen(points.map(shift))
        case .highlighter(let points): copy.shape = .highlighter(points.map(shift))
        case .line(let a, let b): copy.shape = .line(shift(a), shift(b))
        case .arrow(let a, let b): copy.shape = .arrow(shift(a), shift(b))
        case .rectangle(let r): copy.shape = .rectangle(r.offsetBy(dx: delta.width, dy: delta.height))
        case .ellipse(let r): copy.shape = .ellipse(r.offsetBy(dx: delta.width, dy: delta.height))
        case .redact(let r): copy.shape = .redact(r.offsetBy(dx: delta.width, dy: delta.height))
        case .text(let s, let o): copy.shape = .text(s, shift(o))
        }
        return copy
    }

    /// The mark with one handle dragged to a new place.
    func reshaped(handle index: Int, to point: CGPoint) -> MarkupItem {
        var copy = self
        switch shape {
        case .line(let a, let b): copy.shape = index == 0 ? .line(point, b) : .line(a, point)
        case .arrow(let a, let b): copy.shape = index == 0 ? .arrow(point, b) : .arrow(a, point)
        case .rectangle(let r), .ellipse(let r), .redact(let r):
            // The corner opposite the one being dragged stays where it is.
            let corners = MarkupItem(shape: .rectangle(r), color: color, lineWidth: 0, fontSize: 0).handles
            let anchor = corners[(index + 2) % 4]
            let rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                              width: abs(anchor.x - point.x), height: abs(anchor.y - point.y))
            switch shape {
            case .rectangle: copy.shape = .rectangle(rect)
            case .ellipse: copy.shape = .ellipse(rect)
            default: copy.shape = .redact(rect)
            }
        default: break
        }
        return copy
    }

    /// Whether a click at `point` lands on the mark. Outlines are hit along
    /// the line, filled shapes and text anywhere inside.
    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = tolerance + lineWidth / 2
        switch shape {
        case .pen(let points):
            return Self.distance(from: point, toPath: points) <= reach
        case .highlighter(let points):
            return Self.distance(from: point, toPath: points) <= tolerance + lineWidth * 3
        case .line(let a, let b), .arrow(let a, let b):
            return Self.distance(from: point, toPath: [a, b]) <= reach
        case .rectangle(let rect):
            let r = rect.standardized
            return r.insetBy(dx: -reach, dy: -reach).contains(point)
                && !r.insetBy(dx: reach, dy: reach).contains(point)
        case .ellipse(let rect):
            let r = rect.standardized
            guard r.width > 0, r.height > 0 else { return false }
            // Distance from the ellipse, approximated radially.
            let dx = (point.x - r.midX) / (r.width / 2)
            let dy = (point.y - r.midY) / (r.height / 2)
            let radial = sqrt(dx * dx + dy * dy)
            return abs(radial - 1) * min(r.width, r.height) / 2 <= reach
        case .redact(let rect):
            return rect.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func distance(from p: CGPoint, toPath points: [CGPoint]) -> CGFloat {
        guard var previous = points.first else { return .infinity }
        var best = hypot(p.x - previous.x, p.y - previous.y)
        for next in points.dropFirst() {
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((p.x - previous.x) * dx + (p.y - previous.y) * dy) / length))
            best = min(best, hypot(p.x - (previous.x + t * dx), p.y - (previous.y + t * dy)))
            previous = next
        }
        return best
    }
}

/// Draws marks. The same code paints the overlay while the user works and
/// burns the result into the bitmap afterwards, so what is saved is exactly
/// what was on screen.
@MainActor
enum MarkupRenderer {

    /// - Parameter context: in image coordinates, origin top left, y down.
    static func draw(_ items: [MarkupItem], in context: CGContext, skippingTextAt skipped: Int? = nil) {
        for (index, item) in items.enumerated() {
            if index == skipped, case .text = item.shape { continue }
            draw(item, in: context)
        }
    }

    private static func draw(_ item: MarkupItem, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(item.color.cgColor)
        context.setFillColor(item.color.cgColor)
        context.setLineWidth(item.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch item.shape {
        case .pen(let points):
            context.addPath(smoothPath(points))
            context.strokePath()

        case .highlighter(let points):
            // Multiplied, so ink darkens what is under it the way a real
            // highlighter does instead of fogging it.
            context.setBlendMode(.multiply)
            context.setAlpha(0.45)
            context.setLineWidth(item.lineWidth * 6)
            context.setLineCap(.butt)
            context.addPath(smoothPath(points))
            context.strokePath()

        case .line(let a, let b):
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()

        case .arrow(let a, let b):
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { return }
            let head = min(max(item.lineWidth * 4.5, 10), length)
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            // The shaft stops inside the head, so its round cap never pokes
            // out past the point.
            let neck = CGPoint(x: b.x - ux * head * 0.8, y: b.y - uy * head * 0.8)
            context.move(to: a)
            context.addLine(to: neck)
            context.strokePath()

            let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
            let half = head * 0.55
            context.move(to: b)
            context.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
            context.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
            context.closePath()
            context.fillPath()

        case .rectangle(let rect):
            context.setLineJoin(.miter)
            context.stroke(rect.standardized)

        case .ellipse(let rect):
            context.strokeEllipse(in: rect.standardized)

        case .redact(let rect):
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect.standardized)

        case .text(let string, let origin):
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSAttributedString(string: string, attributes: item.textAttributes).draw(at: origin)
            NSGraphicsContext.current = previous
        }
    }

    /// A stroke through the midpoints of the samples, which rounds off the
    /// corners a mouse puts into a freehand line.
    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            // A click with no drag still leaves a dot.
            if points.count == 1 { path.addLine(to: first) }
            return path
        }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2,
                              y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Burns the marks into a copy of the bitmap.
    static func flatten(_ items: [MarkupItem], onto image: CGImage) -> CGImage? {
        guard !items.isEmpty else { return image }
        guard let context = ImageEdits.context(width: image.width, height: image.height, like: image)
        else { return nil }
        let height = CGFloat(image.height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: height))
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        draw(items, in: context)
        return context.makeImage()
    }
}
