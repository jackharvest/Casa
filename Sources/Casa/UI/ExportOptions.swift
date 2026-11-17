import AppKit
import UniformTypeIdentifiers

/// The format, quality and — for documents — protection choices under the
/// save panel when exporting.
///
/// One row of controls that changes with the format: a quality slider only
/// for formats that have such a thing, a password only for a PDF.
@MainActor
final class ExportOptions: NSObject {

    let view: NSView

    /// The image format chosen, or nil for "a PDF document".
    private(set) var format: ImageExporter.Format?
    var quality: Double { qualitySlider.doubleValue }
    var password: String? {
        let text = passwordField.stringValue
        return text.isEmpty ? nil : text
    }
    var reducesFileSize: Bool { reduceBox.state == .on }

    private weak var panel: NSSavePanel?
    private let isDocument: Bool
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 0.9, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality:")
    private let qualityRow: NSStackView
    private let passwordField = NSSecureTextField()
    private let reduceBox = NSButton(checkboxWithTitle: "Reduce file size", target: nil, action: nil)
    private let documentRows: NSStackView

    /// - Parameters:
    ///   - isDocument: exporting a PDF, which can stay a PDF or have its
    ///     current page written out as an image.
    ///   - preferred: the image format to start on.
    init(panel: NSSavePanel, isDocument: Bool, preferred: ImageExporter.Format?) {
        self.panel = panel
        self.isDocument = isDocument

        let formatLabel = NSTextField(labelWithString: "Format:")
        let formatRow = NSStackView(views: [formatLabel, popup])

        qualitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let least = NSTextField(labelWithString: "Least")
        let best = NSTextField(labelWithString: "Best")
        for label in [least, best] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        qualityRow = NSStackView(views: [qualityLabel, least, qualitySlider, best])

        passwordField.placeholderString = "None"
        passwordField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let passwordRow = NSStackView(views: [NSTextField(labelWithString: "Password:"), passwordField])
        reduceBox.toolTip = "Recompresses images for the screen. Smaller, and softer in print."
        documentRows = NSStackView(views: [passwordRow, reduceBox])
        documentRows.orientation = .vertical
        documentRows.alignment = .leading

        let stack = NSStackView(views: [formatRow, qualityRow, documentRows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        view = stack

        super.init()

        if isDocument {
            popup.addItem(withTitle: "PDF")
            popup.menu?.addItem(.separator())
        }
        for (index, entry) in ImageExporter.formats.enumerated() {
            let title = isDocument ? "\(entry.name) (this page)" : entry.name
            popup.addItem(withTitle: title)
            popup.lastItem?.tag = index + 1
        }
        popup.target = self
        popup.action = #selector(formatChanged(_:))

        if !isDocument {
            format = preferred ?? ImageExporter.formats.first
            if let format, let index = ImageExporter.formats.firstIndex(of: format) {
                popup.selectItem(withTag: index + 1)
            }
        }
        sync()
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        let tag = sender.selectedItem?.tag ?? 0
        format = tag > 0 ? ImageExporter.formats[tag - 1] : nil
        sync()
    }

    private func sync() {
        qualityRow.isHidden = !(format?.isLossy ?? false)
        documentRows.isHidden = !(isDocument && format == nil)
        // Setting the type is what makes the panel rewrite the extension in
        // the name field as the format changes.
        panel?.allowedContentTypes = [format?.type ?? .pdf]
    }
}
