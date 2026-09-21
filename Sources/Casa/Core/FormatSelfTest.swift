import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes every file in a folder and reports what happened, so format
/// coverage is a measurement rather than an assumption.
///
/// Run with `--selftest <folder>`. Picasa's viewer opened essentially anything
/// the machine could decode, and matching that is not a feature you can eyeball
/// — a format either round-trips through the real decode ladder or it does not.
/// This drives the same `ImageSource` the app uses, so a regression here is a
/// regression in the app.
enum FormatSelfTest {

    struct Row {
        let name: String
        let accepted: Bool
        let pixels: CGSize?
        let frames: Int
        let tier: String
        let milliseconds: Double
        let note: String
    }

    static func run(directory: URL) async -> Never {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            print("no files in \(directory.path)")
            exit(1)
        }

        var rows: [Row] = []
        for file in files {
            rows.append(await examine(file))
        }

        let nameWidth = max(18, rows.map(\.name.count).max() ?? 18)
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
        }

        print("")
        print(pad("FILE", nameWidth) + "  OPEN  " + pad("PIXELS", 12) + pad("FRAMES", 8) + pad("TIER", 10) + pad("MS", 8) + "NOTE")
        print(String(repeating: "-", count: nameWidth + 52))
        for row in rows {
            let size = row.pixels.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
            print(pad(row.name, nameWidth)
                  + "  " + (row.accepted ? " ok  " : "MISS ") + " "
                  + pad(size, 12)
                  + pad(row.frames > 1 ? "\(row.frames)" : (row.frames == 1 ? "1" : "-"), 8)
                  + pad(row.tier, 10)
                  + pad(String(format: "%.1f", row.milliseconds), 8)
                  + row.note)
        }

        // Fixtures named `bad_*` are deliberately malformed. Rejecting them
        // without crashing is the pass condition, not a failure — Quick Look
        // abort-traps on one of these.
        let expectedToFail = rows.filter { $0.name.hasPrefix("bad_") }
        let real = rows.filter { !$0.name.hasPrefix("bad_") }

        let failures = real.filter { $0.pixels == nil }
        let leaked = expectedToFail.filter { $0.pixels != nil }
        let animated = rows.filter { $0.note.contains("animated") }
        let videos = rows.filter { $0.note.contains("video") }
        // Decodes, but a folder scan would not list it — an extensionless file
        // is shown when opened directly and skipped when enumerating, because
        // sniffing every file in a large folder costs an open per file.
        let unlisted = real.filter { !$0.accepted && $0.pixels != nil }

        print("")
        print("\(real.count - failures.count)/\(real.count) displayable"
              + "  ·  \(animated.count) animated"
              + "  ·  \(videos.count) video"
              + "  ·  \(expectedToFail.count - leaked.count)/\(expectedToFail.count) malformed rejected safely")
        if !unlisted.isEmpty {
            print("open-only (not listed when scanning): " + unlisted.map(\.name).joined(separator: ", "))
        }
        if !failures.isEmpty {
            print("FAILED: " + failures.map(\.name).joined(separator: ", "))
        }
        if !leaked.isEmpty {
            print("MALFORMED ACCEPTED: " + leaked.map(\.name).joined(separator: ", "))
        }
        exit(failures.isEmpty && leaked.isEmpty ? 0 : 1)
    }

    private static func examine(_ url: URL) async -> Row {
        let name = url.lastPathComponent
        let accepted = SupportedTypes.canOpen(url)
        let start = ContinuousClock.now

        // Movies do not go through ImageIO; they are examined by producing the
        // same poster frame the app puts in the ladder and the filmstrip.
        if VideoSource.isVideo(url) {
            guard let poster = await VideoSource.posterFrame(url, maxPixelSize: 2048) else {
                return Row(name: name, accepted: accepted, pixels: nil, frames: 0, tier: "-",
                           milliseconds: start.duration(to: .now).seconds * 1000,
                           note: "video: no poster frame")
            }
            let native = await VideoSource.naturalSize(url)
                ?? CGSize(width: poster.width, height: poster.height)
            let seconds = await VideoSource.duration(url) ?? 0
            return Row(name: name, accepted: accepted, pixels: native, frames: 1, tier: "poster",
                       milliseconds: start.duration(to: .now).seconds * 1000,
                       note: String(format: "video %.1fs", seconds))
        }

        guard let size = ImageSource.probe(url) else {
            return Row(name: name, accepted: accepted, pixels: nil, frames: 0,
                       tier: "-", milliseconds: 0,
                       note: accepted ? "probe failed" : "not accepted")
        }

        // Walk the real ladder and record the best rung that produced pixels.
        var tier = "-"
        for candidate in [DecodeTier.thumbnail, .preview, .display] {
            if ImageSource.decode(url, tier: candidate, maxPixelSize: 2048) != nil {
                tier = candidate.name
            }
        }

        // Prove the animation actually decodes, not merely that frames exist.
        var note = tier == "-" ? "no rung produced pixels" : ""
        let frames = ImageSource.frameCount(url)
        if frames > 1 {
            if let animation = ImageSource.animation(url) {
                note = String(format: "animated %.2fs loop", animation.totalDuration)
            } else {
                note = "multi-frame but animation decode failed"
            }
        } else if case .pdf(let pages) = VectorSource.kind(of: url), pages > 1 {
            note = "pdf \(pages) pages"
        }

        let elapsed = start.duration(to: .now).seconds * 1000
        return Row(name: name, accepted: accepted, pixels: size, frames: frames,
                   tier: tier, milliseconds: elapsed, note: note)
    }
}
