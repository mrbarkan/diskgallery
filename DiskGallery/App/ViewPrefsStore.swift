import Foundation
import Observation

/// Gallery thumbnail tile size — the "large or small icons" control.
enum GalleryTileSize: String, CaseIterable, Identifiable {
    case small, large
    var id: String { rawValue }
    /// Adaptive grid min/max for `GridItem(.adaptive(...))`.
    var gridMin: CGFloat { self == .small ? 96 : 150 }
    var gridMax: CGFloat { self == .small ? 130 : 220 }
}

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
    private let galleryFilterKey = "view.galleryFilter"
    private let galleryGroupingKey = "view.galleryGrouping"
    private let galleryTileSizeKey = "view.galleryTileSize"
    private let galleryShowLabelsKey = "view.galleryShowLabels"

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

    var galleryFilter: GalleryFilter {
        didSet { defaults.set(galleryFilter.rawValue, forKey: galleryFilterKey) }
    }
    var galleryGrouping: GalleryGrouping {
        didSet { defaults.set(galleryGrouping.rawValue, forKey: galleryGroupingKey) }
    }
    var galleryTileSize: GalleryTileSize {
        didSet { defaults.set(galleryTileSize.rawValue, forKey: galleryTileSizeKey) }
    }
    var galleryShowLabels: Bool {
        didSet { defaults.set(galleryShowLabels, forKey: galleryShowLabelsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideHidden = defaults.object(forKey: hideHiddenKey) as? Bool ?? true
        restoreLastView = defaults.object(forKey: restoreLastViewKey) as? Bool ?? true
        lastSelection = defaults.string(forKey: lastSelectionKey)
        galleryFilter = (defaults.string(forKey: galleryFilterKey)).flatMap(GalleryFilter.init(rawValue:)) ?? .all
        galleryGrouping = (defaults.string(forKey: galleryGroupingKey)).flatMap(GalleryGrouping.init(rawValue:)) ?? .none
        galleryTileSize = (defaults.string(forKey: galleryTileSizeKey)).flatMap(GalleryTileSize.init(rawValue:)) ?? .large
        galleryShowLabels = defaults.object(forKey: galleryShowLabelsKey) as? Bool ?? true
    }
}
