import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a bitmap to a file, in whatever formats this Mac can encode.
///
/// Like `SupportedTypes`, the list is asked of ImageIO at runtime rather than
/// written down, so a format the system gains later appears in the Export
/// panel without a code change.
enum ImageExporter {

    struct Format: Equatable, Sendable {
        let type: UTType
        let name: String
        /// Whether the encoder takes a quality setting.
        let isLossy: Bool
        let keepsAlpha: Bool

        var fileExtension: String { type.preferredFilenameExtension ?? "img" }
    }

    enum Failure: LocalizedError {
        case unsupportedFormat(String)
        case notPermitted
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let name): "Casa can't save \(name) files on this Mac."
            case .notPermitted: "This location is read-only."
            case .writeFailed: "The file couldn't be written."
            }
        }
    }

    /// Formats offered for export, most useful first.
    static let formats: [Format] = {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let candidates: [(String, String, Bool, Bool)] = [
            ("public.jpeg", "JPEG", true, false),
            ("public.png", "PNG", false, true),
            ("public.heic", "HEIC", true, true),
            ("public.tiff", "TIFF", false, true),
            ("com.adobe.pdf", "PDF", false, true),
            ("public.avif", "AVIF", true, true),
            ("public.jpeg-xl", "JPEG XL", true, true),
            ("org.webmproject.webp", "WebP", true, true),
            ("public.jpeg-2000", "JPEG 2000", true, true),
            ("com.compuserve.gif", "GIF", false, true),
            ("com.microsoft.bmp", "BMP", false, false),
            ("com.ilm.openexr-image", "OpenEXR", false, true),
        ]
        return candidates.compactMap { identifier, name, lossy, alpha in
            guard writable.contains(identifier), let type = UTType(identifier) else { return nil }
            return Format(type: type, name: name, isLossy: lossy, keepsAlpha: alpha)
        }
    }()

    /// The format a file is already in, if it is one we can write back.
    static func format(of url: URL) -> Format? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return formats.first { $0.type.identifier == identifier }
    }

    static func format(forExtension ext: String) -> Format? {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return nil }
        return formats.first { $0.type == type }
    }

    /// Encodes `image` to `url`.
    ///
    /// - Parameter metadataFrom: a file whose EXIF, GPS, IPTC and TIFF blocks
    ///   are carried into the new one. An edit should not cost a photograph
    ///   its capture date and camera.
    static func write(_ image: CGImage, to url: URL, format: Format,
                      quality: Double = 0.9, metadataFrom original: URL? = nil) throws {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else { throw Failure.notPermitted }

        // Beside the destination, so the final move is atomic and a failed
        // encode never leaves half a file where a photograph used to be.
        let scratch = directory.appendingPathComponent(".casa-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let destination = CGImageDestinationCreateWithURL(
            scratch as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw Failure.unsupportedFormat(format.name) }

        var properties = original.map(carriedMetadata(from:)) ?? [:]
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.01), 1)
        }

        let flattened = format.keepsAlpha ? image : (opaque(image) ?? image)
        CGImageDestinationAddImage(destination, flattened, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.writeFailed }

        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
            // Overwriting keeps the creation date: it is the same photograph.
            if let created {
                try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
            }
        } else {
            try FileManager.default.moveItem(at: scratch, to: url)
        }
    }

    /// Everything descriptive from the original, minus the facts the edit has
    /// made untrue.
    private static func carriedMetadata(from url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }

        // The pixels we are writing are already upright and may be a different
        // size, so these must not survive.
        for key in [kCGImagePropertyOrientation, kCGImagePropertyPixelWidth,
                    kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                    kCGImagePropertyHasAlpha, kCGImagePropertyFileSize] {
            properties.removeValue(forKey: key)
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImagePropertyOrientation] = 1
        return properties
    }

    /// Composites onto white, for formats with no alpha channel. Left to the
    /// encoder, transparency comes out black.
    private static func opaque(_ image: CGImage) -> CGImage? {
        guard ImageEdits.hasAlpha(image) else { return image }
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
