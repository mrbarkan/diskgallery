import SwiftUI
import DiskGalleryCore

struct VolumeBrowserView: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary
    @State private var rootEntry: Entry?

    var body: some View {
        Group {
            if let snapshotId = summary.latestSnapshotId {
                if let root = rootEntry {
                    NavigationStack {
                        FolderView(snapshotId: snapshotId, folder: root)
                    }
                } else {
                    ProgressView()
                        .task(id: snapshotId) {
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

/// One level of the tree. Folders push a deeper level; tapping any row shows it in
/// the detail inspector (so files and folders alike can be tagged).
struct FolderView: View {
    @Environment(AppEnvironment.self) private var env
    let snapshotId: Int64
    let folder: Entry

    @State private var children: [Entry] = []
    @State private var tags: [String: Tag] = [:]

    var body: some View {
        List {
            ForEach(children) { entry in
                row(for: entry)
            }
            if children.isEmpty {
                Text("Empty folder").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(folder.name)
        .navigationDestination(for: Entry.self) { child in
            FolderView(snapshotId: snapshotId, folder: child)
        }
        .task(id: folder.id) { await load() }
        .onChange(of: env.dataVersion) { _, _ in Task { await load() } }
        .onAppear { env.selectedEntry = folder }
    }

    @ViewBuilder
    private func row(for entry: Entry) -> some View {
        if entry.isDir {
            NavigationLink(value: entry) {
                EntryRow(entry: entry, tag: tags[entry.relPath])
            }
        } else {
            Button {
                env.selectedEntry = entry
            } label: {
                EntryRow(entry: entry, tag: tags[entry.relPath])
            }
            .buttonStyle(.plain)
        }
    }

    private func load() async {
        children = (try? await env.catalog.library.children(parentId: folder.id, snapshotId: snapshotId)) ?? []
        if let key = env.selectedVolumeKey {
            tags = (try? await env.catalog.annotations.tags(volumeKey: key, relPaths: children.map(\.relPath))) ?? [:]
        }
    }
}

struct EntryRow: View {
    let entry: Entry
    let tag: Tag?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(entry.name).lineLimit(1)
            Spacer(minLength: 8)
            if let tag, tag != .none { TagChip(tag: tag) }
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
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tag {
        case .delete: return .red
        case .keep: return .green
        case .review: return .orange
        case .none: return .gray
        }
    }
}
