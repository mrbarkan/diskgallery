import SwiftUI
import DiskGalleryCore

struct VolumeBrowserView: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary
    @State private var rootEntry: Entry?
    @State private var nav = BrowserNav()
    @State private var showChanges = false

    private var modern: Bool { env.theme.skin == .modern }

    @ViewBuilder private var browser: some View {
        Group {
            if let snapshotId = summary.latestSnapshotId {
                if let root = rootEntry {
                    NavigationStack(path: $nav.path) {
                        FolderView(snapshotId: snapshotId, folder: root, nav: nav, isRoot: true)
                            .navigationDestination(for: Entry.self) { child in
                                FolderView(snapshotId: snapshotId, folder: child, nav: nav)
                            }
                    }
                } else {
                    ProgressView().task(id: snapshotId) {
                        rootEntry = try? await env.catalog.library.rootEntry(snapshotId: snapshotId)
                    }
                }
            } else {
                ContentUnavailableView("Not scanned yet",
                                       systemImage: "externaldrive.badge.questionmark",
                                       description: Text("Connect this drive and scan it to browse its contents."))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if summary.latestSnapshotId != nil {
                if env.theme.skin == .modern {
                    OLEDDisplayView(
                        summary: summary,
                        connected: env.volumes.isConnected(key: summary.uuid ?? summary.name),
                        browsePath: "/Volumes/\(summary.name)",
                        layout: env.theme.oledLayout,
                        palette: env.theme.accent.palette
                    )
                    .padding(12)
                    ModernActionRow(summary: summary) { showChanges = true }
                } else {
                    DriveHeaderBar(summary: summary) { showChanges = true }
                    Divider()
                }
            }
            if summary.latestSnapshotComplete == false {
                IncompleteBanner(summary: summary)
            }
            if modern {
                browser
                    .glassCard()
                    .padding([.horizontal, .bottom], 12)
            } else {
                browser
            }
            if modern, summary.latestSnapshotId != nil {
                HStack(spacing: 12) {
                    ReclaimableTile(palette: env.theme.accent.palette)
                    ActionPlanTile()
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding([.horizontal, .bottom], 12)
            }
        }
        .onAppear { env.selectedVolumeKey = summary.uuid ?? summary.name }
        .sheet(isPresented: $showChanges) { ChangesView(summary: summary) }
    }
}

/// Per-drive header: last-scanned glance, capacity gauge, and quick re-scan / compare.
struct DriveHeaderBar: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary
    let onShowChanges: () -> Void

    var body: some View {
        let connected = env.volumes.isConnected(key: summary.uuid ?? summary.name)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    DriveStatusDot(connected: connected)
                    Text(summary.name).font(.headline)
                }
                Text(infoLine).font(.caption).foregroundStyle(.secondary)
                    .help(summary.scannedAt.map { "Last scanned \(Format.date($0))" } ?? "")
            }
            Spacer()
            if summary.totalCapacity != nil {
                CapacityBar(total: summary.totalCapacity, free: summary.freeCapacity)
                    .frame(width: 200)
            }
            Button(action: onShowChanges) {
                Label("Changes…", systemImage: "clock.arrow.2.circlepath")
            }
            .help("Compare this drive’s scans to see what changed")
            if connected {
                Button { env.rescan(volume: summary) } label: {
                    Label("Re-scan", systemImage: "arrow.clockwise")
                }
                .help("Scan again to update the catalog and detect changes")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var infoLine: String {
        var parts: [String] = []
        if let total = summary.totalLogical { parts.append(Format.bytes(total)) }
        if let files = summary.fileCount { parts.append("\(Format.count(files)) files") }
        if summary.scannedAt != nil { parts.append("scanned \(Format.relativeDate(summary.scannedAt))") }
        return parts.joined(separator: " · ")
    }
}

/// Compact action row shown under the OLED hero in the Modern skin — integrated glass
/// pills for cycling the OLED layout and the Changes… / Re-scan actions that
/// DriveHeaderBar provides in Classic.
struct ModernActionRow: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary
    let onShowChanges: () -> Void

    var body: some View {
        let connected = env.volumes.isConnected(key: summary.uuid ?? summary.name)
        let accent = env.theme.accent.palette.accent
        HStack(spacing: 8) {
            Button { env.theme.cycleOLEDLayout() } label: {
                pill(env.theme.oledLayout.name, systemImage: oledIcon, accent: accent)
            }
            .help("Switch the OLED display layout (Telemetry · Gauge · Minimal)")
            Spacer()
            Button(action: onShowChanges) {
                pill("Changes…", systemImage: "clock.arrow.2.circlepath", accent: accent)
            }
            .help("Compare this drive's scans to see what changed")
            if connected {
                Button { env.rescan(volume: summary) } label: {
                    pill("Re-scan", systemImage: "arrow.clockwise", accent: accent)
                }
                .help("Scan again to update the catalog and detect changes")
            }
        }
        .buttonStyle(ModernPillButtonStyle())
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var oledIcon: String {
        switch env.theme.oledLayout {
        case .telemetry: return "rectangle.split.3x1"
        case .gauge:     return "gauge.medium"
        case .minimal:   return "textformat.size"
        }
    }

    private func pill(_ title: String, systemImage: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(accent)
            Text(title)
        }
    }
}

