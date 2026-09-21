import AppKit

/// A short burst of confetti, in the icon's colours.
///
/// `CAEmitterLayer` rather than a hand-rolled particle loop: the render server
/// runs it, so a celebration costs no main-thread time at the exact moment the
/// app is otherwise busy finishing a job.
@MainActor
enum Confetti {

    private static let colors: [NSColor] = [
        NSColor(red: 0.929, green: 0.396, blue: 0.239, alpha: 1),
        NSColor(red: 0.737, green: 0.808, blue: 0.196, alpha: 1),
        NSColor(red: 0.302, green: 0.741, blue: 0.267, alpha: 1),
        NSColor(red: 0.180, green: 0.718, blue: 0.553, alpha: 1),
        NSColor(red: 0.200, green: 0.510, blue: 0.867, alpha: 1),
        NSColor(red: 0.898, green: 0.600, blue: 0.114, alpha: 1),
    ]

    /// Fires once over `view`, then tidies itself up.
    ///
    /// Silently does nothing when Reduce Motion is on — a celebration is the
    /// most skippable animation in any app.
    static func burst(over view: NSView, duration: TimeInterval = 0.9) {
        guard !Accommodations.current.reduceMotion else { return }
        guard let host = view.layer else { return }

        let emitter = CAEmitterLayer()
        emitter.frame = view.bounds
        emitter.emitterPosition = CGPoint(x: view.bounds.midX, y: view.bounds.maxY + 8)
        emitter.emitterSize = CGSize(width: view.bounds.width * 0.8, height: 1)
        emitter.emitterShape = .line
        emitter.beginTime = CACurrentMediaTime()

        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = chip(color).cgImage(forProposedRect: nil, context: nil, hints: nil)
            cell.birthRate = 26
            cell.lifetime = 3.2
            cell.velocity = 150
            cell.velocityRange = 70
            // Downward, with spread, plus a little gravity.
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi / 7
            cell.yAcceleration = 160
            cell.spin = 3.4
            cell.spinRange = 4.5
            cell.scale = 0.5
            cell.scaleRange = 0.25
            cell.alphaSpeed = -0.35
            return cell
        }

        host.addSublayer(emitter)

        // Stop emitting quickly; let what is already falling finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            emitter.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 3.4) {
            emitter.removeFromSuperlayer()
        }
    }

    /// A single paper chip. Drawn rather than shipped as an asset, and small
    /// enough that the rounding reads at confetti scale.
    private static func chip(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 9, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        return image
    }
}
