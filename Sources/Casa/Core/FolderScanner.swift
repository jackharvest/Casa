import Foundation

/// How the sibling list is ordered.
///
/// Trait 07 — inheriting Finder's sort — is the wedge, and it is deliberately
/// modeled as one more case here rather than bolted on later. Everything
/// downstream consumes an ordered `[URL]` and does not care where the order
/// came from, so adding the Finder-derived case is a change in exactly one
/// place.
enum SortOrder: String, Sendable, CaseIterable {
    /// Finder's default: natural ordering, so `IMG_2.jpg` precedes `IMG_10.jpg`.
    case name
    case dateModified
    case dateCreated
    case size

    var displayName: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .size: "Size"
        }
    }
}

/// Enumerates the images that live alongside the one the user opened.
///
/// Runs off the main actor. On a folder of a few thousand files this is single
/// digit milliseconds, but it is still I/O and must never sit between the user
/// double-clicking and the first pixel appearing — see `Session` for the
/// ordering that guarantees that.
struct FolderScanner: Sendable {

    struct Result: Sendable {
        let urls: [URL]
        /// Index of the URL the user actually opened, or 0 if it vanished
        /// between the double-click and the scan.
        let startIndex: Int
    }

    /// Lists decodable siblings of `url`, sorted, and locates `url` within them.
    static func scan(siblingsOf url: URL,
                     sortedBy order: SortOrder,
                     ascending: Bool = true) -> Result {
        let directory = url.deletingLastPathComponent()

        let keys: [URLResourceKey] = [
            .contentTypeKey, .contentModificationDateKey,
            .creationDateKey, .fileSizeKey, .isRegularFileKey,
        ]

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        // Normalized to the same form `Session` uses, so a URL is one key
        // everywhere in the app.
        var images = contents
            .filter { SupportedTypes.canOpen($0) }
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
        images = sort(images, by: order, ascending: ascending)

        // The opened file may not be in the list — it can be hidden, or a type
        // ImageIO declined. Show it anyway rather than silently substituting a
        // different photo, which would be baffling.
        let index: Int
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if let found = images.firstIndex(of: target) {
            index = found
        } else {
            images.insert(target, at: 0)
            index = 0
        }

        Log.folder.debug("Scanned \(images.count, privacy: .public) images in \(directory.lastPathComponent, privacy: .private)")
        return Result(urls: images, startIndex: index)
    }

    private static func sort(_ urls: [URL], by order: SortOrder, ascending: Bool) -> [URL] {
        let sorted: [URL]
        switch order {
        case .name:
            // `localizedStandardCompare` is what Finder itself uses: natural
            // number runs, case- and diacritic-insensitive, locale-aware.
            sorted = urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        case .dateModified:
            sorted = urls.sorted { date($0, .contentModificationDateKey) < date($1, .contentModificationDateKey) }
        case .dateCreated:
            sorted = urls.sorted { date($0, .creationDateKey) < date($1, .creationDateKey) }
        case .size:
            sorted = urls.sorted { size($0) < size($1) }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private static func date(_ url: URL, _ key: URLResourceKey) -> Date {
        let values = try? url.resourceValues(forKeys: [key])
        return (key == .creationDateKey ? values?.creationDate : values?.contentModificationDate) ?? .distantPast
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
