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

// MARK: - Artwork

/// The colour fan, lifted from the reference artwork by
/// `Scripts/IconTools/ExtractFan.swift` and stored as two layers:
///
/// - `fan-multiply` is what the glass does to whatever is behind it
/// - `fan-light` is the specular edges, which are brighter than the ground
///
/// Compositing them in that order over a redrawn tray reproduces the original
/// where the tray matches and adapts where it doesn't. Drawing the fan
/// procedurally got the structure right but never the subtlety — the real
/// artwork has irregularities in every blade that are not worth deriving.
func loadLayer(_ name: String) -> CGImage? {
    let candidates = [
        URL(fileURLWithPath: "Resources/Art/\(name).png"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Art/\(name).png"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
    }
    return nil
}

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
let bodyInset = size * 0.076
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
    CGColor(red: 0.988, green: 0.992, blue: 0.996, alpha: 1),
    CGColor(red: 0.957, green: 0.969, blue: 0.980, alpha: 1),
    CGColor(red: 0.933, green: 0.949, blue: 0.965, alpha: 1),
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
let wallThickness = size * 0.017
let well = body.insetBy(dx: wallThickness, dy: wallThickness)
let wellPath = squircle(in: well)

// A soft inner shadow just inside the wall, so the wall has depth.
context.saveGState()
context.addPath(wellPath)
context.clip()
context.setShadow(offset: .zero, blur: size * 0.011, color: gray(0.56, 0.18))
context.addPath(squircle(in: well.insetBy(dx: -size * 0.02, dy: -size * 0.02)))
context.addPath(wellPath)
context.setFillColor(gray(1, 0.001))
context.drawPath(using: .eoFill)
context.restoreGState()

// --- the fan ----------------------------------------------------------------
context.saveGState()
context.addPath(wellPath)
context.clip()

if let multiply = loadLayer("fan-multiply"), let light = loadLayer("fan-light") {
    // Fitted to the well with a little breathing room, preserving aspect.
    let aspect = CGFloat(multiply.width) / CGFloat(multiply.height)
    let available = well.insetBy(dx: well.width * 0.002, dy: well.height * 0.002)
    var fanSize = CGSize(width: available.height * aspect, height: available.height)
    if fanSize.width > available.width {
        fanSize = CGSize(width: available.width, height: available.width / aspect)
    }
    let fanRect = CGRect(x: available.midX - fanSize.width / 2,
                         y: available.midY - fanSize.height / 2,
                         width: fanSize.width, height: fanSize.height)

    // A soft shadow under the whole fan, so it sits in the tray rather than on
    // top of it. Drawn from the multiply layer's own darkness.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                      blur: size * 0.018, color: gray(0.35, 0.28))
    context.setBlendMode(.multiply)
    context.draw(multiply, in: fanRect)
    context.restoreGState()

    context.saveGState()
    context.setBlendMode(.plusLighter)
    context.setAlpha(0.85)
    context.draw(light, in: fanRect)
    context.restoreGState()
} else {
    FileHandle.standardError.write(Data("missing Resources/Art/fan-*.png\n".utf8))
}
context.restoreGState()

// --- glass on top of the fan ------------------------------------------------
// A broad specular sheen across the upper-left, drawn over everything so the
// fan reads as being *under* glass rather than sitting on it.
context.saveGState()
context.addPath(bodyPath)
context.clip()
let sheen = [gray(1, 0.26), gray(1, 0.05), gray(1, 0.0)] as CFArray
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
context.setStrokeColor(gray(1, 0.38))
context.setLineWidth(size * 0.0035)
context.strokePath()

// The bevel: a bright band just inside the outer edge, fading inward, which
// is what gives the wall apparent thickness.
context.saveGState()
context.addPath(bodyPath)
context.addPath(squircle(in: body.insetBy(dx: wallThickness, dy: wallThickness)))
context.clip(using: .evenOdd)
let bevel = [gray(1, 0.24), gray(1, 0.02), gray(0.78, 0.055)] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: bevel, locations: [0, 0.5, 1]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: body.minX, y: body.maxY),
                               end: CGPoint(x: body.maxX, y: body.minY),
                               options: [])
}
context.restoreGState()


context.restoreGState()

// MARK: - Write

guard let image = context.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: out)
print("wrote \(out.lastPathComponent) at \(Int(size))px")
