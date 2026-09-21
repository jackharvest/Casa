// Writes an animated GIF and an APNG whose frames are obviously different, so
// a viewer showing only frame 0 is immediately visible in a screenshot.
// usage: WriteAnimations <out-dir>
import ImageIO
import UniformTypeIdentifiers
import Foundation
import CoreGraphics
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let frameCount = 6

func frame(_ index: Int) -> CGImage {
    let edge = 240
    let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
    let angle = CGFloat(index) / CGFloat(frameCount) * .pi * 2
    context.setFillColor(NSColor(hue: CGFloat(index) / CGFloat(frameCount),
                                 saturation: 0.85, brightness: 0.95, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: 120 + cos(angle) * 60 - 34,
                                   y: 120 + sin(angle) * 60 - 34, width: 68, height: 68))
    return context.makeImage()!
}
let frames = (0..<frameCount).map(frame)

func write(_ name: String, _ type: UTType, container: CFString, delayKey: CFString, loopKey: CFString) {
    let out = outDir.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(
        out as CFURL, type.identifier as CFString, frames.count, nil) else { return }
    CGImageDestinationSetProperties(destination, [container: [loopKey: 0]] as CFDictionary)
    for image in frames {
        CGImageDestinationAddImage(destination, image, [container: [delayKey: 0.12]] as CFDictionary)
    }
    print(CGImageDestinationFinalize(destination) ? "wrote \(name)" : "FAILED \(name)")
}

write("anim_gif.gif", .gif, container: kCGImagePropertyGIFDictionary,
      delayKey: kCGImagePropertyGIFUnclampedDelayTime, loopKey: kCGImagePropertyGIFLoopCount)
write("anim_apng.png", .png, container: kCGImagePropertyPNGDictionary,
      delayKey: kCGImagePropertyAPNGUnclampedDelayTime, loopKey: kCGImagePropertyAPNGLoopCount)
