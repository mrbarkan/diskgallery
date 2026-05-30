import SwiftUI
import DiskGalleryCore

struct EntryDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let entry = env.selectedEntry {
            EntryInspector(entry: entry, volumeKey: env.selectedVolumeKey)
                .id(entry.id)
        } else {
            ContentUnavailableView("No selection",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a file or folder to see details and mark it."))
        }
    }
}

struct EntryInspector: View {
    @Environment(AppEnvironment.self) private var env
    let entry: Entry
    let volumeKey: String?

    @State private var tag: Tag = .none
    @State private var note: String = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: entry.name)
                LabeledContent("Kind", value: entry.isDir ? "Folder" : "File")
                LabeledContent("Size", value: Format.bytes(entry.displaySize))
                if !entry.isDir {
                    LabeledContent("On disk", value: Format.bytes(entry.allocSize))
                    if let ext = entry.ext { LabeledContent("Type", value: ".\(ext)") }
                }
                LabeledContent("Modified", value: Format.date(entry.modifiedAt))
                LabeledContent("Path", value: entry.relPath.isEmpty ? "/" : entry.relPath)
                if let hash = entry.contentHash {
                    LabeledContent("SHA-256", value: String(hash.prefix(16)) + "…")
                }
            }

            Section("Decision") {
                Picker("Mark as", selection: $tag) {
                    ForEach(Tag.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)

                Button("Save") { save() }
                    .disabled(volumeKey == nil)
            }
        }
        .formStyle(.grouped)
        .task(id: entry.id) { await loadAnnotation() }
    }

    private func loadAnnotation() async {
        guard let volumeKey else { return }
        if let annotation = try? await env.catalog.annotations.annotation(volumeKey: volumeKey, relPath: entry.relPath) {
            tag = annotation.tag
            note = annotation.note ?? ""
        } else {
            tag = .none
            note = ""
        }
        loaded = true
    }

    private func save() {
        guard let volumeKey else { return }
        Task { await env.setTag(tag, note: note, volumeKey: volumeKey, relPath: entry.relPath) }
    }
}
