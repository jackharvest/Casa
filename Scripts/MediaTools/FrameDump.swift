// Pulls cropped, scaled PNG frames out of a `screencapture -V` recording, for
// MakeGif. Crop is in movie pixels, top-left origin.
//
// usage: FrameDump <movie> <outdir> <fps> <start> <duration> <x> <y> <w> <h> <outwidth>
import AVFoundation
import AppKit
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let out = a[2]; let fps = Double(a[3])!; let start = Double(a[4])!; let dur = Double(a[5])!
let crop = CGRect(x: Double(a[6])!, y: Double(a[7])!, width: Double(a[8])!, height: Double(a[9])!)
let ow = Int(a[10])!
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
var i = 0; var t = start
let oh = Int(Double(ow) * crop.height / crop.width)
while t < start + dur {
    if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil),
       let c = img.cropping(to: crop) {
        let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(c, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", out, i)))
        i += 1
    }
    t += 1 / fps
}
print("\(i) frames")
