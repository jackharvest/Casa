import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Video support: poster frames for the ladder and the filmstrip, and the
/// asset the canvas hands to an `AVPlayer`.
///
/// A video behaves like a photograph everywhere except the moment you press
/// play. Producing a poster frame through the same ladder means the folder
/// list, the preload window, the filmstrip and the fit geometry need no
/// knowledge that this item is a movie at all — the one place that has to care
/// is the canvas.
///
/// Asynchronous throughout. AVFoundation's synchronous accessors are all
/// deprecated because loading asset properties can block on I/O for a remote
/// or slow file; `ImagePipeline` is already async, so there is nothing to gain
/// from pretending otherwise.
enum VideoSource {

    /// Whether this URL is a movie we can play.
    static func isVideo(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// Natural presentation size, with any rotation already applied.
    static func naturalSize(_ url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }

        // `naturalSize` ignores the rotation stored in the track's transform,
        // so a portrait phone video reports landscape unless it is applied.
        let rotated = size.applying(transform)
        let result = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        return result.width > 0 && result.height > 0 ? result : nil
    }

    /// A representative still, for the ladder and the filmstrip.
    ///
    /// Taken a moment in rather than at zero — the first frame of a video is
    /// very often black, and a rail of black rectangles is useless.
    static func posterFrame(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Generous tolerance: an exact frame would force decoding forward from
        // the previous keyframe, which for a long GOP is far more work than a
        // thumbnail is worth.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)

        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let target = seconds.isFinite && seconds > 2 ? min(seconds * 0.1, 3) : 0

        if let image = try? await generator.image(at: CMTime(seconds: target, preferredTimescale: 600)).image {
            return image
        }
        // A very short or awkwardly encoded clip may have nothing at that
        // offset; the first frame is better than no frame.
        return try? await generator.image(at: .zero).image
    }

    /// Seconds, or nil if unknown.
    static func duration(_ url: URL) async -> TimeInterval? {
        guard let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
