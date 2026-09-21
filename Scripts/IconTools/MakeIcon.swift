// Draws Casa's app icon procedurally at any size.
//
// The icon is a squircle glass tray holding a fan of translucent colour
// blades — film slides, or the colour filters you'd fan over a light table.
// Everything is parameterised as a fraction of the canvas, so the same code
// draws a crisp 16 px menu icon and a 1024 px master.
//
// usage: MakeIcon <size> <out.png>
import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// A superellipse — Apple's rounded-rect corners are continuous-curvature, not
/// circular arcs, and a plain `roundedRect` reads as visibly wrong beside real
/// macOS icons. `n = 5` is very close to the system shape.
func squircle(in rect: CGRect, n: Double = 5, segments: Int = 512) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let exponent = 2 / n

    for step in 0...segments {
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

/// One blade: a tapered, rounded paddle that is narrow at the pivot and wide
/// at the tip, rotated about the pivot.
///
/// Built as a rounded path in blade-local space (pivot at the origin, pointing
/// along +x) and then transformed, which keeps the taper and the corner radii
/// independent of the angle.
func blade(pivot: CGPoint, angle: Double, length: CGFloat,
           halfWidthNear: CGFloat, halfWidthFar: CGFloat, corner: CGFloat) -> CGPath {
    let local = CGMutablePath()
    let nearX: CGFloat = 0, farX = length

    // Corners, near-bottom → far-bottom → far-top → near-top.
    let points = [
        CGPoint(x: nearX, y: -halfWidthNear),
        CGPoint(x: farX, y: -halfWidthFar),
        CGPoint(x: farX, y: halfWidthFar),
        CGPoint(x: nearX, y: halfWidthNear),
    ]

    local.move(to: midpoint(points[3], points[0]))
    for index in 0..<4 {
        let current = points[index]
        let next = points[(index + 1) % 4]
        local.addArc(tangent1End: current, tangent2End: next, radius: corner)
    }
    local.closeSubpath()

    var transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
        .rotated(by: angle * .pi / 180)
    return local.copy(using: &transform) ?? local
}

func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

// MARK: - Palette

/// The fan, from the leftmost blade round to the lowest.
///
/// Drawn in this order, each over the last, which is what produces the
/// overlapping-slide look: every blade's leading edge sits on top of its
/// neighbour.
///
/// The angles and lengths are deliberately uneven. Evenly spaced blades of
/// equal length read as a pie chart; a handful of degrees and a few percent of
/// length in either direction is the difference between a diagram and a stack
/// of glass slides someone actually dropped in a tray.
let fan: [(angle: Double, reach: CGFloat, color: (r: CGFloat, g: CGFloat, b: CGFloat))] = [
    (114, 1.00, (0.929, 0.396, 0.239)),   // salmon
    ( 97, 0.93, (0.737, 0.808, 0.196)),   // yellow-green
    ( 78, 0.97, (0.302, 0.741, 0.267)),   // green
    ( 61, 0.89, (0.180, 0.718, 0.553)),   // teal
    ( 42, 1.00, (0.200, 0.510, 0.867)),   // blue
    ( 23, 0.88, (0.720, 0.780, 0.886)),   // pale glass
    (  6, 0.96, (0.898, 0.600, 0.114)),   // amber
    (-13, 1.00, (0.898, 0.412, 0.122)),   // orange
]

// MARK: - Render

let size = CGFloat(Int(CommandLine.arguments[1]) ?? 1024)
let out = URL(fileURLWithPath: CommandLine.arguments[2])

guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot create context") }

context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

func gray(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: value, green: value, blue: value, alpha: alpha)
}
func rgba(_ c: (r: CGFloat, g: CGFloat, b: CGFloat), _ alpha: CGFloat) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: alpha)
}

// The macOS icon grid: the body occupies ~82% of the canvas, leaving room for
// the shadow so icons of different shapes optically match in the Dock.
let bodyInset = size * 0.090
let body = CGRect(x: bodyInset, y: bodyInset,
                  width: size - bodyInset * 2, height: size - bodyInset * 2)
let bodyPath = squircle(in: body)

// --- drop shadow under the whole tray ---------------------------------------
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.040, color: gray(0.35, 0.34))
context.addPath(bodyPath)
context.setFillColor(gray(1, 1))
context.fillPath()
context.restoreGState()

// --- the glass slab ---------------------------------------------------------
context.saveGState()
context.addPath(bodyPath)
context.clip()

// Cool near-white, brighter at the top-left where the light is.
let slabColors = [
    CGColor(red: 0.996, green: 0.998, blue: 1.000, alpha: 1),
    CGColor(red: 0.941, green: 0.953, blue: 0.965, alpha: 1),
    CGColor(red: 0.906, green: 0.922, blue: 0.941, alpha: 1),
] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: slabColors, locations: [0, 0.55, 1]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: body.minX, y: body.maxY),
                               end: CGPoint(x: body.maxX, y: body.minY),
                               options: [])
}
context.restoreGState()

