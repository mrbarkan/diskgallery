import SwiftUI
import DiskGalleryCore

struct VolumeBrowserView: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary
    @State private var rootEntry: Entry?
    @State private var nav = BrowserNav()

    var body: some View {
        Group {
            if let snapshotId = summary.latestSnapshotId {
                if let root = rootEntry {
                    NavigationStack(path: $nav.path) {
                        FolderView(snapshotId: snapshotId, folder: root)
                            .navigationDestination(for: Entry.self) { child in
                                FolderView(snapshotId: snapshotId, folder: child)
                            }
                    }
                    .environment(nav)
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
        .onAppear { env.selectedVolumeKey = summary.uuid ?? summary.name }
    }
}

/// One level of the tree. Single-click selects (multi-select with ⌘/⇧); double-click
/// opens a folder. Tagging shortcuts act on the current selection.
struct FolderView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(BrowserNav.self) private var nav
    let snapshotId: Int64
    let folder: Entry

    @State private var children: [Entry] = []
    @State private var annotations: [String: Annotation] = [:]
    @State private var selection: Set<Int64> = []
    @FocusState private var focused: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(children) { entry in
                EntryRow(entry: entry, annotation: annotations[entry.relPath])
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        if entry.isDir { nav.open(entry) }
                    })
            }
            if children.isEmpty {
                Text("Empty folder").foregroundStyle(.secondary)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(headerSummary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: folder.id) {
            await load()
            focused = true
        }
        .onChange(of: env.dataVersion) { _, _ in Task { await load() } }
        .onChange(of: selection) { _, _ in updateSelection() }
        .onAppear { if selection.isEmpty { env.selectedEntries = [folder] } }
    }

    private var headerSummary: String {
        let count = children.count
        if selection.count > 1 { return "\(selection.count) selected" }
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    private func updateSelection() {
        let selected = children.filter { selection.contains($0.id) }
        env.selectedEntries = selected.isEmpty ? [folder] : selected
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let action = env.shortcuts.action(forKey: press.characters) else { return .ignored }
        let targets = env.selectedEntries
        guard !targets.isEmpty else { return .ignored }
        Task { await env.perform(action, on: targets) }
        return .handled
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
