import SwiftUI
import DiskGalleryCore

/// The three list pages' bento grid (mockup `.page--dupes / .page--plan / .page--transfer`):
/// columns 1.55fr / 1fr, rows 1.12fr / 0.88fr, with the right card spanning both rows.
struct ModernBento<TopLeft: View, BottomLeft: View, Right: View>: View {
    @ViewBuilder var topLeft: TopLeft
    @ViewBuilder var bottomLeft: BottomLeft
    @ViewBuilder var right: Right

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 14
            let leftW = (geo.size.width - gap) * (1.55 / 2.55)
            let rightW = (geo.size.width - gap) - leftW
            let topH = (geo.size.height - gap) * (1.12 / 2.0)
            let botH = (geo.size.height - gap) - topH
            HStack(spacing: gap) {
                VStack(spacing: gap) {
                    topLeft.frame(width: leftW, height: topH)
                    bottomLeft.frame(width: leftW, height: botH)
                }
                right.frame(width: rightW, height: geo.size.height)
            }
        }
    }
}

/// Topbar + permanent OLED + page content (mockup app shell, minus the volume-only bento).
/// The global toolbar (Display / Check changes / Re-scan) acts on the currently-selected drive
/// (or the first cataloged one) so it stays present on every page like the mockup.
struct ModernPageScaffold<Content: View>: View {
    @Environment(AppEnvironment.self) private var env
    var leadingIcon: String
    let crumbs: [String]
    /// Only the Organize page passes this — it drives the OLED's `.actionDetail` layout.
    var oledPlan: OLEDDisplayView.PlanSummary? = nil
    /// Per-page OLED layout override (Organize uses `.actionDetail`). When nil, the
    /// user's persisted layout is used. Avoids mutating the shared persisted layout.
    var oledLayoutOverride: OLEDLayout? = nil
    @ViewBuilder var content: Content

    private var currentDrive: VolumeSummary? {
        if let key = env.selectedVolumeKey,
           let match = env.volumeSummaries.first(where: { ($0.uuid ?? $0.name) == key }) {
            return match
        }
        return env.volumeSummaries.first
    }

    var body: some View {
        let drive = currentDrive
        let layout = oledLayoutOverride ?? env.theme.oledLayout
        VStack(spacing: 14) {
            ModernTopbar(
                showVolumeActions: drive != nil,
                rescanEnabled: drive.map { env.volumes.isConnected(key: $0.uuid ?? $0.name) } ?? false,
                displayedLayout: layout,
                onDisplay: { withAnimation { env.theme.cycleOLEDLayout() } },
                onChanges: {},
                onRescan: { if let drive { env.rescan(volume: drive) } },
                onSearch: { env.selection = .search }
            )
            if let drive {
                OLEDDisplayView(summary: drive,
                                connected: env.volumes.isConnected(key: drive.uuid ?? drive.name),
                                reclaimable: env.totalReclaimable,
                                hardware: drive.hardware.map(DriveHardwareDisplay.init),
                                layout: layout,
                                palette: env.theme.accent.palette,
                                plan: oledPlan)
                    .frame(height: drive.hardware != nil && layout == .telemetry ? 244 : 216)
            }
            ModernPathBar(leadingIcon: leadingIcon, crumbs: crumbs)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
