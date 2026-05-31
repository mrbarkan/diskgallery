import SwiftUI
import DiskGalleryCore

/// Modern Transfer Planner page (mockup `.page--transfer`): queue + drive projections + summary,
/// below the permanent OLED. The queue is the real set of Move/Backup-tagged items; the
/// destination is a real picker; projections recompute real used→projected capacity from
/// `freeCapacity`. "Start transfer" + time estimate are rendered; the real engine is in the backlog.
struct ModernTransferPage: View {
    @Environment(AppEnvironment.self) private var env

    @State private var queue: [TaggedEntry] = []
    @State private var stats: [DriveStats] = []
    @State private var destinationKey: String?

    private var queueBytes: Int64 { queue.compactMap(\.displaySize).reduce(0, +) }
    private var destName: String? { stats.first { $0.volumeKey == destinationKey }?.name }

    var body: some View {
        ModernPageScaffold(leadingIcon: "arrow.left.arrow.right",
                           crumbs: ["Transfer Planner", "\(queue.count) queued"]) {
            ModernBento {
                TransferQueueCard(queue: queue, queueBytes: queueBytes,
                                  destName: destName, isConnected: { env.volumes.isConnected(key: $0) },
                                  volumeKey: volumeKey)
            } bottomLeft: {
                TransferSummaryTile(jobCount: queue.count, queueBytes: queueBytes,
                                    onStart: { /* real transfer engine: future-sprint backlog */ })
            } right: {
                DriveProjectionsCard(stats: capacityStats, destinationKey: $destinationKey,
                                     destName: destName, projections: projections())
            }
        }
        .task(id: env.dataVersion) { await reload() }
    }

    private var capacityStats: [DriveStats] { stats.filter { ($0.totalCapacity ?? 0) > 0 } }

    private func reload() async {
        stats = (try? await env.catalog.planning.driveStats()) ?? []
        var q = (try? await env.catalog.annotations.taggedEntries(.move)) ?? []
        q += (try? await env.catalog.annotations.taggedEntries(.backup)) ?? []
        queue = q.sorted { ($0.displaySize ?? 0) > ($1.displaySize ?? 0) }
        if destinationKey == nil || !stats.contains(where: { $0.volumeKey == destinationKey }) {
            destinationKey = capacityStats.max { ($0.freeCapacity ?? 0) < ($1.freeCapacity ?? 0) }?.volumeKey
        }
    }

    /// Source volume key for a queued item (match its volume name to a known drive).
    private func volumeKey(for item: TaggedEntry) -> String {
        stats.first { $0.name == item.volumeName }?.volumeKey ?? (item.volumeName ?? "")
    }

    private func projections() -> [DriveProjection] {
        let totalIncoming = queueBytes
        return capacityStats.map { s in
            let total = s.totalCapacity ?? 0
            let usedBytes: Int64 = {
                if let free = s.freeCapacity { return max(total - free, 0) }
                return s.usedLogical ?? 0
            }()
            let isDest = s.volumeKey == destinationKey
            let outgoing: Int64 = isDest ? 0 : queue
                .filter { $0.volumeName == s.name && $0.tag == .move }
                .compactMap(\.displaySize).reduce(0, +)
            let incoming: Int64 = isDest ? totalIncoming : 0
            let projBytes = max(usedBytes + incoming - outgoing, 0)
            return DriveProjection(
                id: s.volumeKey, name: s.name,
                cur: total > 0 ? Double(usedBytes) / Double(total) : 0,
                proj: total > 0 ? Double(projBytes) / Double(total) : 0,
                connected: env.volumes.isConnected(key: s.volumeKey))
        }
    }
}

struct DriveProjection: Identifiable {
    let id: String
    let name: String
    let cur: Double
    let proj: Double
    let connected: Bool
}

// MARK: - Transfer queue (area-tqueue)

private struct TransferQueueCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let queue: [TaggedEntry]
    let queueBytes: Int64
    let destName: String?
    let isConnected: (String) -> Bool
    let volumeKey: (TaggedEntry) -> String

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "arrow.left.arrow.right", title: "Transfer Queue",
                                 meta: "\(queue.count) queued · \(Format.bytes(queueBytes))", accent: accent)
                List {
                    ForEach(queue) { item in
                        QueueRow(item: item, destName: destName ?? "Choose…",
                                 connected: isConnected(volumeKey(item)), accent: accent)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 18))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if queue.isEmpty {
                        Text("Nothing queued — tag items Move or Backup")
                            .font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct QueueRow: View {
    @Environment(\.colorScheme) private var scheme
    let item: TaggedEntry
    let destName: String
    let connected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: (item.isDir == true) ? "folder.fill" : "doc").font(.system(size: 18))
                .frame(width: 20).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DGToken.ink(scheme))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(item.volumeName ?? "—").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DGToken.ink2(scheme))
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    Text(destName).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DGToken.ink2(scheme))
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Format.bytes(item.displaySize ?? 0)).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DGToken.ink2(scheme))
                QStatus(ready: connected)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

