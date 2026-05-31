import SwiftUI
import DiskGalleryCore

// NOTE: stub — fully implemented in Task 6.
struct ModernSearchPage: View {
    var body: some View {
        ModernPageScaffold(leadingIcon: "magnifyingglass", crumbs: ["Search"]) {
            ModernEmptyWorkspace(title: "Search", systemImage: "magnifyingglass")
        }
    }
}
