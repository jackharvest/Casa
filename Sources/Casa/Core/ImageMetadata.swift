import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// What the inspector shows: a file's facts, grouped and already formatted.
///
/// Read off the main thread — a header parse, never a decode — and handed to
/// the panel as plain strings, so the view has no opinions about EXIF.
struct ImageMetadata: Sendable {

    struct Row: Sendable, Equatable {
        let label: String
        let value: String
    }

    struct Section: Sendable, Equatable {
        let title: String
        let rows: [Row]
    }

    let sections: [Section]
    /// Where the photograph was taken, when the file says.
    let coordinate: (latitude: Double, longitude: Double)?

    static func read(_ url: URL) -> ImageMetadata {
        var sections = [fileSection(url)]
        var coordinate: (Double, Double)?

        if VectorSource.isPDF(url) {
            sections += documentSections(url)
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            sections.append(imageSection(properties, frames: CGImageSourceGetCount(source)))
            sections += cameraSections(properties)
            if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                let (section, place) = locationSection(gps)
                if let section { sections.append(section) }
                coordinate = place
            }
            if let section = descriptionSection(properties) { sections.append(section) }
        }

        return ImageMetadata(sections: sections.filter { !$0.rows.isEmpty }, coordinate: coordinate)
    }

    // MARK: - File

    private static func fileSection(_ url: URL) -> Section {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
        ])
        var rows = [Row(label: "Name", value: url.lastPathComponent)]
        if let kind = values?.localizedTypeDescription { rows.append(Row(label: "Kind", value: kind)) }
        if let bytes = values?.fileSize {
            rows.append(Row(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        if let created = values?.creationDate { rows.append(Row(label: "Created", value: format(created))) }
        if let modified = values?.contentModificationDate { rows.append(Row(label: "Modified", value: format(modified))) }
        rows.append(Row(label: "Where", value: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        return Section(title: "File", rows: rows)
    }

    // MARK: - Image

    private static func imageSection(_ properties: [CFString: Any], frames: Int) -> Section {
        var rows: [Row] = []
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let turned = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
            let (w, h) = turned ? (height, width) : (width, height)
            rows.append(Row(label: "Dimensions", value: "\(w) × \(h)"))
            let megapixels = Double(w * h) / 1_000_000
            if megapixels >= 0.1 {
                rows.append(Row(label: "Megapixels", value: String(format: megapixels >= 10 ? "%.0f MP" : "%.1f MP", megapixels)))
            }
        }
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
            rows.append(Row(label: "Resolution", value: "\(Int(dpi.rounded())) pixels/inch"))
        }
        if let model = properties[kCGImagePropertyColorModel] as? String {
            rows.append(Row(label: "Color model", value: model))
        }
        if let profile = properties[kCGImagePropertyProfileName] as? String {
            rows.append(Row(label: "Color profile", value: profile))
        }
        if let depth = properties[kCGImagePropertyDepth] as? Int {
            rows.append(Row(label: "Depth", value: "\(depth) bits per channel"))
        }
        if let alpha = properties[kCGImagePropertyHasAlpha] as? Bool {
            rows.append(Row(label: "Transparency", value: alpha ? "Yes" : "No"))
        }
        if frames > 1 { rows.append(Row(label: "Frames", value: "\(frames)")) }
        return Section(title: "Image", rows: rows)
    }

    private static func cameraSections(_ properties: [CFString: Any]) -> [Section] {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        var camera: [Row] = []
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            // Most cameras repeat the maker in the model; say it once.
            let name = make.map { model.localizedCaseInsensitiveContains($0) ? model : "\($0) \(model)" } ?? model
            camera.append(Row(label: "Camera", value: name))
        }
        if let lens = (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String {
            camera.append(Row(label: "Lens", value: lens))
        }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let date = exifDate(taken) {
            camera.append(Row(label: "Taken", value: format(date)))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String {
            camera.append(Row(label: "Software", value: software))
        }

        var exposure: [Row] = []
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            exposure.append(Row(label: "Shutter", value: shutter(time)))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
            exposure.append(Row(label: "Aperture", value: "ƒ/" + trimmed(aperture)))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            exposure.append(Row(label: "ISO", value: "\(iso)"))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            var text = trimmed(focal) + " mm"
            if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, equivalent > 0,
               abs(Double(equivalent) - focal) >= 1 {
                text += "  (\(equivalent) mm equivalent)"
            }
            exposure.append(Row(label: "Focal length", value: text))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
            exposure.append(Row(label: "Compensation", value: String(format: "%+.1f EV", bias)))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            exposure.append(Row(label: "Flash", value: flash & 1 == 1 ? "Fired" : "Off"))
        }

        return [Section(title: "Camera", rows: camera), Section(title: "Exposure", rows: exposure)]
    }

    private static func locationSection(_ gps: [CFString: Any]) -> (Section?, (Double, Double)?) {
        guard var latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              var longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return (nil, nil) }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }

        var rows = [
            Row(label: "Latitude", value: String(format: "%.5f° %@", abs(latitude), latitude >= 0 ? "N" : "S")),
            Row(label: "Longitude", value: String(format: "%.5f° %@", abs(longitude), longitude >= 0 ? "E" : "W")),
        ]
        if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
            let below = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
            rows.append(Row(label: "Altitude", value: "\(Int((below ? -altitude : altitude).rounded())) m"))
        }
        return (Section(title: "Location", rows: rows), (latitude, longitude))
    }

    private static func descriptionSection(_ properties: [CFString: Any]) -> Section? {
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var rows: [Row] = []
        if let title = iptc[kCGImagePropertyIPTCObjectName] as? String { rows.append(Row(label: "Title", value: title)) }
        if let caption = (iptc[kCGImagePropertyIPTCCaptionAbstract] ?? tiff[kCGImagePropertyTIFFImageDescription]) as? String,
           !caption.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(Row(label: "Caption", value: caption))
        }
        if let keywords = iptc[kCGImagePropertyIPTCKeywords] as? [String], !keywords.isEmpty {
            rows.append(Row(label: "Keywords", value: keywords.joined(separator: ", ")))
        }
        if let artist = (tiff[kCGImagePropertyTIFFArtist] ?? iptc[kCGImagePropertyIPTCByline]) as? String {
            rows.append(Row(label: "Author", value: artist))
        }
        if let copyright = (tiff[kCGImagePropertyTIFFCopyright] ?? iptc[kCGImagePropertyIPTCCopyrightNotice]) as? String {
            rows.append(Row(label: "Copyright", value: copyright))
        }
        return rows.isEmpty ? nil : Section(title: "Description", rows: rows)
    }

    // MARK: - Documents

    private static func documentSections(_ url: URL) -> [Section] {
        guard let document = PDFDocument(url: url) else { return [] }
        var rows = [Row(label: "Pages", value: "\(document.pageCount)")]
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .cropBox)
            let turned = page.rotation % 180 != 0
            let (w, h) = turned ? (box.height, box.width) : (box.width, box.height)
            rows.append(Row(label: "Page size", value: String(format: "%.1f × %.1f in", w / 72, h / 72)))
        }
        rows.append(Row(label: "PDF version", value: "\(document.majorVersion).\(document.minorVersion)"))
        if document.isEncrypted { rows.append(Row(label: "Security", value: "Password protected")) }

        var about: [Row] = []
        let attributes = document.documentAttributes ?? [:]
        func add(_ label: String, _ key: PDFDocumentAttribute) {
            if let value = attributes[key] as? String, !value.isEmpty { about.append(Row(label: label, value: value)) }
        }
        add("Title", .titleAttribute)
        add("Author", .authorAttribute)
        add("Subject", .subjectAttribute)
        add("Creator", .creatorAttribute)
        add("Producer", .producerAttribute)
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String], !keywords.isEmpty {
            about.append(Row(label: "Keywords", value: keywords.joined(separator: ", ")))
        }
        return [Section(title: "Document", rows: rows), Section(title: "Description", rows: about)]
    }

    // MARK: - Formatting

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// 0.004 s reads as 1/250, which is how every photographer says it.
    static func shutter(_ seconds: Double) -> String {
        if seconds >= 1 { return trimmed(seconds) + " s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
