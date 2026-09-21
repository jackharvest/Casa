// Lifts the colour fan out of the reference artwork so it can be composited
// onto a freshly drawn glass tray.
//
// The fan behaves like stacked colour filters on a light table, so it is
// decomposed the way that physically works: a MULTIPLY layer carrying the
// colour and the darkening, and a LIGHT layer carrying the specular edges that
// are brighter than the ground behind them. Reassembling those two over any
// background reproduces the original wherever the background matches, and
// adapts where it doesn't — which is the whole point, since the tray is being
// redrawn.
//
// usage: ExtractFan <reference.png> <out-multiply.png> <out-light.png>
import AppKit
import CoreGraphics
import Foundation

let reference = URL(fileURLWithPath: CommandLine.arguments[1])
let multiplyOut = URL(fileURLWithPath: CommandLine.arguments[2])
let lightOut = URL(fileURLWithPath: CommandLine.arguments[3])

guard let source = CGImageSourceCreateWithURL(reference as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fatalError("cannot read \(reference.path)") }

let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let readContext = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no read context") }
readContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func sample(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
    let i = (y * width + x) * 4
    return (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
}

/// Chroma — how far a pixel is from neutral grey. The tray is very nearly
/// neutral; the fan is not. This is what locates the fan.
func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double {
    max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
}

// --- locate the fan ---------------------------------------------------------
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width where chroma(sample(x, y)) > 0.10 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard minX < maxX else { fatalError("found no coloured region") }

// A little margin so the blades' soft edges are not clipped.
let margin = 6
minX = max(0, minX - margin); minY = max(0, minY - margin)
maxX = min(width - 1, maxX + margin); maxY = min(height - 1, maxY + margin)
let cropW = maxX - minX + 1, cropH = maxY - minY + 1
FileHandle.standardError.write(Data("fan bounds: \(minX),\(minY) \(cropW)x\(cropH)\n".utf8))

// --- estimate the ground the fan was photographed against -------------------
// The brightest neutral pixels inside the crop are the tray showing between
// the blades. The 92nd percentile avoids the specular highlights.
var neutrals: [Double] = []
for y in minY...maxY {
    for x in minX...maxX {
        let c = sample(x, y)
        if chroma(c) < 0.045 { neutrals.append((c.r + c.g + c.b) / 3) }
    }
}
neutrals.sort()
let ground = neutrals.isEmpty ? 0.94 : neutrals[Int(Double(neutrals.count) * 0.92)]
FileHandle.standardError.write(Data("estimated ground: \(String(format: "%.3f", ground))\n".utf8))

// --- decompose --------------------------------------------------------------
var multiplyPixels = [UInt8](repeating: 255, count: cropW * cropH * 4)
var lightPixels = [UInt8](repeating: 0, count: cropW * cropH * 4)

for y in 0..<cropH {
    for x in 0..<cropW {
        let c = sample(minX + x, minY + y)
        let i = (y * cropW + x) * 4

        // Multiply: what this pixel does to whatever is behind it.
        let mr = min(1, c.r / ground), mg = min(1, c.g / ground), mb = min(1, c.b / ground)
        multiplyPixels[i] = UInt8(mr * 255)
        multiplyPixels[i + 1] = UInt8(mg * 255)
        multiplyPixels[i + 2] = UInt8(mb * 255)
        multiplyPixels[i + 3] = 255

        // Light: only what is brighter than the ground — the glass edges.
        let lr = max(0, c.r - ground), lg = max(0, c.g - ground), lb = max(0, c.b - ground)
        let strength = max(lr, max(lg, lb))
        // Premultiplied, so the alpha and the colour agree.
        lightPixels[i] = UInt8(min(1, lr) * 255)
        lightPixels[i + 1] = UInt8(min(1, lg) * 255)
        lightPixels[i + 2] = UInt8(min(1, lb) * 255)
        lightPixels[i + 3] = UInt8(min(1, strength * 3.2) * 255)
    }
}

func write(_ data: [UInt8], to url: URL) {
    var bytes = data
    guard let context = CGContext(data: &bytes, width: cropW, height: cropH,
                                  bitsPerComponent: 8, bytesPerRow: cropW * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let out = context.makeImage()
    else { fatalError("no write context") }
    let rep = NSBitmapImageRep(cgImage: out)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

write(multiplyPixels, to: multiplyOut)
write(lightPixels, to: lightOut)
print("wrote \(multiplyOut.lastPathComponent) and \(lightOut.lastPathComponent) at \(cropW)x\(cropH)")
