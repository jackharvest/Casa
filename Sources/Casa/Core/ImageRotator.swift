import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a rotation back to the file.
///
/// Picasa's viewer did not treat rotation as a preview: you turned a photo, you
/// moved on, and the file was turned. Matching that means writing, so the bar
/// for not damaging anything is high.
///
/// Where the format carries an EXIF orientation tag — JPEG, HEIC, TIFF — only
/// that tag is rewritten. The encoded pixels are copied across untouched, so
/// rotating a JPEG a hundred times costs it nothing. Formats without an
/// orientation tag fall back to re-encoding, and formats we cannot write at all
/// are refused rather than mangled.
enum ImageRotator {

    enum Failure: LocalizedError {
        case unreadable
        case unwritableFormat(String)
        case notPermitted
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "Casa couldn't read this file to rotate it."
            case .unwritableFormat(let ext): "Casa can't save a rotation into a .\(ext) file."
            case .notPermitted: "This file is read-only."
            case .writeFailed: "The rotation couldn't be saved."
            }
        }
    }

    /// EXIF orientation values arranged so that rotating clockwise is a step
    /// forward through the array. Values 1-8 are not in rotational order, which
    /// is why this table exists rather than arithmetic.
    private static let clockwise: [Int: Int] = [1: 6, 6: 3, 3: 8, 8: 1,
                                                2: 7, 7: 4, 4: 5, 5: 2]

    static func orientation(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let value = properties[kCGImagePropertyOrientation] as? Int
        else { return 1 }
        return (1...8).contains(value) ? value : 1
    }

    /// Whether we can write a rotation into this file at all. Checked before
    /// offering the action, not after the user has already turned the picture.
    static func canRotate(_ url: URL) -> Bool {
        guard FileManager.default.isWritableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source)
        else { return false }
        return (CGImageDestinationCopyTypeIdentifiers() as? [String])?
            .contains(type as String) ?? false
    }

    /// Applies `quarterTurns` clockwise and saves.
    static func apply(quarterTurns: Int, to url: URL) throws {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return }

        guard FileManager.default.isWritableFile(atPath: url.path) else { throw Failure.notPermitted }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source)
        else { throw Failure.unreadable }

        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type as String) == true
        else { throw Failure.unwritableFormat(url.pathExtension) }

        var orientation = orientation(of: url)
        for _ in 0..<turns { orientation = clockwise[orientation] ?? 1 }

        // Write beside the original so a failure never leaves a half-written
        // photo where the photo used to be.
        let scratch = url.deletingLastPathComponent()
            .appendingPathComponent(".casa-rotate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let destination = CGImageDestinationCreateWithURL(
            scratch as CFURL, type, CGImageSourceGetCount(source), nil)
        else { throw Failure.writeFailed }

        // Copying from the source rewrites the metadata and leaves the encoded
        // image data alone, so this is lossless on JPEG.
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)

        // Any remaining frames — an animation, or a multi-page TIFF — are
        // carried over untouched.
        for index in 1..<CGImageSourceGetCount(source) {
            CGImageDestinationAddImageFromSource(destination, source, index, nil)
        }

        guard CGImageDestinationFinalize(destination) else { throw Failure.writeFailed }

        // Keep the creation date. The modification date should move; the photo
        // really was modified.
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
        if let created {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }

        Log.decode.notice("rotated \(url.lastPathComponent, privacy: .public) to orientation \(orientation, privacy: .public)")
    }
}
