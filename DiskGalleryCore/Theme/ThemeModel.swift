import Foundation

/// Overall visual skin. `classic` is the original look; `modern` adds the OLED
/// telemetry hero and the redesign's accent styling.
public enum Skin: String, CaseIterable, Identifiable, Sendable {
    case classic, modern
    public var id: String { rawValue }
    public var name: String { self == .classic ? "Classic" : "Modern" }
}

/// Unified accent palette shared by both skins. Raw values are persisted — keep stable.
public enum Accent: String, CaseIterable, Identifiable, Sendable {
    case graphite, violet, blue, green, amber, coral
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}

/// Which OLED hero layout the Modern skin shows.
public enum OLEDLayout: String, CaseIterable, Identifiable, Sendable {
    case telemetry, gauge, minimal
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
