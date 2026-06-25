import SwiftUI
import DiskGalleryCore

/// Every action-tagged file/folder in one place, with a decision filter.
/// `initialFilter == nil` (or `.none`) shows all action tags; a specific tag pre-filters.
struct TaggedListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var filter: Tag?            // nil == All
    @State private var entries: [TaggedEntry] = []

    init(initialFilter: Tag? = nil) {
        _filter = State(initialValue: (initialFilter == Tag.none) ? nil : initialFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            List(entries) { entry in row(entry) }
                .overlay { if entries.isEmpty { emptyState } }
        }
        .navigationTitle("Tagged")
        .task(id: reloadKey) { await load() }
    }

    private var filterBar: some View {
        Picker("Filter", selection: $filter) {
            Text("All").tag(Tag?.none)
            ForEach(Tag.actionTags) { t in
                Text("\(t.label) (\(env.tagCounts[t] ?? 0))").tag(Tag?.some(t))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(8)
    }

    private func row(_ entry: TaggedEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDir == true ? "folder.fill" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).lineLimit(1)
                Text("\(entry.volumeName ?? entry.volumeUuid) · \(entry.relPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let note = entry.note, !note.isEmpty {
                    Text(note).font(.caption2).italic().foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: entry.tag.symbol).foregroundStyle(entry.tag.swiftUIColor)
                .help(entry.tag.label)
            if let size = entry.displaySize {
                Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("Nothing tagged",
                               systemImage: "tag",
                               description: Text("Select files or folders while browsing a drive and mark them Keep, Delete, Review, Move, or Backup — they collect here."))
    }

    private var reloadKey: String { "\(filter?.rawValue ?? -1)-\(env.dataVersion)" }

    private func load() async {
        let tags = filter.map { [$0] } ?? Tag.actionTags
        entries = (try? await env.catalog.annotations.taggedEntries(in: tags)) ?? []
    }
}
