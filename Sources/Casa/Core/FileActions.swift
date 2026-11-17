import AppKit
import UniformTypeIdentifiers

/// The things a viewer does to a file other than look at it: trash it, rename
/// it, copy it, and make one out of the clipboard.
///
/// Each returns what the caller needs to undo it, and none of them touch the
/// session — the controller decides what the list looks like afterwards.
enum FileActions {

    enum Failure: LocalizedError {
        case nameTaken(String)
        case emptyName
        case nothingToPaste

        var errorDescription: String? {
            switch self {
            case .nameTaken(let name): "“\(name)” already exists in this folder."
            case .emptyName: "A file needs a name."
            case .nothingToPaste: "There's no image on the clipboard."
            }
        }
    }

    /// Moves a file to the Trash and returns where it landed, so the move can
    /// be reversed.
    static func trash(_ url: URL) throws -> URL {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        return (landed as URL?) ?? url
    }

    /// Puts a trashed file back where it was.
    static func restore(_ trashed: URL, to original: URL) throws {
        guard !FileManager.default.fileExists(atPath: original.path) else {
            throw Failure.nameTaken(original.lastPathComponent)
        }
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    /// Renames in place. The extension is kept when the new name leaves it
    /// off, because dropping it by accident turns a photograph into a blank
    /// document icon.
    static func rename(_ url: URL, to proposed: String) throws -> URL {
        var name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: ":")
        guard !name.isEmpty, name != "." else { throw Failure.emptyName }
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty {
            name += "." + url.pathExtension
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination.path != url.path else { return url }
        // A case-only rename is the same file on a case-insensitive volume.
        let sameFile = destination.path.lowercased() == url.path.lowercased()
        guard sameFile || !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.nameTaken(name)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Copies a file beside itself as "name copy", the way Finder does.
    static func duplicate(_ url: URL) throws -> URL {
        let destination = unusedURL(for: url, suffix: " copy")
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// `photo.jpg` → `photo copy.jpg`, `photo copy 2.jpg`, … — the first that
    /// does not exist yet.
    static func unusedURL(for url: URL, suffix: String) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent + suffix

        func candidate(_ counter: Int) -> URL {
            let name = counter == 1 ? base : "\(base) \(counter)"
            return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        }
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate(counter).path) { counter += 1 }
        return candidate(counter)
    }

    /// Copies what makes a file *that* file to its replacement: when it was
    /// created, and the Finder tags on it.
    static func carryIdentity(from original: URL, to replacement: URL) {
        guard let values = try? original.resourceValues(forKeys: [.creationDateKey, .tagNamesKey]) else { return }
        if let created = values.creationDate {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: replacement.path)
        }
        if let tags = values.tagNames, !tags.isEmpty {
            try? (replacement as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
    }

    // MARK: - Clipboard

    /// Where clipboard images are written so they can be opened like any
    /// other file. Emptied of anything older than a week on each use.
    private static var clipboardDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.jackharvest.casa")
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    /// Whether a file is one of ours from the clipboard, and so has no real
    /// home to be saved back to.
    static func isClipboardFile(_ url: URL) -> Bool {
        let home = clipboardDirectory
        return url.path.hasPrefix(home.resolvingSymlinksInPath().path) || url.path.hasPrefix(home.path)
    }

    /// Writes the clipboard's image to a file and returns it.
    ///
    /// A copied *file* is returned as itself — pasting a photo you copied in
    /// Finder should open that photo, not a re-encoded twin of it.
    @MainActor
    static func fileFromClipboard() throws -> URL {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first(where: SupportedTypes.canOpen) {
            return first
        }

        let directory = clipboardDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sweep(directory)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Clipboard \(formatter.string(from: Date()))"

        if let pdf = pasteboard.data(forType: .pdf) {
            let url = directory.appendingPathComponent("\(name).pdf")
            try pdf.write(to: url)
            return url
        }
        if let png = pasteboard.data(forType: .png) {
            let url = directory.appendingPathComponent("\(name).png")
            try png.write(to: url)
            return url
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let url = directory.appendingPathComponent("\(name).png")
            try png.write(to: url)
            return url
        }
        throw Failure.nothingToPaste
    }

    private static func sweep(_ directory: URL) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
