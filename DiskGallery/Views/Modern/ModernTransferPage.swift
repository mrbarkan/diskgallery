import SwiftUI
import DiskGalleryCore

// NOTE: stub — fully implemented in Task 5.
struct ModernTransferPage: View {
    var body: some View {
        ModernPageScaffold(leadingIcon: "arrow.left.arrow.right", crumbs: ["Transfer Planner"]) {
            ModernEmptyWorkspace(title: "Transfer Planner", systemImage: "arrow.left.arrow.right")
        }
    }
}
