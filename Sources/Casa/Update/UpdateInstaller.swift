import AppKit
import Foundation
import Security

/// Unpacks a verified archive, replaces the running app, and relaunches it.
///
/// Replacing a running application sounds impossible and is not: the running
/// process holds its executable by inode, so the bundle directory can be
/// swapped underneath it. What it cannot do is *become* the new version — so
/// the last step hands off to a detached shell that waits for this process to
/// exit and then launches the replacement.
enum UpdateInstaller {

    enum Failure: LocalizedError {
        case notWritable(URL)
        case unpackFailed(String)
        case noBundleInArchive
        case identifierMismatch(expected: String, found: String)
        case notNewer(found: SemanticVersion, current: SemanticVersion)
        case codeSignatureInvalid(OSStatus)
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .notWritable(let url):
                "Casa can’t update itself where it’s installed (\(url.deletingLastPathComponent().path))."
            case .unpackFailed(let detail):
                "The update couldn’t be unpacked. \(detail)"
            case .noBundleInArchive:
                "The update archive doesn’t contain an app."
            case .identifierMismatch(let expected, let found):
                "The update is a different app (\(found), expected \(expected))."
            case .notNewer(let found, let current):
                "The update is version \(found), which isn’t newer than \(current)."
            case .codeSignatureInvalid:
                "The update’s code signature is invalid, so it won’t be installed."
            case .replaceFailed(let detail):
                "Casa couldn’t replace itself. \(detail)"
            }
        }

        var recovery: String {
            switch self {
            case .notWritable:
                "Move Casa to your Applications or Downloads folder and try again."
            default:
                "Download the release from GitHub and replace Casa manually."
            }
        }
    }

    /// Whether an in-place update is possible at all. Checked before offering
    /// one, so the user is never walked through a download that cannot land.
    static func canInstallInPlace(bundle: Bundle = .main) -> Bool {
        let app = bundle.bundleURL
        return FileManager.default.isWritableFile(atPath: app.path)
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Unpacks and validates, returning the staged bundle ready to swap in.
    ///
    /// Kept separate from `install` so everything that can fail safely fails
    /// *before* the running app is touched.
    static func stage(archive: URL, expecting version: SemanticVersion,
                      bundle: Bundle = .main) throws -> URL {
        let currentApp = bundle.bundleURL
        guard canInstallInPlace(bundle: bundle) else { throw Failure.notWritable(currentApp) }

        // Same volume as the destination, which `replaceItemAt` requires to be
        // atomic. `.itemReplacementDirectory` exists for exactly this.
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: currentApp, create: true)

        // `ditto` rather than `unzip`: it preserves extended attributes and
        // the code signature, which `unzip` silently drops — and a bundle with
        // a stripped signature is refused by Gatekeeper on first launch.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, scratch.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            throw Failure.unpackFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let staged = try locateBundle(in: scratch) else { throw Failure.noBundleInArchive }
        try validate(staged, expecting: version, against: bundle)
        return staged
    }

    private static func locateBundle(in directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        return contents.first { $0.pathExtension == "app" }
    }

    /// Three independent checks, all of which must pass: it is the same app,
    /// it is newer, and its signature is intact.
    private static func validate(_ staged: URL, expecting version: SemanticVersion,
                                 against current: Bundle) throws {
        guard let stagedBundle = Bundle(url: staged) else { throw Failure.noBundleInArchive }

        let expectedIdentifier = current.bundleIdentifier ?? "com.jackharvest.casa"
        let foundIdentifier = stagedBundle.bundleIdentifier ?? "?"
        guard foundIdentifier == expectedIdentifier else {
            throw Failure.identifierMismatch(expected: expectedIdentifier, found: foundIdentifier)
        }

        let foundVersion = (stagedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(SemanticVersion.init) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        let currentVersion = (current.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(SemanticVersion.init) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        guard foundVersion > currentVersion else {
            throw Failure.notNewer(found: foundVersion, current: currentVersion)
        }

        // Confirms the bundle has not been modified since it was signed. With
        // an ad-hoc signature this proves nothing about *who* signed it — the
        // Ed25519 check in `UpdateSecurity` is what establishes authorship —
        // but it does catch a corrupted or tampered-with unpack.
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(staged as CFURL, [], &staticCode)
        if status == errSecSuccess, let staticCode {
            status = SecStaticCodeCheckValidity(staticCode, [], nil)
        }
        guard status == errSecSuccess else { throw Failure.codeSignatureInvalid(status) }

        Log.update.info("staged \(foundVersion.description, privacy: .public) validated")
    }

    /// Swaps the staged bundle in. Atomic — after this returns the app on disk
    /// is entirely the old version or entirely the new one, never a mixture.
    static func install(staged: URL, bundle: Bundle = .main) throws {
        let currentApp = bundle.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(currentApp, withItemAt: staged,
                                                      backupItemName: nil,
                                                      options: [.usingNewMetadataOnly])
        } catch {
            throw Failure.replaceFailed(error.localizedDescription)
        }
        Log.update.info("replaced bundle at \(currentApp.path, privacy: .public)")
    }

    /// Relaunches and terminates.
    ///
    /// A process cannot exec its own replacement cleanly while AppKit is
    /// running, so a detached shell does the waiting: it polls until this PID
    /// is gone, then opens the new bundle. Reopening the photograph that was
    /// on screen means the update costs the user their place for about a
    /// second rather than losing it.
    static func relaunch(reopening file: URL?, bundle: Bundle = .main) -> Never {
        let app = bundle.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        var command = "while kill -0 \(pid) 2>/dev/null; do sleep 0.15; done; sleep 0.2; "
        if let file {
            command += "open -a \(shellQuoted(app)) \(shellQuoted(file.path))"
        } else {
            command += "open \(shellQuoted(app))"
        }

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", command]
        // Detached: this outlives us, which is the entire point.
        try? relaunch.run()

        Log.update.notice("relaunching into the updated build")
        // `exit` rather than `NSApp.terminate`: terminate is interruptible by
        // delegates and window controllers, and there is nothing left to save.
        exit(0)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
