import Foundation

/// A semantic version, compared properly.
///
/// String comparison gets this wrong in ways that matter: `"0.10.0" < "0.9.0"`
/// lexicographically, which would silently stop offering updates after the
/// tenth minor release. Pre-release identifiers sort *below* the release they
/// qualify, so `1.0.0-beta.2 < 1.0.0`, per the spec.
struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers, e.g. `["beta", "2"]`. Empty for a
    /// final release.
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `1.2.3`, `v1.2.3`, `1.2`, `1.2.3-beta.1`. Build metadata after
    /// `+` is ignored, as the spec requires.
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        text = text.components(separatedBy: "+").first ?? text

        let parts = text.components(separatedBy: "-")
        let numbers = parts[0].components(separatedBy: ".")
        guard !numbers.isEmpty, let major = Int(numbers[0]) else { return nil }

        self.major = major
        self.minor = numbers.count > 1 ? (Int(numbers[1]) ?? 0) : 0
        self.patch = numbers.count > 2 ? (Int(numbers[2]) ?? 0) : 0
        self.prerelease = parts.count > 1
            ? parts.dropFirst().joined(separator: "-").components(separatedBy: ".")
            : []
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease.joined(separator: "."))"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A version with pre-release identifiers precedes the same core
        // version without them.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            // Numeric identifiers compare numerically and rank below
            // alphanumeric ones.
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
