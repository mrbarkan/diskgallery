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
        case .organize:
            ModernOrganizePage()
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
                showVolumeActions: scanned,
                rescanEnabled: connected,
                onDisplay: { withAnimation { env.theme.cycleOLEDLayout() } },
                onChanges: { showChanges = true },
                onRescan: { env.rescan(volume: summary) },
                onSearch: { env.selection = .search }
            )

            if scanned {
                OLEDDisplayView(summary: summary, connected: connected, browsePath: browsePath,
                                reclaimable: env.totalReclaimable,
                                hardware: summary.hardware.map(DriveHardwareDisplay.init),
                                layout: env.theme.oledLayout,
                                palette: env.theme.accent.palette)
                    .frame(height: summary.hardware != nil && env.theme.oledLayout == .telemetry ? 244 : 216)
            }
            if summary.latestSnapshotComplete == false {
                IncompleteBanner(summary: summary).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if scanned {
                ModernPathBar(crumbs: crumbs, onCrumb: { i in nav.path = Array(nav.path.prefix(i)) })
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
                let prefs = env.viewPrefs
                let showBottom = prefs.showReclaimable || prefs.showActionPlan
                let baseLeftW = (geo.size.width - gap) * (1.55 / 2.55)
                let leftW = prefs.showInspector ? baseLeftW : geo.size.width
                let rightW = (geo.size.width - gap) - baseLeftW
                let topH = showBottom ? (geo.size.height - gap) * (1.12 / 2.0) : geo.size.height
                let botH = (geo.size.height - gap) - topH
                HStack(spacing: gap) {
                    VStack(spacing: gap) {
                        browserSlot.frame(width: leftW, height: topH)
                        if showBottom {
                            HStack(spacing: gap) {
                                if prefs.showReclaimable {
                                    ReclaimableTile()
                                        .overlay(alignment: .topTrailing) { collapseChevron("chevron.down") { prefs.showReclaimable = false } }
                                }
                                if prefs.showActionPlan {
                                    ActionPlanTile()
                                        .overlay(alignment: .topTrailing) { collapseChevron("chevron.down") { prefs.showActionPlan = false } }
                                }
                            }
                            .frame(width: leftW, height: botH)
                        }
                    }
                    if prefs.showInspector {
                        ModernInspectorCard()
                            .overlay(alignment: .topTrailing) { collapseChevron("chevron.right") { prefs.showInspector = false } }
                            .frame(width: rightW, height: geo.size.height)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !prefs.allPanesVisible { showPanesPill }
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

    /// Small floating control to collapse one bento pane.
    private func collapseChevron(_ icon: String, _ hide: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.25)) { hide() } } label: {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(6).background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain).padding(8).help("Hide this panel · press Tab to toggle all")
    }

    /// Restore control shown whenever any pane is collapsed.
    private var showPanesPill: some View {
        Button { withAnimation(.easeInOut(duration: 0.25)) { env.viewPrefs.showAllPanes() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "sidebar.right").font(.system(size: 11, weight: .semibold))
                Text("Show panes").font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain).padding(10).help("Show all panes (Tab)")
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
