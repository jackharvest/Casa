import AppKit
import PDFKit

/// `PDFView`, taught the viewer's keys and the markup tools.
///
/// Everything PDFKit already does well is left to it: text selection, links,
/// form fields, scrolling, the password prompt. This adds only what a viewer
/// needs on top — Escape closes, the arrows turn pages, and a drag with a
/// drawing tool held makes an annotation instead of a selection.
final class ReaderPDFView: PDFView, NSTextFieldDelegate {

    weak var pane: PDFPane?

    var tool: MarkupTool = .select {
        didSet {
            guard tool != oldValue else { return }
            endTextEditing()
            if tool != .select { selectAnnotation(nil) }
            window?.invalidateCursorRects(for: self)
        }
    }

    var style = MarkupStyle() {
        didSet {
            guard style != oldValue, let selected = selectedAnnotation, let page = selected.page else { return }
            pane?.restyle(selected, on: page, with: style)
            syncRing()
        }
    }

    // MARK: - Sizes

    /// Stroke width in page points.
    var lineWidth: CGFloat { 1.5 * style.weight.multiple }
    var fontSize: CGFloat { 9 + 4.5 * style.weight.multiple }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command), let pane else {
            super.keyDown(with: event)
            return
        }

        switch event.specialKey {
        case .leftArrow: pane.turnPage(by: -1); return
        case .rightArrow: pane.turnPage(by: 1); return
        case .home: goToFirstPage(nil); return
        case .end: goToLastPage(nil); return
        case .carriageReturn, .enter: pane.delegate?.pdfPaneRequestsPresentationToggle(pane); return
        case .delete, .deleteForward:
            if let selected = selectedAnnotation, let page = selected.page {
                selectAnnotation(nil)
                pane.remove(selected, from: page, actionName: "Delete")
            }
            return
        default: break
        }

        if event.charactersIgnoringModifiers == "\u{1b}" {
            if selectedAnnotation != nil {
                selectAnnotation(nil)
            } else {
                pane.delegate?.pdfPaneDidPressEscape(pane)
            }
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘C with text selected copies the text. With nothing selected it would
    /// otherwise be dimmed, which makes "copy this document" unreachable from
    /// the keyboard, so that case goes to the viewer instead.
    override func copy(_ sender: Any?) {
        if let text = currentSelection?.string, !text.isEmpty {
            super.copy(sender)
        } else if let pane {
            pane.delegate?.pdfPaneCopyWithoutSelection(pane)
        }
    }

    /// PDFKit validates its own menu items but does not publish the method,
    /// so the one item we need to answer for is answered here and the rest
    /// are passed to the implementation underneath by hand.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return true }
        let selector = #selector(NSMenuItemValidation.validateMenuItem(_:))
        guard let method = class_getInstanceMethod(PDFView.self, selector) else { return true }
        typealias Validator = @convention(c) (AnyObject, Selector, NSMenuItem) -> Bool
        let inherited = unsafeBitCast(method_getImplementation(method), to: Validator.self)
        return inherited(self, selector, menuItem)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endTextEditing()
        let point = convert(event.locationInWindow, from: nil)
        guard let pane, let page = page(for: point, nearest: true) else {
            super.mouseDown(with: event)
            return
        }
        let place = convert(point, to: page)

        switch tool {
        case .select:
            if let hit = page.annotation(at: place), Self.isOurs(hit) {
                selectAnnotation(hit)
                if event.clickCount == 2, hit.type == "FreeText" {
                    beginTextEditing(on: page, at: CGPoint(x: hit.bounds.minX, y: hit.bounds.maxY), editing: hit)
                } else if Self.isMovable(hit) {
                    trackMove(of: hit, on: page, from: place)
                }
            } else {
                selectAnnotation(nil)
                super.mouseDown(with: event)
            }

        case .text:
            beginTextEditing(on: page, at: place, editing: nil)

        case .pen, .line, .arrow, .rectangle, .ellipse:
            trackDrawing(on: page, from: place, pane: pane)

        default:
            super.mouseDown(with: event)
        }
    }

    private func nextDragEvent() -> NSEvent? {
        window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
    }

    private func pagePoint(_ event: NSEvent, on page: PDFPage) -> CGPoint {
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        // Marks stay on the paper.
        let box = page.bounds(for: displayBox)
        return CGPoint(x: min(max(point.x, box.minX), box.maxX),
                       y: min(max(point.y, box.minY), box.maxY))
    }

    /// Follows a drag, replacing the annotation on every move so the page
    /// shows the mark growing under the pointer.
    private func trackDrawing(on page: PDFPage, from start: CGPoint, pane: PDFPane) {
        var points = [start]
        var live: PDFAnnotation?

        while let event = nextDragEvent() {
            let point = pagePoint(event, on: page)
            if tool == .pen { points.append(point) } else { points = [start, point] }

            if let live { page.removeAnnotation(live) }
            live = makeAnnotation(points)
            if let live { page.addAnnotation(live) }
            if event.type == .leftMouseUp { break }
        }

        guard let live else { return }
        // Added without an undo step while it was being drawn; take it off
        // and put it back through the door that registers one.
        page.removeAnnotation(live)
        let extent = points.reduce(CGRect(origin: start, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard tool == .pen || max(extent.width, extent.height) > 3 else { return }
        pane.add(live, to: page, actionName: tool.label)
        selectAnnotation(live)
    }

    private func makeAnnotation(_ points: [CGPoint]) -> PDFAnnotation? {
        guard let first = points.first, let last = points.last else { return nil }
        let border = PDFBorder()
        border.lineWidth = lineWidth
        let pad = lineWidth * (tool == .arrow ? 6 : 1.5)
        let extent = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        let bounds = extent.insetBy(dx: -pad, dy: -pad)

        let annotation: PDFAnnotation
        switch tool {
        case .pen:
            annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            let path = NSBezierPath()
            // Ink paths are in the annotation's own space, not the page's.
            path.move(to: CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY))
            for point in points.dropFirst() {
                path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
            }
            if points.count == 1 { path.line(to: CGPoint(x: first.x - bounds.minX + 0.1, y: first.y - bounds.minY)) }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            annotation.add(path)
        case .line, .arrow:
            annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY)
            annotation.endPoint = CGPoint(x: last.x - bounds.minX, y: last.y - bounds.minY)
            annotation.endLineStyle = tool == .arrow ? .closedArrow : .none
            if tool == .arrow { annotation.interiorColor = style.color }
        case .rectangle:
            annotation = PDFAnnotation(bounds: extent, forType: .square, withProperties: nil)
        case .ellipse:
            annotation = PDFAnnotation(bounds: extent, forType: .circle, withProperties: nil)
        default:
            return nil
        }
        annotation.border = border
        annotation.color = style.color
        return annotation
    }

    private func trackMove(of annotation: PDFAnnotation, on page: PDFPage, from start: CGPoint) {
        let original = annotation.bounds
        var moved = false
        while let event = nextDragEvent() {
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            let next = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            if next != annotation.bounds {
                annotation.bounds = next
                moved = true
                syncRing()
            }
            if event.type == .leftMouseUp { break }
        }
        guard moved else { return }
        let final = annotation.bounds
        annotation.bounds = original
        pane?.move(annotation, to: final)
        syncRing()
    }

    // MARK: - Selection

    private(set) var selectedAnnotation: PDFAnnotation?
    private let ring = SelectionRing()

    private static let ourTypes: Set<String> = [
        "Ink", "Line", "Square", "Circle", "FreeText", "Highlight", "Underline", "StrikeOut",
    ]

    /// Marks made by a person, as opposed to links and form fields, which
    /// belong to the document and must keep working when clicked.
    private static func isOurs(_ annotation: PDFAnnotation) -> Bool {
        ourTypes.contains(annotation.type ?? "")
    }

    private static func isMovable(_ annotation: PDFAnnotation) -> Bool {
        ["Ink", "Line", "Square", "Circle", "FreeText"].contains(annotation.type ?? "")
    }

    func selectAnnotation(_ annotation: PDFAnnotation?) {
        selectedAnnotation = annotation
        syncRing()
    }

    /// Keeps the selection outline over its annotation through scrolling and
    /// zooming. Called by the pane whenever the view's geometry changes.
    func syncRing() {
        guard let selected = selectedAnnotation, let page = selected.page else {
            ring.removeFromSuperview()
            return
        }
        if ring.superview !== self { addSubview(ring) }
        ring.frame = convert(selected.bounds, from: page).insetBy(dx: -4, dy: -4)
    }

    // MARK: - Text

    private var editor: NSTextField?
    private var editorPage: PDFPage?
    private var editorAnchor: CGPoint = .zero
    private var editedAnnotation: PDFAnnotation?

    /// - Parameter anchor: the text's top-left corner, in page space.
    private func beginTextEditing(on page: PDFPage, at anchor: CGPoint, editing existing: PDFAnnotation?) {
        let size = (existing?.font?.pointSize ?? fontSize)
        let field = NSTextField(string: existing?.contents ?? "")
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 1, alpha: 0.85)
        field.textColor = existing?.fontColor ?? style.color
        field.font = .systemFont(ofSize: size * scaleFactor)
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        addSubview(field)

        editor = field
        editorPage = page
        editorAnchor = anchor
        editedAnnotation = existing
        // Hidden while its text is in the field, so the two do not overprint.
        existing?.shouldDisplay = false
        selectAnnotation(nil)

        sizeEditorToFit()
        window?.makeFirstResponder(field)
    }

    private func sizeEditorToFit() {
        guard let editor, let page = editorPage, let font = editor.font else { return }
        let text = NSAttributedString(string: editor.stringValue + "MM", attributes: [.font: font])
        let size = CGSize(width: ceil(text.size().width) + 8, height: ceil(text.size().height) + 4)
        let corner = convert(editorAnchor, from: page)
        // The view may or may not be flipped depending on the system; place
        // the field so its top edge is at the anchor either way.
        editor.frame = CGRect(x: corner.x - 2, y: isFlipped ? corner.y : corner.y - size.height,
                              width: size.width, height: size.height)
    }

    func controlTextDidChange(_ notification: Notification) { sizeEditorToFit() }
    func controlTextDidEndEditing(_ notification: Notification) { endTextEditing() }

    func endTextEditing() {
        guard let editor, let page = editorPage, let pane else { return }
        self.editor = nil
        editor.delegate = nil
        let string = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = (editor.font?.pointSize ?? fontSize * scaleFactor) / scaleFactor
        let colour = editor.textColor ?? style.color
        editor.removeFromSuperview()

        let existing = editedAnnotation
        editedAnnotation = nil
        existing?.shouldDisplay = true

        var replacement: PDFAnnotation?
        if !string.isEmpty {
            let font = NSFont.systemFont(ofSize: size)
            let extent = NSAttributedString(string: string, attributes: [.font: font]).size()
            let box = CGRect(x: editorAnchor.x, y: editorAnchor.y - ceil(extent.height) - 4,
                             width: ceil(extent.width) + 8, height: ceil(extent.height) + 4)
            let annotation = PDFAnnotation(bounds: box, forType: .freeText, withProperties: nil)
            annotation.contents = string
            annotation.font = font
            annotation.fontColor = colour
            annotation.color = .clear
            replacement = annotation
        }

        if existing?.contents != replacement?.contents || existing == nil {
            pane.replace(existing, with: replacement, on: page, actionName: "Text")
        }
        selectAnnotation(replacement ?? nil)
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch tool {
        case .select: break
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }
}

/// A dashed outline around the selected annotation. Never takes a click.
private final class SelectionRing: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
