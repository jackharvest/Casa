import AppKit

/// The zoom percentage, shown beside the pointer while you zoom.
///
/// Measured Photoshop-style: **100% means one image pixel per screen pixel**,
/// not "fills the window". A 6000 px photo fitted to a laptop display is
/// genuinely at 25%, and zooming into it should say 40% rather than pretending
/// the fitted size was the baseline. Knowing you are under 100% is the whole
/// reason the number is worth showing.
///
/// The ring is open, and the opening faces the pointer, so the badge reads as
/// attached to the cursor rather than parked near it.
@MainActor
final class ZoomBadge: NSView {

    private var percent: Int = 100
    /// Direction from the badge back to the pointer, in radians.
    private var gapAngle: CGFloat = .pi
    private var hideWork: DispatchWorkItem?

    /// Diameter, from the user's text size like everything else.
    static func diameter() -> CGFloat { max(58, (Metrics.pointSize(.control) * 4.6).rounded()) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Not interactive: it must never swallow a click meant for the photo.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// - Parameters:
    ///   - scale: points per image pixel.
    ///   - backingScale: the display's pixel density.
    ///   - pointer: cursor position in the parent's coordinates.
    func show(scale: CGFloat, backingScale: CGFloat, pointer: CGPoint, in parent: NSView) {
        percent = max(1, Int((scale * backingScale * 100).rounded()))

        let edge = Self.diameter()
        // Offset up and to the right, flipping when that would run off the
        // edge, so the badge is never clipped or under the cursor.
        let reach = edge * 0.78
        var center = CGPoint(x: pointer.x + reach, y: pointer.y - reach)
        if center.x + edge / 2 > parent.bounds.maxX { center.x = pointer.x - reach }
        if center.y - edge / 2 < parent.bounds.minY { center.y = pointer.y + reach }
        center.x = min(max(center.x, parent.bounds.minX + edge / 2), parent.bounds.maxX - edge / 2)
        center.y = min(max(center.y, parent.bounds.minY + edge / 2), parent.bounds.maxY - edge / 2)

        gapAngle = atan2(pointer.y - center.y, pointer.x - center.x)
        setFrameSize(NSSize(width: edge, height: edge))
        setFrameOrigin(NSPoint(x: center.x - edge / 2, y: center.y - edge / 2))
        needsDisplay = true

        hideWork?.cancel()
        if alphaValue < 1 {
            let duration = Accommodations.current.reduceMotion ? 0 : 0.09
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                animator().alphaValue = 1
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.fade() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    private func fade() {
        let duration = Accommodations.current.reduceMotion ? 0 : 0.25
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.width * 0.09
        let ring = bounds.insetBy(dx: inset, dy: inset)
        let radius = ring.width / 2
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)

        // 80% of a circle, the missing fifth centred on the pointer.
        let gapSpan: CGFloat = .pi * 2 * 0.20
        let start = gapAngle + gapSpan / 2
        let end = gapAngle - gapSpan / 2 + .pi * 2

        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: radius,
                       startAngle: start * 180 / .pi, endAngle: end * 180 / .pi)
        path.lineWidth = max(2, bounds.width * 0.055)
        path.lineCapStyle = .round

        // A dark disc behind the number, so it holds on a bright photograph.
        NSColor(white: 0.08, alpha: 0.62).setFill()
        NSBezierPath(ovalIn: ring.insetBy(dx: -path.lineWidth / 2, dy: -path.lineWidth / 2)).fill()

        NSColor(white: 1, alpha: 0.92).setStroke()
        path.stroke()

        let text = "\(percent)%"
        // Shrink to fit rather than overflow the disc. "116%" is comfortable at
        // the base size; "1600%" is not, and a number spilling past its own
        // ring looks like a bug rather than a big zoom.
        let room = bounds.width * 0.66
        var fontSize = bounds.width * 0.25
        var font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        var size = (text as NSString).size(withAttributes: [.font: font])
        if size.width > room {
            fontSize *= room / size.width
            font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
            size = (text as NSString).size(withAttributes: [.font: font])
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        (text as NSString).draw(at: NSPoint(x: centre.x - size.width / 2,
                                            y: centre.y - size.height / 2),
                                withAttributes: attributes)
    }
}
