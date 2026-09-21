import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Runtime assertions over the arithmetic that is easy to break and hard to
/// notice: version ordering, zoom anchoring, and the dismiss surround.
///
/// A runtime check against the real `ImageCanvasView` rather than a unit test
/// against a copy of the maths. The behaviour that matters here is emergent —
/// it depends on the view's bounds, its content insets and its backing scale —
/// and a test that reimplemented those would pass while the app was wrong.
///
/// `--selfcheck` exits non-zero on failure, so it works as a CI gate alongside
/// `--selftest`.
@MainActor
enum SelfCheck {

    private nonisolated(unsafe) static var failures: [String] = []

    private static func expect(_ condition: Bool, _ description: String) {
        if condition {
            print("  ok   \(description)")
        } else {
            print("  FAIL \(description)")
            failures.append(description)
        }
    }

    private static func expectClose(_ actual: CGFloat, _ expected: CGFloat,
                                    _ tolerance: CGFloat, _ description: String) {
        expect(abs(actual - expected) <= tolerance,
               "\(description) — got \(String(format: "%.2f", actual)), expected ~\(String(format: "%.2f", expected))")
    }

    static func run() -> Never {
        print("\nversion ordering")
        checkVersions()
        print("\nzoom anchoring")
        checkZoomAnchoring()
        print("\nsurround regions")
        checkDismissSurround()
        print("\ndigest")
        checkDigest()
        print("\nrotation")
        checkRotation()

        print("")
        if failures.isEmpty {
            print("all self-checks passed")
            exit(0)
        }
        print("\(failures.count) self-check(s) failed")
        exit(1)
    }

    // MARK: - Versions

