import AppKit

/// Editing: crop, colour, size, flip, markup, and lifting a subject off its
/// background.
///
/// Edits are held in memory and nothing touches the file until it is saved.
/// That is a deliberate difference from rotation, which writes as you move
/// on: turning a photo is lossless and obviously wanted, while a crop throws
/// pixels away and deserves a decision.
extension ViewerController {

    var isVideo: Bool { session.currentURL.map(VideoSource.isVideo) ?? false }

    /// Whether the thing on screen has pixels that can be changed.
    var canEditCurrent: Bool {
        session.currentURL != nil && !isDocumentActive && !isVideo
            && canvas.playable == .none && canvas.hasImage
    }

    // MARK: - The editor

    /// Returns the editor for the picture on screen, starting one if needed.
    ///
    /// Starting means decoding the whole image — edits are made to the real
    /// pixels, not to the screen-sized proxy — and baking in any turn that
    /// was showing, so every tool can assume an upright picture.
    func prepareEditor() async -> ImageEditor? {
        if let editor, editor.url == session.currentURL { return editor }
        guard canEditCurrent, !isWorking, let url = session.currentURL else {
            NSSound.beep()
            return nil
        }
        stopSlideshow()
        isWorking = true
        defer { isWorking = false }

        guard let decoded = await session.fullResolutionImage(), url == session.currentURL else { return nil }
        let turns = canvas.quarterTurns
        var image = decoded.cgImage
        if turns != 0 { image = ImageEdits.rotate(image, quarterTurns: turns) ?? image }
        // The turn now lives in the pixels; it must not also be written to
        // the file as a tag when the user moves on.
        session.discardPendingRotation()
        session.isEditing = true

        let editor = ImageEditor(url: url, image: image, matchesFile: turns == 0)
        editor.onChange = { [weak self] in self?.editorChanged() }
        self.editor = editor
        undoManager?.levelsOfUndo = 8
        showWorkingImage()
        return editor
    }

    func showWorkingImage() {
        guard let editor else { return }
        canvas.resetRotation()
        canvas.display(DecodedImage(cgImage: editor.image, tier: .full, nativePixelSize: editor.pixelSize),
                       preservingZoom: true)
    }

    private func editorChanged() {
        showWorkingImage()
        chrome.filmstrip.clearRotation(for: editor?.url ?? URL(fileURLWithPath: "/"))
        chrome.update(filename: session.currentURL?.lastPathComponent ?? "", detail: detailDescription)
        updateWindowTitle()
    }

    /// Throws the edits away and shows the file as it is on disk.
    func discardEdits(reload: Bool) {
        guard let editor else { return }
        undoManager?.removeAllActions(withTarget: editor)
        self.editor = nil
        session.isEditing = false
        chrome.filmstrip.clearRotation(for: editor.url)
        if reload { session.reloadCurrent() }
    }

    /// Runs a slow edit off the main thread and applies the result.
    private func runEdit(named name: String, progress: String,
                         _ work: @escaping @Sendable (DecodedImage) throws -> CGImage?) {
        Task {
            guard let editor = await prepareEditor(), !isWorking else { return }
            isWorking = true
            announce(progress)
            let source = DecodedImage(cgImage: editor.image, tier: .full, nativePixelSize: editor.pixelSize)
            let outcome: Result<DecodedImage?, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try work(source).map {
                        DecodedImage(cgImage: $0, tier: .full,
                                     nativePixelSize: CGSize(width: $0.width, height: $0.height))
                    }
                }
            }.value
            isWorking = false

