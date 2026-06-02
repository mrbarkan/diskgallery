import SwiftUI
import DiskGalleryCore

/// Adds a "Show in Finder" context-menu item to any row that represents a single concrete
/// file. Disabled when the file's drive is offline or the row is a directory. Reveals via
/// `AppEnvironment.revealInFinder` — Finder performs any real action, so the app stays read-only.
private struct RevealInFinderModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let volumeKey: String?
    let relPath: String
    let isDir: Bool

    func body(content: Content) -> some View {
        let enabled = !isDir && env.canReveal(volumeKey: volumeKey)
        content.contextMenu {
            Button {
                env.revealInFinder(volumeKey: volumeKey, relPath: relPath)
            } label: {
                Label("Show in Finder", systemImage: "magnifyingglass")
            }
            .disabled(!enabled)
        }
    }
}

extension View {
    /// Marks a row as a revealable single file. `isDir` rows and offline drives disable it.
    func revealInFinder(volumeKey: String?, relPath: String, isDir: Bool = false) -> some View {
        modifier(RevealInFinderModifier(volumeKey: volumeKey, relPath: relPath, isDir: isDir))
    }
}
