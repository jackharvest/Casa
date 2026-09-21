import CoreGraphics
import Foundation
import ImageIO

/// A decoded animation: every frame, and how long each is held.
///
/// Held whole rather than streamed. An animation is bounded — a few dozen
/// frames at a few hundred kilobytes each — and having them all resident lets
/// Core Animation play the sequence on the render server with no CPU and no
/// timer of ours. A frame-at-a-time decoder would cost more memory in
/// scaffolding than the frames do.
struct Animation: @unchecked Sendable {
    let frames: [CGImage]
    /// Per-frame display durations, in seconds. Same count as `frames`.
    let durations: [TimeInterval]
    let pixelSize: CGSize

    var totalDuration: TimeInterval {
        max(durations.reduce(0, +), 0.05)
    }

    var byteCost: Int {
        frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }
}

extension ImageSource {

    /// Largest animation we will hold in memory. Beyond this the still frame
    /// is shown instead — a 4K 300-frame GIF exists, and paying 4 GB to loop it
    /// is not a trade worth making silently.
    static let animationByteCeiling = 96 * 1024 * 1024

    /// Decodes every frame, or nil if the file is a still image.
    ///
    /// Frames are capped to `previewCap` on the long edge. Animated formats are
    /// almost always small, and an animation is watched rather than inspected —
    /// nobody pixel-peeps a GIF.
    static func animation(_ url: URL) -> Animation? {
        guard !VideoSource.isVideo(url), VectorSource.kind(of: url) == nil,
              let source = CGImageSourceCreateWithURL(url as CFURL, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary)
        else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        var frames: [CGImage] = []
        var durations: [TimeInterval] = []
        frames.reserveCapacity(count)
        durations.reserveCapacity(count)
        var bytes = 0

        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: previewCap,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else { continue }

            bytes += frame.bytesPerRow * frame.height
            guard bytes <= animationByteCeiling else {
                Log.decode.info("animation \(url.lastPathComponent, privacy: .public) exceeds memory ceiling at frame \(index, privacy: .public); showing still")
                return nil
            }

            frames.append(frame)
            durations.append(duration(of: source, at: index))
        }

        guard frames.count > 1, let first = frames.first else { return nil }
        Log.decode.info("animation \(url.lastPathComponent, privacy: .public) \(frames.count, privacy: .public) frames \(bytes / 1024, privacy: .public)KB")
        return Animation(frames: frames, durations: durations,
                         pixelSize: CGSize(width: first.width, height: first.height))
    }

    /// Per-frame delay, checking each container's own dictionary.
    ///
    /// The unclamped value is preferred where present: the clamped one floors
    /// very short delays at 100 ms for compatibility with ancient browsers, and
    /// using it makes fast animations play visibly too slowly.
    private static func duration(of source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]

        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]

        for (container, unclamped, clamped) in containers {
            guard let dictionary = properties?[container] as? [CFString: Any] else { continue }
            if let value = dictionary[unclamped] as? TimeInterval, value > 0 { return value }
            if let value = dictionary[clamped] as? TimeInterval, value > 0 { return value }
        }
        // The de facto default for a frame that declares no delay.
        return 0.1
    }
}
