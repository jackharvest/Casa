import AppKit
import PDFKit

/// The document side of the viewer: showing a PDF, and everything that can
/// be done to one.
extension ViewerController: PDFPaneDelegate {

    var isDocumentActive: Bool { session?.currentIsDocument ?? false }

    private var isWindowed: Bool { (view.window as? ViewerWindow)?.presentation == .windowed }

    /// "Page 3 of 40", plus where you are among the search results.
    var documentPositionDescription: String {
        guard let pane = pdfPaneIfLoaded, pane.pageCount > 0 else { return "" }
        var text = "Page \(pane.pageIndex + 1) of \(pane.pageCount)"
        if !pane.matches.isEmpty {
            text += "  ·  \(pane.matchIndex + 1) of \(pane.matches.count) found"
        } else if !lastQuery.isEmpty {
            text += "  ·  Not found"
        }
        return text
    }

    func makePDFPane() -> PDFPane {
        let pane = PDFPane()
        pane.delegate = self
        pane.isHidden = true
        view.addSubview(pane, positioned: .above, relativeTo: canvas)
        let edges = (top: pane.topAnchor.constraint(equalTo: view.topAnchor),
                     bottom: pane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                     leading: pane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                     trailing: pane.trailingAnchor.constraint(equalTo: view.trailingAnchor))
        NSLayoutConstraint.activate([edges.top, edges.bottom, edges.leading, edges.trailing])
        pdfEdges = edges
        pdfPaneIfLoaded = pane
        return pane
    }

    // MARK: - Showing and hiding the reader

    /// Brings the reader up when the current file is a PDF and puts it away
    /// when it is not. Called on every navigation.
    func syncDocumentMode() {
        guard isDocumentActive, let url = session.currentURL else {
            if let pane = pdfPaneIfLoaded, !pane.isHidden {
                endDocumentMarkup()
                pane.unload()
                pane.isHidden = true
                canvas.isHidden = false
                lastQuery = ""
                view.window?.makeFirstResponder(canvas)
            }
            applyReaderFurniture()
            return
        }

        let pane = pdfPane
        if pane.url != url {
            endDocumentMarkup()
            lastQuery = ""
            if !pane.load(url) { announce("Can’t display this file") }
        }
        pane.isHidden = false
        canvas.isHidden = true
        applyReaderFurniture()

        // Unless the user is typing in the search field, keys go to the page.
        if !(view.window?.firstResponder is NSText) {
            view.window?.makeFirstResponder(pane.pdfView)
        }
        // There is no bitmap to wait for; the document is what opens the
        // window.
        (view.window as? ViewerWindow)?.revealIfWaiting()
    }

    /// The reader's sidebar and window toolbar exist only for a document in
    /// a window. Everywhere else the floating chrome does the job.
    private func applyReaderFurniture() {
        guard let window = view.window as? ViewerWindow else { return }
        let reading = isDocumentActive && isWindowed

        if let pane = pdfPaneIfLoaded {
            let bearing: PDFPane.Bearing = reading ? .reading : .floating
            if pane.bearing != bearing { pane.apply(bearing) }
        }

        if reading {
            let reader = readerToolbar ?? ReaderToolbar(target: self)
            readerToolbar = reader
            if window.toolbar !== reader.toolbar {
                window.toolbar = reader.toolbar
                window.toolbarStyle = .unified
            }
        } else if window.toolbar != nil {
            window.toolbar = nil
        }
        syncChromeSuspension()
        layoutDocumentPane()
    }

    /// The chrome stands down while a tool is up, and for a document being
    /// read in a window, which has a real toolbar instead.
    func syncChromeSuspension() {
        chrome.isSuspended = (isDocumentActive && isWindowed) || activeTool != nil || toolBar != nil
    }

    /// Floating, the page sits inside the same margins a photograph does.
    /// In a window it fills the frame.
    func layoutDocumentPane() {
        guard let edges = pdfEdges else { return }
        let panel = inspector != nil ? SidePanel.preferredWidth + ChromeMetrics.spacing(3) : 0
        if isWindowed {
            edges.top.constant = 0
            edges.bottom.constant = toolBar != nil ? -toolBarInset : 0
            edges.leading.constant = 0
            edges.trailing.constant = -panel
        } else {
            let margin = ChromeMetrics.spacing(3)
            edges.top.constant = chrome.topInset + margin
            edges.bottom.constant = -(chrome.bottomInset + margin)
            edges.leading.constant = margin
            edges.trailing.constant = -(margin + panel)
        }
    }

    // MARK: - PDFPaneDelegate

    func pdfPaneDidChangePage(_ pane: PDFPane) {
        updateNavigationControls()
        updateWindowTitle()
        if !chrome.isShowingNote {
            chrome.update(filename: session.currentURL?.lastPathComponent ?? "", detail: detailDescription)
        }
    }

    func pdfPaneDidEdit(_ pane: PDFPane) {
        updateWindowTitle()
        chrome.update(filename: session.currentURL?.lastPathComponent ?? "", detail: detailDescription)
    }

    func pdfPane(_ pane: PDFPane, requestsFileStep offset: Int) {
        step(by: offset)
    }

