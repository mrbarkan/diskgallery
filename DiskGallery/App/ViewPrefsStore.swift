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

    var hideHidden: Bool {
        didSet { defaults.set(hideHidden, forKey: hideHiddenKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideHidden = defaults.object(forKey: hideHiddenKey) as? Bool ?? true
    }
}
