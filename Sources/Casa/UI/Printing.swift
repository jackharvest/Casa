import AppKit

/// Puts a photograph on paper.
///
/// The paper is turned to suit the picture, and the picture is scaled to the
/// printable area — the two things Preview makes you find in a dialog before
/// a landscape photo stops coming out as a postage stamp on a portrait sheet.
@MainActor
enum Printing {

    static func operation(for image: CGImage, title: String) -> NSPrintOperation {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.orientation = image.width > image.height ? .landscape : .portrait
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        let view = PrintImageView(image: image, info: info)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.printPanel.options.insert([.showsOrientation, .showsPaperSize, .showsScaling])
        operation.printPanel.addAccessoryController(PrintOptionsController(view: view))
        return operation
    }
}

/// One page, holding one picture.
final class PrintImageView: NSView {

    enum Scaling: Int {
        /// The whole picture, as large as the paper allows.
        case fit
        /// Cover the printable area, cropping whatever overhangs.
        case fill
        /// At the resolution the file declares, or 72 pixels per inch.
        case actual
    }

    private let image: CGImage
    private let info: NSPrintInfo
    var scaling: Scaling = .fit { didSet { needsDisplay = true } }

    init(image: CGImage, info: NSPrintInfo) {
        self.image = image
        self.info = info
        super.init(frame: .zero)
        resizeToPage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The printable area of the current paper, re-read on every pass because
    /// the user can change paper and orientation in the panel.
    private func resizeToPage() {
        let paper = info.paperSize
        let size = CGSize(width: paper.width - info.leftMargin - info.rightMargin,
                          height: paper.height - info.topMargin - info.bottomMargin)
        if frame.size != size { setFrameSize(size) }
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        resizeToPage()
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let picture = CGSize(width: image.width, height: image.height)

        let scale: CGFloat = switch scaling {
        case .fit: min(bounds.width / picture.width, bounds.height / picture.height)
        case .fill: max(bounds.width / picture.width, bounds.height / picture.height)
        case .actual: 1
        }
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        let target = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)

        context.saveGState()
        context.clip(to: bounds)
        context.interpolationQuality = .high
        context.draw(image, in: target)
        context.restoreGState()
    }
}

/// The "how big" choice in the print panel.
final class PrintOptionsController: NSViewController, NSPrintPanelAccessorizing {

    private let target: PrintImageView

    /// KVO-observed by the panel: changing it redraws the preview.
    @objc dynamic var scaling = 0 {
        didSet { target.scaling = PrintImageView.Scaling(rawValue: scaling) ?? .fit }
    }

    init(view: PrintImageView) {
        self.target = view
        super.init(nibName: nil, bundle: nil)
        title = "Casa"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let label = NSTextField(labelWithString: "Size:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Scale to Fit", "Fill the Page", "Actual Size"])
        popup.target = self
        popup.action = #selector(choose(_:))

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        view = row
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        scaling = sender.indexOfSelectedItem
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["scaling"] }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let names = ["Scale to Fit", "Fill the Page", "Actual Size"]
        return [[.itemName: "Size", .itemDescription: names[min(max(scaling, 0), 2)]]]
    }
}
