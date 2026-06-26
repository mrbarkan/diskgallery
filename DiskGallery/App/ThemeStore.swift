import SwiftUI
import Observation
import DiskGalleryCore

/// System / light / dark. (Accent lives in DiskGalleryCore.)
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@MainActor
@Observable
final class ThemeStore {
    private let defaults = UserDefaults.standard

    var accent: Accent          { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var mode: AppearanceMode    { didSet { defaults.set(mode.rawValue, forKey: "appearanceMode") } }

    init() {
        mode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        // Accent: prefer the new key; otherwise migrate the legacy `theme` value once.
        if let raw = defaults.string(forKey: "accent"), let stored = Accent(rawValue: raw) {
            accent = stored
        } else {
            let migrated = ThemeMigration.accent(fromLegacy: defaults.string(forKey: "theme"))
            accent = migrated
            defaults.set(migrated.rawValue, forKey: "accent")
        }
    }

}
