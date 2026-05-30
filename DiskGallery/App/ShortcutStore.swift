import Foundation
import Observation
import DiskGalleryCore

/// A user-bindable tagging action. Pressing an action's key applies it; pressing it
/// again on an already-tagged selection clears it (toggle).
enum ShortcutAction: String, CaseIterable, Identifiable {
    case keep, delete, review
    case color1, color2, color3, color4, color5, color6, color7

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return "Keep"
        case .delete: return "Delete"
        case .review: return "Review"
        default: return color?.tagName ?? rawValue
        }
    }

    var defaultKey: String {
        switch self {
        case .keep: return "q"
        case .delete: return "w"
        case .review: return "e"
        case .color1: return "1"
        case .color2: return "2"
        case .color3: return "3"
        case .color4: return "4"
        case .color5: return "5"
        case .color6: return "6"
        case .color7: return "7"
        }
    }

    var decision: Tag? {
        switch self {
        case .keep: return .keep
        case .delete: return .delete
        case .review: return .review
        default: return nil
        }
    }

    var color: FinderColor? {
        switch self {
        case .color1: return FinderColor.keyOrder[0]
        case .color2: return FinderColor.keyOrder[1]
        case .color3: return FinderColor.keyOrder[2]
        case .color4: return FinderColor.keyOrder[3]
        case .color5: return FinderColor.keyOrder[4]
        case .color6: return FinderColor.keyOrder[5]
        case .color7: return FinderColor.keyOrder[6]
        default: return nil
        }
    }

    /// The shortcut action that toggles a given action tag, for showing its key.
    static func forDecision(_ tag: Tag) -> ShortcutAction? {
        switch tag {
        case .keep: return .keep
        case .delete: return .delete
        case .review: return .review
        case .none: return nil
        }
    }

    static let decisionActions: [ShortcutAction] = [.keep, .delete, .review]
    static let colorActions: [ShortcutAction] = [.color1, .color2, .color3, .color4, .color5, .color6, .color7]
}

/// Persists the user's key bindings for tagging actions.
@MainActor
@Observable
final class ShortcutStore {
    private let defaults = UserDefaults.standard
    private let prefix = "shortcut."
    private(set) var bindings: [ShortcutAction: String] = [:]

    init() {
        for action in ShortcutAction.allCases {
            bindings[action] = defaults.string(forKey: prefix + action.rawValue) ?? action.defaultKey
        }
    }

    func key(for action: ShortcutAction) -> String { bindings[action] ?? action.defaultKey }

    func setKey(_ key: String, for action: ShortcutAction) {
        let normalized = String(key.prefix(1)).lowercased()
        guard !normalized.isEmpty else { return }
        bindings[action] = normalized
        defaults.set(normalized, forKey: prefix + action.rawValue)
    }

    func resetToDefaults() {
        for action in ShortcutAction.allCases {
            bindings[action] = action.defaultKey
            defaults.removeObject(forKey: prefix + action.rawValue)
        }
    }

    /// The action bound to a typed character, if any.
    func action(forKey characters: String) -> ShortcutAction? {
        let lower = characters.lowercased()
        return ShortcutAction.allCases.first { key(for: $0) == lower }
    }
}
