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

    private var modern: Bool { env.theme.skin == .modern }

    var body: some View {
        Group {
            if modern { modernBody } else { classicForm }
        }
        .task(id: reloadKey) { await load() }
    }

    // Classic — the original grouped Form, unchanged.
    private var classicForm: some View {
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
    }

    // Modern — a frosted-glass inspector card on the spatial backdrop.
    private var modernBody: some View {
        let accent = env.theme.accent.palette.accent
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.opacity(0.22))
                        Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                            .font(.system(size: 22)).foregroundStyle(accent)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline).lineLimit(2)
                        Text(entry.isDir ? "Folder" : (entry.ext.map { ".\($0)" } ?? "File"))
                            .font(.system(.caption, design: .monospaced)).textCase(.uppercase)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                specGrid(accent: accent)

                ModernInspectorSection(title: "Action Tag") {
                    TagControls(targets: [entry], current: annotation, modern: true)
                    FinderSyncNote()
                }

                ModernInspectorSection(title: "Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Note") { Task { await env.applyNote(note, to: entry) } }
                        .controlSize(.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .padding(12)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func specGrid(accent: Color) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            specRow("Size", Format.bytes(entry.displaySize), color: accent)
            if !entry.isDir { specRow("On disk", Format.bytes(entry.allocSize)) }
            specRow("Modified", Format.date(entry.modifiedAt))
            specRow("Path", entry.relPath.isEmpty ? "/" : entry.relPath)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func specRow(_ key: String, _ value: String, color: Color = .primary) -> some View {
        GridRow {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                .textCase(.uppercase).foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(color)
                .lineLimit(1).truncationMode(.middle)
        }
    }

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

    private var modern: Bool { env.theme.skin == .modern }

    var body: some View {
        if modern {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(entries.count) items selected").font(.headline)
                    Text("Total \(Format.bytes(entries.reduce(0) { $0 + $1.displaySize }))")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    ModernInspectorSection(title: "Tag all selected") {
                        TagControls(targets: entries, current: nil, modern: true)
                        FinderSyncNote()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
                .padding(12)
            }
            .scrollContentBackground(.hidden)
        } else {
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
        }
    }
}

/// Mono-caps section wrapper used in the Modern inspector.
struct ModernInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2)
                .textCase(.uppercase).foregroundStyle(.tertiary)
            content
        }
    }
}

// MARK: - Shared tag controls

struct TagControls: View {
    @Environment(AppEnvironment.self) private var env
    let targets: [Entry]
    let current: Annotation?
    var modern: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if !modern { Text("Action Tag").font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], spacing: 6) {
                    ForEach([Tag.none] + Tag.actionTags) { tag in
                        DecisionButton(tag: tag,
                                       active: current?.tag == tag,
                                       key: ShortcutAction.forDecision(tag).map { env.shortcuts.key(for: $0) },
                                       modern: modern) {
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
    var modern: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .padding(.vertical, modern ? 9 : 5).padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background(active ? tag.swiftUIColor.opacity(0.22) : Color.gray.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: modern ? 11 : 7))
                .overlay(RoundedRectangle(cornerRadius: modern ? 11 : 7)
                    .strokeBorder(active ? tag.swiftUIColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? tag.swiftUIColor : .primary)
    }

    // Modern: icon-over-label (the design's .tagbtn). Classic: label+icon with key hint.
    @ViewBuilder private var content: some View {
        if modern {
            VStack(spacing: 5) {
                Image(systemName: tag.symbol).font(.system(size: 15))
                Text(tag.label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).textCase(.uppercase)
            }
        } else {
            VStack(spacing: 2) {
                Label(tag.label, systemImage: tag.symbol).labelStyle(.titleAndIcon).font(.callout)
                Text((key ?? " ").uppercased()).font(.caption2).foregroundStyle(.secondary)
            }
        }
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
