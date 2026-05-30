import SwiftUI
import Observation

enum AppTheme: String, CaseIterable, Identifiable {
    case graphite, ocean, sunset, forest, grape, rose

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var accent: Color {
        switch self {
        case .graphite: return Color(red: 0.36, green: 0.45, blue: 0.62)
        case .ocean:    return Color(red: 0.00, green: 0.55, blue: 0.65)
        case .sunset:   return Color(red: 0.95, green: 0.45, blue: 0.20)
        case .forest:   return Color(red: 0.20, green: 0.55, blue: 0.34)
        case .grape:    return Color(red: 0.50, green: 0.32, blue: 0.78)
        case .rose:     return Color(red: 0.85, green: 0.28, blue: 0.45)
        }
    }
}

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

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    var mode: AppearanceMode {
        didSet { defaults.set(mode.rawValue, forKey: "appearanceMode") }
    }

    init() {
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .graphite
        mode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
    }
}
