import Foundation

/// The user-assigned role of a drive. Drives the Organize solver's destination
/// preferences (which drive should receive Backups vs Moves) without ever moving
/// files — the plan stays a non-destructive suggestion. Raw values are persisted —
/// keep them stable. Display labels are renameable in the app layer.
public enum DriveRole: String, CaseIterable, Sendable, Codable {
    case localSystem, main, work, mainBackup, fallbackBackup, archive, neutral

    /// The stock display name (the app may override this with a custom label).
    public var defaultLabel: String {
        switch self {
        case .localSystem:    return "Local / System"
        case .main:           return "Main"
        case .work:           return "Work / Scratch"
        case .mainBackup:     return "Main Backup"
        case .fallbackBackup: return "Fallback Backup"
        case .archive:        return "Archive / Cold"
        case .neutral:        return "Neutral"
        }
    }

    /// Local/System (the boot disk) is only ever a source to clear — never a target.
    public var neverDestination: Bool { self == .localSystem }

    /// Can a drive with this role receive items tagged `tag` as a destination?
    /// Neutral is always an eligible fallback; Local/System never is.
    public func canReceive(_ tag: Tag) -> Bool {
        if neverDestination { return false }
        return rank(for: tag) > 0 || self == .neutral
    }

    /// Destination preference for `tag` — higher is better; 0 means "no role preference"
    /// (still eligible only if `neutral`, handled by `canReceive`).
    public func rank(for tag: Tag) -> Int {
        switch (tag, self) {
        case (.backup, .mainBackup):     return 3
        case (.backup, .fallbackBackup): return 2
        case (.move, .archive):          return 3
        case (.move, .main):             return 2
        case (.move, .work):             return 1
        default:                         return 0
        }
    }
}
