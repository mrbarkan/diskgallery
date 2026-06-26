import SwiftUI
import DiskGalleryCore

extension Coverage {
    var color: Color {
        switch self {
        case .atRisk:    return .red
        case .backedUp:  return .orange
        case .protected: return .green
        }
    }
    var label: String {
        switch self {
        case .atRisk:    return "At risk"
        case .backedUp:  return "Backed up"
        case .protected: return "Protected"
        }
    }
}

/// Per-folder copy comparison, shared by the Classic and Modern All Drives surfaces.
/// Lists each drive's copy with reference/partial/identical/offline badges, a size bar,
/// modified date, and a non-destructive tag menu that feeds the Organize plan.
struct UnifiedComparePanel: View {
    @Environment(AppEnvironment.self) private var env
    let node: UnifiedNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(node.copies) { copyRow($0) }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: node.isDir ? "folder.fill" : "doc").foregroundStyle(.secondary)
                Text(node.name).font(.headline).lineLimit(1)
            }
            HStack(spacing: 6) {
                Circle().fill(node.coverage.color).frame(width: 8, height: 8)
                Text(node.coverage.label)
                Text("· on \(node.driveCount) drive\(node.driveCount == 1 ? "" : "s")")
                if node.redundantSize > 0 {
                    Text("· \(Format.size2(node.redundantSize)) redundant")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private func copyRow(_ copy: UnifiedCopy) -> some View {
        let connected = env.volumes.isConnected(key: copy.volumeKey)
        let fraction = node.referenceSize > 0 ? Double(copy.size) / Double(node.referenceSize) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(copy.volumeName).fontWeight(copy.isReference ? .semibold : .regular).lineLimit(1)
                if copy.isReference { badge("Reference", .green) }
                if copy.isPartial { badge("Partial", .orange) }
                if let m = copy.matchesReference { badge(m ? "Identical" : "Differs", m ? .secondary : .orange) }
                if !connected { badge("Offline", .secondary) }
                Spacer(minLength: 8)
                Text(Format.size2(copy.size)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                tagMenu(copy)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(copy.isReference ? Color.green : Color.accentColor)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, fraction))))
                }
            }
            .frame(height: 5)
            if let d = copy.modifiedAt {
                Text("modified \(Format.relativeDate(d))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(copy.isReference ? Color.green.opacity(0.08) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(copy.isReference ? Color.green.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    private func tagMenu(_ copy: UnifiedCopy) -> some View {
        Menu {
            Button("Back up") { env.tagCopy(.backup, copy: copy) }
            Button("Move")    { env.tagCopy(.move, copy: copy) }
            Button("Delete", role: .destructive) { env.tagCopy(.delete, copy: copy) }
            Divider()
            Button("Clear tag") { env.tagCopy(.none, copy: copy) }
        } label: {
            Image(systemName: "tag")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Tag this copy for the Organize plan")
    }
}
