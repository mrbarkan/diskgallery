import SwiftUI
import DiskGalleryCore

struct TaggedListView: View {
    @Environment(AppEnvironment.self) private var env
    let tag: Tag
    @State private var entries: [TaggedEntry] = []

    var body: some View {
        List(entries) { entry in
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
                if let size = entry.displaySize {
                    Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .navigationTitle("Marked \(tag.label)")
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Nothing marked \(tag.label)",
                                       systemImage: "tag",
                                       description: Text("Select files or folders and mark them \(tag.label) to collect them here."))
            }
        }
        .task(id: reloadKey) { await load() }
    }

    private var reloadKey: String { "\(tag.rawValue)-\(env.dataVersion)" }

    private func load() async {
        entries = (try? await env.catalog.annotations.taggedEntries(tag)) ?? []
    }
}
