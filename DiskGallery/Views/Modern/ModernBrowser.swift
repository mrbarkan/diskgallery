import SwiftUI
import DiskGalleryCore

/// Modern bento browser — a folder's contents as `.frow` rows inside a glass card (spec §9).
/// Keeps SwiftUI `List` so native multi-select (⌘/⇧), keyboard nav, the context-menu tag
/// actions, and double-click-to-open (`primaryAction`) all work exactly as in Classic.
struct ModernBrowserCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let snapshotId: Int64
    let folder: Entry
    let nav: BrowserNav

    @State private var children: [Entry] = []
    @State private var annotations: [String: Annotation] = [:]
    @State private var selection: Set<Int64> = []

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "folder.fill", title: folder.name, meta: meta, accent: accent)
                list
            }
        }
        .task(id: folder.id) { await load() }
        .onChange(of: env.dataVersion) { _, _ in Task { await load() } }
        .onChange(of: selection) { _, _ in updateSelection() }
        .onAppear { if selection.isEmpty { env.selectedEntries = [folder] } }
    }

    private var visibleChildren: [Entry] {
        env.viewPrefs.hideHidden ? children.filter { !PathVisibility.isHidden(relPath: $0.name) } : children
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(visibleChildren) { entry in
                ModernFrow(entry: entry, annotation: annotations[entry.relPath], accent: accent)
                    .tag(entry.id)
                    .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 18))
                    .listRowSeparator(.hidden)
                    .listRowBackground(rowBackground(for: entry))
            }
            if children.isEmpty {
                Text("Empty folder").font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            tagMenu(for: entries(for: ids))
        } primaryAction: { ids in
            if let entry = entries(for: ids).first(where: \.isDir) { nav.open(entry) }
        }
    }

    @ViewBuilder private func rowBackground(for entry: Entry) -> some View {
        if selection.contains(entry.id) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(accent.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(accent.opacity(0.42), lineWidth: 1))
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }

    private var meta: String {
        let count = children.count
        let total = children.reduce(Int64(0)) { $0 + $1.displaySize }
        return "\(count) item\(count == 1 ? "" : "s") · \(Format.bytes(total))"
    }

    private func entries(for ids: Set<Int64>) -> [Entry] { children.filter { ids.contains($0.id) } }

    private func updateSelection() {
        let selected = entries(for: selection)
        env.selectedEntries = selected.isEmpty ? [folder] : selected
    }

    @ViewBuilder private func tagMenu(for targets: [Entry]) -> some View {
        if !targets.isEmpty {
            if let single = targets.first, targets.count == 1, !single.isDir,
               env.canReveal(volumeKey: env.selectedVolumeKey) {
                Button {
                    env.revealInFinder(volumeKey: env.selectedVolumeKey, relPath: single.relPath)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Divider()
            }
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

/// The mockup's `.frow` — icon · name(+ext) · tag chip + color dot · mono size.
struct ModernFrow: View {
    @Environment(\.colorScheme) private var scheme
    let entry: Entry
    let annotation: Annotation?
    var accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .font(.system(size: 18)).frame(width: 20)
                .foregroundStyle(entry.isDir ? accent : DGToken.ink3(scheme))
            name.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                if let tag = annotation?.tag, tag != .none { ChipView(tag: tag) }
                if let color = annotation?.color, color != .none { ColorDot(color: color) }
            }
            Text(Format.bytes(entry.displaySize))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DGToken.ink2(scheme))
                .frame(minWidth: 66, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    private var name: some View {
        let base: String, ext: String
        if !entry.isDir, let e = entry.ext, !e.isEmpty, entry.name.hasSuffix("." + e) {
            base = String(entry.name.dropLast(e.count + 1)); ext = "." + e
        } else {
            base = entry.name; ext = ""
        }
        return HStack(spacing: 0) {
            Text(base).foregroundStyle(DGToken.ink(scheme)).lineLimit(1).truncationMode(.middle)
            if !ext.isEmpty { Text(ext).foregroundStyle(DGToken.ink3(scheme)).lineLimit(1) }
        }
        .font(.system(size: 13.5, weight: .medium))
    }
}
