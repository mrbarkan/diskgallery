import SwiftUI
import DiskGalleryCore

/// Modern workspace router (spec §4.3). The detail pane for the Modern shell.
/// Volume routes use the drive-browser bento; the four library routes use their own
/// page views, each wrapped in `ModernPageScaffold` (topbar + permanent OLED).
struct ModernWorkspace: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch env.selection {
        case .volume(let id):
            if let summary = env.volumeSummaries.first(where: { $0.id == id }) {
                VolumeBentoWorkspace(summary: summary).id(summary.id)
            } else {
                ModernEmptyWorkspace(title: "Drive not found", systemImage: "externaldrive")
            }
        case .duplicates:
            ModernDuplicatesPage()
        case .plan:
            ModernActionPlanPage(initialFilter: nil).id("plan")
        case .tagged(let tag):
            ModernActionPlanPage(initialFilter: tag).id("tagged-\(tag.rawValue)")
        case .transfer:
            ModernTransferPage()
        case .search:
            ModernSearchPage()
        case nil:
            ModernEmptyWorkspace(title: "Select a drive", systemImage: "sidebar.left",
                                 message: "Pick a drive, or scan a new one, to browse its catalog.")
        }
    }
}

struct ModernEmptyWorkspace: View {
    let title: String
    var systemImage: String = "sidebar.left"
    var message: String? = nil
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The mockup workspace: topbar → OLED hero → bento(browser + stats | inspector). Spec §C/§5.
struct VolumeBentoWorkspace: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary

    @State private var rootEntry: Entry?
    @State private var nav = BrowserNav()
    @State private var showChanges = false

    private var connected: Bool { env.volumes.isConnected(key: summary.uuid ?? summary.name) }
    private var scanned: Bool { summary.latestSnapshotId != nil }
    private var crumbs: [String] { [summary.name] + nav.path.map(\.name) }
    private var browsePath: String { "/Volumes/" + crumbs.joined(separator: "/") }

    var body: some View {
        VStack(spacing: 14) {
            ModernTopbar(
                leadingIcon: "externaldrive",
                crumbs: crumbs,
                onCrumb: { i in nav.path = Array(nav.path.prefix(i)) },
                showVolumeActions: scanned,
                rescanEnabled: connected,
                onDisplay: { withAnimation { env.theme.cycleOLEDLayout() } },
                onChanges: { showChanges = true },
                onRescan: { env.rescan(volume: summary) },
                onSearch: { env.selection = .search }
            )

            if scanned {
                OLEDDisplayView(summary: summary, connected: connected, browsePath: browsePath,
                                reclaimable: env.totalReclaimable, layout: env.theme.oledLayout,
                                palette: env.theme.accent.palette)
                    .frame(height: 216)
            }
            if summary.latestSnapshotComplete == false {
                IncompleteBanner(summary: summary).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            bento
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { env.selectedVolumeKey = summary.uuid ?? summary.name }
        .sheet(isPresented: $showChanges) { ChangesView(summary: summary) }
    }

    @ViewBuilder private var bento: some View {
        if scanned {
            GeometryReader { geo in
                let gap: CGFloat = 14
                let leftW = (geo.size.width - gap) * (1.55 / 2.55)
                let rightW = (geo.size.width - gap) - leftW
                let topH = (geo.size.height - gap) * (1.12 / 2.0)
                let botH = (geo.size.height - gap) - topH
                HStack(spacing: gap) {
                    VStack(spacing: gap) {
                        browserSlot.frame(width: leftW, height: topH)
                        HStack(spacing: gap) {
                            ReclaimableTile()
                            ActionPlanTile()
                        }
                        .frame(width: leftW, height: botH)
                    }
                    ModernInspectorCard().frame(width: rightW, height: geo.size.height)
                }
            }
        } else {
            GlassCard {
                ContentUnavailableView("Not scanned yet",
                                       systemImage: "externaldrive.badge.questionmark",
                                       description: Text("Connect this drive and scan it to browse its contents."))
            }
        }
    }

    @ViewBuilder private var browserSlot: some View {
        if let snapshotId = summary.latestSnapshotId {
            if let root = rootEntry {
                let folder = nav.path.last ?? root
                ModernBrowserCard(snapshotId: snapshotId, folder: folder, nav: nav)
                    .id(folder.id)
            } else {
                GlassCard { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    .task(id: snapshotId) {
                        rootEntry = try? await env.catalog.library.rootEntry(snapshotId: snapshotId)
                    }
            }
        }
    }
}
