import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Renders the two formats ImageIO cannot: PDF and SVG.
///
/// Both are resolution-independent, which makes them *better* behaved than
/// photographs rather than worse. There is no "native pixel size" to decode at
/// and no detail to lose, so the decode ladder collapses to a single rule:
/// render at whatever size is being asked for. Zooming re-renders rather than
/// magnifying, so a PDF stays crisp at 32x where a JPEG would be mush.
enum VectorSource {

    enum Kind {
        case pdf(pages: Int)
        case svg
    }

    /// Whether this URL is something we render rather than decode.
    static func kind(of url: URL) -> Kind? {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return nil
        }
        if type.conforms(to: .pdf) {
            guard let document = CGPDFDocument(url as CFURL) else { return nil }
            return .pdf(pages: document.numberOfPages)
        }
        if type.conforms(to: .svg) {
            return .svg
        }
        return nil
    }

    /// The document's natural size in points. Used for fit and for aspect.
    static func nativeSize(_ url: URL, page: Int = 1) -> CGSize? {
        switch kind(of: url) {
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL),
                  let pdfPage = document.page(at: max(1, page)) else { return nil }
            let box = pdfPage.getBoxRect(.cropBox)
            // Odd rotations swap the reported dimensions, exactly as EXIF
            // orientation does for photographs.
            return abs(pdfPage.rotationAngle) % 180 == 90
                ? CGSize(width: box.height, height: box.width)
                : box.size
        case .svg:
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
            return image.size
        case nil:
            return nil
        }
    }

    /// Renders at a given longest-edge pixel budget.
    static func render(_ url: URL, page: Int = 1, maxPixelSize: Int) -> CGImage? {
        guard let natural = nativeSize(url, page: page), natural.width > 0, natural.height > 0 else {
            return nil
        }

        let longest = max(natural.width, natural.height)
        let scale = max(CGFloat(maxPixelSize), 1) / longest
        let pixelWidth = max(Int((natural.width * scale).rounded()), 1)
        let pixelHeight = max(Int((natural.height * scale).rounded()), 1)

        // Guard against a pathological document asking for gigabytes.
        guard pixelWidth * pixelHeight <= 64_000_000 else { return nil }

        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high

        switch kind(of: url) {
        case .pdf:
            // Paper is white. A PDF drawn onto transparency shows the viewer's
            // dark ground through its margins, which looks like a rendering
            // bug rather than a document.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

            guard let document = CGPDFDocument(url as CFURL),
                  let pdfPage = document.page(at: max(1, page)) else { return nil }
            // `getDrawingTransform` handles the crop box origin, the page
            // rotation and the aspect fit in one step — all three are easy to
            // get subtly wrong by hand.
            let target = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
            context.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(pdfPage)

        case .svg:
            guard let image = NSImage(contentsOf: url) else { return nil }
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            image.draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
                       from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

        case nil:
            return nil
        }

        return context.makeImage()
    }

    /// Page count, or 1 for anything that is not a multi-page PDF.
    static func pageCount(_ url: URL) -> Int {
        if case .pdf(let pages) = kind(of: url) { return pages }
        return 1
    }
}
