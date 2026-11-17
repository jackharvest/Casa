import AppKit
import UniformTypeIdentifiers

/// What the viewer does to a file other than show it: save, export, print,
/// share, rename, duplicate, trash.
extension ViewerController {

    // MARK: - Unsaved work

    var hasUnsavedChanges: Bool {
        if let editor, editor.isDirty { return true }
        if let markupView, !markupView.items.isEmpty { return true }
        if let pane = pdfPaneIfLoaded, pane.url != nil, pane.isDirty { return true }
        return false
    }

    /// Runs `proceed` once it is safe to stop showing the current file.
    ///
    /// Every route away from a file — an arrow key, the rail, another file
    /// being opened, the window closing, the app quitting — comes through
    /// here, so there is exactly one place where unsaved work is asked about
    /// and no route that forgets to.
    ///
    /// - Parameter cancelled: called instead if the user backs out, or a
    ///   save they asked for fails.
    func leaveCurrent(_ proceed: @escaping () -> Void, cancelled: (() -> Void)? = nil) {
        finishActiveTool()
        endDocumentMarkup()

        guard hasUnsavedChanges, let url = session.currentURL, let window = view.window else {
            discardChanges(reload: false)
            proceed()
            return
        }
        stopSlideshow()

        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(url.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.buttons[2].hasDestructiveAction = true

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveChanges { saved in if saved { proceed() } else { cancelled?() } }
            case .alertThirdButtonReturn:
                self.discardChanges(reload: false)
                proceed()
            default:
                cancelled?()
            }
        }
    }

    /// Drops everything unsaved. `reload` puts the file back on screen as it
    /// is on disk; it is skipped when something else is about to be shown.
    func discardChanges(reload: Bool) {
        discardEdits(reload: reload)
        if let pane = pdfPaneIfLoaded, pane.isDirty {
            let url = pane.url
            pane.unload()
            if reload, let url { pane.load(url) }
        }
        updateWindowTitle()
    }

    // MARK: - Save

    @objc func save(_ sender: Any?) {
        finishActiveTool()
        saveChanges { _ in }
    }

    @objc func revertToSaved(_ sender: Any?) {
        finishActiveTool()
        pendingNote = "Reverted"
        discardChanges(reload: true)
        refreshChrome(for: session)
    }

    /// Writes unsaved work back to the file it came from.
    ///
    /// A photograph's original goes to the Trash first rather than being
    /// overwritten, so a crop you regret a week later can still be put back.
    /// Where the format cannot be written, this becomes Export instead.
    func saveChanges(completion: @escaping (Bool) -> Void) {
        guard let url = session.currentURL else { completion(false); return }

        if isDocumentActive {
            do {
                try pdfPane.save()
                announce("Saved")
                updateWindowTitle()
                completion(true)
            } catch {
                presentFailure(error, title: "The document couldn’t be saved")
                completion(false)
            }
            return
        }

        guard let editor, editor.isDirty else { completion(true); return }
        guard let format = ImageExporter.format(of: url),
              FileManager.default.isWritableFile(atPath: url.path),
              !FileActions.isClipboardFile(url) else {
            // No way to write this back where it came from: a RAW, an SVG, a
            // read-only file, or something that only exists on the clipboard.
            runExportPanel(completion: completion)
            return
        }

        let image = DecodedImage(cgImage: editor.image, tier: .full, nativePixelSize: editor.pixelSize)
        isWorking = true
        announce("Saving…")
        Task {
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    try Self.overwrite(url, with: image.cgImage, format: format)
                    return nil
                } catch {
                    return error
                }
            }.value
            isWorking = false

            if let failure {
                presentFailure(failure, title: "The photo couldn’t be saved")
                completion(false)
                return
            }
            editor.markSaved()
            discardEdits(reload: false)
            session.fileChanged(url)
            announce("Saved. The original is in the Trash", afterReload: true)
            completion(true)
        }
    }

    /// Replaces a photograph with an edited version of itself, keeping the
    /// original recoverable.
    nonisolated private static func overwrite(_ url: URL, with image: CGImage,
                                              format: ImageExporter.Format) throws {
        // Not every volume has a Trash. Where there is none the file is
        // simply replaced, which is what every other editor does.
        guard let trashed = try? FileActions.trash(url) else {
            try ImageExporter.write(image, to: url, format: format, quality: 0.92, metadataFrom: url)
            return
        }
        do {
            try ImageExporter.write(image, to: url, format: format, quality: 0.92, metadataFrom: trashed)
            FileActions.carryIdentity(from: trashed, to: url)
        } catch {
            // Never leave the folder without its photograph.
            try? FileActions.restore(trashed, to: url)
            throw error
        }
    }

    func presentFailure(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Export

    @objc func exportDocument(_ sender: Any?) {
        finishActiveTool()
        runExportPanel { _ in }
    }

    /// Save As, under its Mac name. Any format this Mac can write, with a
    /// quality slider where the format has one; a PDF can also be given a
    /// password or shrunk, or have the current page written as an image.
    func runExportPanel(completion: @escaping (Bool) -> Void) {
        guard let url = session.currentURL, let window = view.window, !isVideo else {
            completion(false)
            return
        }
        let isDocument = isDocumentActive
        let wasDirty = hasUnsavedChanges

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileActions.isClipboardFile(url)
            ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            : url.deletingLastPathComponent()
        // The whole name, so re-exporting a .jpg offers .jpg rather than
        // the type's textbook .jpeg; the panel swaps the extension itself if
        // another format is chosen.
        panel.nameFieldStringValue = url.lastPathComponent

        let hasAlpha = editor.map { ImageEdits.hasAlpha($0.image) } ?? false
        let preferred = ImageExporter.format(of: url)
            ?? ImageExporter.formats.first { $0.type == (hasAlpha ? .png : .jpeg) }
        let options = ExportOptions(panel: panel, isDocument: isDocument, preferred: preferred)
        panel.accessoryView = options.view

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else {
                completion(false)
                return
            }
            // Read before the panel goes away and takes its fields with it.
            let format = options.format
            let quality = options.quality
            let document = PDFPane.WriteOptions(password: options.password,
                                                reducesFileSize: options.reducesFileSize)

            Task {
                do {
                    if isDocument, format == nil {
                        try self.pdfPane.write(to: destination, options: document)
                    } else if let format {
                        try await self.export(to: destination, format: format, quality: quality, original: url)
                    }
                    self.finishExport(to: destination, from: url, resolvedEdits: wasDirty)
                    completion(true)
                } catch {
                    self.presentFailure(error, title: "The file couldn’t be exported")
                    completion(false)
                }
            }
        }
    }

    private func export(to destination: URL, format: ImageExporter.Format,
                        quality: Double, original: URL) async throws {
        let source: CGImage
        if isDocumentActive {
            guard let page = pdfPane.currentPageImage() else { throw ImageExporter.Failure.writeFailed }
            source = page
        } else if let editor, editor.url == original {
            source = editor.image
        } else {
            guard let decoded = await session.fullResolutionImage() else { throw ImageExporter.Failure.writeFailed }
            // A turn that is showing but not yet written still belongs in
            // the export: what you see is what you get.
            source = ImageEdits.rotate(decoded.cgImage, quarterTurns: canvas.quarterTurns) ?? decoded.cgImage
        }

        let image = DecodedImage(cgImage: source, tier: .full,
                                 nativePixelSize: CGSize(width: source.width, height: source.height))
        isWorking = true
        defer { isWorking = false }
        announce("Exporting…")
        let metadata = isDocumentActive ? nil : original
        try await Task.detached(priority: .userInitiated) {
            try ImageExporter.write(image.cgImage, to: destination, format: format,
                                    quality: quality, metadataFrom: metadata)
        }.value
    }

    private func finishExport(to destination: URL, from original: URL, resolvedEdits: Bool) {
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        // Exporting edited work is the save: the edits now live in the new
        // file, and the original is left exactly as it was.
        if resolvedEdits { discardChanges(reload: true) }

        if destination == original {
            session.fileChanged(original)
            announce("Saved", afterReload: true)
        } else if destination.deletingLastPathComponent() == original.deletingLastPathComponent(),
                  SupportedTypes.canOpen(destination) {
            // It landed in the folder being walked, so show it there.
            pendingNote = "Exported"
            session.insert(destination, at: session.index + 1)
        } else if FileActions.isClipboardFile(original) {
            session.open(destination)
            refreshChrome(for: session)
        } else {
            announce("Exported to \(destination.deletingLastPathComponent().lastPathComponent)")
        }
    }

    // MARK: - Print

    @objc func printDocument(_ sender: Any?) {
        guard let url = session.currentURL, let window = view.window else { return }
        finishActiveTool()

        if isDocumentActive {
            pdfPane.printOperation()?.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return
        }

        Task {
            let image: CGImage
            if let editor, editor.url == url {
                image = editor.image
            } else {
                guard let decoded = await session.fullResolutionImage(), url == session.currentURL else { return }
                image = ImageEdits.rotate(decoded.cgImage, quarterTurns: canvas.quarterTurns) ?? decoded.cgImage
            }
            Printing.operation(for: image, title: url.deletingPathExtension().lastPathComponent)
                .runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    // MARK: - Share, and other apps

    @objc func share(_ sender: Any?) {
        guard let url = session.currentURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        // Anchored to the button when the click came from one, and to the
        // middle of the window when it came from a menu.
        if let button = sender as? NSView, button.window != nil {
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        } else {
            let anchor = NSRect(x: view.bounds.midX - 1, y: view.bounds.midY - 1, width: 2, height: 2)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard let url = session.currentURL, let application = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func setDesktopPicture(_ sender: Any?) {
        guard let url = session.currentURL, let screen = view.window?.screen ?? NSScreen.main else { return }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            announce("Set as the desktop picture")
        } catch {
            presentFailure(error, title: "The desktop picture couldn’t be changed")
        }
    }

    @objc func showMoreMenu(_ sender: NSView) {
        let menu = MenuBuilder.contextMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    // MARK: - Rename, duplicate, trash

    @objc func renameFile(_ sender: Any?) {
        guard let url = session.currentURL, let window = view.window else { return }
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)

        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(url, to: field.stringValue)
        }
        // Select the name and leave the extension alone, as Finder does.
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    private func rename(_ url: URL, to name: String) {
        do {
            let renamed = try FileActions.rename(url, to: name)
            guard renamed != url else { return }
            let previous = url.lastPathComponent
            session.replace(url, with: renamed)
            let landed = renamed.resolvingSymlinksInPath().standardizedFileURL
            editor?.url = landed
            pdfPaneIfLoaded?.noteRenamed(to: landed)
            undoManager?.registerUndo(withTarget: self) { controller in
                controller.rename(landed, to: previous)
            }
            undoManager?.setActionName("Rename")
            refreshChrome(for: session)
        } catch {
            presentFailure(error, title: "The file couldn’t be renamed")
        }
    }

    @objc func duplicateFile(_ sender: Any?) {
        guard let url = session.currentURL else { return }
        do {
            let copy = try FileActions.duplicate(url)
            leaveCurrent { [self] in
                session.insert(copy, at: session.index + 1)
            }
        } catch {
            presentFailure(error, title: "The file couldn’t be duplicated")
        }
    }

    /// Delete-and-advance: the file goes to the Trash and the next one takes
    /// its place. ⌘Z brings it back to where it was, in the folder and in
    /// the list.
    @objc func moveToTrash(_ sender: Any?) {
        guard let url = session.currentURL else { return }
        // Unsaved edits to something being thrown away go with it.
        finishActiveTool()
        endDocumentMarkup()
        discardChanges(reload: false)
        pdfPaneIfLoaded?.unload()
        trash(url)
    }

    private func trash(_ url: URL) {
        guard let position = session.urls.firstIndex(of: url) else { return }
        do {
            let trashed = try FileActions.trash(url)
            session.remove(url)
            undoManager?.registerUndo(withTarget: self) { controller in
                controller.untrash(trashed, to: url, at: position)
            }
            undoManager?.setActionName("Move to Trash")

            // Nothing left to look at: the viewer has no reason to stay.
            if session.urls.isEmpty {
                (view.window as? ViewerWindow)?.dismissAnimated()
            } else {
                announce("Moved to the Trash  ·  ⌘Z to put it back")
            }
        } catch {
            presentFailure(error, title: "“\(url.lastPathComponent)” couldn’t be moved to the Trash")
        }
    }

    private func untrash(_ trashed: URL, to url: URL, at position: Int) {
        do {
            try FileActions.restore(trashed, to: url)
            leaveCurrent { [self] in
                session.insert(url, at: position)
                undoManager?.registerUndo(withTarget: self) { controller in controller.trash(url) }
                undoManager?.setActionName("Move to Trash")
            }
        } catch {
            presentFailure(error, title: "“\(url.lastPathComponent)” couldn’t be put back")
        }
    }

    // MARK: - Inspector

    @objc func toggleInspector(_ sender: Any?) {
        if let inspector {
            inspector.removeFromSuperview()
            self.inspector = nil
        } else {
            guard adjustPanel == nil else { return }
            let panel = InspectorPanel()
            inspector = panel
            install(panel)
            refreshInspector()
        }
        updateCanvasInsets()
        updateNavigationControls()
    }

    /// Re-reads the file's facts for the panel. Off the main thread, because
    /// a header parse on a network volume is not instant.
    func refreshInspector() {
        guard let inspector, let url = session.currentURL else { return }
        Task {
            let metadata = await Task.detached(priority: .userInitiated) { ImageMetadata.read(url) }.value
            guard self.inspector === inspector, url == session.currentURL else { return }
            inspector.show(metadata)
        }
    }
}
