import CoreGraphics
import Foundation
import ImageIO

/// A decoded bitmap plus the facts we need to lay it out.
///
/// `CGImage` is immutable and safe to hand between threads, but it does not
/// carry a `Sendable` conformance we can rely on across SDK versions. Boxing it
/// here states the guarantee once, in the one place that can justify it, rather
/// than sprinkling `@unchecked` at every call site.
struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    /// Which rung of the ladder produced this.
    let tier: DecodeTier
    /// Pixel dimensions of the *original* file, not of this bitmap. Layout and
    /// the zoom ceiling depend on the real size even while showing a proxy.
    let nativePixelSize: CGSize

    var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    /// Approximate resident bytes, used to weight the cache.
    var byteCost: Int {
        cgImage.bytesPerRow * cgImage.height
    }
}

/// The four rungs of the decode ladder, cheapest first.
///
/// Four rather than three because measurement forced it. A file with no
/// embedded preview — which includes every HEIC macOS ships as a wallpaper —
/// used to fall straight from "nothing" to a full screen-resolution decode,
/// and on a 6016 x 6016 HEIC that is 369 ms of blank window. `preview` fills
/// that hole: it is a real decode, so it always succeeds, but it is capped
/// small enough to land in a fraction of the time.
enum DecodeTier: Int, Sendable, Comparable {
    /// A filmstrip-sized thumbnail, a few hundred pixels. Cheap enough that
    /// dozens can be resident at once, which is what a rail of them needs.
    case strip = 0
    /// The preview the camera already embedded in the file. Costs a seek and a
    /// JPEG decode of something around 160–1600 px — typically under 5 ms even
    /// for a 100 MB raw, because the raw data is never touched. Free when it
    /// exists, absent often enough that it cannot be relied on.
    case thumbnail = 1
    /// A real but deliberately small decode, capped at `previewCap`. This is
    /// the rung that guarantees *something* is on screen quickly regardless of
    /// what the file does or does not contain, and it is also what neighbors
    /// are preloaded at — a quarter of the linear size is a sixteenth of the
    /// memory, which is what makes a deep preload window affordable.
    case preview = 2
    /// Downsampled during decode to the screen's pixel budget. ImageIO reads
    /// the file progressively and never materializes the full-size bitmap, so
    /// a 100 MP file costs roughly what a screen-sized one does.
    case display = 3
    /// The real thing. Only decoded when the user zooms past 1:1, because a
    /// 100 MP image is ~400 MB resident and there is no reason to pay that to
    /// look at it fit-to-window.
    case full = 4

    static func < (lhs: DecodeTier, rhs: DecodeTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var name: String {
        switch self {
        case .strip: "strip"
        case .thumbnail: "thumbnail"
        case .preview: "preview"
        case .display: "display"
        case .full: "full"
        }
    }
}

/// Reads images via ImageIO.
///
/// Every call here is synchronous and blocking by design — concurrency is the
/// caller's business (`Preloader` owns it). Keeping this layer plain makes the
/// cost of each rung obvious and testable.
enum ImageSource {

    /// Pixel dimensions and orientation without decoding anything.
    /// Cheap enough (a header read) to call during layout.
    static func probe(_ url: URL) -> CGSize? {
        if VectorSource.kind(of: url) != nil { return VectorSource.nativeSize(url) }
        guard let source = makeSource(url) else { return nil }
        return nativeSize(of: source)
    }

    private static func nativeSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        // Orientations 5–8 are the transposed ones; report post-rotation size
        // so callers never have to think about it.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Decodes `url` at the given rung.
    ///
    /// - Parameter maxPixelSize: the longest-edge budget for `.display`.
    ///   Ignored by the other tiers.
    static func decode(_ url: URL, tier: DecodeTier, maxPixelSize: Int = 0) -> DecodedImage? {
        let start = ContinuousClock.now

        // PDF and SVG have no pixels to decode, only a size to render at.
        if VectorSource.kind(of: url) != nil {
            return renderVector(url, tier: tier, maxPixelSize: maxPixelSize, start: start)
        }

        guard let source = makeSource(url) else { return nil }
        // Read the header from the source we already hold. Calling `probe`
        // here would open and parse the file a second time on every single
        // decode, which on a preload of five images is five wasted header
        // reads per navigation.
        let native = nativeSize(of: source) ?? .zero

        let image: CGImage?
        switch tier {
        case .strip:
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.stripCap,
                kCGImageSourceSubsampleFactor: subsampleFactor(native: native, target: Self.stripCap),
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)

        case .thumbnail:
            // `kCGImageSourceThumbnailMaxPixelSize` is not optional here, and
            // omitting it is a trap worth naming: without a cap,
            // `CGImageSourceCreateThumbnailAtIndex` returns the image at its
            // FULL native size. On a 9000 x 9000 JPEG that is a 324 MB bitmap
            // produced by a call whose entire purpose was to avoid decoding —
            // roughly a second of work and a gigabyte of resident memory, on
            // the path that is supposed to be the fast one.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                // Only use a preview the file already contains. If there is
                // none, fail fast and let the caller fall through to `.display`
                // rather than quietly paying for a full decode here.
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceThumbnailMaxPixelSize: Self.embeddedPreviewCap,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)

        case .preview:
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.previewCap,
                kCGImageSourceSubsampleFactor: subsampleFactor(native: native, target: Self.previewCap),
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)

