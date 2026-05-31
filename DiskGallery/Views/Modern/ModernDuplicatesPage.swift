import SwiftUI
import DiskGalleryCore

// NOTE: stub — fully implemented in Task 3.
struct ModernDuplicatesPage: View {
    var body: some View {
        ModernPageScaffold(leadingIcon: "square.on.square", crumbs: ["Duplicates", "All drives"]) {
            ModernEmptyWorkspace(title: "Duplicates", systemImage: "square.on.square")
        }
    }
}
