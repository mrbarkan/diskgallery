import SwiftUI
import DiskGalleryCore

/// Modern "All Drives" — the fixed OLED hero shows a cross-drive coverage readout; below
/// it, a Finder-style expandable outline (left) and a copy-comparison inspector (right).
struct ModernAllDrivesPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var atRiskOnly = false

    var body: some View {
        VStack(spacing: 14) {
            ModernTopbar(showVolumeActions: false, onSearch: { env.selection = .search })
            CoverageOLED(summary: env.coverageSummary, palette: env.theme.accent.palette)
                .frame(height: 156)
            filterBar
            HStack(spacing: 14) {
                GlassCard { UnifiedOutline(atRiskOnly: atRiskOnly) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                GlassCard { comparePane }
                    .frame(width: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(env.dataVersion)|\(env.viewPrefs.hideHidden)") {
            env.coverageSummary = await env.unifiedCoverage()
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Toggle("At-risk only", isOn: $atRiskOnly).toggleStyle(.switch).controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    @ViewBuilder private var comparePane: some View {
        if let node = env.selectedUnifiedNode {
            ScrollView { UnifiedComparePanel(node: node) }
        } else {
            ContentUnavailableView("Compare copies", systemImage: "rectangle.on.rectangle",
                                   description: Text("Select an item to compare its copies across drives."))
        }
    }
}
