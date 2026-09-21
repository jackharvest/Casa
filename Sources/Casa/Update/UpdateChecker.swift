import Foundation

/// Asks GitHub whether there is a newer release.
///
/// Reads the repository from `Info.plist` rather than hardcoding it, so a fork
/// can point at its own releases without touching code.
struct UpdateChecker: Sendable {

    enum Outcome: Sendable {
        case upToDate(current: SemanticVersion)
        case available(UpdateRelease)
    }

    enum Failure: LocalizedError {
        case noRepositoryConfigured
        case rateLimited
        case network(String)
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .noRepositoryConfigured: "This build has no update source configured."
            case .rateLimited: "GitHub is rate-limiting update checks. Try again later."
            case .network(let detail): detail
            case .badResponse(let code): "GitHub returned an unexpected response (\(code))."
            }
        }
    }

    let repository: String
    let currentVersion: SemanticVersion

    /// Reads both from the running bundle.
    init?(bundle: Bundle = .main) {
        guard let repository = bundle.object(forInfoDictionaryKey: "CasaUpdateRepository") as? String,
              !repository.isEmpty,
              let versionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = SemanticVersion(versionString)
        else { return nil }
        self.repository = repository
        self.currentVersion = version
    }

    /// Every recent release, newest first. Used by the What's New pane.
    func recentReleases(limit: Int = 12) async throws -> [UpdateRelease] {
        try await fetchReleases()
            .filter { !$0.prerelease }
            .compactMap { $0.resolved() }
            .sorted { $0.version > $1.version }
            .prefix(limit)
            .map { $0 }
    }

    func check(includePrereleases: Bool = false) async throws -> Outcome {
        let releases = try await fetchReleases()

        let candidates = releases
            .filter { includePrereleases || !$0.prerelease }
            .compactMap { $0.resolved() }
            .filter { $0.version > currentVersion }
            .sorted { $0.version > $1.version }

        guard let newest = candidates.first else { return .upToDate(current: currentVersion) }
        return .available(newest)
    }

    /// One request, shared by the update check and the What's New pane.
    private func fetchReleases() async throws -> [GitHubRelease] {
        // `/releases` rather than `/releases/latest`: the latter hides
        // pre-releases entirely, and we want to make that our decision rather
        // than GitHub's.
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20") else {
            throw Failure.noRepositoryConfigured
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Casa/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        // Update checks must never serve a stale answer from a shared cache.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Unauthenticated callers get 60 requests an hour, which a daily
            // check never approaches — but a developer hammering it will.
            throw http.statusCode == 403 || http.statusCode == 429
                ? Failure.rateLimited
                : Failure.badResponse(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GitHubRelease].self, from: data)) ?? []
    }

    /// Fetches a small sidecar asset — the digest or the signature.
    static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        // Sidecars are tiny; anything large is not what we asked for.
        guard data.count < 4096, let text = String(data: data, encoding: .utf8) else {
            throw Failure.network("Unexpected content in \(url.lastPathComponent).")
        }
        // `shasum` writes "<digest>  <filename>"; take the first field.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).first ?? ""
    }
}
