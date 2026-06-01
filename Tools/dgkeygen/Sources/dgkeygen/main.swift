import Foundation
import CryptoKit

// MARK: - Crypto (must match DiskGalleryCore/Licensing/LicenseVerifier.swift exactly)

func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

struct Payload: Codable {
    var product: String
    var email: String
    var issuedAt: Date
    var expiresAt: Date?
    var seats: Int?
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
let product = "com.dbarkan.DiskGallery"

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--generate-keypair") {
    let key = Curve25519.Signing.PrivateKey()
    print("PRIVATE (keep secret, set as DG_PRIVATE_KEY):")
    print(key.rawRepresentation.base64EncodedString())
    print("")
    print("PUBLIC (paste into LicenseConfig.publicKeyBase64):")
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

guard let email = option("--email") else {
    die("""
    usage:
      dgkeygen --generate-keypair
      DG_PRIVATE_KEY=<base64> dgkeygen --email <addr> [--seats N] [--expires YYYY-MM-DD]
    """)
}

guard let privB64 = ProcessInfo.processInfo.environment["DG_PRIVATE_KEY"],
      let privRaw = Data(base64Encoded: privB64),
      let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privRaw) else {
    die("Set DG_PRIVATE_KEY to your base64 private key (from --generate-keypair).")
}

var expiresAt: Date?
if let exp = option("--expires") {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(identifier: "UTC")
    guard let d = fmt.date(from: exp) else { die("--expires must be YYYY-MM-DD") }
    expiresAt = d
}
let seats = option("--seats").flatMap(Int.init)

let payload = Payload(product: product, email: email, issuedAt: Date(),
                      expiresAt: expiresAt, seats: seats)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .secondsSince1970
encoder.outputFormatting = [.sortedKeys]
let payloadData = try encoder.encode(payload)
let signature = try priv.signature(for: payloadData)
print(base64urlEncode(payloadData) + "." + base64urlEncode(signature))
