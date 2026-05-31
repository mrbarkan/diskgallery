import SwiftUI
import Observation
import DiskGalleryCore

/// System / light / dark. (Skin, Accent, and OLEDLayout live in DiskGalleryCore.)
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

    var skin: Skin              { didSet { defaults.set(skin.rawValue, forKey: "skin") } }
    var accent: Accent          { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var mode: AppearanceMode    { didSet { defaults.set(mode.rawValue, forKey: "appearanceMode") } }
    var oledLayout: OLEDLayout  { didSet { defaults.set(oledLayout.rawValue, forKey: "oledLayout") } }

    init() {
        skin = Skin(rawValue: defaults.string(forKey: "skin") ?? "") ?? .modern
        mode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        oledLayout = OLEDLayout(rawValue: defaults.string(forKey: "oledLayout") ?? "") ?? .telemetry
        // Accent: prefer the new key; otherwise migrate the legacy `theme` value once.
        if let raw = defaults.string(forKey: "accent"), let stored = Accent(rawValue: raw) {
            accent = stored
        } else {
            let migrated = ThemeMigration.accent(fromLegacy: defaults.string(forKey: "theme"))
            accent = migrated
            defaults.set(migrated.rawValue, forKey: "accent")
        }
    }

    /// Advance the OLED layout Telemetry → Gauge → Minimal → Telemetry (the Display button).
    func cycleOLEDLayout() {
        let all = OLEDLayout.allCases
        guard let i = all.firstIndex(of: oledLayout) else { return }
        oledLayout = all[(i + 1) % all.count]
    }
}
