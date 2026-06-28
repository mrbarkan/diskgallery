import Foundation
import Observation
import DiskGalleryCore

/// The build-specific beta hard-stop. Active only in builds compiled with the `BETA`
/// flag (the beta DMG). Records first-launch in UserDefaults and reports expiry via the
/// pure `BetaWindow`. In non-beta builds it is inert (`isExpired == false`).
@MainActor
@Observable
final class BetaGate {
    /// Per-build so each beta (a new `CURRENT_PROJECT_VERSION`) starts its own 14-day
    /// window — bumping the beta number gives testers a fresh clock instead of inheriting
    /// an earlier beta's first-launch date.
    private var firstLaunchKey: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "beta.firstLaunch.\(build)"
    }
    private let durationDays = 14
    private let defaults: UserDefaults

    private(set) var isExpired = false
    private(set) var daysLeft = 0

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        #if BETA
        let firstLaunch: Date
        if let stored = defaults.object(forKey: firstLaunchKey) as? Date {
            firstLaunch = stored
        } else {
            firstLaunch = now                          // fail-open: never expire on day one
            defaults.set(now, forKey: firstLaunchKey)
        }
        let window = BetaWindow(firstLaunch: firstLaunch, durationDays: durationDays)
        isExpired = window.isExpired(now: now)
        daysLeft = window.daysLeft(now: now)
        #endif
    }
}