            guard self.editor === editor else { return }
            switch outcome {
            case .success(let result?):
                editor.apply(result.cgImage, named: name, undoManager: undoManager)
            case .success(nil):
                announce(ImageEdits.Failure.renderFailed.localizedDescription)
            case .failure(let error):
                announce(error.localizedDescription)
            }
        }
    }

    // MARK: - One-step edits

    @objc func flipHorizontal(_ sender: Any?) {
        runEdit(named: "Flip Horizontal", progress: "Flipping…") { ImageEdits.flip($0.cgImage, horizontal: true) }
    }

    @objc func flipVertical(_ sender: Any?) {
        runEdit(named: "Flip Vertical", progress: "Flipping…") { ImageEdits.flip($0.cgImage, horizontal: false) }
    }

    @objc func removeBackground(_ sender: Any?) {
        runEdit(named: "Remove Background", progress: "Finding the subject…") {
            try ImageEdits.removeBackground($0.cgImage)
        }
    }

    // MARK: - Tools

    /// Puts a bar where the toolbar was and stands the chrome down.
    func install(_ bar: EditBar) {
        toolBar?.removeFromSuperview()
        toolBar = bar
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ChromeMetrics.spacing(2.5)),
        ])
        syncChromeSuspension()
        updateCanvasInsets()
    }

    func install(_ overlay: CanvasOverlayView) {
        view.addSubview(overlay, positioned: .above, relativeTo: canvas)
        Glass.pin(overlay, to: view)
        canvas.tracksOverlay = true
        liveText?.clear()
        view.window?.makeFirstResponder(overlay)
    }

    func install(_ panel: SidePanel) {
        view.addSubview(panel)
        let margin = ChromeMetrics.spacing(3)
        let centred = panel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        centred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            centred,
            panel.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: margin),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -margin),
        ])
        updateCanvasInsets()
    }

    /// Takes down whatever tool is up, without applying it.
    func tearDownTool() {
        cropOverlay?.removeFromSuperview()
        cropOverlay = nil
        markupView?.forgetUndo()
        markupView?.removeFromSuperview()
        markupView = nil
        adjustPanel?.removeFromSuperview()
        adjustPanel = nil
        adjustProxy = nil
        adjustGeneration += 1
        toolBar?.removeFromSuperview()
        toolBar = nil
        canvas.tracksOverlay = false
        syncChromeSuspension()
        updateCanvasInsets()
        if !isDocumentActive { view.window?.makeFirstResponder(canvas) }
    }

    /// Ends the active tool the way leaving the photograph should: a crop
    /// frame or a set of sliders the user never confirmed is dropped, but
    /// marks already drawn are kept, because they are work already done.
    func finishActiveTool() {
        switch activeTool {
        case .markup: finishMarkup()
        case .crop: cancelCrop()
        case .adjust: cancelAdjust()
        case nil: break
        }
    }

    // MARK: - Crop

    @objc func crop(_ sender: Any?) {
        if activeTool == .crop { commitCrop(); return }
        guard activeTool == nil else { return }
        Task {
            guard let editor = await prepareEditor(), activeTool == nil else { return }
            beginCrop(editor)
        }
    }

    private func beginCrop(_ editor: ImageEditor) {
        let overlay = CropOverlayView(canvas: canvas, imageSize: editor.pixelSize)
        let bar = CropBar(imageSize: editor.pixelSize)
        overlay.onChange = { [weak bar] rect in bar?.update(rect) }
        overlay.onCommit = { [weak self] in self?.commitCrop() }
        overlay.onCancel = { [weak self] in self?.cancelCrop() }
        bar.onAspect = { [weak overlay] ratio in overlay?.setAspect(ratio) }
        bar.onCommit = { [weak self] in self?.commitCrop() }
        bar.onCancel = { [weak self] in self?.cancelCrop() }

        cropOverlay = overlay
        // Fitted, so the whole frame is reachable to begin with.
        canvas.fit(animated: false)
        install(bar)
        install(overlay)
    }

    private func commitCrop() {
        guard let overlay = cropOverlay, let editor else { return }
        let rect = overlay.cropRect
        let whole = overlay.isWholeImage
        tearDownTool()
        guard !whole, let cropped = ImageEdits.crop(editor.image, to: rect) else { return }
        editor.apply(cropped, named: "Crop", undoManager: undoManager)
    }

    private func cancelCrop() {
        tearDownTool()
        if editor?.isDirty == false { discardEdits(reload: false) }
    }

    // MARK: - Markup

    var isMarkupActive: Bool { markupView != nil || toolBar is MarkupBar }

    @objc func toggleMarkup(_ sender: Any?) {
        if isDocumentActive {
            toggleDocumentMarkup()
            return
        }
        if markupView != nil { finishMarkup(); return }
        guard activeTool == nil else { return }
        Task {
            guard let editor = await prepareEditor(), activeTool == nil else { return }
            beginMarkup(editor)
        }
    }

    private func beginMarkup(_ editor: ImageEditor) {
        let overlay = MarkupView(canvas: canvas, imageSize: editor.pixelSize)
        let bar = MarkupBar(flavor: .image)
        bar.delegate = self
        overlay.tool = bar.tool
        overlay.style = bar.style
        overlay.onFinish = { [weak self] in self?.finishMarkup() }
        markupView = overlay
        install(bar)
        install(overlay)
    }

    /// Burns the marks into the picture as one undoable step.
    private func finishMarkup() {
        guard let overlay = markupView, let editor else { return }
        overlay.forgetUndo()
        let items = overlay.items
        tearDownTool()
        guard !items.isEmpty else {
            if !editor.isDirty { discardEdits(reload: false) }
            return
        }
        guard let flattened = MarkupRenderer.flatten(items, onto: editor.image) else {
            announce(ImageEdits.Failure.renderFailed.localizedDescription)
            return
        }
        editor.apply(flattened, named: "Markup", undoManager: undoManager)
    }

    // MARK: - Colour

    @objc func adjustColor(_ sender: Any?) {
        guard activeTool == nil else { return }
        Task {
            guard let editor = await prepareEditor(), activeTool == nil else { return }
            beginAdjust(editor)
        }
    }

    private func beginAdjust(_ editor: ImageEditor) {
        // The sliders work on a screen-sized copy; the full picture is only
        // run once, when the user is happy.
        let longest = max(editor.pixelSize.width, editor.pixelSize.height)
        let shrink = min(1, 1600 / longest)
        adjustProxy = shrink < 1
            ? ImageEdits.resize(editor.image, to: CGSize(width: editor.pixelSize.width * shrink,
                                                         height: editor.pixelSize.height * shrink))
            : editor.image

        let panel = AdjustPanel()
        panel.onChange = { [weak self] adjustments in self?.previewAdjustments(adjustments) }
        panel.onCommit = { [weak self] in self?.commitAdjust() }
        panel.onCancel = { [weak self] in self?.cancelAdjust() }
        adjustPanel = panel
        if inspector != nil { toggleInspector(nil) }
        install(panel)
        syncChromeSuspension()
        view.window?.makeFirstResponder(panel)
    }

    private func previewAdjustments(_ adjustments: Adjustments) {
        guard let proxy = adjustProxy else { return }
        adjustGeneration += 1
        let generation = adjustGeneration
        let source = DecodedImage(cgImage: proxy, tier: .preview,
                                  nativePixelSize: CGSize(width: proxy.width, height: proxy.height))
        Task {
            let preview = await Task.detached(priority: .userInitiated) {
                ImageEdits.adjust(source.cgImage, adjustments).map {
                    DecodedImage(cgImage: $0, tier: .preview, nativePixelSize: source.nativePixelSize)
                }
            }.value
            // Sliders move faster than frames render; only the newest counts.
            guard generation == adjustGeneration, adjustPanel != nil, let preview else { return }
            canvas.setPreviewContents(preview.cgImage)
        }
    }

    private func commitAdjust() {
        guard let panel = adjustPanel else { return }
        let adjustments = panel.adjustments
        tearDownTool()
        guard !adjustments.isIdentity else {
            showWorkingImage()
            if editor?.isDirty == false { discardEdits(reload: false) }
            return
        }
        runEdit(named: "Adjust Color", progress: "Applying…") { ImageEdits.adjust($0.cgImage, adjustments) }
    }

    private func cancelAdjust() {
        tearDownTool()
        showWorkingImage()
        if editor?.isDirty == false { discardEdits(reload: false) }
    }

    // MARK: - Size

    @objc func adjustSize(_ sender: Any?) {
        guard activeTool == nil, let window = view.window else { return }
        Task {
            guard let editor = await prepareEditor() else { return }
            let form = ResizeForm(size: editor.pixelSize)
            let alert = NSAlert()
            alert.messageText = "Adjust Size"
            alert.informativeText = "The picture is resampled to the new dimensions."
            alert.accessoryView = form.view
            alert.addButton(withTitle: "Resize")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = form.firstField

            let response = await alert.beginSheetModal(for: window)
            let target = form.size
            guard response == .alertFirstButtonReturn, target != editor.pixelSize,
                  target.width >= 1, target.height >= 1 else {
                if !editor.isDirty { discardEdits(reload: false) }
                return
            }
            runEdit(named: "Adjust Size", progress: "Resizing…") { ImageEdits.resize($0.cgImage, to: target) }
        }
    }
}

