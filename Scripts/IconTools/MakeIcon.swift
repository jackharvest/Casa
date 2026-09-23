// Draws Casa's app icon procedurally at any size.
//
// A white continuous-corner tile on Apple's icon grid holding a six-blade
// iris. The blades are white; a full-spectrum sweep sits beneath them and
// shows only through the seams and the opening, so every hue appears once.
//
// Every coordinate is derived from the tile's centre, so the mark is centred
// by construction rather than nudged into place by eye.
//
// It is deliberately *not* a ring of coloured blades. That construction — a
// shutter whose segments are the colours — is Picasa's registered design, and
// Casa's lineage makes a lookalike the one thing it cannot afford. Here the
// colour is light behind the iris, not the iris itself.
//
// usage: MakeIcon <size> <out.png>
import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// A superellipse. Apple's icon corners are continuous-curvature, and a plain
/// rounded rect reads as subtly wrong beside real macOS icons. `n = 5` is very
/// close to the system shape.
func squircle(in rect: CGRect, n: Double = 5, segments: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let exponent = 2 / n
    for step in 0..<segments {
        let t = Double(step) / Double(segments) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = cx + a * (cosT < 0 ? -1 : 1) * pow(abs(cosT), exponent)
        let y = cy + b * (sinT < 0 ? -1 : 1) * pow(abs(sinT), exponent)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func point(_ centre: CGPoint, _ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
    let r = degrees * .pi / 180
    return CGPoint(x: centre.x + radius * cos(r), y: centre.y + radius * sin(r))
}

// MARK: - Colour

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { rgb(v, v, v, a) }

/// Six hues in wheel order, each used once.
let spectrum: [CGColor] = [
    rgb(0.98, 0.27, 0.25),   // red
    rgb(1.00, 0.58, 0.05),   // orange
    rgb(1.00, 0.80, 0.04),   // yellow
    rgb(0.20, 0.76, 0.36),   // green
    rgb(0.05, 0.50, 1.00),   // blue
    rgb(0.62, 0.33, 0.90),   // purple
]

// MARK: - Setup

let size = CGFloat(Int(CommandLine.arguments[1]) ?? 1024)
let out = URL(fileURLWithPath: CommandLine.arguments[2])

guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot create context") }
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    guard let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)
    else { return }
    context.drawLinearGradient(gradient, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Apple's macOS grid: an 824-unit body on a 1024-unit canvas. Matching it is
// what makes the icon sit at the same visual weight as its Dock neighbours.
let inset = size * 100 / 1024
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = squircle(in: tile)
let centre = CGPoint(x: tile.midX, y: tile.midY)
let unit = tile.width

// MARK: - Tile

// Grid shadow: soft and short, so it grounds the tile without a halo.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -size * 0.010),
                  blur: size * 0.022, color: gray(0, 0.28))
context.addPath(tilePath)
context.setFillColor(gray(1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tilePath)
context.clip()
linear([gray(1.0), rgb(0.925, 0.933, 0.945)],
       from: CGPoint(x: centre.x, y: tile.maxY), to: CGPoint(x: centre.x, y: tile.minY))
context.restoreGState()

// MARK: - Iris

let radius = unit * 0.30
let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
let bladeCount = 6
let step = 360 / CGFloat(bladeCount)
let turn: CGFloat = 90                 // a vertex straight up
let hole = unit * 0.10                 // opening's circumradius
let seamWidth = max(1, unit * 0.045)

// A soft shadow under the whole disc, so white blades lift off a white tile.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -unit * 0.008), blur: unit * 0.035,
                  color: gray(0, 0.18))
context.addEllipse(in: disc)
context.setFillColor(gray(1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addEllipse(in: disc)
context.clip()

// The light: one sweep through every hue, run across the part of the disc
// the seams actually cross so each colour shows up in at least one gap.
let pull = radius * 0.45
linear(spectrum, from: CGPoint(x: disc.minX + pull, y: disc.maxY - pull),
       to: CGPoint(x: disc.maxX - pull, y: disc.minY + pull))

// The blades, in a transparency layer so the seams and the opening can be cut
// clean through to the light rather than painted over it.
context.beginTransparencyLayer(auxiliaryInfo: nil)

// Turning counter-clockwise: the same construction, seen in a mirror.
context.translateBy(x: centre.x, y: 0)
context.scaleBy(x: -1, y: 1)
context.translateBy(x: -centre.x, y: 0)

let vertices = (0..<bladeCount).map { point(centre, hole, turn + CGFloat($0) * step) }

/// Each blade edge is one side of the opening, extended to the rim — how the
/// leaves of a real iris lie.
func rayEnd(_ i: Int) -> CGPoint {
    let a = vertices[i], b = vertices[(i + 1) % bladeCount]
    let dx = b.x - a.x, dy = b.y - a.y
    let length = hypot(dx, dy)
    return CGPoint(x: a.x + dx / length * radius * 3, y: a.y + dy / length * radius * 3)
}

for i in 0..<bladeCount {
    let blade = CGMutablePath()
    blade.move(to: vertices[(i + 1) % bladeCount])
    blade.addLine(to: rayEnd(i))
    // The far corner sits on the bisector of rays i and i + 1.
    blade.addLine(to: point(centre, radius * 3, turn + CGFloat(i) * step + 90 + step))
    blade.addLine(to: rayEnd((i + 1) % bladeCount))
    blade.closeSubpath()
    context.addPath(blade)
    // Alternate a whisper of grey, so neighbouring blades read as separate
    // leaves even where a seam is narrow at small sizes.
    context.setFillColor(i % 2 == 0 ? gray(1) : gray(0.95))
    context.fillPath()
}

context.setBlendMode(.clear)
context.setLineWidth(seamWidth)
context.setLineCap(.round)
for i in 0..<bladeCount {
    context.move(to: vertices[i])
    context.addLine(to: rayEnd(i))
}
context.strokePath()
let opening = CGMutablePath()
opening.addLines(between: vertices)
opening.closeSubpath()
context.addPath(opening)
context.fillPath()

context.endTransparencyLayer()
context.restoreGState()

// A hairline on the tile edge keeps a white icon crisp against a white
// Finder window, where it would otherwise dissolve into the background.
context.addPath(tilePath)
context.setStrokeColor(gray(0, 0.08))
context.setLineWidth(max(0.5, size / 1024))
context.strokePath()

// MARK: - Write

guard let image = context.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: out)
print("wrote \(out.lastPathComponent) at \(Int(size))px")
