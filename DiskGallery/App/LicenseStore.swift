import Foundation
import Observation
import DiskGalleryCore

/// Build-time licensing configuration.
enum LicenseConfig {
    static let product = "com.dbarkan.DiskGallery"

    /// Ed25519 **public** key (base64). Empty ⇒ licensing disabled ⇒ everything unlocked
    /// (dev builds). Paired private key lives only in the seller's `dgkeygen` env.
    static let publicKeyBase64 = "iH7+6uh/56PEP/YfcjUhgHOkNdGmLWgdxezXsNa0M2k="

    /// One-time Pro price, shown in the upgrade sheet. Configurable; nothing depends on the value.
    static let proPrice = "$19"

    /// Where "Buy" sends people.
    static let buyURL = URL(string: "https://diskgallery.app")!
    /// Where the expired-beta "Check for update" button sends people (Sparkle-ready later).
    static let updatesURL = URL(string: "https://diskgallery.app/download")!
    /// Where the expired-beta "Send feedback" button sends people.
    static let feedbackURL = URL(string: "https://diskgallery.app/feedback")!
}

/// Tracks freemium license state. Verification is fully offline via `LicenseVerifier`.
/// Free tier is perpetual; Pro is a one-time unlock. No trial.
@MainActor
@Observable
final class LicenseStore {
    enum Status: Equatable {
        case unconfigured            // no public key in this build → licensing disabled
        case free                    // configured, no valid key → free tier
        case licensed(email: String)
    }

    private let verifier: LicenseVerifier?
    private let defaults: UserDefaults
    private let keyDefaultsKey = "license.key"

    private(set) var status: Status = .unconfigured

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        verifier = try? LicenseVerifier(product: LicenseConfig.product,
                                        publicKeyBase64: LicenseConfig.publicKeyBase64)
        refresh()
    }

    /// Premium features unlocked? True for unconfigured (dev) and licensed; false for free.
    var isPro: Bool {
        switch status {
        case .unconfigured, .licensed: return true
        case .free:                    return false
        }
    }

    /// Single call site for gating. Uniform policy today (== isPro); the `Feature`
    /// argument lets the policy vary per-feature later without touching callers.
    func isUnlocked(_ feature: Feature) -> Bool { isPro }

    var licenseEmail: String? {
        if case .licensed(let email) = status { return email }
        return nil
    }

    func refresh() {
        guard let verifier else { status = .unconfigured; return }
        if let key = defaults.string(forKey: keyDefaultsKey), let payload = try? verifier.verify(key) {
            status = .licensed(email: payload.email)
        } else {
            status = .free
        }
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
