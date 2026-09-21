// Writes one file per ImageIO-writable type, from a single source image.
// usage: WriteStills <source-image> <out-dir>
import ImageIO
import UniformTypeIdentifiers
import Foundation
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: WriteStills <source> <out-dir>") }
let source = URL(fileURLWithPath: arguments[1])
let outDir = URL(fileURLWithPath: arguments[2])

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 900,
      ] as CFDictionary)
else { fatalError("cannot read \(source.path)") }

var written = 0
for identifier in ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).sorted() {
    guard let type = UTType(identifier), let ext = type.preferredFilenameExtension else { continue }
    let out = outDir.appendingPathComponent("gen_\(ext).\(ext)")
    guard let destination = CGImageDestinationCreateWithURL(out as CFURL, identifier as CFString, 1, nil)
    else { continue }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { continue }

    // ImageIO reports success for some types while writing nothing at all —
    // DDS did exactly that. An empty file is not a test fixture.
    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    if (size ?? 0) == 0 {
        try? FileManager.default.removeItem(at: out)
        print("skipped \(ext) (wrote 0 bytes)")
        continue
    }
    written += 1
    print("wrote \(ext)")
}
print("stills written: \(written)")
