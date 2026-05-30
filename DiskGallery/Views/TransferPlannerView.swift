import SwiftUI
import DiskGalleryCore

/// Simulates moving a set of files from one drive to another and tells the user — up
/// front, offline — whether it will fit, with how much room to spare.
struct TransferPlannerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var stats: [DriveStats] = []
    @State private var sourceId: Int64?
    @State private var destId: Int64?
    @State private var choice: SourceChoice = .move
    @State private var items: [PlannedItem] = []

    enum SourceChoice: String, CaseIterable, Identifiable {
        case move, backup, keep, entire
        var id: String { rawValue }
        var label: String {
            switch self {
            case .move: return "Tagged Move"
            case .backup: return "Tagged Backup"
            case .keep: return "Tagged Keep"
            case .entire: return "Entire drive"
            }
        }
        var tag: Tag? {
            switch self {
            case .move: return .move
            case .backup: return .backup
            case .keep: return .keep
            case .entire: return nil
            }
        }
    }

    private var source: DriveStats? { stats.first { $0.id == sourceId } }
    private var destination: DriveStats? { stats.first { $0.id == destId } }

    private var transferBytes: Int64 {
        guard let source else { return 0 }
        if let tag = choice.tag { return source.bytes(for: tag) }
        return source.usedLogical ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pickers
            Divider()
            if source != nil, destination != nil {
                resultCard
                if !items.isEmpty { itemList }
                Spacer()
            } else {
                ContentUnavailableView("Plan a transfer",
                                       systemImage: "arrow.left.arrow.right",
                                       description: Text("Pick what to move and where to move it. DiskGallery checks it’ll fit — no need to plug anything in."))
            }
        }
        .padding(16)
        .navigationTitle("Transfer Planner")
        .task(id: env.dataVersion) { await loadStats() }
        .onChange(of: sourceId) { _, _ in Task { await loadItems() } }
        .onChange(of: choice) { _, _ in Task { await loadItems() } }
    }

    private var pickers: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Move").foregroundStyle(.secondary)
                Picker("", selection: $choice) {
                    ForEach(SourceChoice.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
                Text("from").foregroundStyle(.secondary)
                drivePicker(selection: $sourceId)
            }
            GridRow {
                Text("to").foregroundStyle(.secondary)
                Color.clear.frame(height: 0)
                Color.clear.frame(height: 0)
                drivePicker(selection: $destId, excluding: sourceId)
            }
        }
    }

    private func drivePicker(selection: Binding<Int64?>, excluding: Int64? = nil) -> some View {
        Picker("", selection: selection) {
            Text("Choose a drive…").tag(Int64?.none)
            ForEach(stats.filter { $0.id != excluding }) { drive in
                Text(drive.name).tag(Int64?.some(drive.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 240, alignment: .leading)
    }

    private var resultCard: some View {
        let free = destination?.freeCapacity
        let fits = free.map { transferBytes <= $0 }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: verdictIcon(fits)).foregroundStyle(verdictColor(fits))
                Text(verdictText(fits)).font(.headline).foregroundStyle(verdictColor(fits))
            }
            Text("Moving \(Format.bytes(transferBytes)) → “\(destination?.name ?? "")”")
                .font(.callout).foregroundStyle(.secondary)
            CapacityBar(total: destination?.totalCapacity, free: destination?.freeCapacity,
                        incoming: transferBytes)
                .frame(maxWidth: 420)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdictColor(fits).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(items.count) item\(items.count == 1 ? "" : "s") to move").font(.subheadline.weight(.medium))
            List(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isDir ? "folder.fill" : "doc")
                        .foregroundStyle(item.isDir ? Color.accentColor : .secondary).frame(width: 16)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text(Format.bytes(item.sizeBytes)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minHeight: 140)
        }
    }

    private func verdictText(_ fits: Bool?) -> String {
        guard let dest = destination else { return "" }
        guard let free = dest.freeCapacity else { return "Free space on “\(dest.name)” is unknown" }
        if transferBytes <= free {
            return "Fits — \(Format.bytes(free - transferBytes)) to spare"
        }
        return "Won’t fit — over by \(Format.bytes(transferBytes - free))"
    }

    private func verdictIcon(_ fits: Bool?) -> String {
        switch fits {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "exclamationmark.triangle.fill"
        case .none: return "questionmark.circle"
        }
    }

    private func verdictColor(_ fits: Bool?) -> Color {
        switch fits {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }

    private func loadStats() async {
        stats = (try? await env.catalog.planning.driveStats()) ?? []
        if sourceId == nil { sourceId = stats.first?.id }
        if destId == nil { destId = stats.dropFirst().first?.id }
        await loadItems()
    }

    private func loadItems() async {
        guard let source, let tag = choice.tag else { items = []; return }
        items = (try? await env.catalog.planning.plannedItems(volumeKey: source.volumeKey, tag: tag)) ?? []
    }
}
