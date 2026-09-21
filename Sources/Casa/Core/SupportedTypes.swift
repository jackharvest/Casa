import ImageIO
import UniformTypeIdentifiers

/// The set of formats we can open.
///
/// We do not maintain a hand-written extension list. `CGImageSourceCopyTypeIdentifiers`
/// asks ImageIO what the *current system* can decode, which means HEIC, AVIF,
/// every camera RAW Apple has ever shipped support for, and anything a codec
/// installed later adds — all without a code change. This is the macOS
/// equivalent of the Windows Imaging Component coverage FlyPhotos leans on,
/// except we get it for free.
enum SupportedTypes {

    /// Whether a URL is something we should show. Resolved from the file's
    /// actual content type rather than its extension, so a mislabeled `.jpg`
    /// that is really a PNG still opens, and a `.raw` we cannot decode is
    /// correctly skipped.
    static func canOpen(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        // PDF and SVG are not ImageIO types and do not conform to `public.image`,
        // so they are admitted explicitly and rendered by `VectorSource`.
        if type.conforms(to: .pdf) || type.conforms(to: .svg) { return true }
        // Movies appear in the folder list like anything else; the canvas is
        // the only part of the app that knows the difference.
        if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
        return type.conforms(to: .image)
    }
}
