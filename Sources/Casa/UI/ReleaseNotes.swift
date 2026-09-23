import AppKit

/// Renders GitHub release notes for display.
///
/// Markdown parsed line by line rather than wholesale. `AttributedString`'s
/// full markdown parser produces presentation intents that still have to be
/// turned into fonts and indentation by hand, so the block structure —
/// headings, bullets, rules — is handled here and only the *inline* formatting
/// (bold, code, links) is delegated to Foundation.
///
/// Every size comes from `Metrics`, so notes grow with the user's text size
/// like everything else.
@MainActor
enum ReleaseNotes {

    static func rendered(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        // Body size, not caption: notes are read, and at caption size a
        // paragraph of them was a strain on anything but a laptop.
        let body = Metrics.font(.control)
        let heading = NSFont.systemFont(ofSize: Metrics.pointSize(.control) * 1.15, weight: .semibold)
        let indent = Metrics.spacing(3.5)
        /// Set by a rule, so the next heading opens a new section with room
        /// above it.
        var afterRule = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Machine-readable markers some releases carry; never shown.
            if line.hasPrefix("<!--") { continue }

            // Blank lines are dropped: paragraph spacing carries the rhythm.
            // Rendering each one as an empty line stacked four or five of
            // them between releases, which read as a gap in the page.
            if line.isEmpty { continue }

            if line.hasPrefix("---") || line.hasPrefix("***") {
                afterRule = true
                continue
            }

            // Headings: the marker is dropped and the weight carries the level.
            if let stripped = line.dropHashes() {
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = output.length == 0 ? 0
                    : Metrics.spacing(afterRule ? 5 : 3)
                style.paragraphSpacing = Metrics.spacing(1.5)
                afterRule = false
                output.append(inline(stripped, font: heading, color: .labelColor, style: style))
                output.append(NSAttributedString(string: "\n"))
                continue
            }

            // Bullets: a real bullet glyph and a hanging indent, so wrapped
            // lines align under the text rather than under the marker.
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                let style = NSMutableParagraphStyle()
                style.headIndent = indent
                style.firstLineHeadIndent = Metrics.spacing(1)
                style.paragraphSpacing = Metrics.spacing(1.25)
                style.lineSpacing = 2
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]

                // The bullet and tab are prepended *after* parsing. Running the
                // inline parser over a string that starts with a tab makes it
                // treat the line as preformatted, and bold inside bullets then
                // renders as literal asterisks.
                let marker = NSMutableAttributedString(
                    string: "•\t",
                    attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor,
                                 .paragraphStyle: style])
                marker.append(inline(String(line.dropFirst(2)), font: body,
                                     color: .secondaryLabelColor, style: style))
                output.append(marker)
                output.append(NSAttributedString(string: "\n"))
                continue
            }

            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = Metrics.spacing(1.25)
            style.lineSpacing = 2
            output.append(inline(line, font: body, color: .secondaryLabelColor, style: style))
            output.append(NSAttributedString(string: "\n"))
        }

        return output
    }

    /// Inline markdown — bold, italic, code, links — via Foundation, then the
    /// block-level font and colour applied underneath so they do not fight.
    private static func inline(_ text: String, font: NSFont, color: NSColor,
                               style: NSParagraphStyle) -> NSAttributedString {
        let parsed: NSMutableAttributedString
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            parsed = NSMutableAttributedString(attributed)
        } else {
            parsed = NSMutableAttributedString(string: text)
        }

        let whole = NSRange(location: 0, length: parsed.length)
        parsed.addAttributes([.paragraphStyle: style], range: whole)

        // Fill in only where the inline parser left the attribute unset, so
        // its bold and italic survive.
        parsed.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let existing = value as? NSFont else {
                parsed.addAttribute(.font, value: font, range: range)
                return
            }
            let traits = existing.fontDescriptor.symbolicTraits
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            parsed.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font,
                                range: range)
        }
        parsed.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { parsed.addAttribute(.foregroundColor, value: color, range: range) }
        }
        return parsed
    }
}

private extension String {
    /// Strips leading `#` markers, returning nil when there are none.
    func dropHashes() -> String? {
        guard hasPrefix("#") else { return nil }
        return String(drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
    }
}
