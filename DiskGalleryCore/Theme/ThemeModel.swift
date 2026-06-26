import Foundation

/// Unified accent palette shared across all layouts. Raw values are persisted — keep stable.
public enum Accent: String, CaseIterable, Identifiable, Sendable {
    case graphite, violet, blue, green, amber, coral
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}

/// One-time migration from the pre-redesign `theme` accent names to the unified set.
public enum ThemeMigration {
    /// Maps a legacy stored `theme` value to the new accent. Unknown / nil → `.violet`.
    public static func accent(fromLegacy legacy: String?) -> Accent {
        switch legacy {
        case "graphite": return .graphite
        case "grape":    return .violet
        case "ocean":    return .blue
        case "forest":   return .green
        case "sunset":   return .amber
        case "rose":     return .coral
        default:         return .violet
        }
    }
}
