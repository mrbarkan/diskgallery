import SwiftUI
import DiskGalleryCore

/// Modern two-pane workspace router (spec §4.3). The detail pane for the Modern shell.
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
        case .search:
            RouteBentoWorkspace(title: "Search", systemImage: "magnifyingglass", wrapInCard: true, showInspector: true) {
                SearchResultsView()
            }
        case .tagged(let tag):
            RouteBentoWorkspace(title: tag.label, systemImage: tagIcon(tag), wrapInCard: true, showInspector: true) {
                TaggedListView(tag: tag)
            }
        case .duplicates:
            RouteBentoWorkspace(title: "Duplicates", systemImage: "square.on.square", wrapInCard: false, showInspector: false) {
                DuplicatesView()
            }
        case .plan:
            RouteBentoWorkspace(title: "Action Plan", systemImage: "checklist", wrapInCard: false, showInspector: false) {
                ActionPlanView()
            }
        case .transfer:
            RouteBentoWorkspace(title: "Transfer Planner", systemImage: "arrow.left.arrow.right", wrapInCard: false, showInspector: false) {
                TransferPlannerView()
            }
        case nil:
            ModernEmptyWorkspace(title: "Select a drive", systemImage: "sidebar.left",
                                 message: "Pick a drive, or scan a new one, to browse its catalog.")
        }
    }

    private func tagIcon(_ tag: Tag) -> String {
        switch tag {
        case .keep:   "checkmark.circle"
        case .delete: "trash"
        case .review: "questionmark.circle"
        case .move:   "arrow.right.circle"
        case .backup: "shippingbox"
        case .none:   "tag"
        }
    }
}

/// Bento shell for non-volume routes (spec §12): topbar + content (+ optional inspector).
/// Routes that already style themselves (Duplicates/Plan/Transfer) render directly;
/// plain lists (Search/Tagged) get a glass card + header and the inspector alongside.
struct RouteBentoWorkspace<Content: View>: View {
    @Environment(AppEnvironment.self) private var env
    let title: String
    var systemImage: String
    var wrapInCard: Bool = true
    var showInspector: Bool = false
    @ViewBuilder var content: Content

    private var accent: Color { env.theme.accent.palette.accent }

    /// The drive whose telemetry the permanent OLED shows: the last-selected volume,
    /// else the first cataloged one.
    private var currentDrive: VolumeSummary? {
        if let key = env.selectedVolumeKey,
           let match = env.volumeSummaries.first(where: { ($0.uuid ?? $0.name) == key }) {
            return match
        }
        return env.volumeSummaries.first
    }

    var body: some View {
        VStack(spacing: 14) {
            ModernTopbar(leadingIcon: systemImage, crumbs: [title], onSearch: { env.selection = .search })
            if let drive = currentDrive {
                OLEDDisplayView(summary: drive,
                                connected: env.volumes.isConnected(key: drive.uuid ?? drive.name),
                                reclaimable: env.totalReclaimable,
                                layout: env.theme.oledLayout,
                                palette: env.theme.accent.palette)
                    .frame(height: 216)
            }
            GeometryReader { geo in
                let gap: CGFloat = 14
                if showInspector {
                    let leftW = (geo.size.width - gap) * (1.55 / 2.55)
                    HStack(spacing: gap) {
                        contentArea.frame(width: leftW, height: geo.size.height)
                        ModernInspectorCard().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    contentArea.frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var contentArea: some View {
        if wrapInCard {
            GlassCard {
                VStack(spacing: 0) {
                    ModernCardHeader(systemImage: systemImage, title: title, accent: accent)
                    content.modernListChrome(true).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            content
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
