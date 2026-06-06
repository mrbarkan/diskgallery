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
    private let showReclaimableKey = "view.show.reclaimable"
    private let showActionPlanKey = "view.show.actionPlan"
    private let showInspectorKey = "view.show.inspector"

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

    // MARK: Modern bento pane visibility (item 4 — collapsible panes / Tab focus mode)

    /// The three collapsible Modern bento boxes. Each persists; default visible.
    var showReclaimable: Bool { didSet { defaults.set(showReclaimable, forKey: showReclaimableKey) } }
    var showActionPlan: Bool  { didSet { defaults.set(showActionPlan, forKey: showActionPlanKey) } }
    var showInspector: Bool   { didSet { defaults.set(showInspector, forKey: showInspectorKey) } }

    /// Visibility captured when entering focus mode, so Tab restores the prior arrangement.
    @ObservationIgnored private var preFocus: [Bool]?

    var anyPaneVisible: Bool { showReclaimable || showActionPlan || showInspector }
    var allPanesVisible: Bool { showReclaimable && showActionPlan && showInspector }

    /// Tab focus mode: if any pane is visible, hide all three (remembering the layout);
    /// otherwise restore the remembered layout (or all-visible as a fallback).
    func toggleFocusMode() {
        if anyPaneVisible {
            preFocus = [showReclaimable, showActionPlan, showInspector]
            showReclaimable = false; showActionPlan = false; showInspector = false
        } else {
            let restore = preFocus ?? [true, true, true]
            showReclaimable = restore[0]; showActionPlan = restore[1]; showInspector = restore[2]
            if !anyPaneVisible { showAllPanes() }
        }
    }

    func showAllPanes() {
        showReclaimable = true; showActionPlan = true; showInspector = true
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideHidden = defaults.object(forKey: hideHiddenKey) as? Bool ?? true
        restoreLastView = defaults.object(forKey: restoreLastViewKey) as? Bool ?? true
        lastSelection = defaults.string(forKey: lastSelectionKey)
        showReclaimable = defaults.object(forKey: showReclaimableKey) as? Bool ?? true
        showActionPlan = defaults.object(forKey: showActionPlanKey) as? Bool ?? true
        showInspector = defaults.object(forKey: showInspectorKey) as? Bool ?? true
    }
}
