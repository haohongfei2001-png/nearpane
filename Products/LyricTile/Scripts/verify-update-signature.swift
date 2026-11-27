import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Usage: verify-update-signature.swift ARCHIVE PUBLIC_KEY SIGNATURE\n", stderr)
    exit(2)
}
do {
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    guard publicKey.isValidSignature(signature, for: archive) else {
        fputs("The Sparkle Ed25519 signature does not match these archive bytes.\n", stderr)
        exit(1)
    }
    print("Ed25519 signature verified against the app's public key and exact archive bytes.")
} catch {
    fputs("Signature verification failed: \(error)\n", stderr)
    exit(1)
}
