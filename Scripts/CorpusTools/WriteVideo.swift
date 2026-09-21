// Writes a 4-second H.264 clip whose hue sweeps and whose ball travels left to
// right, so two screenshots taken a second apart prove playback is running.
// usage: WriteVideo <out-file.mov|.mp4>
import AVFoundation
import AppKit
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)

let size = CGSize(width: 640, height: 360)
let fileType: AVFileType = out.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
let writer = try! AVAssetWriter(outputURL: out, fileType: fileType)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(size.width),
    AVVideoHeightKey: Int(size.height),
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: Int(size.width),
    kCVPixelBufferHeightKey as String: Int(size.height),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let fps: Int32 = 24, seconds = 4
for frame in 0..<(Int(fps) * seconds) {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
    guard let buffer = pixelBuffer else { break }
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                            width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)!
    let progress = Double(frame) / Double(Int(fps) * seconds)
    context.setFillColor(NSColor(hue: progress, saturation: 0.7, brightness: 0.35, alpha: 1).cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: CGRect(x: 40 + (size.width - 160) * progress,
                                   y: size.height / 2 - 40, width: 80, height: 80))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(out.lastPathComponent)"
                                  : "FAILED: \(String(describing: writer.error))")
