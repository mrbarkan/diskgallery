import SwiftUI
import AppKit
import Observation

/// Tracks the macOS system appearance so the "System" mode resolves to a *concrete*
/// ColorScheme. Passing `nil` to `.preferredColorScheme` leaves SwiftUI's colorScheme
/// ambiguous while glass materials follow the real system appearance — which renders a
/// mixed light/dark UI. Resolving to a concrete scheme keeps tokens and materials in sync.
@MainActor
@Observable
final class SystemAppearance {
    var colorScheme: ColorScheme = SystemAppearance.current()
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.colorScheme = SystemAppearance.current() }
        }
    }

    static func current() -> ColorScheme {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }
}

extension AppearanceMode {
    /// Resolve to a concrete scheme, mapping `.system` through the live system appearance.
    @MainActor
    func resolvedScheme(_ system: SystemAppearance) -> ColorScheme {
        switch self {
        case .light:  .light
        case .dark:   .dark
        case .system: system.colorScheme
        }
    }
}
