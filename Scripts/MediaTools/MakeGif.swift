// Assembles an animated GIF from a sequence of PNG frames, for README media.
//
// usage: MakeGif <out.gif> <delay-seconds> <max-width> <frame.png>...
//
// A frame may carry its own delay as `frame.png@1.5`, so a GIF can hold on a
// still moment without repeating the frame, and play motion in real time.
import ImageIO
import UniformTypeIdentifiers
import Foundation
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    FileHandle.standardError.write(Data("usage: MakeGif <out.gif> <delay> <max-width> <frames...>\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: arguments[1])
let delay = Double(arguments[2]) ?? 0.25
let maxWidth = Int(arguments[3]) ?? 900
let frames: [(url: URL, delay: Double)] = arguments.dropFirst(4).map { argument in
    let parts = argument.split(separator: "@", maxSplits: 1).map(String.init)
    let own = parts.count == 2 ? Double(parts[1]) : nil
    return (URL(fileURLWithPath: parts[0]), own ?? delay)
}

guard let destination = CGImageDestinationCreateWithURL(
    out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { exit(1) }

CGImageDestinationSetProperties(destination, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)

var added = 0
for frame in frames {
    guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: maxWidth,
              kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
    else { continue }
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: frame.delay],
    ] as CFDictionary)
    added += 1
}

guard CGImageDestinationFinalize(destination) else { exit(1) }
let bytes = ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int) ?? 0
print("wrote \(out.lastPathComponent): \(added) frames, \(bytes / 1024) KB")