extension ViewerController: MarkupBarDelegate {

    func markupBar(_ bar: MarkupBar, didChoose tool: MarkupTool) {
        markupView?.tool = tool
        if isDocumentActive { pdfPane.pdfView.tool = tool }
    }

    func markupBar(_ bar: MarkupBar, didChange style: MarkupStyle) {
        markupView?.style = style
        if isDocumentActive { pdfPane.pdfView.style = style }
    }

    func markupBar(_ bar: MarkupBar, didRequestTextMark mark: MarkupBar.TextMark) {
        markSelection(mark, colour: bar.style.color)
    }

    func markupBarDidFinish(_ bar: MarkupBar) {
        toggleMarkup(nil)
    }
}

/// Width and height fields that keep each other in proportion.
@MainActor
final class ResizeForm: NSObject, NSTextFieldDelegate {

    let view: NSView
    private let original: CGSize
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let lock = NSButton(checkboxWithTitle: "Keep proportions", target: nil, action: nil)
    private let result = NSTextField(labelWithString: "")

    var firstField: NSView { widthField }

    var size: CGSize {
        CGSize(width: CGFloat(max(widthField.integerValue, 0)), height: CGFloat(max(heightField.integerValue, 0)))
    }

    init(size: CGSize) {
        original = size
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 30000

        for field in [widthField, heightField] {
            field.formatter = formatter
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        }
        widthField.integerValue = Int(size.width)
        heightField.integerValue = Int(size.height)
        lock.state = .on
        result.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        result.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width:"), widthField, NSTextField(labelWithString: "pixels")],
            [NSTextField(labelWithString: "Height:"), heightField, NSTextField(labelWithString: "pixels")],
            [NSGridCell.emptyContentView, lock, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, result, NSGridCell.emptyContentView],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2), verticalRange: NSRange(location: 2, length: 1))
        grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2), verticalRange: NSRange(location: 3, length: 1))
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setFrameSize(grid.fittingSize)
        view = grid

        super.init()
        widthField.delegate = self
        heightField.delegate = self
        describe()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if lock.state == .on, original.width > 0, original.height > 0 {
            if field === widthField {
                heightField.integerValue = Int((CGFloat(widthField.integerValue) * original.height / original.width).rounded())
            } else {
                widthField.integerValue = Int((CGFloat(heightField.integerValue) * original.width / original.height).rounded())
            }
        }
        describe()
    }

    private func describe() {
        let percent = original.width > 0 ? size.width / original.width * 100 : 100
        result.stringValue = String(format: "%.0f%% of %d × %d", percent, Int(original.width), Int(original.height))
    }
}
