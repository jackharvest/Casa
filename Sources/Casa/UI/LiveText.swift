import AppKit
import VisionKit

/// Selectable text in photographs.
///
/// A screenshot of an error, a photo of a whiteboard, a scan of a receipt:
/// half the reason anyone opens these is to get the words out of them. The
/// system's own recogniser finds the text and draws the selection, so it
/// behaves exactly as it does in Photos and Preview — drag to select, ⌘C to
/// copy, links and phone numbers live.
///
/// It is deliberately late and lazy. Recognition starts only once the picture
/// has been still on screen for a moment, and is abandoned the instant the
/// user moves on, so walking a folder never pays for reading photographs
/// nobody stopped to look at.
@MainActor
final class LiveText: NSObject, ImageAnalysisOverlayViewDelegate {

    /// Sits over the photograph. Clicks reach it only where there is text;
    /// everywhere else they fall through to the canvas, so panning and
    /// double-click zoom behave as if it were not there.
    let view = PassthroughView()

    private let overlay = ImageAnalysisOverlayView()
    private let analyzer = ImageAnalyzer()
    private var task: Task<Void, Never>?
    private var generation = 0

    static var isSupported: Bool { ImageAnalyzer.isSupported }

    override init() {
        super.init()
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        overlay.delegate = self
        // No floating Live Text badge in the corner of the photograph; the
        // text is simply selectable.
        overlay.isSupplementaryInterfaceHidden = true
        overlay.autoresizingMask = [.width, .height]
        view.overlay = overlay
        view.addSubview(overlay)
        view.isHidden = true
    }

    /// The words currently selected, if any.
    var selectedText: String? {
        let text = overlay.selectedText
        return text.isEmpty ? nil : text
    }

    var hasText: Bool { overlay.analysis?.hasResults(for: .text) ?? false }

    func selectAll() { overlay.selectAll(nil) }

    /// What was last read, so a sharper copy of the same picture arriving
    /// does not throw away a selection the user is in the middle of.
    private var subject: String?

    /// Reads the picture, after a pause.
    ///
    /// - Parameter key: identifies the picture's content. The same key again
    ///   is ignored.
    func analyze(_ image: CGImage, key: String) {
        guard key != subject else { return }
        clear()
        guard Self.isSupported else { return }
        subject = key
        generation += 1
        let generation = self.generation
        let analyzer = self.analyzer
        let picture = DecodedImage(cgImage: image, tier: .display,
                                   nativePixelSize: CGSize(width: image.width, height: image.height))

        task = Task { [weak self] in
            // Long enough that a held arrow key never gets here.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let configuration = ImageAnalyzer.Configuration([.text])
            let analysis: ImageAnalysis?
            do {
                analysis = try await analyzer.analyze(picture.cgImage, orientation: .up,
                                                      configuration: configuration)
            } catch {
                Log.render.error("text recognition failed: \(error.localizedDescription, privacy: .public)")
                analysis = nil
            }
            guard let self, !Task.isCancelled, generation == self.generation, let analysis else { return }
            Log.render.info("text recognition: \(analysis.hasResults(for: .text) ? "found text" : "no text", privacy: .public)")
            self.overlay.analysis = analysis
            self.view.isHidden = !analysis.hasResults(for: .text)
        }
    }

    /// Forgets the current picture's text. Called on every navigation.
    func clear() {
        task?.cancel()
        task = nil
        subject = nil
        generation += 1
        if overlay.analysis != nil {
            overlay.resetSelection()
            overlay.analysis = nil
        }
        view.isHidden = true
    }

    // The overlay is laid exactly over the photograph, so the image fills it.
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Takes clicks only where there is something to select or follow.
    final class PassthroughView: NSView {
        fileprivate weak var overlay: ImageAnalysisOverlayView?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let overlay, !isHidden else { return nil }
            let local = overlay.convert(point, from: superview)
            guard overlay.hasInteractiveItem(at: local) || overlay.hasActiveTextSelection else { return nil }
            return super.hitTest(point)
        }
    }
}