private struct QStatus: View {
    @Environment(\.colorScheme) private var scheme
    let ready: Bool
    var body: some View {
        Text(ready ? "READY" : "WAITING DRIVE")
            .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.0)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(ready ? DGToken.ok.opacity(0.16) : DGToken.glass2(scheme),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(ready ? DGToken.ok : DGToken.ink3(scheme))
    }
}

// MARK: - Drive projections (area-tproj)

private struct DriveProjectionsCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let stats: [DriveStats]
    @Binding var destinationKey: String?
    let destName: String?
    let projections: [DriveProjection]

    private var accent: Color { env.theme.accent.palette.accent }
    private var destOverfull: Bool { projections.first { $0.id == destinationKey }.map { $0.proj > 0.95 } ?? false }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "externaldrive", title: "Drive Projections",
                                 meta: "after transfer", accent: accent)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        destinationPicker
                        ForEach(projections) { p in ProjRow(p: p, accent: accent) }
                        if destOverfull {
                            ModernNote(text: "\(destName ?? "Destination") will exceed 95% — pick another target",
                                       systemImage: "exclamationmark.triangle", warn: true)
                        } else {
                            ModernNote(text: "All targets within capacity", systemImage: "checkmark.shield")
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var destinationPicker: some View {
        HStack(spacing: 10) {
            SecHeader(title: "Destination").fixedSize()
            Picker("", selection: $destinationKey) {
                ForEach(stats) { s in Text(s.name).tag(Optional(s.volumeKey)) }
            }
            .labelsHidden().pickerStyle(.menu).tint(accent)
            Spacer(minLength: 0)
        }
    }
}

private struct ProjRow: View {
    @Environment(\.colorScheme) private var scheme
    let p: DriveProjection
    let accent: Color

    private var shrinking: Bool { p.proj < p.cur }
    private var deltaColor: Color {
        if p.proj > 0.95 { return DGToken.bad }
        if shrinking { return DGToken.ok }
        return accent
    }
    private var dotColor: Color {
        if p.proj > 0.95 { return DGToken.bad }
        return p.connected ? DGToken.ok : DGToken.ink4(scheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(DGToken.ink(scheme))
                }
                Spacer(minLength: 8)
                (Text("\(Format.percent(p.cur)) → ").foregroundColor(DGToken.ink2(scheme))
                 + Text(Format.percent(p.proj)).fontWeight(.bold).foregroundColor(deltaColor))
                    .font(.system(size: 11, design: .monospaced))
            }
            bar
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                if shrinking {
                    Rectangle().fill(LinearGradient(colors: [env.accent2, accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * min(p.proj, 1))
                } else {
                    Rectangle().fill(DGToken.ink4(scheme)).frame(width: w * min(p.cur, 1))
                    Rectangle().fill(LinearGradient(colors: [env.accent2, accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * max(min(p.proj, 1) - min(p.cur, 1), 0))
                    if p.proj > 1 {
                        Rectangle().fill(DGToken.bad).frame(width: w * min(p.proj - 1, 0.08))
                    }
                }
            }
        }
        .frame(height: 12).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background(DGToken.inset(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // accent2 read via environment for the gradient's lighter stop
    @Environment(AppEnvironment.self) private var env
}

private extension AppEnvironment { var accent2: Color { theme.accent.palette.accent2 } }

// MARK: - Transfer summary (area-tsum)

private struct TransferSummaryTile: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let jobCount: Int
    let queueBytes: Int64
    let onStart: () -> Void

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Transfer Summary").modernMonoLabel(size: 9.5, tracking: 1.9)
                BigNum(bytes: queueBytes, tint: accent).padding(.top, 10)
                (Text("\(jobCount)").fontWeight(.bold).foregroundColor(DGToken.ink(scheme))
                 + Text(" jobs · est. ").foregroundColor(DGToken.ink2(scheme))
                 + Text("—").foregroundColor(DGToken.ink3(scheme))
                 + Text(" over USB-C").foregroundColor(DGToken.ink2(scheme)))
                    .font(.system(size: 12)).padding(.top, 8)
                Spacer(minLength: 8)
                CTAButton(title: "Start transfer", systemImage: "arrow.left.arrow.right", action: onStart)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
