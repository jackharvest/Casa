import CoreGraphics
import CoreImage
import Foundation
import Vision

/// The colour controls, as one value.
///
/// Every field is a signed offset from "leave it alone", so the identity is
/// all zeroes and a slider's middle is always the photograph as it was.
struct Adjustments: Equatable, Sendable {
    /// Stops, −2 … +2.
    var exposure: Double = 0
    /// −1 … +1 around the unchanged picture.
    var contrast: Double = 0
    var saturation: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    /// −1 (cooler) … +1 (warmer).
    var temperature: Double = 0
    /// −1 (green) … +1 (magenta).
    var tint: Double = 0
    /// 0 … 1.
    var sharpness: Double = 0
    /// 0 … 1.
    var sepia: Double = 0
    /// Apple's own automatic correction, applied before the sliders.
    var autoEnhance = false

    var isIdentity: Bool { self == Adjustments() }
}

/// Pixel edits. Pure functions from one bitmap to another.
///
/// Nothing here knows about files, views or undo. Each function takes the
/// upright picture and returns a new one, which is what makes the editor a
/// stack of images rather than a pile of state — and what lets the self-check
/// exercise the same code the app runs.
///
/// Coordinates are image pixels with the origin at the **top left**, matching
/// the canvas and `CGImage.cropping(to:)`.
enum ImageEdits {

    enum Failure: LocalizedError {
        case noSubject
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .noSubject: "Casa couldn't find a subject to lift from the background."
            case .renderFailed: "The edit couldn't be applied to this image."
            }
        }
    }

    // MARK: - Geometry

    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        // `cropping` shares the parent's storage; redrawing gives the result
        // its own, so the uncropped bitmap can be released.
        guard let cropped = image.cropping(to: clipped) else { return nil }
        return redraw(cropped, width: cropped.width, height: cropped.height)
    }

    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        return redraw(image, width: width, height: height)
    }

    static func flip(_ image: CGImage, horizontal: Bool) -> CGImage? {
        redraw(image, width: image.width, height: image.height) { context in
            if horizontal {
                context.translateBy(x: CGFloat(image.width), y: 0)
                context.scaleBy(x: -1, y: 1)
            } else {
                context.translateBy(x: 0, y: CGFloat(image.height))
                context.scaleBy(x: 1, y: -1)
            }
        }
    }

    /// Clockwise quarter turns, baked into the pixels.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let swaps = turns % 2 == 1
        let width = swaps ? image.height : image.width
        let height = swaps ? image.width : image.height

        return redraw(image, width: width, height: height, drawSize: CGSize(width: image.width, height: image.height)) { context in
            // Core Graphics is y-up, so a clockwise turn on screen is a
            // negative angle here.
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: -CGFloat(turns) * .pi / 2)
            context.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        }
    }

    // MARK: - Colour

    /// One context for the life of the process. Creating a `CIContext` costs
    /// tens of milliseconds and it is documented thread-safe.
    private static let colourContext = CIContext(options: [.cacheIntermediates: false])

    static func adjust(_ image: CGImage, _ adjustments: Adjustments) -> CGImage? {
        guard !adjustments.isIdentity else { return image }
        var picture = CIImage(cgImage: image)

        if adjustments.autoEnhance {
            for filter in picture.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(picture, forKey: kCIInputImageKey)
                picture = filter.outputImage ?? picture
            }
        }

        func apply(_ name: String, _ values: [String: Any]) {
            guard let filter = CIFilter(name: name) else { return }
            filter.setValue(picture, forKey: kCIInputImageKey)
            for (key, value) in values { filter.setValue(value, forKey: key) }
            picture = filter.outputImage ?? picture
        }

        if adjustments.exposure != 0 {
            apply("CIExposureAdjust", [kCIInputEVKey: adjustments.exposure])
        }
        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            apply("CIHighlightShadowAdjust", [
                // 1 leaves highlights alone and lower values recover them, so
                // the slider's negative half does the useful work and its
                // positive half is a gentle lift through exposure instead.
                "inputHighlightAmount": 1 + min(adjustments.highlights, 0),
                "inputShadowAmount": adjustments.shadows,
            ])
            if adjustments.highlights > 0 {
                apply("CIToneCurve", [
                    "inputPoint0": CIVector(x: 0, y: 0),
                    "inputPoint1": CIVector(x: 0.25, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.04 * adjustments.highlights),
                    "inputPoint3": CIVector(x: 0.75, y: min(1, 0.75 + 0.12 * adjustments.highlights)),
                    "inputPoint4": CIVector(x: 1, y: 1),
                ])
            }
        }
        if adjustments.contrast != 0 || adjustments.saturation != 0 {
            apply("CIColorControls", [
                // Contrast is very sensitive around 1; half the slider's range
                // is already a strong look.
                kCIInputContrastKey: 1 + adjustments.contrast * 0.5,
                kCIInputSaturationKey: 1 + adjustments.saturation,
            ])
        }
        if adjustments.temperature != 0 || adjustments.tint != 0 {
            apply("CITemperatureAndTint", [
                "inputNeutral": CIVector(x: 6500 - adjustments.temperature * 2500,
                                         y: -adjustments.tint * 80),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if adjustments.sepia > 0 {
            apply("CISepiaTone", [kCIInputIntensityKey: adjustments.sepia])
        }
        if adjustments.sharpness > 0 {
            apply("CISharpenLuminance", [kCIInputSharpnessKey: adjustments.sharpness * 1.6])
        }

        return render(picture, like: image)
    }

    // MARK: - Subject

    /// Lifts the subject off its background, leaving transparency behind it.
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Failure.noSubject
        }
        let buffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let lifted = CIImage(cvPixelBuffer: buffer)
        guard let result = colourContext.createCGImage(
            lifted, from: lifted.extent, format: .RGBA8,
            colorSpace: workingSpace(of: image)) else { throw Failure.renderFailed }
        return result
    }

    // MARK: - Rendering

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The picture's own colour space where we can draw into it, sRGB where we
    /// cannot. A Display P3 photograph stays Display P3 through an edit.
    private static func workingSpace(of image: CGImage) -> CGColorSpace {
        guard let space = image.colorSpace, space.model == .rgb, space.supportsOutput else { return sRGB }
        return space
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// A bitmap context shaped like `image`: same colour space, same depth
    /// class, alpha only if the source had it.
    static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let alpha = hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast

        func make(_ space: CGColorSpace, deep: Bool) -> CGContext? {
            var info = alpha.rawValue
            if deep { info |= CGBitmapInfo.byteOrder16Little.rawValue }
            return CGContext(data: nil, width: width, height: height,
                             bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                             space: space, bitmapInfo: info)
        }

        let space = workingSpace(of: image)
        // Sixteen-bit sources keep their depth; anything the platform refuses
        // falls back a step at a time rather than failing the edit.
        return (image.bitsPerComponent > 8 ? make(space, deep: true) : nil)
            ?? make(space, deep: false)
            ?? make(sRGB, deep: false)
    }

    private static func redraw(_ image: CGImage, width: Int, height: Int,
                               drawSize: CGSize? = nil,
                               transform: ((CGContext) -> Void)? = nil) -> CGImage? {
        guard let context = context(width: width, height: height, like: image) else { return nil }
        context.interpolationQuality = .high
        transform?(context)
        let size = drawSize ?? CGSize(width: width, height: height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private static func render(_ picture: CIImage, like image: CGImage) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return colourContext.createCGImage(
            picture, from: extent,
            format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8,
            colorSpace: workingSpace(of: image))
    }
}
