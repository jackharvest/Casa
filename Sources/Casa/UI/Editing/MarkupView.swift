import AppKit

/// The markup layer over a photograph.
///
/// Marks stay live — movable, recolourable, deletable — for as long as the
/// layer is up, and are burned into the pixels when it comes down. Leaving
/// always keeps what was drawn; Undo takes the whole session back in one step.
final class MarkupView: CanvasOverlayView, NSTextFieldDelegate {

    let imageSize: CGSize
    private(set) var items: [MarkupItem] = []

    var tool: MarkupTool = .pen {
        didSet {
            guard tool != oldValue else { return }
            endTextEditing()
            if tool != .select { select(nil) }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Applies to the next mark, and to the selected one if there is one.
    var style = MarkupStyle() {
        didSet {
            guard style != oldValue, let selection else { return }
            var next = items
            next[selection].color = style.color
            next[selection].lineWidth = lineWidth
            next[selection].fontSize = fontSize
            commit(next, "Change Style")
            editor?.textColor = style.color
        }
    }

    /// Escape or Return with nothing selected: the user is done.
    var onFinish: (() -> Void)?

    private var selection: Int?

    private enum Drag {
        case stroke
        case handle(Int)
        case move(last: CGPoint)
    }
    private var drag: Drag?
    /// The marks as they were when the mouse went down, for one undo step
    /// per gesture rather than one per mouse-moved event.
    private var itemsBeforeDrag: [MarkupItem] = []

    init(canvas: ImageCanvasView, imageSize: CGSize) {
        self.imageSize = imageSize
        super.init(canvas: canvas)
    }

    // MARK: - Sizes

    /// Stroke and type sizes follow the picture, not the screen. A mark that
    /// looks right on a fitted 45-megapixel photograph would be a hairline if
    /// it were a fixed number of pixels wide.
    private var unit: CGFloat { max(max(imageSize.width, imageSize.height) / 500, 1.5) }
    private var lineWidth: CGFloat { unit * style.weight.multiple }
    private var fontSize: CGFloat { max(unit * 9 * (0.5 + style.weight.multiple / 2), 12) }

    private func newItem(_ shape: MarkupItem.Shape) -> MarkupItem {
        MarkupItem(shape: shape, color: style.color, lineWidth: lineWidth, fontSize: fontSize)
    }

    // MARK: - Changes

    private func commit(_ next: [MarkupItem], _ name: String) {
        let previous = items
        guard next != previous else { return }
        undoManager?.registerUndo(withTarget: self) { view in
            view.endTextEditing()
            view.commit(previous, name)
        }
        undoManager?.setActionName(name)
        items = next
        if let selection, !items.indices.contains(selection) { self.selection = nil }
        needsDisplay = true
    }

    private func select(_ index: Int?) {
        guard selection != index else { return }
        selection = index
        needsDisplay = true
    }

    /// Drops this layer's entries from the undo stack. Called as it comes
    /// down, when the marks stop being objects and become pixels.
    func forgetUndo() {
        endTextEditing()
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let imageRect = viewRect(forImageRect: CGRect(origin: .zero, size: imageSize))

        context.saveGState()
        // Marks cannot be seen past the edge of the picture once flattened,
        // so they are not shown there now.
        context.clip(to: imageRect)
        context.translateBy(x: imageRect.minX, y: imageRect.minY)
        context.scaleBy(x: canvas.scale, y: canvas.scale)
        MarkupRenderer.draw(items, in: context, skippingTextAt: editingIndex)
        context.restoreGState()

        guard let selection, items.indices.contains(selection), editingIndex != selection else { return }
        let item = items[selection]
        let accent = NSColor.controlAccentColor

        if item.handles.isEmpty {
            let outline = viewRect(forImageRect: item.bounds).insetBy(dx: -5, dy: -5)
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(outline)
            context.setLineDash(phase: 0, lengths: [])
        }
        for handle in item.handles {
            let centre = canvas.viewPoint(forImagePoint: handle)
            let knob = CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(2)
            context.setShadow(offset: .zero, blur: 2, color: NSColor(white: 0, alpha: 0.4).cgColor)
            context.fillEllipse(in: knob)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.strokeEllipse(in: knob)
        }
    }

    // MARK: - Mouse

    /// How close, in image pixels, counts as on target. Constant on screen.
    private var reach: CGFloat { 7 / max(canvas.scale, 0.0001) }

    private func hitItem(at point: CGPoint) -> Int? {
        items.indices.reversed().first { items[$0].contains(point, tolerance: reach) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endTextEditing()
        let point = canvas.imagePoint(forViewPoint: convert(event.locationInWindow, from: nil))
        itemsBeforeDrag = items
        drag = nil

        switch tool {
        case .select:
            if let selection,
               let handle = items[selection].handles.firstIndex(where: {
                   hypot($0.x - point.x, $0.y - point.y) <= reach * 1.4
               }) {
                drag = .handle(handle)
            } else if let hit = hitItem(at: point) {
                select(hit)
                if event.clickCount == 2, case .text = items[hit].shape {
                    beginTextEditing(hit)
                } else {
                    drag = .move(last: point)
                }
            } else {
                select(nil)
            }

        case .text:
            if let hit = hitItem(at: point), case .text = items[hit].shape {
                select(hit)
                beginTextEditing(hit)
            } else {
                items.append(newItem(.text("", point)))
                select(items.count - 1)
                beginTextEditing(items.count - 1)
            }

        case .pen:
            items.append(newItem(.pen([point])))
            select(nil)
            drag = .stroke
        case .highlighter:
            items.append(newItem(.highlighter([point])))
            select(nil)
            drag = .stroke

        case .line, .arrow:
            items.append(newItem(tool == .line ? .line(point, point) : .arrow(point, point)))
            select(items.count - 1)
            drag = .handle(1)

        case .rectangle, .ellipse, .redact:
            let seed = CGRect(origin: point, size: .zero)
            let shape: MarkupItem.Shape = tool == .rectangle ? .rectangle(seed)
                : (tool == .ellipse ? .ellipse(seed) : .redact(seed))
            items.append(newItem(shape))
            select(items.count - 1)
            drag = .handle(2)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        var point = canvas.imagePoint(forViewPoint: convert(event.locationInWindow, from: nil))

        switch drag {
        case .stroke:
            guard let last = items.indices.last else { return }
            switch items[last].shape {
            case .pen(let points): items[last].shape = .pen(points + [point])
            case .highlighter(let points): items[last].shape = .highlighter(points + [point])
            default: break
            }

        case .handle(let handle):
            guard let selection else { return }
            // Shift holds a line to the nearest 45° and a box to a square.
            if event.modifierFlags.contains(.shift) {
                point = constrained(point, item: items[selection], handle: handle)
            }
            items[selection] = items[selection].reshaped(handle: handle, to: point)

        case .move(let last):
            guard let selection else { return }
            items[selection] = items[selection].moved(by: CGSize(width: point.x - last.x,
                                                                 height: point.y - last.y))
            self.drag = .move(last: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil

        // A click that never became a drag leaves a shape with no size. Those
        // are dropped, except for a pen dot, which is a legitimate mark.
        if tool != .select, let last = items.indices.last, items.count > itemsBeforeDrag.count {
            let box = items[last].bounds
            let degenerate: Bool
            switch items[last].shape {
            case .pen: degenerate = false
            case .highlighter, .line, .arrow: degenerate = max(box.width, box.height) < reach / 2
            default: degenerate = box.width < reach / 2 || box.height < reach / 2
            }
            if degenerate {
                items = itemsBeforeDrag
                select(nil)
                needsDisplay = true
                return
            }
        }

        let result = items
        items = itemsBeforeDrag
        commit(result, tool == .select ? "Move" : tool.label)
    }

    private func constrained(_ point: CGPoint, item: MarkupItem, handle: Int) -> CGPoint {
        switch item.shape {
        case .line(let a, let b), .arrow(let a, let b):
            let anchor = handle == 0 ? b : a
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
        case .rectangle, .ellipse, .redact:
            let anchor = item.handles[(handle + 2) % 4]
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            let edge = max(abs(dx), abs(dy))
            return CGPoint(x: anchor.x + (dx < 0 ? -edge : edge), y: anchor.y + (dy < 0 ? -edge : edge))
        default:
            return point
        }
    }

    // MARK: - Text

    private var editor: NSTextField?
    private var editingIndex: Int?

    private func beginTextEditing(_ index: Int) {
        guard case .text(let string, let origin) = items[index].shape else { return }
        let item = items[index]

        let field = NSTextField(string: string)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = item.color
        field.font = .systemFont(ofSize: item.fontSize * canvas.scale, weight: .semibold)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        addSubview(field)

        editor = field
        editingIndex = index
        // The field cell insets its text by two points; start it that much to
        // the left so the type does not jump when editing ends.
        let place = canvas.viewPoint(forImagePoint: origin)
        field.setFrameOrigin(CGPoint(x: place.x - 2, y: place.y))
        sizeEditorToFit()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func sizeEditorToFit() {
        guard let editor, let font = editor.font else { return }
        let text = NSAttributedString(string: editor.stringValue + "MM", attributes: [.font: font])
        let size = text.size()
        editor.setFrameSize(CGSize(width: ceil(size.width) + 8, height: ceil(size.height) + 2))
    }

    func controlTextDidChange(_ notification: Notification) {
        sizeEditorToFit()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endTextEditing()
    }

    private func endTextEditing() {
        guard let editor, let index = editingIndex else { return }
        self.editor = nil
        editingIndex = nil
        editor.delegate = nil
        let string = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()

        guard items.indices.contains(index), case .text(_, let origin) = items[index].shape else { return }
        var result = items
        if string.isEmpty {
            result.remove(at: index)
            selection = nil
        } else {
            result[index].shape = .text(string, origin)
        }
        // The empty placeholder was appended without an undo step; rewind to
        // before it so one undo removes the whole text, not just its letters.
        if items.count > itemsBeforeDrag.count { items = itemsBeforeDrag }
        commit(result, "Text")
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\u{7f}", "\u{f728}":       // Delete, Forward Delete
            guard let selection else { return }
            var next = items
            next.remove(at: selection)
            self.selection = nil
            commit(next, "Delete")
        case "\u{1b}":
            if selection != nil { select(nil) } else { onFinish?() }
        case "\r", "\u{3}":
            onFinish?()
        default:
            super.keyDown(with: event)
        }
    }

    override func geometryChanged() {
        // The text field is positioned in view coordinates; rather than chase
        // the photograph with it, finish the edit.
        endTextEditing()
        super.geometryChanged()
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }
}