// --- the inner well, which is what makes it read as a tray with thick walls -
let wallThickness = size * 0.064
let well = body.insetBy(dx: wallThickness, dy: wallThickness)
let wellPath = squircle(in: well)

// A soft inner shadow just inside the wall, so the wall has depth.
context.saveGState()
context.addPath(wellPath)
context.clip()
context.setShadow(offset: .zero, blur: size * 0.018, color: gray(0.45, 0.42))
context.addPath(squircle(in: well.insetBy(dx: -size * 0.02, dy: -size * 0.02)))
context.addPath(wellPath)
context.setFillColor(gray(1, 0.001))
context.drawPath(using: .eoFill)
context.restoreGState()

// --- the fan ----------------------------------------------------------------
context.saveGState()
context.addPath(wellPath)
context.clip()

// Pivot low and left of centre, which is what gives the fan its sweep.
let pivot = CGPoint(x: well.minX + well.width * 0.30,
                    y: well.minY + well.height * 0.13)
let bladeLength = well.width * 0.72
let corner = well.width * 0.045

for entry in fan {
    let path = blade(pivot: pivot, angle: entry.angle, length: bladeLength * entry.reach,
                     // Wide enough that neighbours overlap by roughly a
                     // third. The overlap *is* the effect: it is what turns
                     // eight flat shapes into stacked colour filters.
                     halfWidthNear: well.width * 0.022,
                     halfWidthFar: well.width * 0.172,
                     corner: corner)

    // Shadow first, in normal blending — a shadow drawn in multiply would
    // tint rather than darken.
    context.saveGState()
    context.setShadow(offset: CGSize(width: size * 0.003, height: -size * 0.005),
                      blur: size * 0.012, color: gray(0.32, 0.22))
    context.addPath(path)
    context.setFillColor(gray(1, 0.40))
    context.fillPath()
    context.restoreGState()

    // The blade itself, multiplied so crossings mix the way real colour
    // filters stacked on a light table do.
    context.saveGState()
    context.setBlendMode(.multiply)
    context.addPath(path)
    context.setFillColor(rgba(entry.color, 0.60))
    context.fillPath()
    context.restoreGState()

    // A two-tone edge, which is what sells glass rather than paper: the white
    // catches the light, and the faint darker line just inside it reads as the
    // thickness of the sheet. Without the dark line, three overlapping blades
    // merge into one continuous fan.
    context.saveGState()
    context.setBlendMode(.multiply)
    context.addPath(path)
    context.setStrokeColor(rgba(entry.color, 0.55))
    context.setLineWidth(max(size * 0.0075, 0.7))
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(gray(1, 0.85))
    context.setLineWidth(max(size * 0.0035, 0.5))
    context.strokePath()
    context.restoreGState()
}
context.restoreGState()

// --- glass on top of the fan ------------------------------------------------
// A broad specular sheen across the upper-left, drawn over everything so the
// fan reads as being *under* glass rather than sitting on it.
context.saveGState()
context.addPath(bodyPath)
context.clip()
let sheen = [gray(1, 0.46), gray(1, 0.10), gray(1, 0.0)] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: sheen, locations: [0, 0.34, 0.62]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: body.minX, y: body.maxY),
                               end: CGPoint(x: body.midX + body.width * 0.1,
                                            y: body.midY - body.height * 0.05),
                               options: [])
}
context.restoreGState()

// --- rim --------------------------------------------------------------------
// Bright outside edge, then a fainter inner line to suggest the glass's
// thickness where it turns.
context.saveGState()
context.addPath(bodyPath)
context.setStrokeColor(gray(1, 0.98))
context.setLineWidth(size * 0.016)
context.strokePath()

// The bevel: a bright band just inside the outer edge, fading inward, which
// is what gives the wall apparent thickness.
context.saveGState()
context.addPath(bodyPath)
context.addPath(squircle(in: body.insetBy(dx: wallThickness, dy: wallThickness)))
context.clip(using: .evenOdd)
let bevel = [gray(1, 0.70), gray(1, 0.06), gray(0.72, 0.16)] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: bevel, locations: [0, 0.5, 1]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: body.minX, y: body.maxY),
                               end: CGPoint(x: body.maxX, y: body.minY),
                               options: [])
}
context.restoreGState()

context.addPath(squircle(in: body.insetBy(dx: size * 0.010, dy: size * 0.010)))
context.setStrokeColor(gray(0.62, 0.20))
context.setLineWidth(max(size * 0.0030, 0.5))
context.strokePath()

context.addPath(wellPath)
context.setStrokeColor(gray(1, 0.70))
context.setLineWidth(max(size * 0.0035, 0.5))
context.strokePath()
context.restoreGState()

// MARK: - Write

guard let image = context.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: out)
print("wrote \(out.lastPathComponent) at \(Int(size))px")
