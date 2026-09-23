import AppKit

/// Every size in this app comes from here. Nothing hardcodes a pixel.
///
/// Three independent things scale the interface and all three must be honored
/// at once, because a user can be using any combination of them:
///
///   1. **Display resolution.** Handled by AppKit: we work in points and the
///      backing store renders at 1x/2x/3x. The rule is simply to never reason
///      in pixels — `backingScaleFactor` appears exactly once in this codebase,
///      in the decode ladder, where we genuinely need a pixel count.
///   2. **System text size.** `NSFont.preferredFont(forTextStyle:)` tracks the
///      Accessibility text-size setting. Deriving icon and spacing sizes from
///      the *resolved* font means one setting moves the whole interface
///      coherently, instead of type growing while icons stay stranded.
///   3. **Symbol weight/scale.** SF Symbols carry optical sizing. Configuring a
///      symbol with a text style rather than a point size lets the glyph pick
///      the right optical variant, so a small icon is not just a shrunk large
///      one — strokes stay the correct weight against the type beside it.
///
/// The failure mode this file exists to prevent: an icon specified as
/// `NSSize(width: 16, height: 16)`. That is correct on exactly one machine.
@MainActor
enum Metrics {

    /// Typographic roles in the viewer chrome. Each maps to a system text style
    /// so it inherits the user's text-size preference.
    enum Role {
        /// Primary chrome controls — the navigation and rotation buttons.
        case control
        /// The filename readout along the top edge.
        case title
        /// Counters, dimensions, EXIF crumbs.
        case caption
        /// The centred play button. The only deliberately large control.
        case hero

        var textStyle: NSFont.TextStyle {
            switch self {
            case .control: .body
            case .title: .headline
            case .caption: .caption1
            case .hero: .largeTitle
            }
        }

        /// Optical scale for symbols in this role. `.large` gives chrome
        /// controls presence without inflating their layout box.
        var symbolScale: NSImage.SymbolScale {
            switch self {
            case .control: .large
            case .title: .medium
            case .caption: .small
            case .hero: .large
            }
        }
    }

    // MARK: - Type

    static func font(_ role: Role) -> NSFont {
        NSFont.preferredFont(forTextStyle: role.textStyle)
    }

    /// The resolved point size for a role, after the user's text-size setting.
    /// This is the number every other metric is derived from.
    static func pointSize(_ role: Role) -> CGFloat {
        font(role).pointSize
    }

    // MARK: - Icons

    /// Builds an SF Symbol that tracks the user's text size and the current
    /// accessibility contrast setting.
    ///
    /// The returned image is marked as a template so it picks up the layer's
    /// tint, and `isAccessibilityElement`-facing description is required rather
    /// than optional — an unlabeled icon button is invisible to VoiceOver.
    static func icon(_ symbolName: String,
                     role: Role = .control,
                     describedAs description: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbolName,
                                 accessibilityDescription: description) else {
            Log.render.error("Missing SF Symbol: \(symbolName, privacy: .public)")
            return nil
        }

        // Increase Contrast thickens strokes so glyphs hold up against a
        // photograph, which is an unusually hostile background for chrome.
        // The heavier variant is built from the text style's *resolved* point
        // size rather than a literal, so it still tracks the user's text
        // setting — a weight change must not cost us the scaling.
        let configuration: NSImage.SymbolConfiguration =
            if Accommodations.current.increaseContrast {
                NSImage.SymbolConfiguration(pointSize: pointSize(role),
                                            weight: .semibold,
                                            scale: role.symbolScale)
            } else {
                NSImage.SymbolConfiguration(textStyle: role.textStyle,
                                            scale: role.symbolScale)
            }

