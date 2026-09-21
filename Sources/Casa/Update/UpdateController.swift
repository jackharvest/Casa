import AppKit
import Foundation

/// Owns the update lifecycle and publishes one state at a time.
///
/// A single explicit state rather than a scatter of booleans — `isChecking`,
/// `isDownloading`, `hasFailed` and friends can contradict each other, and the
/// UI then renders a combination nobody designed. Here the view is a pure
/// function of one value.
@MainActor
final class UpdateController {

    enum State {
        case idle
        case checking
        case upToDate(SemanticVersion)
        case available(UpdateRelease)
        case downloading(UpdateRelease, UpdateDownloader.Progress)
        case verifying(UpdateRelease)
        case installing(UpdateRelease)
        case relaunching(UpdateRelease)
        case failed(release: UpdateRelease?, message: String, recovery: String)

        /// Whether the user is mid-flight; used to refuse a second start and
        /// to keep the window from being dismissed under them.
        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing, .relaunching: true
            case .idle, .upToDate, .available, .failed: false
            }
        }
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?
    /// Asked for the photograph to reopen after relaunching, so an update
    /// costs the user their place for a second rather than losing it.
    var currentlyViewedFile: (() -> URL?)?

    private var work: Task<Void, Never>?
    private let checker = UpdateChecker()

    /// How long between background checks. Daily: often enough that a fix
    /// lands, rare enough that it is never the reason the app feels busy.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    var isConfigured: Bool { checker != nil }
    var currentVersion: SemanticVersion? { checker?.currentVersion }

    // MARK: - Checking

    /// Silent background check, throttled, skipping versions the user declined.
    func checkInBackgroundIfDue() {
        guard Preferences.automaticUpdateChecks, checker != nil, !state.isBusy else { return }
        if let last = Preferences.lastUpdateCheck,
           Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    /// - Parameter userInitiated: a user-initiated check reports being up to
    ///   date and surfaces errors. A background one stays quiet unless it has
    ///   something to offer — an app that announces "no updates" unprompted is
    ///   an app that interrupts for nothing.
    func check(userInitiated: Bool) {
        guard let checker else {
            if userInitiated {
                state = .failed(release: nil,
                                message: UpdateChecker.Failure.noRepositoryConfigured.localizedDescription,
                                recovery: "Check GitHub for a newer build.")
            }
            return
        }
        guard !state.isBusy else { return }

        work?.cancel()
        state = .checking

        work = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await checker.check()
                Preferences.lastUpdateCheck = Date()
                guard !Task.isCancelled else { return }

                switch outcome {
                case .upToDate(let version):
                    if userInitiated { self.state = .upToDate(version) } else { self.state = .idle }

                case .available(let release):
                    // A skipped version stays skipped for background checks
                    // only; asking explicitly means you want to know.
                    if !userInitiated, Preferences.skippedVersion == release.version.description {
                        self.state = .idle
                        return
                    }
                    Log.update.notice("update available: \(release.version.description, privacy: .public)")
                    self.state = .available(release)
                }
            } catch {
                Log.update.error("check failed: \(error.localizedDescription, privacy: .public)")
                if userInitiated {
                    self.state = .failed(release: nil,
                                         message: error.localizedDescription,
                                         recovery: "Try again, or check GitHub directly.")
                } else {
                    self.state = .idle
                }
            }
        }
    }

    // MARK: - Installing

    func install(_ release: UpdateRelease) {
        guard !state.isBusy else { return }

        // Refused up front rather than after a download: walking someone
        // through a 20 MB transfer and *then* saying it cannot be installed is
        // the rudest possible ordering.
        guard UpdateInstaller.canInstallInPlace() else {
            let failure = UpdateInstaller.Failure.notWritable(Bundle.main.bundleURL)
            state = .failed(release: release,
                            message: failure.localizedDescription,
                            recovery: failure.recovery)
            return
        }

        work?.cancel()
        state = .downloading(release, .init(received: 0, expected: release.archiveBytes, bytesPerSecond: 0))

        work = Task { [weak self] in
            guard let self else { return }
            do {
                let downloader = UpdateDownloader()
                // The outer task already holds `self` strongly for its own
                // duration, so this inner hop takes it strongly too rather
                // than mixing ownership within one scope.
                let archive = try await downloader.download(release) { progress in
                    Task { @MainActor in
                        guard case .downloading = self.state else { return }
                        self.state = .downloading(release, progress)
                    }
                }
                guard !Task.isCancelled else { return }

                self.state = .verifying(release)
                // `Optional.map` cannot take an async closure, so these are
                // bound explicitly rather than mapped.
                var digest: String?
                if let url = release.digestURL { digest = try await UpdateChecker.fetchText(url) }
                var signature: String?
                if let url = release.signatureURL { signature = try await UpdateChecker.fetchText(url) }

                // Off the main actor: hashing 20 MB and unpacking a bundle are
                // both long enough to drop frames.
                let staged = try await Task.detached(priority: .userInitiated) {
                    try UpdateSecurity.verify(archive: archive,
                                              expectedDigest: digest,
                                              signatureBase64: signature)
                    return try UpdateInstaller.stage(archive: archive, expecting: release.version)
                }.value
                guard !Task.isCancelled else { return }

                self.state = .installing(release)
                try UpdateInstaller.install(staged: staged)

                self.state = .relaunching(release)
                let reopen = self.currentlyViewedFile?()
                // One beat so the relaunching state is actually seen. An
                // update that finishes invisibly reads as a crash.
                try? await Task.sleep(for: .milliseconds(700))
                UpdateInstaller.relaunch(reopening: reopen)

            } catch is CancellationError {
                self.state = .available(release)
            } catch let failure as UpdateSecurity.Failure {
                Log.update.error("verification failed: \(failure.localizedDescription, privacy: .public)")
                self.state = .failed(release: release,
                                     message: failure.localizedDescription,
                                     recovery: failure.recovery)
            } catch let failure as UpdateInstaller.Failure {
                Log.update.error("install failed: \(failure.localizedDescription, privacy: .public)")
                self.state = .failed(release: release,
                                     message: failure.localizedDescription,
                                     recovery: failure.recovery)
            } catch {
                Log.update.error("update failed: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(release: release,
                                     message: error.localizedDescription,
                                     recovery: "Try again, or download the release from GitHub.")
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        if case .downloading(let release, _) = state {
            state = .available(release)
        } else if state.isBusy {
            state = .idle
        }
    }

    func skip(_ release: UpdateRelease) {
        Preferences.skippedVersion = release.version.description
        state = .idle
    }

    func dismiss() {
        if state.isBusy { return }
        state = .idle
    }
}
