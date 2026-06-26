import Foundation
import Observation

/// User view preferences that affect what the catalog shows (not what it scans).
/// Persisted across launches. `hideHidden` defaults to ON so dotfiles/.folders don't
/// clutter the browser, search, and duplicate views.
@MainActor
@Observable
final class ViewPrefsStore {
    private let defaults: UserDefaults
    private let hideHiddenKey = "view.hideHidden"
    private let restoreLastViewKey = "view.restoreLastView"
    private let lastSelectionKey = "view.lastSelection"

    var hideHidden: Bool {
        didSet { defaults.set(hideHidden, forKey: hideHiddenKey) }
    }

    /// When on (default), the app reopens on whatever view you last had selected.
    /// When off, it opens on the first drive.
    var restoreLastView: Bool {
        didSet { defaults.set(restoreLastView, forKey: restoreLastViewKey) }
    }

    /// The encoded `SidebarItem` token of the last-selected view (see `SidebarItem.token`).
    var lastSelection: String? {
        didSet { defaults.set(lastSelection, forKey: lastSelectionKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideHidden = defaults.object(forKey: hideHiddenKey) as? Bool ?? true
        restoreLastView = defaults.object(forKey: restoreLastViewKey) as? Bool ?? true
        lastSelection = defaults.string(forKey: lastSelectionKey)
    }
}
