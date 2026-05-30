import XCTest
@testable import DiskGalleryCore

final class LicenseTests: XCTestCase {
    let product = "com.dbarkan.DiskGallery"

    private func makePair() -> (signer: LicenseSigner, verifier: LicenseVerifier) {
        let signer = LicenseSigner()
        let verifier = try! LicenseVerifier(product: product, publicKeyBase64: signer.publicKeyBase64)
        return (signer, verifier)
    }

    func testValidKeyRoundTrips() throws {
        let (signer, verifier) = makePair()
        let payload = LicensePayload(product: product, email: "dbarkan@gmail.com",
                                     issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let key = try signer.makeKey(for: payload)

        let verified = try verifier.verify(key)
        XCTAssertEqual(verified.email, "dbarkan@gmail.com")
        XCTAssertEqual(verified.product, product)
    }

    func testTamperedKeyIsRejected() throws {
        let (signer, verifier) = makePair()
        let key = try signer.makeKey(for: LicensePayload(product: product, email: "a@b.com",
                                                         issuedAt: Date(timeIntervalSince1970: 1)))
        // Flip a character in the payload section.
        var chars = Array(key)
        let dot = chars.firstIndex(of: ".")!
        chars[dot - 1] = chars[dot - 1] == "A" ? "B" : "A"
        XCTAssertThrowsError(try verifier.verify(String(chars))) { error in
            XCTAssertTrue(error is LicenseError)
        }
    }

    func testKeyFromDifferentPrivateKeyIsRejected() throws {
        let attacker = LicenseSigner()                                   // different keypair
        let (_, verifier) = makePair()
        let forged = try attacker.makeKey(for: LicensePayload(product: product, email: "x@y.com",
                                                              issuedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertThrowsError(try verifier.verify(forged)) { XCTAssertEqual($0 as? LicenseError, .badSignature) }
    }

    func testWrongProductIsRejected() throws {
        let (signer, verifier) = makePair()
        let key = try signer.makeKey(for: LicensePayload(product: "com.someone.else", email: "a@b.com",
                                                         issuedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertThrowsError(try verifier.verify(key)) { XCTAssertEqual($0 as? LicenseError, .wrongProduct) }
    }

    func testExpiredLicenseIsRejected() throws {
        let (signer, verifier) = makePair()
        let issued = Date(timeIntervalSince1970: 1_000)
        let expires = Date(timeIntervalSince1970: 2_000)
        let key = try signer.makeKey(for: LicensePayload(product: product, email: "a@b.com",
                                                         issuedAt: issued, expiresAt: expires))
        // Valid before expiry, invalid after.
        XCTAssertNoThrow(try verifier.verify(key, now: Date(timeIntervalSince1970: 1_500)))
        XCTAssertThrowsError(try verifier.verify(key, now: Date(timeIntervalSince1970: 3_000))) {
            XCTAssertEqual($0 as? LicenseError, .expired)
        }
    }

    func testEmptyPublicKeyMeansNotConfigured() {
        XCTAssertThrowsError(try LicenseVerifier(product: product, publicKeyBase64: "")) {
            XCTAssertEqual($0 as? LicenseError, .notConfigured)
        }
    }
}
