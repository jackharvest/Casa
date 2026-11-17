import AppKit
import PDFKit

@MainActor
protocol PDFPaneDelegate: AnyObject {
    /// The page on screen changed, or the page count did.
    func pdfPaneDidChangePage(_ pane: PDFPane)
    /// Something was edited, or an edit was undone.
    func pdfPaneDidEdit(_ pane: PDFPane)
    /// An arrow key ran off the end of the document.
    func pdfPane(_ pane: PDFPane, requestsFileStep offset: Int)
    func pdfPaneDidPressEscape(_ pane: PDFPane)
    func pdfPaneRequestsPresentationToggle(_ pane: PDFPane)
    func pdfPaneCopyWithoutSelection(_ pane: PDFPane)
}

/// The document reader: a PDF with its pages down the side.
///
/// A PDF is the one thing Casa opens that is read rather than looked at, so
/// it does not go through the decode ladder at all. PDFKit draws it, which is
/// what makes its text selectable and searchable, its links live, its forms
/// fillable and every page reachable — none of which a bitmap of page one
/// could offer.
///
/// It has two bearings. Walked onto in a folder of photographs it *floats*:
/// one page at a time over the same veil as a photograph, turning with the
/// arrow keys. In a window it *reads*: continuous scrolling, a sidebar of
/// thumbnails, and a toolbar with search.
final class PDFPane: NSView {

    weak var delegate: PDFPaneDelegate?

    let pdfView = ReaderPDFView()
    private let sidebar = NSVisualEffectView()
    private let thumbnails = PDFThumbnailView()
    private let outlineScroll = NSScrollView()
    private let outlineView = NSOutlineView()
    private let sidebarSwitch = NSSegmentedControl(labels: ["Pages", "Contents"],
                                                   trackingMode: .selectOne, target: nil, action: nil)
    private var outlineSource: OutlineSource?
    private var sidebarWidth: NSLayoutConstraint!
    private var pdfLeading: NSLayoutConstraint!

    private(set) var url: URL?
    var document: PDFDocument? { pdfView.document }

    enum Bearing { case floating, reading }

    private(set) var bearing: Bearing = .floating

    /// How pages are laid out while reading. Remembered across documents.
    var readingMode: PDFDisplayMode = .singlePageContinuous {
        didSet { if bearing == .reading { pdfView.displayMode = readingMode; pdfView.autoScales = true } }
    }

    var showsSidebar = true {
        didSet { applySidebar() }
    }

    private static let sidebarEdge: CGFloat = 176

