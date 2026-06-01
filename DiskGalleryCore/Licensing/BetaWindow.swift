import Foundation

/// Pure time-window math for the beta hard-stop. "14 days from first launch":
/// the window expires at `firstLaunch + durationDays` and is **inclusive** of the
/// boundary instant (>= expiry counts as expired). No UI, no persistence — the app's
/// `BetaGate` supplies `firstLaunch` (from UserDefaults) and `now`.
public struct BetaWindow: Sendable, Equatable {
    public let firstLaunch: Date
    public let durationDays: Int

    public init(firstLaunch: Date, durationDays: Int = 14) {
        self.firstLaunch = firstLaunch
        self.durationDays = durationDays
    }

    /// The instant the window closes.
    public var expiry: Date {
        firstLaunch.addingTimeInterval(Double(durationDays) * 86_400)
    }

    public func isExpired(now: Date) -> Bool {
        now >= expiry
    }

    /// Whole days remaining, rounded up, clamped to `0`.
    public func daysLeft(now: Date) -> Int {
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int(ceil(remaining / 86_400))
    }
}
