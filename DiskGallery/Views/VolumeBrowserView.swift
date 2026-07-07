import SwiftUI
import DiskGalleryCore

struct VolumeBrowserView: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary
    @State private var rootEntry: Entry?
    @State private var nav = BrowserNav()

    @ViewBuilder private var browser: some View {
        Group {
            if let snapshotId = summary.latestSnapshotId {
                if let root = rootEntry {
                    NavigationStack(path: $nav.path) {
                        FolderView(snapshotId: snapshotId, folder: root, nav: nav)
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
                DriveHeaderBar(summary: summary)
                Divider()
            }
            if summary.latestSnapshotComplete == false {
                IncompleteBanner(summary: summary)
            }
            browser
        }
        .onAppear { env.selectedVolumeKey = summary.uuid ?? summary.name }
    }
}

/// Per-drive header: last-scanned glance, capacity gauge, and quick re-scan / compare.
struct DriveHeaderBar: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary

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
                if let hw = summary.hardware.map(DriveHardwareDisplay.init) {
                    HStack(spacing: 5) {
                        Image(systemName: hw.busIcon).font(.system(size: 9))
                        Text(hw.badgeText).lineLimit(1)
                        if let brandModel = hw.brandModel { Text("· \(brandModel)").lineLimit(1) }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Detected \(Format.relativeDate(hw.hardware.capturedAt))")
                }
            }
            Spacer()
            if summary.totalCapacity != nil {
                CapacityBar(total: summary.totalCapacity, free: summary.freeCapacity)
                    .frame(width: 200)
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

    @State private var children: [Entry] = []
    @State private var annotations: [String: Annotation] = [:]
    @State private var selection: Set<Int64> = []

    var body: some View {
        List(selection: $selection) {
            ForEach(children) { entry in
                EntryRow(entry: entry, annotation: annotations[entry.relPath])
                    .tag(entry.id)
            }
            if children.isEmpty {
                Text("Empty folder").foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            tagMenu(for: entries(for: ids))
        } primaryAction: { ids in
            if let entry = entries(for: ids).first(where: \.isDir) {
                nav.open(entry)
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(headerSummary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: folder.id) { await load() }
        .onChange(of: env.dataVersion) { _, _ in Task { await load() } }
        .onChange(of: env.viewPrefs.hideHidden) { _, _ in Task { await load() } }
        .onChange(of: selection) { _, _ in updateSelection() }
        .onAppear { if selection.isEmpty { env.selectedEntries = [folder] } }
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
        children = (try? await env.catalog.library.children(
            parentId: folder.id, snapshotId: snapshotId,
            hideHidden: env.viewPrefs.hideHidden)) ?? []
        if let key = env.selectedVolumeKey {
            annotations = (try? await env.catalog.annotations.annotations(
                volumeKey: key, relPaths: children.map(\.relPath))) ?? [:]
        }
    }
}

struct EntryRow: View {
    @Environment(AppEnvironment.self) private var env
    let entry: Entry
    let annotation: Annotation?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDir ? env.theme.accent.palette.accent : Color.secondary)
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