        let configured = base.withSymbolConfiguration(configuration)
        configured?.isTemplate = true
        return configured
    }

    // MARK: - Layout

    /// Spacing unit, proportional to body text. A "step" is roughly one third
    /// of the body point size, so gaps open up alongside type instead of
    /// pinching shut when someone raises their text size.
    static func spacing(_ steps: CGFloat = 1) -> CGFloat {
        (pointSize(.control) / 3).rounded() * steps
    }

    /// Minimum clickable edge for a chrome control. Scales with type, and never
    /// drops below the macOS comfortable-target floor even at the smallest
    /// text setting.
    static func hitTarget(_ role: Role = .control) -> CGFloat {
        // The hero control is sized to be unmissable rather than merely
        // tappable, so it gets its own multiple.
        let multiple: CGFloat = role == .hero ? 2.6 : 2.2
        return max(28, (pointSize(role) * multiple).rounded())
    }

    /// Corner radius for chrome surfaces, proportional so the curve keeps its
    /// relationship to the control it rounds.
    static func cornerRadius(_ role: Role = .control) -> CGFloat {
        (pointSize(role) * 0.45).rounded()
    }

    /// Filmstrip thumbnail edge, in points.
    static var filmstripThumb: CGFloat {
        (pointSize(.control) * 5).rounded()
    }
}

/// Sizes for the viewer's chrome, which floats over a photograph filling a
/// whole display rather than sitting in a window someone reads up close.
///
/// Same inputs as `Metrics` — the user's text size drives everything — plus
/// the display itself. A 32-inch 4K panel at 1x and a 14-inch laptop show
/// thirteen points at nearly the same physical size, but nobody sits as close
/// to the 32-inch one, and a control cluster sized for the laptop becomes a
/// speck in the middle of a vast dark ground. So the chrome grows with the
/// short edge of the screen it is on, from 1x at 1100 points to a ceiling of
/// 1.45x, and the settings windows — which are read, not glanced at — stay on
/// plain `Metrics`.
@MainActor
enum ChromeMetrics {

    /// Set from the viewer's screen. Returns true if it changed, so the caller
    /// knows to re-lay out.
    @discardableResult
    static func adopt(_ screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        let shortEdge = min(screen.frame.width, screen.frame.height)
        let next = min(1.45, max(1, (shortEdge / 1100 * 20).rounded() / 20))
        guard next != displayScale else { return false }
        displayScale = next
        return true
    }

    private(set) static var displayScale: CGFloat = 1

    /// The chrome reads a step larger than body copy at every size. Picasa's
    /// controls were chunky, and a photograph is a busy background that
    /// swallows fine type.
    private static func boost(_ role: Metrics.Role) -> CGFloat {
        switch role {
        case .control: 1.25
        case .title: 1.2
        case .caption: 1.25
        case .hero: 1.0
        }
    }

    static func pointSize(_ role: Metrics.Role) -> CGFloat {
        (Metrics.pointSize(role) * boost(role) * displayScale).rounded()
    }

    static func font(_ role: Metrics.Role, weight: NSFont.Weight? = nil) -> NSFont {
        let size = pointSize(role)
        switch role {
        case .title: return .systemFont(ofSize: size, weight: weight ?? .semibold)
        case .caption: return .monospacedDigitSystemFont(ofSize: size, weight: weight ?? .medium)
        default: return .systemFont(ofSize: size, weight: weight ?? .regular)
        }
    }

    static func icon(_ symbolName: String,
                     role: Metrics.Role = .control,
                     weight: NSFont.Weight = .medium,
                     describedAs description: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbolName,
                                 accessibilityDescription: description) else {
            Log.render.error("Missing SF Symbol: \(symbolName, privacy: .public)")
            return nil
        }
        let contrast = Accommodations.current.increaseContrast
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize(role),
            weight: contrast ? .bold : weight,
            scale: role == .hero ? .large : .medium)
        let configured = base.withSymbolConfiguration(configuration)
        configured?.isTemplate = true
        return configured
    }

    /// Spacing unit: a third of the control size, rounded to whole points.
    static func spacing(_ steps: CGFloat = 1) -> CGFloat {
        (pointSize(.control) / 3).rounded() * steps
    }

    /// A control's square target. Generous, because these are hit with a
    /// mouse travelling across a large screen, not a finger on a small one.
    static func hitTarget(_ role: Metrics.Role = .control) -> CGFloat {
        let multiple: CGFloat = role == .hero ? 2.6 : 2.3
        return max(32, (pointSize(role) * multiple).rounded())
    }

    static var filmstripThumb: CGFloat {
        (pointSize(.control) * 4.2).rounded()
    }
}
