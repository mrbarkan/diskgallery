import Foundation
import Observation
import DiskGalleryCore

/// Build-time licensing configuration. Fill these in when you set up sales.
enum LicenseConfig {
    static let product = "com.dbarkan.DiskGallery"

    /// Your Ed25519 **public** key (base64), produced alongside the private key you
    /// keep secret for signing keys. While this is empty, licensing stays OFF and every
    /// feature is unlocked — so development and testing are never blocked.
    ///
    /// Generate a keypair with `LicenseSigner()` (e.g. a tiny one-off script):
    ///   let s = LicenseSigner(); print(s.privateKeyBase64, s.publicKeyBase64)
    static let publicKeyBase64 = ""

    static let trialDays = 14

    /// Where the "Buy" button sends people (your Lemon Squeezy / Paddle / site link).
    static let buyURL = URL(string: "https://diskgallery.app")!
}

/// Tracks the app's license state: free trial, activated license, or (once configured)
/// an expired trial. Verification is fully offline via `LicenseVerifier`.
@MainActor
@Observable
final class LicenseStore {
    enum Status: Equatable {
        case unconfigured           // no public key in this build → licensing disabled
        case trial(daysLeft: Int)
        case trialExpired
        case licensed(email: String)
    }

    private let verifier: LicenseVerifier?
    private let defaults = UserDefaults.standard
    private let keyDefaultsKey = "license.key"
    private let firstLaunchKey = "license.firstLaunch"

    private(set) var status: Status = .unconfigured

    init() {
        verifier = try? LicenseVerifier(product: LicenseConfig.product,
                                        publicKeyBase64: LicenseConfig.publicKeyBase64)
        if defaults.object(forKey: firstLaunchKey) == nil {
            defaults.set(Date(), forKey: firstLaunchKey)
        }
        refresh()
    }

    /// Are premium features unlocked? Always true until licensing is configured and the
    /// trial has expired, so turning licensing on later is a one-line gate per feature.
    var isPro: Bool {
        switch status {
        case .unconfigured, .trial, .licensed: return true
        case .trialExpired: return false
        }
    }

    var licenseEmail: String? {
        if case .licensed(let email) = status { return email }
        return nil
    }

    func refresh() {
        guard let verifier else { status = .unconfigured; return }
        if let key = defaults.string(forKey: keyDefaultsKey), let payload = try? verifier.verify(key) {
            status = .licensed(email: payload.email)
            return
        }
        let first = (defaults.object(forKey: firstLaunchKey) as? Date) ?? Date()
        let elapsed = Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
        let left = LicenseConfig.trialDays - elapsed
        status = left > 0 ? .trial(daysLeft: left) : .trialExpired
    }

    /// Activates a pasted key. Returns nil on success, or a human-readable error.
    @discardableResult
    func activate(_ key: String) -> String? {
        guard let verifier else { return LicenseError.notConfigured.errorDescription }
        do {
            let payload = try verifier.verify(key)
            defaults.set(key, forKey: keyDefaultsKey)
            status = .licensed(email: payload.email)
            return nil
        } catch {
            return (error as? LicenseError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deactivate() {
        defaults.removeObject(forKey: keyDefaultsKey)
        refresh()
    }
}