    func pdfPaneDidPressEscape(_ pane: PDFPane) {
        if toolBar is MarkupBar {
            endDocumentMarkup()
        } else if inspector != nil {
            toggleInspector(nil)
        } else {
            dismissWindow()
        }
    }

    func pdfPaneRequestsPresentationToggle(_ pane: PDFPane) {
        canvasDidRequestWindowedToggle(canvas)
    }

    func pdfPaneCopyWithoutSelection(_ pane: PDFPane) {
        copyImage(nil)
    }

    // MARK: - View

    @objc func toggleSidebar(_ sender: Any?) {
        guard isDocumentActive else { return }
        if !isWindowed {
            // The sidebar lives in the reading window; asking for it is
            // asking for that.
            pdfPane.showsSidebar = true
            setPresentation(.windowed, animated: !Accommodations.current.reduceMotion)
        } else {
            pdfPane.showsSidebar.toggle()
        }
    }

    /// Single page, continuous, or two-up. The menu item's tag is the
    /// `PDFDisplayMode`.
    @objc func setPageLayout(_ sender: NSMenuItem) {
        guard let mode = PDFDisplayMode(rawValue: sender.tag) else { return }
        pdfPane.readingMode = mode
        if !isWindowed { setPresentation(.windowed, animated: !Accommodations.current.reduceMotion) }
    }

    // MARK: - Go

    @objc func goToFirstPage(_ sender: Any?) { pdfPane.go(toPage: 0) }
    @objc func goToLastPage(_ sender: Any?) { pdfPane.go(toPage: pdfPane.pageCount - 1) }

    @objc func goToPage(_ sender: Any?) {
        guard let window = view.window, pdfPane.pageCount > 0 else { return }
        let field = NSTextField(string: "\(pdfPane.pageIndex + 1)")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        field.alignment = .center

        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = "1 to \(pdfPane.pageCount)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.pdfPane.go(toPage: field.integerValue - 1)
        }
    }

    // MARK: - Find

    @objc func find(_ sender: Any?) {
        guard isDocumentActive else { return }
        // Search lives in the reader's toolbar, so finding means reading.
        if !isWindowed { setPresentation(.windowed, animated: false) }
        readerToolbar?.beginSearch()
    }

    /// The search field fires on typing and again on Return. The same text a
    /// second time means "next", which is what Return in a search field has
    /// meant since Safari.
    @objc func searchFieldChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if query == lastQuery, !pdfPane.matches.isEmpty {
            pdfPane.findStep(1)
        } else {
            lastQuery = query
            pdfPane.find(query)
        }
        updateWindowTitle()
    }

    @objc func findNext(_ sender: Any?) {
        pdfPane.findStep(1)
        updateWindowTitle()
    }

    @objc func findPrevious(_ sender: Any?) {
        pdfPane.findStep(-1)
        updateWindowTitle()
    }

    // MARK: - Marking up

    private static let highlighterYellow = NSColor(srgbRed: 1, green: 0.86, blue: 0.2, alpha: 1)

    @objc func highlightSelection(_ sender: Any?) { markSelection(.highlight, colour: Self.highlighterYellow) }
    @objc func underlineSelection(_ sender: Any?) { markSelection(.underline, colour: MarkupStyle.palette[0].color) }
    @objc func strikeThroughSelection(_ sender: Any?) { markSelection(.strikethrough, colour: MarkupStyle.palette[0].color) }

    func markSelection(_ mark: MarkupBar.TextMark, colour: NSColor) {
        guard isDocumentActive else { return }
        // Red highlighter ink is unreadable; a highlight asked for with the
        // default red in hand comes out yellow.
        let ink = mark == .highlight && colour == MarkupStyle.palette[0].color ? Self.highlighterYellow : colour
        if !pdfPane.mark(mark, colour: ink) {
            announce("Select some text first")
            NSSound.beep()
        }
    }

    func toggleDocumentMarkup() {
        if toolBar is MarkupBar {
            endDocumentMarkup()
            return
        }
        let bar = MarkupBar(flavor: .document)
        bar.delegate = self
        pdfPane.pdfView.tool = bar.tool
        pdfPane.pdfView.style = bar.style
        install(bar)
        layoutDocumentPane()
    }

    /// Puts the document's drawing tools away. Unlike a photograph's marks,
    /// annotations are already part of the document, so there is nothing to
    /// flatten.
    func endDocumentMarkup() {
        guard toolBar is MarkupBar, markupView == nil else { return }
        pdfPaneIfLoaded?.pdfView.tool = .select
        toolBar?.removeFromSuperview()
        toolBar = nil
        syncChromeSuspension()
        layoutDocumentPane()
        updateCanvasInsets()
    }

    // MARK: - Pages

    @objc func deletePage(_ sender: Any?) {
        pdfPane.deleteCurrentPage()
    }

    @objc func insertBlankPage(_ sender: Any?) {
        pdfPane.insertBlankPage()
    }

    /// Merges another PDF, or an image as a page, in after the current page.
    @objc func insertPagesFromFile(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs or images to insert after this page."
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.undoManager?.beginUndoGrouping()
            let failed = panel.urls.filter { !self.pdfPane.insertPages(from: $0) }
            self.undoManager?.endUndoGrouping()
            if let first = failed.first {
                self.announce("Couldn’t insert \(first.lastPathComponent)")
            }
        }
    }
}
