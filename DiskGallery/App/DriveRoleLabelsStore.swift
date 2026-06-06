import Foundation
import Observation
import DiskGalleryCore

/// Persists user-renamed display labels for the 7 built-in `DriveRole`s. Behaviors are
/// fixed in Core; only the names are customizable. Falls back to `role.defaultLabel`.
@MainActor
@Observable
final class DriveRoleLabelsStore {
    private let defaults = UserDefaults.standard
    private let prefix = "role.label."
    private(set) var labels: [DriveRole: String] = [:]

    init() {
        for role in DriveRole.allCases {
            if let custom = defaults.string(forKey: prefix + role.rawValue), !custom.isEmpty {
                labels[role] = custom
            }
        }
    }

    func label(for role: DriveRole) -> String { labels[role] ?? role.defaultLabel }

    func setLabel(_ name: String, for role: DriveRole) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == role.defaultLabel {
            labels[role] = nil
            defaults.removeObject(forKey: prefix + role.rawValue)
        } else {
            labels[role] = trimmed
            defaults.set(trimmed, forKey: prefix + role.rawValue)
        }
    }

    func resetToDefaults() {
        for role in DriveRole.allCases { defaults.removeObject(forKey: prefix + role.rawValue) }
        labels = [:]
    }
}

/// App-layer UI affordances for roles (Core stays free of SF Symbols).
extension DriveRole {
    var symbol: String {
        switch self {
        case .localSystem:    return "laptopcomputer"
        case .main:           return "externaldrive.fill"
        case .work:           return "bolt.fill"
        case .mainBackup:     return "checkmark.shield.fill"
        case .fallbackBackup: return "shield.lefthalf.filled"
        case .archive:        return "archivebox.fill"
        case .neutral:        return "circle.dashed"
        }
    }

    /// Settings list order (Local/System first, Neutral last).
    static var displayOrder: [DriveRole] {
        [.localSystem, .main, .work, .mainBackup, .fallbackBackup, .archive, .neutral]
    }
}