    // MARK: - Build

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        pdfView.pane = self
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        addSubview(pdfView)

        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebar)

        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 112, height: 146)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.backgroundColor = .clear
        thumbnails.allowsDragging = true
        thumbnails.allowsMultipleSelection = true
        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(thumbnails)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.rowSizeStyle = .small
        outlineView.target = self
        outlineView.action = #selector(outlineClicked(_:))
        outlineScroll.documentView = outlineView
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = true
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.isHidden = true
        sidebar.addSubview(outlineScroll)

        sidebarSwitch.target = self
        sidebarSwitch.action = #selector(sidebarSwitched(_:))
        sidebarSwitch.selectedSegment = 0
        sidebarSwitch.controlSize = .small
        sidebarSwitch.segmentDistribution = .fillEqually
        sidebarSwitch.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarSwitch)

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarEdge)
        pdfLeading = pdfView.leadingAnchor.constraint(equalTo: leadingAnchor)
        switchTop = thumbnails.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarWidth,

            sidebarSwitch.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            sidebarSwitch.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarSwitch.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            switchTop,
            thumbnails.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            thumbnails.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            thumbnails.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            outlineScroll.topAnchor.constraint(equalTo: thumbnails.topAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            outlineScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfLeading,
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        center.addObserver(self, selector: #selector(geometryChanged(_:)), name: .PDFViewScaleChanged, object: pdfView)
        center.addObserver(self, selector: #selector(geometryChanged(_:)), name: .PDFViewVisiblePagesChanged, object: pdfView)
        center.addObserver(self, selector: #selector(thumbnailsEdited(_:)),
                           name: .PDFThumbnailViewDocumentEdited, object: nil)
        center.addObserver(self, selector: #selector(annotationHit(_:)), name: .PDFViewAnnotationHit, object: pdfView)

        apply(.floating)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var switchTop: NSLayoutConstraint!

    // MARK: - Document

    /// Shows a document. Returns false if the file is not a readable PDF.
    @discardableResult
    func load(_ url: URL) -> Bool {
        unload()
        guard let document = PDFDocument(url: url) else { return false }
        self.url = url
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.goToFirstPage(nil)

        NotificationCenter.default.addObserver(self, selector: #selector(documentUnlocked(_:)),
                                               name: .PDFDocumentDidUnlock, object: document)
        observeScrolling()
        applyGround()
        rebuildOutline()
        return true
    }

    func unload() {
        pdfView.endTextEditing()
        pdfView.selectAnnotation(nil)
        clearFind()
        if let document {
            undoManager?.removeAllActions(withTarget: self)
            NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidUnlock, object: document)
        }
        pdfView.document = nil
        url = nil
        changeCount = 0
        formTouched = false
    }

    /// The file was renamed underneath an open document.
    func noteRenamed(to url: URL) { self.url = url }

    @objc private func documentUnlocked(_ notification: Notification) {
        rebuildOutline()
        delegate?.pdfPaneDidChangePage(self)
    }

    @objc private func pageChanged(_ notification: Notification) {
        delegate?.pdfPaneDidChangePage(self)
    }

    @objc private func geometryChanged(_ notification: Notification) {
        pdfView.syncRing()
    }

    /// PDFView scrolls an inner clip view and posts nothing useful when it
    /// does, so the selection outline listens to the clip view directly.
    private func observeScrolling() {
        guard let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    // MARK: - Bearing

    func apply(_ bearing: Bearing) {
        self.bearing = bearing
        switch bearing {
        case .floating:
            // One whole page, the way a photograph is one whole picture.
            pdfView.displayMode = .singlePage
            pdfView.backgroundColor = .clear
            pdfView.pageShadowsEnabled = true
        case .reading:
            pdfView.displayMode = readingMode
            pdfView.backgroundColor = NSColor(white: 0.14, alpha: 1)
            pdfView.pageShadowsEnabled = true
        }
        pdfView.autoScales = true
        applyGround()
        applySidebar()
    }

    /// PDFView's `backgroundColor` alone is not enough to see through it:
    /// the scroll view inside paints its own. Floating, both stand down so
    /// the page sits on the viewer's veil like a photograph does.
    private func applyGround() {
        let scroll = pdfView.documentView?.enclosingScrollView
        scroll?.drawsBackground = bearing == .reading
        scroll?.contentView.drawsBackground = bearing == .reading
    }

    private func applySidebar() {
        let visible = bearing == .reading && showsSidebar
        sidebar.isHidden = !visible
        pdfLeading.constant = visible ? Self.sidebarEdge : 0
        needsLayout = true
    }

    /// A window size that shows a whole page beside the sidebar.
    func preferredContentSize(maximum: CGSize) -> CGSize {
        guard let page = pdfView.currentPage ?? document?.page(at: 0) else {
            return CGSize(width: min(900, maximum.width), height: min(1000, maximum.height))
        }
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let aspect = turned ? box.height / box.width : box.width / box.height
        let height = maximum.height
        let side = showsSidebar ? Self.sidebarEdge : 0
        let width = min(maximum.width, (height * aspect).rounded() + side + 24)
        return CGSize(width: max(width, 560), height: height)
    }

    // MARK: - Sidebar

    private var hasOutline: Bool { (document?.outlineRoot?.numberOfChildren ?? 0) > 0 }

    private func rebuildOutline() {
        let root = hasOutline ? document?.outlineRoot : nil
        outlineSource = root.map(OutlineSource.init)
        outlineView.dataSource = outlineSource
        outlineView.delegate = outlineSource
        outlineView.reloadData()
        if root != nil { outlineView.expandItem(nil, expandChildren: false) }

        // The switch only appears for a document that has contents to show.
        sidebarSwitch.isHidden = root == nil
        switchTop.constant = root == nil ? 8 : 40
        if root == nil { sidebarSwitch.selectedSegment = 0 }
        sidebarSwitched(sidebarSwitch)
    }

    @objc private func sidebarSwitched(_ sender: NSSegmentedControl) {
        let contents = sender.selectedSegment == 1
        thumbnails.isHidden = contents
        outlineScroll.isHidden = !contents
    }

    @objc private func outlineClicked(_ sender: Any?) {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? PDFOutline else { return }
        if let destination = item.destination {
            pdfView.go(to: destination)
        } else if let action = item.action {
            pdfView.perform(action)
        }
    }

    // MARK: - Pages

    var pageCount: Int { document?.pageCount ?? 0 }

    var pageIndex: Int {
        guard let document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    /// Turns the page. Off either end of a floating document the step is
    /// passed on, so walking a folder goes *through* a PDF rather than
    /// getting stuck in it.
    func turnPage(by offset: Int) {
        guard let document, document.pageCount > 0 else { return }
        let target = pageIndex + offset
        if document.pageCount > 0, (0..<document.pageCount).contains(target) {
            go(toPage: target)
        } else if bearing == .floating {
            delegate?.pdfPane(self, requestsFileStep: offset < 0 ? -1 : 1)
        }
    }

    func go(toPage index: Int) {
        guard let document, let page = document.page(at: min(max(index, 0), document.pageCount - 1)) else { return }
        pdfView.go(to: page)
    }

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func zoomToFit() { pdfView.autoScales = true }
    func zoomToActualSize() { pdfView.scaleFactor = 1 }
    var isAtActualSize: Bool { abs(pdfView.scaleFactor - 1) < 0.005 }

    // MARK: - Edits

    /// Net edits since the last save. Undo takes it back down, so undoing
    /// everything leaves a document that does not ask to be saved.
    private var changeCount = 0
    var isDirty: Bool { changeCount != 0 }

    private func touched() {
        changeCount += undoManager?.isUndoing == true ? -1 : 1
        pdfView.syncRing()
        delegate?.pdfPaneDidEdit(self)
    }

    func add(_ annotation: PDFAnnotation, to page: PDFPage, actionName: String) {
        page.addAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { pane in
            pane.remove(annotation, from: page, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        touched()
    }

    func remove(_ annotation: PDFAnnotation, from page: PDFPage, actionName: String) {
        if pdfView.selectedAnnotation === annotation { pdfView.selectAnnotation(nil) }
        page.removeAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { pane in
            pane.add(annotation, to: page, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        touched()
    }

    func move(_ annotation: PDFAnnotation, to bounds: CGRect) {
        let previous = annotation.bounds
        annotation.bounds = bounds
        undoManager?.registerUndo(withTarget: self) { pane in pane.move(annotation, to: previous) }
        undoManager?.setActionName("Move")
        touched()
    }

    /// Swaps one annotation for another as a single step. Either may be nil:
    /// a new text box replaces nothing, and an emptied one is replaced by
    /// nothing.
    func replace(_ old: PDFAnnotation?, with new: PDFAnnotation?, on page: PDFPage, actionName: String) {
        guard old != nil || new != nil else { return }
        if let old { page.removeAnnotation(old) }
        if let new { page.addAnnotation(new) }
        undoManager?.registerUndo(withTarget: self) { pane in
            pane.pdfView.selectAnnotation(nil)
            pane.replace(new, with: old, on: page, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        touched()
    }

    func restyle(_ annotation: PDFAnnotation, on page: PDFPage, with style: MarkupStyle) {
        let previousColour = annotation.color
        let previousFontColour = annotation.fontColor
        let previousWidth = annotation.border?.lineWidth
        applyStyle(annotation, colour: style.color, fontColour: style.color,
                   width: 1.5 * style.weight.multiple)
        undoManager?.registerUndo(withTarget: self) { pane in
            pane.applyStyle(annotation, colour: previousColour, fontColour: previousFontColour, width: previousWidth)
            pane.touched()
        }
        undoManager?.setActionName("Change Style")
        touched()
    }

    private func applyStyle(_ annotation: PDFAnnotation, colour: NSColor, fontColour: NSColor?, width: CGFloat?) {
        if annotation.type == "FreeText" {
            annotation.fontColor = fontColour
        } else {
            annotation.color = colour
            if annotation.type == "Line", annotation.endLineStyle != .none { annotation.interiorColor = colour }
            if let width, let border = annotation.border, annotation.type != "Highlight" {
                border.lineWidth = width
                annotation.border = border
            }
        }
        if let page = annotation.page { pdfView.annotationsChanged(on: page) }
    }

    /// Highlights, underlines or strikes through the selected text.
    func mark(_ kind: MarkupBar.TextMark, colour: NSColor) -> Bool {
        guard let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty else { return false }
        let subtype: PDFAnnotationSubtype = switch kind {
        case .highlight: .highlight
        case .underline: .underline
        case .strikethrough: .strikeOut
        }

        undoManager?.beginUndoGrouping()
        // One annotation per line, so a selection that wraps is marked as
        // text rather than as one box around the whole paragraph.
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.color = colour
                add(annotation, to: page, actionName: kind.label)
            }
        }
        undoManager?.endUndoGrouping()
        pdfView.clearSelection()
        return true
    }

    /// Turns the page on screen, in the document rather than just in view.
    func rotateCurrentPage(by quarterTurns: Int) {
        guard let page = pdfView.currentPage else { return }
        rotate(page, by: quarterTurns)
    }

    private func rotate(_ page: PDFPage, by quarterTurns: Int) {
        page.rotation = ((page.rotation + quarterTurns * 90) % 360 + 360) % 360
        undoManager?.registerUndo(withTarget: self) { pane in pane.rotate(page, by: -quarterTurns) }
        undoManager?.setActionName("Rotate Page")
        pdfView.layoutDocumentView()
        touched()
    }

    var canDeletePage: Bool { pageCount > 1 }

    func deleteCurrentPage() {
        guard canDeletePage, let document, let page = pdfView.currentPage else { return }
        removePage(at: document.index(for: page))
    }

    private func removePage(at index: Int) {
        guard let document, let page = document.page(at: index) else { return }
        document.removePage(at: index)
        undoManager?.registerUndo(withTarget: self) { pane in pane.insertPage(page, at: index) }
        undoManager?.setActionName("Delete Page")
        touched()
        delegate?.pdfPaneDidChangePage(self)
    }

    private func insertPage(_ page: PDFPage, at index: Int) {
        guard let document else { return }
        document.insert(page, at: min(index, document.pageCount))
        undoManager?.registerUndo(withTarget: self) { pane in pane.removePage(at: min(index, pane.pageCount - 1)) }
        undoManager?.setActionName("Insert Page")
        pdfView.go(to: page)
        touched()
        delegate?.pdfPaneDidChangePage(self)
    }

    /// Adds another file's pages after the current one. A PDF contributes all
    /// of its pages; an image becomes a page of its own.
    func insertPages(from source: URL) -> Bool {
        var pages: [PDFPage] = []
        if let other = PDFDocument(url: source) {
            for index in 0..<other.pageCount {
                // Copied, because a page can belong to only one document.
                if let page = other.page(at: index)?.copy() as? PDFPage { pages.append(page) }
            }
        } else if let image = NSImage(contentsOf: source), let page = PDFPage(image: image) {
            pages.append(page)
        }
        guard !pages.isEmpty else { return false }

        undoManager?.beginUndoGrouping()
        var slot = pageCount == 0 ? 0 : pageIndex + 1
        for page in pages {
            insertPage(page, at: slot)
            slot += 1
        }
        undoManager?.endUndoGrouping()
        // Left on the last page added, so a second file inserted straight
        // after this one lands behind it rather than in the middle of it.
        if let last = pages.last { pdfView.go(to: last) }
        return true
    }

    func insertBlankPage() {
        let page = PDFPage()
        let size = pdfView.currentPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        page.setBounds(size, for: .mediaBox)
        insertPage(page, at: pageCount == 0 ? 0 : pageIndex + 1)
    }

    /// PDFKit fills in form fields itself and tells nobody. A click on one
    /// is the only sign there is, so that is taken as an edit: asking to
    /// save a form that was only clicked is a far smaller sin than silently
    /// dropping one that was filled in.
    @objc private func annotationHit(_ notification: Notification) {
        guard let hit = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
              hit.type == "Widget", !formTouched else { return }
        formTouched = true
        changeCount += 1
        delegate?.pdfPaneDidEdit(self)
    }

    private var formTouched = false

    /// Dragging in the thumbnail rail reorders pages directly.
    @objc private func thumbnailsEdited(_ notification: Notification) {
        guard (notification.object as? PDFThumbnailView) === thumbnails else { return }
        changeCount += 1
        delegate?.pdfPaneDidEdit(self)
        delegate?.pdfPaneDidChangePage(self)
    }

    // MARK: - Find

    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex = -1

    /// Finds every occurrence and shows the first at or after the page on
    /// screen. Returns how many there were.
    @discardableResult
    func find(_ text: String) -> Int {
        clearFind()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let document else { return 0 }

        matches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches { match.color = NSColor(srgbRed: 1, green: 0.86, blue: 0.2, alpha: 1) }
        pdfView.highlightedSelections = matches
        guard !matches.isEmpty else { return 0 }

        let current = pageIndex
        matchIndex = matches.firstIndex { match in
            match.pages.first.map { document.index(for: $0) >= current } ?? false
        } ?? 0
        showMatch()
        return matches.count
    }

    func findStep(_ offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = ((matchIndex + offset) % matches.count + matches.count) % matches.count
        showMatch()
    }

    private func showMatch() {
        let match = matches[matchIndex]
        pdfView.setCurrentSelection(match, animate: true)
        pdfView.scrollSelectionToVisible(nil)
        delegate?.pdfPaneDidChangePage(self)
    }

    func clearFind() {
        guard !matches.isEmpty || pdfView.highlightedSelections != nil else { return }
        matches = []
        matchIndex = -1
        pdfView.highlightedSelections = nil
    }

    // MARK: - Writing

    enum Failure: LocalizedError {
        case writeFailed

        var errorDescription: String? { "The document couldn't be saved." }
    }

    struct WriteOptions {
        var password: String?
        /// Recompress images for the screen. Much smaller, visibly softer in
        /// print.
        var reducesFileSize = false
    }

    func save() throws {
        guard let url else { return }
        try write(to: url, options: WriteOptions())
        changeCount = 0
        formTouched = false
        delegate?.pdfPaneDidEdit(self)
    }

    func write(to destination: URL, options: WriteOptions) throws {
        guard let document else { throw Failure.writeFailed }
        pdfView.endTextEditing()

        var flags: [PDFDocumentWriteOption: Any] = [:]
        if let password = options.password, !password.isEmpty {
            flags[.userPasswordOption] = password
            flags[.ownerPasswordOption] = password
        }
        if options.reducesFileSize {
            flags[.optimizeImagesForScreenOption] = true
            flags[.saveImagesAsJPEGOption] = true
        }

        // PDFKit reads pages from the original file as it writes, so the
        // document is written beside the destination and swapped in whole.
        // Writing straight over the file being read would cut the branch
        // we are sitting on.
        let scratch = destination.deletingLastPathComponent()
            .appendingPathComponent(".casa-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard document.write(to: scratch, withOptions: flags) else { throw Failure.writeFailed }

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
        } else {
            try FileManager.default.moveItem(at: scratch, to: destination)
        }
    }

    /// The current page as a bitmap, for exporting a page as an image.
    func currentPageImage(pixelsPerInch: CGFloat = 200) -> CGImage? {
        guard let page = pdfView.currentPage else { return nil }
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let points = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = pixelsPerInch / 72
        let width = Int((points.width * scale).rounded()), height = Int((points.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 120_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    func printOperation() -> NSPrintOperation? {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        return document?.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true)
    }
}

/// Feeds a PDF's table of contents to the sidebar's outline view.
@MainActor
private final class OutlineSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let root: PDFOutline

    init(root: PDFOutline) { self.root = root }

    private func node(_ item: Any?) -> PDFOutline { (item as? PDFOutline) ?? root }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item).numberOfChildren
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).child(at: index) ?? root
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        node(item).numberOfChildren > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            cell.identifier = identifier
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = node(item).label ?? ""
        cell.toolTip = node(item).label
        return cell
    }
}
