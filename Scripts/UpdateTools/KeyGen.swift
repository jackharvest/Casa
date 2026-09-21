// Generates the Ed25519 keypair that signs releases.
//
// The private half signs; it must never be committed and must be backed up.
// Losing it means every future release is rejected by every installed copy of
// the app until users update manually.
//
// usage: KeyGen <private-key-out>
import CryptoKit
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: out.path) else {
    FileHandle.standardError.write(Data("refusing to overwrite existing key at \(out.path)\n".utf8))
    exit(1)
}

let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: out, options: [.atomic])
// Owner read/write only. A signing key readable by anything else on the
// machine is not a signing key.
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)

print(key.publicKey.rawRepresentation.base64EncodedString())
