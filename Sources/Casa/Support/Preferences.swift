import Foundation

/// The handful of things worth remembering between launches.
///
/// Deliberately tiny. A viewer that accumulates settings stops being a viewer.
/// What happens when a playable item — an animated GIF, or a video — opens.
///
/// Deliberately one setting with three states rather than three switches.
/// "Autoplay?" and "Muted?" as independent booleans produce a nonsense
/// combination (manual playback, forced mute) and make the user assemble the
/// behaviour they wanted out of parts. Three named outcomes is the same power
/// with none of the assembly.
enum PlaybackPolicy: String, CaseIterable, Sendable {
    /// Show a play button and wait. The default, because a folder of videos
    /// that all start talking at once is a worse first impression than one
    /// extra click.
    case manual
    /// Start immediately, silent.
    case autoplayMuted
    /// Start immediately, with sound.
    case autoplayWithSound

    var title: String {
        switch self {
        case .manual: "Click to Play"
        case .autoplayMuted: "Play Automatically (Muted)"
        case .autoplayWithSound: "Play Automatically (With Sound)"
        }
    }

    var autoplays: Bool { self != .manual }
    var muted: Bool { self != .autoplayWithSound }
}

@MainActor
enum Preferences {

    private enum Key {
        static let followsFinderSort = "followsFinderSort"
        static let hidesDock = "hidesDock"
        static let playback = "playbackPolicy"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let skippedVersion = "skippedUpdateVersion"
    }

    /// Whether to inherit the sort order of the Finder window a photo was
    /// opened from.
    ///
    /// Defaults to off, because switching it on requires permission to send
    /// Apple Events to Finder, and that permission is requested with a modal
    /// system dialog. Showing that to someone who has just double-clicked a
    /// photo — before they have any idea what this app is — would be the worst
    /// possible first impression. It turns on from the View menu, deliberately.
    static var followsFinderSort: Bool {
        get { UserDefaults.standard.bool(forKey: Key.followsFinderSort) }
        set { UserDefaults.standard.set(newValue, forKey: Key.followsFinderSort) }
    }

    /// Take the whole screen, covering the Dock and menu bar, for a larger
    /// photograph.
    ///
    /// Off by default. The thumbnail rail is pinned to the bottom edge, and at
    /// full-screen size the Dock sits on top of it — so the default trades a
    /// little image size for a rail that is actually usable.
    /// How animations and videos behave on open.
    static var playbackPolicy: PlaybackPolicy {
        get {
            UserDefaults.standard.string(forKey: Key.playback)
                .flatMap(PlaybackPolicy.init(rawValue:)) ?? .manual
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.playback) }
    }

    /// Look for updates in the background. On by default, which is the
    /// platform norm and the only honest default for an app that ships its own
    /// updater — a security fix nobody finds isn't a fix.
    static var automaticUpdateChecks: Bool {
        get {
            UserDefaults.standard.object(forKey: Key.automaticUpdateChecks) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.automaticUpdateChecks) }
    }

    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: Key.lastUpdateCheck) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// A version the user asked not to be told about again. Explicitly *not*
    /// "don't check any more" — the next release after it is still offered.
    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Key.skippedVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Key.skippedVersion) }
    }

    static var hidesDock: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hidesDock) }
        set { UserDefaults.standard.set(newValue, forKey: Key.hidesDock) }
    }
}
