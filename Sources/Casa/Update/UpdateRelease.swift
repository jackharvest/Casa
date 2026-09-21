import Foundation

/// A release published on GitHub, reduced to what the updater needs.
struct UpdateRelease: Sendable {
    let version: SemanticVersion
    let title: String
    /// Release notes, as markdown.
    let notes: String
    let publishedAt: Date?
    /// The release page, for the "view on GitHub" escape hatch.
    let pageURL: URL
    let archiveURL: URL
    let archiveBytes: Int64
    /// Sidecar assets carrying the digest and signature.
    let digestURL: URL?
    let signatureURL: URL?

    var hasVerificationMaterial: Bool { digestURL != nil && signatureURL != nil }
}

/// Decodes the subset of GitHub's release JSON we depend on.
///
/// Hand-written rather than `Codable` over the whole payload: the response has
/// well over a hundred fields, almost all of them irrelevant, and a strict
/// decoder would break the updater the next time GitHub adds one.
struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int64
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    /// Converts to an `UpdateRelease`, or nil if this release has nothing we
    /// can install.
    func resolved() -> UpdateRelease? {
        guard !draft, let version = SemanticVersion(tagName) else { return nil }

        // The app archive, by extension rather than by exact name, so the
        // naming scheme can change without stranding old clients.
        guard let archive = assets.first(where: { $0.name.hasSuffix(".zip") }) else { return nil }

        return UpdateRelease(
            version: version,
            title: name?.isEmpty == false ? name! : "Casa \(version)",
            notes: body ?? "",
            publishedAt: publishedAt,
            pageURL: htmlURL,
            archiveURL: archive.browserDownloadURL,
            archiveBytes: archive.size,
            digestURL: assets.first { $0.name.hasSuffix(".sha256") }?.browserDownloadURL,
            signatureURL: assets.first { $0.name.hasSuffix(".sig") }?.browserDownloadURL
        )
    }
}
