// Signs a release archive's SHA-256 digest with the Ed25519 private key.
//
// The signature covers the hex digest string rather than the archive bytes, so
// signing stays cheap and the digest check and the signature check remain
// independent of one another.
//
// usage: Sign <private-key> <archive>   -> prints base64 signature
import CryptoKit
import Foundation

let keyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let keyText = try? String(contentsOf: keyURL, encoding: .utf8),
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
else {
    FileHandle.standardError.write(Data("cannot read signing key at \(keyURL.path)\n".utf8))
    exit(1)
}

let handle = try FileHandle(forReadingFrom: archiveURL)
var hasher = SHA256()
while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
    hasher.update(data: chunk)
}
try handle.close()

let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
let signature = try key.signature(for: Data(digest.utf8))

// digest on the first line, signature on the second
print(digest)
print(signature.base64EncodedString())
