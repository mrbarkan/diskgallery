import SwiftUI
import DiskGalleryCore

/// Classic "All Drives" — the merged cross-drive tree as a Finder-style expandable
/// outline. The selected item's copy comparison shows in the detail column.
struct AllDrivesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var atRiskOnly = false

    var body: some View {
        UnifiedOutline(atRiskOnly: atRiskOnly)
            .navigationTitle("All Drives")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Toggle("At-risk only", isOn: $atRiskOnly).toggleStyle(.switch)
                }
            }
    }
}
