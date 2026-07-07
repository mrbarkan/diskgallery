import SwiftUI
import DiskGalleryCore

/// The app-wide, user-customizable toolbar (Finder's "Customize Toolbar…" gives
/// reorder / add-remove / icon+label / small-size / persistence for free — we just
/// declare the items). Contextual items grey out when they don't apply.
struct MainToolbar: CustomizableToolbarContent {
    let env: AppEnvironment

    private var isGallery: Bool { if case .gallery = env.selection { return true }; return false }

    var body: some CustomizableToolbarContent {
        @Bindable var prefs = env.viewPrefs

        ToolbarItem(id: "scan", placement: .primaryAction) {
            Button { env.chooseAndScan() } label: { Label("New Scan", systemImage: "externaldrive.badge.plus") }
                .help("Catalog a new drive or folder")
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "rescan", placement: .primaryAction) {
            Button { if let v = env.currentVolumeSummary { env.rescan(volume: v) } }
                label: { Label("Re-scan", systemImage: "arrow.clockwise") }
                .disabled(!(env.currentVolumeSummary != nil && env.isSelectedVolumeConnected))
                .help("Scan the selected drive again")
        }

        ToolbarItem(id: "changes", placement: .primaryAction) {
            Button { env.changesVolume = env.currentVolumeSummary }
                label: { Label("Changes…", systemImage: "clock.arrow.2.circlepath") }
                .disabled(env.currentVolumeSummary?.latestSnapshotId == nil)
                .help("Compare this drive's scans")
        }

        ToolbarItem(id: "filter", placement: .primaryAction) {
            Picker("Filter", selection: $prefs.galleryFilter) {
                ForEach(GalleryFilter.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!isGallery)
            .help("Filter the Gallery by media type")
        }

        ToolbarItem(id: "group", placement: .primaryAction) {
            Picker("Group", selection: $prefs.galleryGrouping) {
                ForEach(GalleryGrouping.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!isGallery)
            .help("Group the Gallery")
        }

        ToolbarItem(id: "tileSize", placement: .primaryAction) {
            Picker("Size", selection: $prefs.galleryTileSize) {
                Image(systemName: "square.grid.3x3").tag(GalleryTileSize.small)
                Image(systemName: "square.grid.2x2").tag(GalleryTileSize.large)
            }
            .pickerStyle(.segmented)
            .disabled(!isGallery)
            .help("Large or small tiles")
        }

        ToolbarItem(id: "labels", placement: .primaryAction) {
            Toggle(isOn: $prefs.galleryShowLabels) { Label("Labels", systemImage: "textformat") }
                .disabled(!isGallery)
                .help("Show file names under tiles")
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "hidden", placement: .primaryAction) {
            Toggle(isOn: $prefs.hideHidden) { Label("Hide Hidden", systemImage: "eye.slash") }
                .help("Hide dotfiles from the browser, Gallery, search, and duplicates")
        }
    }
}
