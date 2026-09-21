import CryptoKit
import Foundation

/// Verifies that a downloaded update is the one the author published.
///
/// This is the most security-sensitive code in the app: everything downstream
/// of it executes as the user. Two independent checks have to pass.
///
/// **SHA-256** proves the bytes arrived intact and match what the release
/// claims. On its own it proves nothing about authorship — whoever wrote the
/// release notes wrote the hash too.
///
/// **Ed25519** is what actually matters. The archive digest is signed with a
/// private key that never leaves the author's machine and is never in this
/// repository; the public half is compiled in below. That means a compromised
/// GitHub account is not enough to push a malicious update — an attacker who
/// can edit releases still cannot produce a signature this app will accept.
/// It is the difference between "the download was not corrupted" and "the
/// author made this".
enum UpdateSecurity {

    /// Ed25519 public key, base64, 32 bytes.
    ///
    /// Replaced by `Scripts/keygen.swift` when a keypair is generated. While
    /// this is empty, signature verification is *unavailable* and
    /// `verify` refuses to install anything — failing closed, because an
    /// updater that silently accepts unsigned code is worse than no updater.
    static let publicKeyBase64 = "vadjX7MW2gKE8Zh3nD22DsmH4K7hamldlLx7+aKWdcI="

    enum Failure: LocalizedError {
        case noPublicKey
        case malformedPublicKey
        case digestMismatch(expected: String, actual: String)
        case missingSignature
        case malformedSignature
        case signatureRejected

        var errorDescription: String? {
            switch self {
            case .noPublicKey:
                "This build has no update signing key, so updates can’t be verified."
            case .malformedPublicKey:
                "This build’s update signing key is unreadable."
            case .digestMismatch:
                "The download doesn’t match what the release published. It may be incomplete."
            case .missingSignature:
                "The release is missing its signature."
            case .malformedSignature:
                "The release signature is unreadable."
            case .signatureRejected:
                "The download isn’t signed by Casa’s author and won’t be installed."
            }
        }

        /// What the user can actually do about it.
        var recovery: String {
            switch self {
            case .digestMismatch, .missingSignature, .malformedSignature:
                "Try again, or download the release from GitHub manually."
            case .signatureRejected:
                "Download only from github.com/jackharvest/Casa."
            case .noPublicKey, .malformedPublicKey:
                "Update manually from GitHub."
            }
        }
    }

    static var isConfigured: Bool {
        !publicKeyBase64.hasPrefix("__") && Data(base64Encoded: publicKeyBase64)?.count == 32
    }

    /// Hex SHA-256 of a file, streamed so a large archive is never held whole.
    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the archive against the digest and signature the release
    /// published. Throws on any doubt; never returns a partial verdict.
    static func verify(archive: URL, expectedDigest: String?, signatureBase64: String?) throws {
        guard isConfigured else { throw Failure.noPublicKey }
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw Failure.malformedPublicKey }

        let actual = try digest(of: archive)

        // Compared case-insensitively, but not short-circuited: the digest is
        // not a secret, so constant time buys nothing here, and clarity does.
        if let expectedDigest, expectedDigest.lowercased() != actual {
            throw Failure.digestMismatch(expected: expectedDigest.lowercased(), actual: actual)
        }

        guard let signatureBase64, !signatureBase64.isEmpty else { throw Failure.missingSignature }
        guard let signature = Data(base64Encoded: signatureBase64) else { throw Failure.malformedSignature }

        // The signature covers the hex digest string, which is what
        // `Scripts/release.sh` signs. Signing the digest rather than the whole
        // archive keeps signing cheap and the two checks independent.
        guard key.isValidSignature(signature, for: Data(actual.utf8)) else {
            throw Failure.signatureRejected
        }
    }
}