        case .display:
            let target = max(maxPixelSize, 1)
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceSubsampleFactor: subsampleFactor(native: native, target: target),
                kCGImageSourceCreateThumbnailWithTransform: true,
                // Force the bitmap to be produced *here*, on whatever queue we
                // are on. Without this, CoreGraphics defers the decode until
                // first draw — which happens on the main thread, which is
                // exactly the stall preloading exists to prevent.
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)

        case .full:
            // Deliberately the thumbnail API at native size rather than
            // `CGImageSourceCreateImageAtIndex`, for two reasons found by
            // measurement:
            //
            //   * `CreateImageAtIndex` returns in ~1 ms for a 36 MP file
            //     because it hands back a *lazy* image and defers the real
            //     decode to first draw — which happens on the render thread.
            //     The work does not disappear, it just moves somewhere it
            //     causes a visible hitch instead of somewhere we control.
            //   * It also ignores EXIF orientation, so a rotated photo came
            //     out sideways at full resolution having been correct at every
            //     other rung.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(native.width, native.height)),
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }

        Log.decode.info("\(tier.name, privacy: .public) \(url.lastPathComponent, privacy: .public) took \(start.duration(to: .now).milliseconds, privacy: .public)ms -> \(image.map { "\($0.width)x\($0.height)" } ?? "nil", privacy: .public)")

        guard let image else {
            Log.decode.debug("No image at tier \(tier.rawValue, privacy: .public) for \(url.lastPathComponent, privacy: .private)")
            return nil
        }

        // Belt and braces for the trap above: if ImageIO ever hands back
        // something far larger than we asked for, refuse it rather than let a
        // full-size bitmap masquerade as a cheap preview and poison the cache.
        if tier == .thumbnail, max(image.width, image.height) > Self.embeddedPreviewCap * 2 {
            Log.decode.error("Oversized thumbnail (\(image.width, privacy: .public)px) rejected for \(url.lastPathComponent, privacy: .private)")
            return nil
        }

        return DecodedImage(cgImage: image, tier: tier, nativePixelSize: native)
    }

    /// Longest edge for the embedded-preview rung. Cameras typically embed
    /// something between 160 px and 1620 px; asking for 1600 gets the largest
    /// useful one without ever provoking a real decode.
    static let embeddedPreviewCap = 1600

    /// Longest edge for a filmstrip thumbnail. Sized for a 2x display at the
    /// largest text setting, so the rail stays crisp without the strip
    /// becoming the most expensive thing in the app.
    static let stripCap = 320

    /// Longest edge for the `preview` rung. 1024 is the knee of the curve:
    /// large enough to read as the photograph rather than as a placeholder
    /// while it sharpens, small enough that the decode is a fraction of the
    /// screen-resolution one and the bitmap costs about 4 MB instead of 36.
    static let previewCap = 1024

    /// Largest power-of-two reduction that still leaves at least `target`
    /// pixels on the long edge.
    ///
    /// This is the difference between asking for a smaller image and actually
    /// getting a cheaper decode. `kCGImageSourceThumbnailMaxPixelSize` alone
    /// describes the *output*: ImageIO is free to decode the file at full size
    /// and then resample, and measurement says it does — a 6016 px source
    /// scaled to 3840 px transiently allocated the whole 145 MB bitmap, in
    /// JPEG as well as HEIC. `kCGImageSourceSubsampleFactor` instead reduces
    /// the decode itself, so the full-size bitmap is never materialized.
    ///
    /// Powers of two only, and at most 8, because that is what the decoders
    /// implement natively; anything else silently falls back to a full decode.
    private static func subsampleFactor(native: CGSize, target: Int) -> Int {
        let longest = Int(max(native.width, native.height))
        guard target > 0, longest > 0 else { return 1 }
        var factor = 1
        while factor < 8, longest / (factor * 2) >= target {
            factor *= 2
        }
        return factor
    }

    /// Rasterizes a vector document at the size this rung calls for.
    ///
    /// `nativePixelSize` is reported as the *rendered* size rather than a fixed
    /// intrinsic one, because for a vector there is no such thing — this keeps
    /// the canvas fitting and the zoom ceiling honest without special-casing
    /// vectors everywhere upstream.
    private static func renderVector(_ url: URL, tier: DecodeTier, maxPixelSize: Int,
                                     start: ContinuousClock.Instant) -> DecodedImage? {
        guard let natural = VectorSource.nativeSize(url) else { return nil }

        let budget: Int
        switch tier {
        // Vectors get sharper rather than merely bigger, so the full rung is
        // worth real resolution — this is what keeps a PDF crisp at high zoom.
        case .full: budget = Int(max(natural.width, natural.height) * 4)
        case .display: budget = max(maxPixelSize, 1)
        default: budget = capacity(for: tier)
        }

        guard let image = VectorSource.render(url, maxPixelSize: budget) else { return nil }
        Log.decode.info("\(tier.name, privacy: .public) \(url.lastPathComponent, privacy: .public) rendered \(start.duration(to: .now).milliseconds, privacy: .public)ms -> \(image.width, privacy: .public)x\(image.height, privacy: .public)")
        return DecodedImage(cgImage: image, tier: tier,
                            nativePixelSize: CGSize(width: image.width, height: image.height))
    }

    /// The longest-edge budget each cheap rung is capped at.
    static func capacity(for tier: DecodeTier) -> Int {
        switch tier {
        case .strip: stripCap
        case .thumbnail: embeddedPreviewCap
        case .preview: previewCap
        case .display, .full: previewCap
        }
    }

    /// Number of frames in the file. One for a still image; more for an
    /// animated GIF, APNG, animated WebP or HEICS.
    static func frameCount(_ url: URL) -> Int {
        if VectorSource.kind(of: url) != nil { return VectorSource.pageCount(url) }
        guard let source = makeSource(url) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    private static func makeSource(_ url: URL) -> CGImageSource? {
        // `ShouldCache: false` keeps ImageIO from retaining decoded planes
        // behind our back. We run our own bounded cache; two caches means
        // double the resident memory and no control over either.
        CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary)
    }
}
