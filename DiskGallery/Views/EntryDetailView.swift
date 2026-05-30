import SwiftUI
import DiskGalleryCore

struct EntryDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let entries = env.selectedEntries
        if entries.isEmpty {
            ContentUnavailableView("No selection",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a file or folder to see details and mark it."))
        } else if entries.count == 1 {
            EntryInspector(entry: entries[0])
        } else {
            MultiSelectInspector(entries: entries)
        }
    }
}

// MARK: - Single selection

struct EntryInspector: View {
    @Environment(AppEnvironment.self) private var env
    let entry: Entry

    @State private var annotation: Annotation?
    @State private var note: String = ""

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
            }

            Section("Tags") {
                TagControls(targets: [entry], current: annotation)
                FinderSyncNote()
            }

            Section("Note") {
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                Button("Save Note") { Task { await env.applyNote(note, to: entry) } }
            }
        }
        .formStyle(.grouped)
        .modernListChrome(modern)
        .task(id: reloadKey) { await load() }
    }

    private var modern: Bool { env.theme.skin == .modern }

    private var reloadKey: String { "\(entry.id)-\(env.dataVersion)" }

    private func load() async {
        guard let key = env.selectedVolumeKey else { return }
        annotation = try? await env.catalog.annotations.annotation(volumeKey: key, relPath: entry.relPath)
        note = annotation?.note ?? ""
    }
}

// MARK: - Multiple selection

struct MultiSelectInspector: View {
    @Environment(AppEnvironment.self) private var env
    let entries: [Entry]

    var body: some View {
        Form {
            Section {
                LabeledContent("Selected", value: "\(entries.count) items")
                LabeledContent("Total size", value: Format.bytes(entries.reduce(0) { $0 + $1.displaySize }))
            }
            Section("Tag all selected") {
                TagControls(targets: entries, current: nil)
                FinderSyncNote()
            }
        }
        .formStyle(.grouped)
        .modernListChrome(modern)
    }

    private var modern: Bool { env.theme.skin == .modern }
}

// MARK: - Shared tag controls

struct TagControls: View {
    @Environment(AppEnvironment.self) private var env
    let targets: [Entry]
    let current: Annotation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Action Tag").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], spacing: 6) {
                    ForEach([Tag.none] + Tag.actionTags) { tag in
                        DecisionButton(tag: tag,
                                       active: current?.tag == tag,
                                       key: ShortcutAction.forDecision(tag).map { env.shortcuts.key(for: $0) }) {
                            Task { await env.applyDecision(tag, to: targets) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Finder Color").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ColorSwatch(color: .none, active: current?.color == FinderColor.none, key: nil) {
                        Task { await env.applyColor(.none, to: targets) }
                    }
                    ForEach(Array(FinderColor.keyOrder.enumerated()), id: \.offset) { index, color in
                        ColorSwatch(color: color, active: current?.color == color,
                                    key: env.shortcuts.key(for: ShortcutAction.colorActions[index])) {
                            Task { await env.applyColor(color, to: targets) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct DecisionButton: View {
    let tag: Tag
    let active: Bool
    let key: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Label(tag.label, systemImage: tag.symbol).labelStyle(.titleAndIcon).font(.callout)
                Text((key ?? " ").uppercased()).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(active ? tag.swiftUIColor.opacity(0.22) : Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? tag.swiftUIColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? tag.swiftUIColor : .primary)
    }
}

struct ColorSwatch: View {
    let color: FinderColor
    let active: Bool
    let key: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    if color == .none {
                        Image(systemName: "slash.circle").foregroundStyle(.secondary)
                    } else {
                        Circle().fill(color.swiftUIColor)
                    }
                }
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(active ? Color.primary : .clear, lineWidth: 2))
                Text(key ?? " ").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(color == .none ? "No color" : color.tagName)
    }
}

struct FinderSyncNote: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.isSelectedVolumeConnected {
            Label("Written to the file as Finder tags", systemImage: "checkmark.icloud")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("Saved in catalog — connect the drive to write Finder tags",
                  systemImage: "externaldrive.badge.xmark")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
