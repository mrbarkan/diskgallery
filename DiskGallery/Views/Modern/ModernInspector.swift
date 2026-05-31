import SwiftUI
import DiskGalleryCore

/// Modern bento inspector card (spec §10). Header + scrollable body. Lives inside the
/// workspace bento; the Classic detail column still uses EntryDetailView's Form, untouched.
struct ModernInspectorCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        let entries = env.selectedEntries
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "info.circle", title: "Inspector",
                                 meta: entries.isEmpty ? "" : "\(entries.count) selected", accent: accent)
                if entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30)).foregroundStyle(DGToken.ink4(scheme))
                        Text("Select a file or folder").font(.system(size: 12)).foregroundStyle(DGToken.ink3(scheme))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        ModernInspectorBody(entries: entries)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }
}

struct ModernInspectorBody: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let entries: [Entry]

    @State private var annotation: Annotation?
    @State private var note: String = ""

    private var accent: Color { env.theme.accent.palette.accent }
    private var single: Entry? { entries.count == 1 ? entries.first : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            if let single { specGrid(single) }
            sectionHeader("Action Tag")
            tagButtons
            sectionHeader("Finder Color")
            swatches
            FinderSyncNote().padding(.top, 12)
            if single != nil {
                sectionHeader("Note")
                noteEditor
            }
        }
        .task(id: reloadKey) { await load() }
    }

    // MARK: Hero
    private var hero: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.30), DGToken.bg2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DGToken.hair2(scheme), lineWidth: 1))
                Image(systemName: heroIcon).font(.system(size: 24)).foregroundStyle(accent)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(heroTitle).font(.system(size: 16, weight: .bold)).foregroundStyle(DGToken.ink(scheme)).lineLimit(2)
                Text(heroKind).font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(1.2)
                    .textCase(.uppercase).foregroundStyle(DGToken.ink3(scheme))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4).padding(.bottom, 14)
    }

    private var heroIcon: String {
        guard let single else { return "square.stack.3d.up.fill" }
        return single.isDir ? "folder.fill" : "doc.fill"
    }
    private var heroTitle: String { single?.name ?? "\(entries.count) items selected" }
    private var heroKind: String {
        if let single { return single.isDir ? "Folder" : (single.ext.map { ".\($0)" } ?? "File") }
        return "Total \(Format.bytes(entries.reduce(Int64(0)) { $0 + $1.displaySize }))"
    }

    // MARK: Spec grid
    private func specGrid(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topRule
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                specRow("Size", Format.bytes(entry.displaySize), color: accent)
                if !entry.isDir { specRow("On disk", Format.bytes(entry.allocSize)) }
                specRow("Modified", Format.date(entry.modifiedAt))
                specRow("Path", entry.relPath.isEmpty ? "/" : entry.relPath)
            }
            .padding(.vertical, 12)
        }
    }

    private func specRow(_ key: String, _ value: String, color: Color? = nil) -> some View {
        GridRow {
            Text(key.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4)
                .foregroundStyle(DGToken.ink3(scheme)).gridColumnAlignment(.leading)
                .frame(width: 84, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color ?? DGToken.ink(scheme)).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: Tag buttons (2×3, mockup order)
    private var tagButtons: some View {
        let order: [Tag] = [.keep, .delete, .review, .move, .backup, .none]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
            ForEach(order) { tag in
                ModernTagButton(tag: tag, active: annotation?.tag == tag) {
                    Task { await env.applyDecision(tag, to: entries) }
                }
            }
        }
    }

    // MARK: Swatches (none + keyOrder, ink active ring)
    private var swatches: some View {
        HStack(spacing: 9) {
            ModernSwatch(color: .none, active: (annotation?.color ?? .none) == .none) {
                Task { await env.applyColor(.none, to: entries) }
            }
            ForEach(FinderColor.keyOrder) { color in
                ModernSwatch(color: color, active: annotation?.color == color) {
                    Task { await env.applyColor(color, to: entries) }
                }
            }
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Note", text: $note, axis: .vertical)
                .lineLimit(3, reservesSpace: true).textFieldStyle(.roundedBorder)
            Button("Save Note") { if let single { Task { await env.applyNote(note, to: single) } } }
                .controlSize(.small)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topRule
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.6)
                .foregroundStyle(DGToken.ink3(scheme)).padding(.top, 12).padding(.bottom, 9)
        }
    }

    private var topRule: some View { Rectangle().fill(DGToken.hair(scheme)).frame(height: 1).frame(maxWidth: .infinity) }

    private var reloadKey: String { entries.map { String($0.id) }.joined(separator: ",") + "-\(env.dataVersion)" }
    private func load() async {
        guard let single, let key = env.selectedVolumeKey else { annotation = nil; note = ""; return }
        annotation = try? await env.catalog.annotations.annotation(volumeKey: key, relPath: single.relPath)
        note = annotation?.note ?? ""
    }
}

/// The mockup's `.tagbtn` — icon over mono label; active = tag color border + tint fill.
struct ModernTagButton: View {
    @Environment(\.colorScheme) private var scheme
    let tag: Tag
    let active: Bool
    let action: () -> Void

    private var icon: String { tag == .none ? "minus" : tag.symbol }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 16))
                Text(tag.label.uppercased()).font(.system(size: 8.5, weight: .bold, design: .monospaced)).tracking(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9).padding(.horizontal, 6)
            .foregroundStyle(active ? tag.modernColor : DGToken.ink2(scheme))
            .background(active ? tag.modernColor.opacity(0.14) : DGToken.glass2(scheme),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(active ? tag.modernColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The mockup's `.sw` — 24px Finder-color circle; active = 2px ink ring (spec §10).
struct ModernSwatch: View {
    @Environment(\.colorScheme) private var scheme
    let color: FinderColor
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if color == .none {
                    Circle().fill(DGToken.glass2(scheme))
                        .overlay(Circle().strokeBorder(DGToken.hair2(scheme), lineWidth: 1))
                    Image(systemName: "line.diagonal").font(.system(size: 12)).foregroundStyle(DGToken.ink3(scheme))
                } else {
                    Circle().fill(color.modernColor)
                        .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                }
            }
            .frame(width: 24, height: 24)
            .overlay { if active { Circle().strokeBorder(DGToken.ink(scheme), lineWidth: 2).padding(-3) } }
        }
        .buttonStyle(.plain)
        .help(color == .none ? "No color" : color.tagName)
    }
}
