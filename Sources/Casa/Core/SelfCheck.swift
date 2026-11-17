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
        print("\nedits")
        checkEdits()
        print("\nexport")
        checkExport()
        print("\nmarkup")
        checkMarkup()
        print("\nfile actions")
        checkFileActions()
        print("\ncrop frame")
        checkCropFrame()

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

    // MARK: - Edits

    /// A 40 x 20 picture whose top-left quarter is red and the rest blue, so
    /// every geometric edit has an answer that can be read off one pixel.
    private static func quartered() -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        // Core Graphics is y-up: the top-left quarter is the upper rows.
        context.fill(CGRect(x: 0, y: 10, width: 20, height: 10))
        return context.makeImage()!
    }

    /// Red, green, blue and alpha at a pixel, counted from the top left.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }

    private static func isRed(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 200 && p.b < 60 }
    private static func isBlue(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.b > 200 && p.r < 60 }

    private static func checkEdits() {
        let image = quartered()
        expect(isRed(pixel(image, 5, 5)) && isBlue(pixel(image, 35, 5)) && isBlue(pixel(image, 5, 15)),
               "the test picture is red in its top-left quarter")

        if let cropped = ImageEdits.crop(image, to: CGRect(x: 0, y: 0, width: 20, height: 10)) {
            expect(cropped.width == 20 && cropped.height == 10, "a crop has the size asked for")
            expect(isRed(pixel(cropped, 10, 5)), "a crop is measured from the top left")
        } else {
            expect(false, "crop returned nothing")
        }
        expect(ImageEdits.crop(image, to: CGRect(x: 100, y: 100, width: 5, height: 5)) == nil,
               "a crop outside the picture is refused")

        if let turned = ImageEdits.rotate(image, quarterTurns: 1) {
            expect(turned.width == 20 && turned.height == 40, "a quarter turn swaps the dimensions")
            // Clockwise: what was top-left is now top-right.
            expect(isRed(pixel(turned, 15, 5)) && isBlue(pixel(turned, 5, 5)),
                   "a clockwise turn moves the top-left corner to the top right")
        } else {
            expect(false, "rotate returned nothing")
        }
        if let around = ImageEdits.rotate(image, quarterTurns: 4) {
            expect(isRed(pixel(around, 5, 5)), "four turns come back to the start")
        }
        if let left = ImageEdits.rotate(image, quarterTurns: -1) {
            expect(isRed(pixel(left, 5, 35)), "an anticlockwise turn moves the top-left corner to the bottom left")
        }

        if let mirrored = ImageEdits.flip(image, horizontal: true) {
            expect(isRed(pixel(mirrored, 35, 5)) && isBlue(pixel(mirrored, 5, 5)),
                   "a horizontal flip mirrors left to right")
        }
        if let inverted = ImageEdits.flip(image, horizontal: false) {
            expect(isRed(pixel(inverted, 5, 15)) && isBlue(pixel(inverted, 5, 5)),
                   "a vertical flip mirrors top to bottom")
        }

        if let smaller = ImageEdits.resize(image, to: CGSize(width: 20, height: 10)) {
            expect(smaller.width == 20 && smaller.height == 10, "a resize has the size asked for")
            expect(isRed(pixel(smaller, 3, 2)) && isBlue(pixel(smaller, 16, 7)), "a resize keeps the picture the right way up")
        }

        expect(ImageEdits.adjust(image, Adjustments()) === image, "no adjustment returns the same picture")
        var brighter = Adjustments()
        brighter.exposure = 1
        var grey = Adjustments()
        grey.saturation = -1
        if let lifted = ImageEdits.adjust(solidImage(width: 8, height: 8).cgImage, brighter) {
            expect(pixel(lifted, 4, 4).r > 150, "raising exposure brightens mid grey")
        }
        if let drained = ImageEdits.adjust(image, grey) {
            let p = pixel(drained, 5, 5)
            expect(abs(p.r - p.b) < 12, "zero saturation is grey")
            expect(drained.width == image.width && drained.height == image.height, "an adjustment keeps the size")
        }
    }

    // MARK: - Export

    private static func checkExport() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("casa-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let names = Set(ImageExporter.formats.map(\.name))
        expect(names.isSuperset(of: ["JPEG", "PNG", "TIFF"]), "the everyday formats can be written")

        // An original with a camera and a sideways orientation tag.
        let original = directory.appendingPathComponent("original.jpg")
        if let destination = CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, quartered(), [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Casa Test"],
            ] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        expect(ImageExporter.format(of: original)?.name == "JPEG", "a JPEG is recognised as writable")

        for format in ImageExporter.formats where ["JPEG", "PNG", "TIFF", "HEIC"].contains(format.name) {
            let target = directory.appendingPathComponent("out.\(format.fileExtension)")
            do {
                try ImageExporter.write(quartered(), to: target, format: format, metadataFrom: original)
                let size = ImageSource.probe(target)
                expect(size == CGSize(width: 40, height: 20), "\(format.name) round-trips at the same size")
            } catch {
                expect(false, "\(format.name) export: \(error.localizedDescription)")
            }
        }

        let copy = directory.appendingPathComponent("out.jpeg")
        if let source = CGImageSourceCreateWithURL(copy as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            expect(tiff?[kCGImagePropertyTIFFMake] as? String == "Casa Test", "an export keeps the camera metadata")
            // The exported pixels are already upright; a surviving tag would
            // turn them a second time.
            expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "an export resets the orientation tag")
        } else {
            expect(false, "the exported JPEG could not be read back")
        }

        // Overwriting must leave exactly one file, with the new content.
        if let jpeg = ImageExporter.formats.first(where: { $0.name == "JPEG" }),
           let half = ImageEdits.resize(quartered(), to: CGSize(width: 20, height: 10)) {
            try? ImageExporter.write(half, to: copy, format: jpeg)
            expect(ImageSource.probe(copy) == CGSize(width: 20, height: 10), "saving over a file replaces it")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasPrefix(".casa-") } ?? []
            expect(leftovers.isEmpty, "no scratch files are left behind")
        }
    }

    // MARK: - Markup

    private static func checkMarkup() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let base = solidImage(width: 100, height: 100).cgImage
        let box = MarkupItem(shape: .rectangle(CGRect(x: 20, y: 10, width: 60, height: 30)),
                             color: red, lineWidth: 4, fontSize: 12)

        if let flat = MarkupRenderer.flatten([box], onto: base) {
            expect(flat.width == 100 && flat.height == 100, "flattening keeps the picture's size")
            // The top edge of the box is at y = 10 from the top.
            expect(isRed(pixel(flat, 50, 10)), "a mark lands where it was drawn, measured from the top")
            expect(!isRed(pixel(flat, 50, 25)), "an outline is not filled")
            expect(!isRed(pixel(flat, 50, 90)), "nothing is drawn where there is no mark")
        } else {
            expect(false, "flatten returned nothing")
        }
        expect(MarkupRenderer.flatten([], onto: base) === base, "flattening nothing changes nothing")

        expect(box.contains(CGPoint(x: 50, y: 10), tolerance: 2), "a click on a rectangle's edge selects it")
        expect(!box.contains(CGPoint(x: 50, y: 25), tolerance: 2), "a click inside an outline passes through")

        let moved = box.moved(by: CGSize(width: 5, height: -5))
        expect(moved.bounds == CGRect(x: 25, y: 5, width: 60, height: 30), "moving a mark moves its bounds")

        // Dragging the bottom-right corner keeps the top-left one fixed.
        let stretched = box.reshaped(handle: 2, to: CGPoint(x: 90, y: 60))
        expect(stretched.bounds == CGRect(x: 20, y: 10, width: 70, height: 50), "dragging a corner pivots on the opposite one")

        let arrow = MarkupItem(shape: .arrow(CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 90)),
                               color: red, lineWidth: 3, fontSize: 12)
        expect(arrow.contains(CGPoint(x: 50, y: 51), tolerance: 2), "a click on an arrow's shaft selects it")
        expect(!arrow.contains(CGPoint(x: 80, y: 20), tolerance: 2), "a click beside an arrow does not")
        if let flat = MarkupRenderer.flatten([arrow], onto: base) {
            expect(isRed(pixel(flat, 50, 50)), "an arrow's shaft is drawn")
        }

        let cover = MarkupItem(shape: .redact(CGRect(x: 0, y: 0, width: 50, height: 50)),
                               color: red, lineWidth: 3, fontSize: 12)
        if let flat = MarkupRenderer.flatten([cover], onto: base) {
            let p = pixel(flat, 25, 25)
            expect(p.r < 10 && p.g < 10 && p.b < 10 && p.a == 255, "a cover-up is opaque black whatever the ink colour")
        }
    }

    // MARK: - File actions

    private static func checkFileActions() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("casa-files-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let photo = directory.appendingPathComponent("photo.jpg")
        try? Data("one".utf8).write(to: photo)

        let copy = try? FileActions.duplicate(photo)
        expect(copy?.lastPathComponent == "photo copy.jpg", "a duplicate is named the way Finder names one")
        let second = try? FileActions.duplicate(photo)
        expect(second?.lastPathComponent == "photo copy 2.jpg", "a second duplicate does not overwrite the first")

        let renamed = try? FileActions.rename(photo, to: "holiday")
        expect(renamed?.lastPathComponent == "holiday.jpg", "a rename keeps the extension when it is left off")
        expect(!FileManager.default.fileExists(atPath: photo.path), "a rename moves the file")

        if let renamed {
            var refused = false
            do { _ = try FileActions.rename(renamed, to: "photo copy.jpg") } catch { refused = true }
            expect(refused, "a rename onto an existing file is refused")
            expect(FileManager.default.fileExists(atPath: renamed.path), "a refused rename leaves the file alone")

            var empty = false
            do { _ = try FileActions.rename(renamed, to: "   ") } catch { empty = true }
            expect(empty, "an empty name is refused")

            // The round trip through the real Trash, which is what Undo does.
            if let trashed = try? FileActions.trash(renamed) {
                expect(!FileManager.default.fileExists(atPath: renamed.path), "trashing removes the file from its folder")
                try? FileActions.restore(trashed, to: renamed)
                expect((try? String(contentsOf: renamed, encoding: .utf8)) == "one", "a trashed file can be put back intact")
            } else {
                print("  skip trash round trip — this volume has no Trash")
            }
        }

        expect(ImageMetadata.shutter(0.004) == "1/250 s", "a fast shutter reads as a fraction")
        expect(ImageMetadata.shutter(2) == "2 s", "a slow shutter reads in seconds")
    }

    // MARK: - Crop frame

    private static func checkCropFrame() {
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        canvas.display(solidImage(width: 4000, height: 2000), preservingZoom: false)
        canvas.layoutSubtreeIfNeeded()

        // The overlay's coordinate conversions are the canvas's; if these
        // disagree, a crop cuts somewhere other than where the frame was.
        let corner = canvas.viewPoint(forImagePoint: CGPoint(x: 4000, y: 2000))
        expectClose(corner.x, canvas.displayedRect.maxX, 0.01, "the last image pixel maps to the picture's right edge")
        expectClose(corner.y, canvas.displayedRect.maxY, 0.01, "…and to its bottom edge")
        let back = canvas.imagePoint(forViewPoint: canvas.viewPoint(forImagePoint: CGPoint(x: 1234, y: 567)))
        expectClose(back.x, 1234, 0.01, "image → view → image is the identity")

        let frame = CropOverlayView(canvas: canvas, imageSize: CGSize(width: 4000, height: 2000))
        expect(frame.isWholeImage, "the frame opens around the whole picture")

        frame.setAspect(1)
        expect(frame.cropRect == CGRect(x: 1000, y: 0, width: 2000, height: 2000),
               "a square frame is the largest square, centred")
        expect(!frame.isWholeImage, "a square frame on a wide picture is a real crop")

        frame.setAspect(16.0 / 9)
        expectClose(frame.cropRect.width / frame.cropRect.height, 16.0 / 9, 0.001, "a locked shape holds its ratio")
        expect(CGRect(x: 0, y: 0, width: 4000, height: 2000).contains(frame.cropRect), "the frame stays inside the picture")
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
