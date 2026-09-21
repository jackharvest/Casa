import AppKit
import UniformTypeIdentifiers

/// Reads and sets which app opens which file types.
///
/// This is the one thing a photo viewer has to get right that has nothing to do
/// with photographs: until Casa is the default handler, every double-click
/// still goes to Preview and the app might as well not be installed.
@MainActor
enum DefaultHandler {

    /// A group of types offered together, because nobody wants to make this
    /// decision eleven times.
    struct Group: Identifiable {
        let id: String
        let title: String
        let detail: String
        /// SF Symbol for the row's badge.
        let symbol: String
        /// Badge tint, taken from the icon's palette so the window and the app
        /// icon read as the same product.
        let tint: NSColor
        let types: [UTType]
        /// Whether to claim this group by default.
        let recommended: Bool
    }

    static let groups: [Group] = [
        Group(
            id: "photos",
            title: "Photos",
            detail: "JPEG, HEIC, PNG, GIF, TIFF, WebP, BMP, AVIF",
            symbol: "photo",
            tint: NSColor(red: 0.200, green: 0.510, blue: 0.867, alpha: 1),
            types: [.jpeg, .heic, .heif, .png, .gif, .tiff, .webP, .bmp, .init("public.avif")]
                .compactMap { $0 },
            recommended: true
        ),
        Group(
            id: "raw",
            title: "Camera RAW",
            detail: "CR2, CR3, NEF, ARW, RAF, ORF, RW2, DNG and the rest",
            symbol: "camera.aperture",
            tint: NSColor(red: 0.302, green: 0.741, blue: 0.267, alpha: 1),
            types: [UTType("public.camera-raw-image"), .init("com.adobe.raw-image")]
                .compactMap { $0 },
            recommended: true
        ),
        Group(
            id: "vector",
            title: "SVG",
            detail: "Re-rendered as you zoom, so it stays sharp",
            symbol: "scribble.variable",
            tint: NSColor(red: 0.180, green: 0.718, blue: 0.553, alpha: 1),
            types: [UTType.svg].compactMap { $0 },
            recommended: true
        ),
        Group(
            id: "pdf",
            title: "PDF",
            detail: "Casa shows page one. You probably want Preview for documents",
            symbol: "doc.richtext",
            tint: NSColor(red: 0.898, green: 0.600, blue: 0.114, alpha: 1),
            types: [UTType.pdf],
            recommended: false
        ),
    ]

    /// Display name of whatever currently opens `type`, or nil if nothing does.
    static func currentHandlerName(for type: UTType) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// Whether Casa already handles every type in a group.
    static func owns(_ group: Group) -> Bool {
        let us = Bundle.main.bundleURL.standardizedFileURL
        return group.types.allSatisfy {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL == us
        }
    }

    /// A one-line summary of who handles a group right now.
    static func summary(for group: Group) -> String {
        if owns(group) { return "Casa" }
        let names = Set(group.types.compactMap { currentHandlerName(for: $0) })
        switch names.count {
        case 0: return "Nothing"
        case 1: return names.first!
        default: return "\(names.count) different apps"
        }
    }

    enum Outcome {
        case claimed(Int)
        case partiallyClaimed(claimed: Int, failed: Int)
        case failed(String)
    }

    /// Claims every type in the given groups.
    ///
    /// macOS may show its own confirmation; that is the system's call, not
    /// ours, and is the correct behaviour — changing a default handler is
    /// exactly the kind of thing the user should be able to veto.
    static func claim(_ groups: [Group],
                      onProgress: @MainActor (Int, Int) -> Void = { _, _ in }) async -> Outcome {
        let us = Bundle.main.bundleURL
        var claimed = 0
        var failed = 0
        var firstError: String?

        let all = groups.flatMap(\.types)
        for (index, type) in all.enumerated() {
            onProgress(index + 1, all.count)
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: us, toOpen: type)
                claimed += 1
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
                Log.update.error("could not claim \(type.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if claimed == 0 {
            return .failed(firstError ?? "macOS declined to change the default app.")
        }
        return failed == 0 ? .claimed(claimed) : .partiallyClaimed(claimed: claimed, failed: failed)
    }

    /// The manual route, for when the API is refused. There is no System
    /// Settings pane for per-type image handlers — it lives in Finder's Get
    /// Info — so the honest fallback is to put the user in front of a file
    /// with the instructions rather than to open a pane that cannot help.
    static func explainManualRoute() {
        let alert = NSAlert()
        alert.messageText = "Set Casa as the default by hand"
        alert.informativeText = """
            macOS wouldn’t let Casa change the setting for you.

            In Finder, right-click any photo → Get Info → Open with → Casa → \
            Change All…

            That applies to every file of that type.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reveal Casa in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }
}
