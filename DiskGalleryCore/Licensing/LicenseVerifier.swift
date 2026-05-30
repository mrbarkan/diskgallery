import Foundation
import CryptoKit

/// The signed contents of a license key.
public struct LicensePayload: Codable, Sendable, Equatable {
    public var product: String           // e.g. "com.dbarkan.DiskGallery"
    public var email: String             // who it was issued to
    public var issuedAt: Date
    public var expiresAt: Date?          // nil = perpetual license
    public var seats: Int?

    public init(product: String, email: String, issuedAt: Date,
                expiresAt: Date? = nil, seats: Int? = nil) {
        self.product = product
        self.email = email
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.seats = seats
    }
}

public enum LicenseError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case malformed
    case badSignature
    case wrongProduct
    case expired

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Licensing isn’t configured in this build yet."
        case .malformed: return "That doesn’t look like a valid license key."
        case .badSignature: return "This license key isn’t genuine."
        case .wrongProduct: return "This key is for a different product."
        case .expired: return "This license has expired."
        }
    }
}

/// Verifies license keys **entirely offline** using Ed25519 public-key crypto. The app
/// embeds only the public key; keys are signed elsewhere with the matching private key
/// (by your store / a small signing tool), so no license server is ever needed.
///
/// Key format: `base64url(payloadJSON) + "." + base64url(signature)`, where the
/// signature covers the exact payload-JSON bytes.
public struct LicenseVerifier: Sendable {
    public let product: String
    private let publicKey: Curve25519.Signing.PublicKey

    /// `publicKeyBase64` is the 32-byte Ed25519 public key, base64-encoded. Throws
    /// `.notConfigured` when empty (a placeholder build).
    public init(product: String, publicKeyBase64: String) throws {
        guard !publicKeyBase64.isEmpty else { throw LicenseError.notConfigured }
        guard let raw = Data(base64Encoded: publicKeyBase64) else { throw LicenseError.malformed }
        self.product = product
        self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// Validates `licenseKey` and returns its payload, or throws a `LicenseError`.
    /// `now` is injectable so expiry checks are testable.
    @discardableResult
    public func verify(_ licenseKey: String, now: Date = Date()) throws -> LicensePayload {
        let parts = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let payloadData = Self.base64urlDecode(parts[0]),
              let signature = Self.base64urlDecode(parts[1]) else { throw LicenseError.malformed }

        guard publicKey.isValidSignature(signature, for: payloadData) else { throw LicenseError.badSignature }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(LicensePayload.self, from: payloadData) else {
            throw LicenseError.malformed
        }
        guard payload.product == product else { throw LicenseError.wrongProduct }
        if let expiresAt = payload.expiresAt, expiresAt < now { throw LicenseError.expired }
        return payload
    }

    static func base64urlDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    public static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Issues license keys from a private key. This is **seller-side tooling** — the
/// private key must never ship inside the app. Useful for a tiny key-gen command or
/// for tests. Pairs with `LicenseVerifier`.
public struct LicenseSigner: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init() { self.privateKey = Curve25519.Signing.PrivateKey() }
    public init(privateKeyBase64: String) throws {
        guard let raw = Data(base64Encoded: privateKeyBase64) else { throw LicenseError.malformed }
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    public var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
    public var privateKeyBase64: String { privateKey.rawRepresentation.base64EncodedString() }

    public func makeKey(for payload: LicensePayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)
        let signature = try privateKey.signature(for: payloadData)
        return LicenseVerifier.base64urlEncode(payloadData) + "." + LicenseVerifier.base64urlEncode(signature)
    }
}
