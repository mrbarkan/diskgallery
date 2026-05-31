import SwiftUI
import DiskGalleryCore

// NOTE: stub — fully implemented in Task 4.
struct ModernActionPlanPage: View {
    var initialFilter: Tag?
    var body: some View {
        ModernPageScaffold(leadingIcon: "checklist", crumbs: ["Action Plan"]) {
            ModernEmptyWorkspace(title: "Action Plan", systemImage: "checklist")
        }
    }
}
