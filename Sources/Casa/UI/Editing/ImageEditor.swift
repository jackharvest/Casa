import AppKit

/// The picture being edited: one upright, full-resolution bitmap, replaced
/// whole by each edit.
///
/// There is no list of operations to replay. Every tool takes the bitmap and
/// hands back a new one, and undo is simply the previous bitmap — which costs
/// memory instead of cleverness, and is why the undo depth is kept short.
@MainActor
final class ImageEditor {

    var url: URL
    private(set) var image: CGImage
    /// The bitmap that matches the file on disk, if any of them does.
    private var saved: CGImage?

    /// Fired after every change, including undo and redo.
    var onChange: (() -> Void)?

    /// - Parameter matchesFile: false when the starting bitmap already
    ///   differs from the file — a turn that was showing but not yet written.
    init(url: URL, image: CGImage, matchesFile: Bool) {
        self.url = url
        self.image = image
        self.saved = matchesFile ? image : nil
    }

    var isDirty: Bool { image !== saved }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    func apply(_ next: CGImage, named name: String, undoManager: UndoManager?) {
        let previous = image
        image = next
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.apply(previous, named: name, undoManager: undoManager)
        }
        undoManager?.setActionName(name)
        onChange?()
    }

    func markSaved() { saved = image }
}