    private static func checkVersions() {
        func version(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

        // The bug this exists to prevent: string comparison puts 0.10.0 below
        // 0.9.0, which would silently stop offering updates after the tenth
        // minor release.
        expect(version("0.10.0") > version("0.9.0"), "0.10.0 > 0.9.0")
        expect(version("1.0.0") > version("0.99.99"), "1.0.0 > 0.99.99")
        expect(version("v1.2.3") == version("1.2.3"), "a leading v is ignored")
        expect(version("1.2") == version("1.2.0"), "a missing patch is zero")
        expect(version("1.0.0-beta.1") < version("1.0.0"), "a prerelease precedes its release")
        expect(version("1.0.0-beta.2") > version("1.0.0-beta.1"), "prerelease numbers compare numerically")
        expect(version("1.0.0-beta.10") > version("1.0.0-beta.2"), "prerelease numbers are not strings")
        expect(version("1.2.3+build9") == version("1.2.3"), "build metadata is ignored")
        expect(SemanticVersion("not a version") == nil, "garbage does not parse")
    }

    // MARK: - Zoom

    private static func checkZoomAnchoring() {
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let image = solidImage(width: 4000, height: 2000)
        canvas.display(image, preservingZoom: false)
        canvas.layoutSubtreeIfNeeded()

        var before = canvas.displayedRect
        expect(before.width > 0, "a fitted image has a non-zero footprint")
        // Fit never upscales, and a 4000 px image in a 1000 pt view must be
        // bounded by the width.
        expect(before.width <= 1000, "fit does not exceed the view width")

        // Anchor on a point a third of the way across the image and confirm
        // that the same *image* pixel stays under it after zooming.
        before = canvas.displayedRect
        let anchor = CGPoint(x: before.minX + before.width / 3,
                            y: before.minY + before.height / 2)
        let fractionBefore = (anchor.x - before.minX) / before.width

        canvas.zoom(by: 2.5, at: anchor)
        let after = canvas.displayedRect
        let fractionAfter = (anchor.x - after.minX) / after.width

        expectClose(fractionAfter, fractionBefore, 0.01,
                    "the image point under the cursor stays under the cursor")
        expectClose(after.width / before.width, 2.5, 0.01, "zooming by 2.5x scales 2.5x")

        // And zooming back out returns to the same place.
        canvas.zoom(by: 1 / 2.5, at: anchor)
        let restored = canvas.displayedRect
        expectClose(restored.width, before.width, 0.5, "zooming out restores the footprint")
        expectClose((anchor.x - restored.minX) / restored.width, fractionBefore, 0.01,
                    "the anchored point survives a round trip")

        // Zooming into a corner, repeatedly, across the fit boundary.
        //
        // This is the regression that mattered: the clamp used to collapse to a
        // single permitted position exactly when the image grew past the
        // viewport, so a corner zoom snapped to the middle.
        canvas.fit(animated: false)
        let corner = CGPoint(x: canvas.displayedRect.minX + canvas.displayedRect.width * 0.08,
                             y: canvas.displayedRect.minY + canvas.displayedRect.height * 0.08)
        let cornerFractionBefore = (corner.x - canvas.displayedRect.minX) / canvas.displayedRect.width
        for _ in 0..<24 { canvas.zoom(by: 1.15, at: corner) }
        let zoomed = canvas.displayedRect
        expect(zoomed.width > 1000, "twenty-four steps really did zoom in")
        expectClose((corner.x - zoomed.minX) / zoomed.width, cornerFractionBefore, 0.02,
                    "a corner stays under the pointer across the fit boundary")

        canvas.fit(animated: false)
    }

    // MARK: - Surround

    /// The surround is what switches to windowed mode, so the regions matter
    /// as much as when it dismissed.
    private static func checkDismissSurround() {
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        canvas.contentInsets = NSEdgeInsets(top: 60, left: 10, bottom: 120, right: 10)
        // A tall image in a wide view leaves surround to the left and right.
        canvas.display(solidImage(width: 400, height: 1200), preservingZoom: false)
        canvas.layoutSubtreeIfNeeded()

        let image = canvas.displayedRect
        expect(image.width < 1000, "a tall image leaves horizontal surround")

        expect(canvas.isPointInDismissableSurround(CGPoint(x: 20, y: 400)),
               "the left margin is surround")
        expect(canvas.isPointInDismissableSurround(CGPoint(x: 980, y: 400)),
               "the right margin is surround")
        expect(!canvas.isPointInDismissableSurround(CGPoint(x: image.midX, y: image.midY)),
               "the photograph itself is not surround")
        // Someone aiming for the rail and missing must not close the window.
        expect(!canvas.isPointInDismissableSurround(CGPoint(x: 500, y: 760)),
               "the bottom chrome band is not surround")
        expect(!canvas.isPointInDismissableSurround(CGPoint(x: 500, y: 20)),
               "the top chrome band is not surround")
    }

    // MARK: - Digest

    private static func checkDigest() {
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent("casa-selfcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        try? Data("abc".utf8).write(to: file)
        // The canonical SHA-256 of "abc".
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let actual = (try? UpdateSecurity.digest(of: file)) ?? ""
        expect(actual == expected, "SHA-256 of \"abc\" matches the published digest")

        expect(UpdateSecurity.isConfigured, "an update signing key is embedded")
    }

    // MARK: - Rotation

    /// Round-trips a rotation through a real file.
    ///
    /// Worth a test because it is the only thing Casa writes. A bug here
    /// damages the user's photograph rather than just looking wrong.
    private static func checkRotation() {
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent("casa-rotate-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }

        // A real JPEG, written through ImageIO so it has proper metadata.
        let image = solidImage(width: 200, height: 120).cgImage
        guard let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            expect(false, "could not create a test JPEG")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            expect(false, "could not write a test JPEG")
            return
        }

        let sizeBefore = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
        expect(ImageRotator.orientation(of: file) == 1, "a fresh JPEG starts at orientation 1")
        expect(ImageRotator.canRotate(file), "a writable JPEG can be rotated")

        do {
            try ImageRotator.apply(quarterTurns: 1, to: file)
        } catch {
            expect(false, "one turn clockwise: \(error.localizedDescription)")
            return
        }
        expect(ImageRotator.orientation(of: file) == 6, "one turn clockwise gives orientation 6")

        // Three more turns must come back to where it started.
        try? ImageRotator.apply(quarterTurns: 3, to: file)
        expect(ImageRotator.orientation(of: file) == 1, "four turns returns to orientation 1")

        let sizeAfter = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
        // Only the metadata is rewritten, so four rotations must not
        // meaningfully change the file. A re-encode would move this a lot.
        let drift = abs(sizeAfter - sizeBefore)
        expect(drift < max(2048, sizeBefore / 20),
               "four rotations are lossless (drift \(drift) bytes of \(sizeBefore))")

        expect(ImageSource.probe(file) != nil, "the rotated file still decodes")
    }

    // MARK: - Helpers

    private static func solidImage(width: Int, height: Int) -> DecodedImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return DecodedImage(cgImage: context.makeImage()!, tier: .display,
                            nativePixelSize: CGSize(width: width, height: height))
    }
}
