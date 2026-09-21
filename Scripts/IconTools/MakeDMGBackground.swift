// Draws the disk-image background: a quiet gradient, a hint arrow, and a line
// of instruction. Procedural for the same reason the icon is — no binary
// master to keep in sync.
//
// usage: MakeDMGBackground <width> <height> <out.png>
import AppKit
import CoreGraphics
import Foundation

let width = CGFloat(Int(CommandLine.arguments[1]) ?? 620)
let height = CGFloat(Int(CommandLine.arguments[2]) ?? 420)
let out = URL(fileURLWithPath: CommandLine.arguments[3])
// Drawn at 2x and tagged, so it is crisp on a Retina display.
let scale: CGFloat = 2

guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no context") }
context.scaleBy(x: scale, y: scale)
context.setAllowsAntialiasing(true)

// --- ground -----------------------------------------------------------------
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ground = [
    CGColor(red: 0.976, green: 0.980, blue: 0.988, alpha: 1),
    CGColor(red: 0.914, green: 0.929, blue: 0.949, alpha: 1),
] as CFArray
if let gradient = CGGradient(colorsSpace: space, colors: ground, locations: [0, 1]) {
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height),
                               end: CGPoint(x: width, y: 0), options: [])
}

// --- the arrow between the two icon positions -------------------------------
// Positions match Scripts/make-dmg.sh. A dashed arrow rather than a solid one:
// it reads as a suggestion, which is what it is.
let fromX = width * 0.26, toX = width * 0.74, midY = height - 195
context.saveGState()
context.setStrokeColor(CGColor(red: 0.42, green: 0.47, blue: 0.55, alpha: 0.45))
context.setLineWidth(2.5)
context.setLineCap(.round)
context.setLineDash(phase: 0, lengths: [9, 9])
context.move(to: CGPoint(x: fromX + width * 0.10, y: midY))
context.addLine(to: CGPoint(x: toX - width * 0.11, y: midY))
context.strokePath()
context.restoreGState()

// Arrowhead
context.saveGState()
let head = toX - width * 0.105
context.setFillColor(CGColor(red: 0.42, green: 0.47, blue: 0.55, alpha: 0.62))
context.move(to: CGPoint(x: head + 13, y: midY))
context.addLine(to: CGPoint(x: head - 5, y: midY + 9))
context.addLine(to: CGPoint(x: head - 5, y: midY - 9))
context.closePath()
context.fillPath()
context.restoreGState()

// --- words ------------------------------------------------------------------
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight,
          alpha: CGFloat, centerY: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(red: 0.18, green: 0.22, blue: 0.28, alpha: alpha),
    ]
    let line = NSAttributedString(string: text, attributes: attributes)
    let bounds = line.size()
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    line.draw(at: NSPoint(x: (width - bounds.width) / 2, y: centerY - bounds.height / 2))
    NSGraphicsContext.restoreGraphicsState()
}

// Below the icons, which Finder centres at y = 195 measured from the top.
// These are CoreGraphics coordinates, so "below" is a *smaller* y.
// Clear of the icon labels above and of Finder's own chrome below — the
// content area is shorter than the window frame, so anything under about
// 0.19 of the height gets clipped.
draw("Drag Casa into your Applications folder", size: 15, weight: .medium,
     alpha: 0.80, centerY: height * 0.285)
draw("Casa keeps itself up to date from then on", size: 11.5, weight: .regular,
     alpha: 0.52, centerY: height * 0.222)

// --- write ------------------------------------------------------------------
guard let image = context.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: width, height: height)   // tags it as 2x
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: out)
print("wrote \(out.lastPathComponent) at \(Int(width))x\(Int(height)) @\(Int(scale))x")
