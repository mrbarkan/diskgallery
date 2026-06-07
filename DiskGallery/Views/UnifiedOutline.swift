import SwiftUI
import DiskGalleryCore

/// One visible line in the flattened outline (a node at a given depth).
private struct OutlineRow: Identifiable, Equatable {
    let node: UnifiedNode
    let depth: Int
    var isExpanded: Bool = false
    var isLoading: Bool = false
    var id: String { node.id }
}

/// A Finder "list view"-style expandable outline of the merged cross-drive tree.
/// Folders expand inline (children loaded lazily); arrow keys navigate and expand/
/// collapse. Selecting a row updates `env.selectedUnifiedNode` for the comparison panel.
/// Shared by the Modern and Classic All Drives surfaces.
struct UnifiedOutline: View {
    @Environment(AppEnvironment.self) private var env
    var atRiskOnly: Bool

    @State private var rows: [OutlineRow] = []
    @State private var selection: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(rows) { row in
                        rowView(row)
                            .tag(row.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: CGFloat(row.depth) * 14 + 10, bottom: 1, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .onKeyPress(.rightArrow) { handleRight() }
                .onKeyPress(.leftArrow) { handleLeft() }
            }
        }
        .onChange(of: selection) {
            env.selectedUnifiedNode = rows.first { $0.id == selection }?.node
        }
        .task(id: "\(env.dataVersion)|\(env.viewPrefs.hideHidden)|\(atRiskOnly)") {
            await reloadRoot()
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private var emptyState: some View {
        if env.volumeSummaries.isEmpty {
            ContentUnavailableView("No drives yet", systemImage: "externaldrive",
                                   description: Text("Scan some drives to see them merged here."))
        } else if atRiskOnly {
            ContentUnavailableView("All clear", systemImage: "checkmark.shield",
                                   description: Text("Nothing at the top level is at risk — every item has a copy on another drive."))
        } else {
            ContentUnavailableView("Nothing here", systemImage: "square.stack.3d.up",
                                   description: Text("No catalogued items."))
        }
    }

    private func rowView(_ row: OutlineRow) -> some View {
        HStack(spacing: 6) {
            if row.node.isDir {
                Button { Task { await toggle(row.id) } } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
            Circle().fill(row.node.coverage.color).frame(width: 7, height: 7)
            Image(systemName: row.node.isDir ? "folder.fill" : "doc")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(row.node.name).font(.system(size: 12)).lineLimit(1)
            if row.node.driveCount > 1 {
                Text("on \(row.node.driveCount)").font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
            }
            if row.isLoading { ProgressView().controlSize(.mini).scaleEffect(0.6) }
            Spacer(minLength: 8)
            Text(Format.size2(row.node.referenceSize))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
    }

    // MARK: Tree ops (flattened model)

    private func visible(_ node: UnifiedNode) -> Bool { atRiskOnly ? node.coverage == .atRisk : true }

    private func reloadRoot() async {
        let kids = await env.unifiedChildren(path: "")
        rows = kids.filter(visible).map { OutlineRow(node: $0, depth: 0) }
        if let sel = selection, !rows.contains(where: { $0.id == sel }) {
            selection = nil
            env.selectedUnifiedNode = nil
        }
    }

    private func toggle(_ id: String) async {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[i].isExpanded { collapse(id: id) } else { await expand(id: id) }
    }

    private func expand(id: String) async {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].node.isDir, !rows[i].isExpanded else { return }
        rows[i].isExpanded = true
        rows[i].isLoading = true
        let kids = await env.unifiedChildren(path: rows[i].node.relPath)
        guard let cur = rows.firstIndex(where: { $0.id == id }) else { return }   // row may have moved
        rows[cur].isLoading = false
        let depth = rows[cur].depth + 1
        let childRows = kids.filter(visible).map { OutlineRow(node: $0, depth: depth) }
        rows.insert(contentsOf: childRows, at: cur + 1)
    }

    private func collapse(id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let depth = rows[i].depth
        var end = i + 1
        while end < rows.count && rows[end].depth > depth { end += 1 }
        rows.removeSubrange((i + 1)..<end)
        rows[i].isExpanded = false
    }

    // MARK: Keyboard (← / → ; ↑↓ handled by List)

    private func handleRight() -> KeyPress.Result {
        guard let id = selection, let i = rows.firstIndex(where: { $0.id == id }) else { return .ignored }
        let row = rows[i]
        guard row.node.isDir else { return .ignored }
        if !row.isExpanded { Task { await expand(id: id) }; return .handled }
        if i + 1 < rows.count, rows[i + 1].depth > row.depth { selection = rows[i + 1].id; return .handled }
        return .ignored
    }

    private func handleLeft() -> KeyPress.Result {
        guard let id = selection, let i = rows.firstIndex(where: { $0.id == id }) else { return .ignored }
        let row = rows[i]
        if row.node.isDir && row.isExpanded { collapse(id: id); return .handled }
        if row.depth > 0 {                              // jump to parent
            var j = i - 1
            while j >= 0 && rows[j].depth >= row.depth { j -= 1 }
            if j >= 0 { selection = rows[j].id; return .handled }
        }
        return .ignored
    }
}