struct IncompleteBanner: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary

    var body: some View {
        let connected = env.volumes.isConnected(key: summary.uuid ?? summary.name)
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("This scan is incomplete").font(.callout.weight(.medium))
                Text("Folder sizes finish calculating once you resume.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") { env.resumeScan(volume: summary) }
                .disabled(!connected)
                .help(connected ? "Continue where it left off" : "Connect the drive to resume")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

/// One level of the tree. Single-click selects (multi-select with ⌘/⇧); double-click
/// (or Return) opens a folder via the List's primary action. Tagging shortcuts come
/// from a window-level key monitor; right-click also tags.
struct FolderView: View {
    @Environment(AppEnvironment.self) private var env
    let snapshotId: Int64
    let folder: Entry
    let nav: BrowserNav
    var isRoot: Bool = false

    @State private var children: [Entry] = []
    @State private var annotations: [String: Annotation] = [:]
    @State private var selection: Set<Int64> = []

    private var modern: Bool { env.theme.skin == .modern }

    var body: some View {
        Group {
            if modern {
                VStack(spacing: 0) {
                    modernHeader
                    list
                }
            } else {
                list
            }
        }
        .navigationTitle(modern ? "" : folder.name)
        .toolbar {
            if !modern {
                ToolbarItem(placement: .navigation) {
                    Text(headerSummary).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: folder.id) { await load() }
        .onChange(of: env.dataVersion) { _, _ in Task { await load() } }
        .onChange(of: selection) { _, _ in updateSelection() }
        .onAppear { if selection.isEmpty { env.selectedEntries = [folder] } }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(children) { entry in
                EntryRow(entry: entry, annotation: annotations[entry.relPath])
                    .tag(entry.id)
            }
            if children.isEmpty {
                Text("Empty folder").foregroundStyle(.secondary)
            }
        }
        .modernListChrome(modern)
        .contextMenu(forSelectionType: Int64.self) { ids in
            tagMenu(for: entries(for: ids))
        } primaryAction: { ids in
            if let entry = entries(for: ids).first(where: \.isDir) {
                nav.open(entry)
            }
        }
    }

    /// Slim integrated header for Modern (the OLED hero already shows the drive),
    /// replacing the heavy navigation-bar title. Shows the folder name only when
    /// drilled in (not at the root), plus the item count.
    @ViewBuilder private var modernHeader: some View {
        HStack(spacing: 8) {
            if !isRoot {
                Image(systemName: "folder.fill").font(.caption2)
                    .foregroundStyle(env.theme.accent.palette.accent)
                Text(folder.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            Text(headerSummary).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    private var headerSummary: String {
        if selection.count > 1 { return "\(selection.count) selected" }
        let count = children.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private func entries(for ids: Set<Int64>) -> [Entry] {
        children.filter { ids.contains($0.id) }
    }

    private func updateSelection() {
        let selected = entries(for: selection)
        env.selectedEntries = selected.isEmpty ? [folder] : selected
    }

    @ViewBuilder
    private func tagMenu(for targets: [Entry]) -> some View {
        if !targets.isEmpty {
            ForEach(Tag.actionTags) { tag in
                Button(tag.label) { Task { await env.applyDecision(tag, to: targets) } }
            }
            Divider()
            Menu("Color") {
                ForEach(FinderColor.keyOrder) { color in
                    Button(color.tagName) { Task { await env.applyColor(color, to: targets) } }
                }
                Button("No Color") { Task { await env.applyColor(.none, to: targets) } }
            }
            Divider()
            Button("Clear Tags") {
                Task {
                    await env.applyDecision(.none, to: targets)
                    await env.applyColor(.none, to: targets)
                }
            }
        }
    }

    private func load() async {
        children = (try? await env.catalog.library.children(parentId: folder.id, snapshotId: snapshotId)) ?? []
        if let key = env.selectedVolumeKey {
            annotations = (try? await env.catalog.annotations.annotations(
                volumeKey: key, relPaths: children.map(\.relPath))) ?? [:]
        }
    }
}

struct EntryRow: View {
    let entry: Entry
    let annotation: Annotation?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(entry.name).lineLimit(1)
            Spacer(minLength: 8)
            if let color = annotation?.color, color != .none {
                Circle().fill(color.swiftUIColor).frame(width: 10, height: 10)
            }
            if let tag = annotation?.tag, tag != .none {
                TagChip(tag: tag)
            }
            Text(Format.bytes(entry.displaySize))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct TagChip: View {
    let tag: Tag

    var body: some View {
        Text(tag.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tag.swiftUIColor.opacity(0.18), in: Capsule())
            .foregroundStyle(tag.swiftUIColor)
    }
}
