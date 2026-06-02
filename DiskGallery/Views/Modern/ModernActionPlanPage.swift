import SwiftUI
import DiskGalleryCore

/// Modern Action Plan page (mockup `.page--plan`): tagged-items list + execute panel + plan totals,
/// below the permanent OLED. Per-tag bytes/counts aggregate the real `driveStats()` across drives.
/// Filter chips and the `.tagged` sidebar route preselect a tag. "Run plan" is rendered; real
/// execution is in the future-sprint backlog.
struct ModernActionPlanPage: View {
    @Environment(AppEnvironment.self) private var env

    let initialFilter: Tag?
    @State private var filter: Tag?
    @State private var items: [TaggedEntry] = []
    @State private var agg = PlanAggregate()

    init(initialFilter: Tag?) {
        self.initialFilter = initialFilter
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        ModernPageScaffold(leadingIcon: "checklist",
                           crumbs: ["Action Plan", "\(agg.totalCount) tagged"]) {
            ModernBento {
                TaggedItemsCard(items: items, filter: $filter,
                                totalCount: agg.totalCount, totalBytes: agg.totalBytes)
            } bottomLeft: {
                PlanTotalsTile(agg: agg)
            } right: {
                ExecutePlanCard(agg: agg)
            }
        }
        .task(id: env.dataVersion) { await reload() }
        .onChange(of: filter) { _, _ in Task { await loadItems() } }
    }

    private func reload() async {
        let stats = (try? await env.catalog.planning.driveStats()) ?? []
        agg = PlanAggregate(stats) { env.volumes.isConnected(key: $0) }
        await loadItems()
    }

    private func loadItems() async {
        let tags = filter.map { [$0] } ?? Tag.actionTags
        var all: [TaggedEntry] = []
        for tag in tags {
            all += (try? await env.catalog.annotations.taggedEntries(tag)) ?? []
        }
        items = all.sorted { ($0.displaySize ?? 0) > ($1.displaySize ?? 0) }
    }
}

/// Per-tag rollup across all drives, from `[DriveStats]`.
struct PlanAggregate {
    var bytes: [Tag: Int64] = [:]
    var counts: [Tag: Int] = [:]
    var disconnected = 0

    init() {}
    init(_ stats: [DriveStats], isConnected: (String) -> Bool) {
        for s in stats {
            for t in Tag.actionTags {
                bytes[t, default: 0] += s.bytes(for: t)
                counts[t, default: 0] += s.count(for: t)
            }
            if s.hasPending && !isConnected(s.volumeKey) { disconnected += 1 }
        }
    }
    var totalCount: Int { Tag.actionTags.reduce(0) { $0 + (counts[$1] ?? 0) } }
    var totalBytes: Int64 { Tag.actionTags.reduce(0) { $0 + (bytes[$1] ?? 0) } }
}

// MARK: - Tagged items (area-plist)

private struct TaggedItemsCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let items: [TaggedEntry]
    @Binding var filter: Tag?
    let totalCount: Int
    let totalBytes: Int64

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "list.bullet.rectangle", title: "Tagged Items",
                                 meta: "\(totalCount) items · \(Format.bytes(totalBytes))", accent: accent)
                HStack(spacing: 7) {
                    ModernFilterChip(label: "All", selected: filter == nil) { filter = nil }
                    ForEach(Tag.actionTags) { tag in
                        ModernFilterChip(label: tag.label, selected: filter == tag) { filter = tag }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)

                List {
                    ForEach(items) { item in
                        PlanItemRow(item: item, accent: accent)
                            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 18))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if items.isEmpty {
                        Text("Nothing tagged yet").font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct PlanItemRow: View {
    @Environment(\.colorScheme) private var scheme
    let item: TaggedEntry
    let accent: Color

    private var isDir: Bool { item.isDir == true }
    private var subtitle: String {
        let parent = (item.relPath as NSString).deletingLastPathComponent
        let path = parent.isEmpty ? "/" : "/" + parent
        return "\(item.volumeName ?? "—") · \(path)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isDir ? "folder.fill" : "doc").font(.system(size: 18)).frame(width: 20)
                .foregroundStyle(isDir ? accent : DGToken.ink3(scheme))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DGToken.ink(scheme))
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 9, design: .monospaced)).foregroundStyle(DGToken.ink3(scheme))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ChipView(tag: item.tag)
            Text(Format.bytes(item.displaySize ?? 0)).font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(DGToken.ink2(scheme)).frame(minWidth: 66, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .contentShape(Rectangle())
        .revealInFinder(volumeKey: item.volumeUuid, relPath: item.relPath, isDir: isDir)
    }
}

// MARK: - Plan totals (area-ptot)

private struct PlanTotalsTile: View {
    let agg: PlanAggregate
    private var rows: [(tag: Tag, bytes: Int64)] {
        [Tag.keep, .backup, .move, .review, .delete].map { ($0, agg.bytes[$0] ?? 0) }
    }
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Plan Totals").modernMonoLabel(size: 9.5, tracking: 1.9)
                PlanBreakdownRows(rows: rows).padding(.top, 13)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Execute plan (area-pexec)

private struct ExecutePlanCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let agg: PlanAggregate

    @State private var running = false
    @State private var result: TagSyncResult?

    private var accent: Color { env.theme.accent.palette.accent }

    private func run() async {
        running = true
        result = await env.syncFinderTags()
        running = false
    }

    private var resultText: String? {
        guard let r = result else { return nil }
        var parts = ["Wrote \(r.filesWritten) tag\(r.filesWritten == 1 ? "" : "s") across \(r.drivesSynced) drive\(r.drivesSynced == 1 ? "" : "s")"]
        if r.filesSkipped > 0 { parts.append("\(r.filesSkipped) skipped (offline)") }
        if r.failures > 0 { parts.append("\(r.failures) failed") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "checkmark.circle", title: "Execute Plan",
                                 meta: "\(agg.totalCount) tagged", accent: accent)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sumGrid
                        runOrder
                        CTAButton(title: running ? "Writing Finder tags…" : "Run plan",
                                  systemImage: "play.fill", disabled: running) {
                            Task { await run() }
                        }
                        .proGated(.bulkTagSync)
                        if let resultText {
                            ModernNote(text: resultText, systemImage: "checkmark.shield")
                        } else if agg.disconnected > 0 {
                            ModernNote(text: "\(agg.disconnected) drive\(agg.disconnected == 1 ? "" : "s") offline — connected drives will still sync",
                                       systemImage: "exclamationmark.triangle", warn: true)
                        } else {
                            ModernNote(text: "All tagged drives connected", systemImage: "checkmark.shield")
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var sumGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            SumCell(bytes: agg.bytes[.delete] ?? 0, caption: "Freed by delete", tint: DGToken.bad)
            SumCell(count: agg.counts[.backup] ?? 0, caption: "To back up", tint: Tag.backup.modernColor)
            SumCell(count: agg.counts[.move] ?? 0, caption: "To move", tint: Tag.move.modernColor)
            SumCell(count: agg.counts[.review] ?? 0, caption: "Need review", tint: DGToken.warn)
        }
    }

    private var runOrder: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecHeader(title: "Run order")
            VStack(spacing: 0) {
                StepRow(n: 1, label: "Verify checksums", amount: "\(agg.totalCount) items", accent: accent, last: false)
                StepRow(n: 2, label: "Move flagged files", amount: Format.bytes(agg.bytes[.move] ?? 0), accent: accent, last: false)
                StepRow(n: 3, label: "Back up to drives", amount: Format.bytes(agg.bytes[.backup] ?? 0), accent: accent, last: false)
                StepRow(n: 4, label: "Delete confirmed duplicates", amount: Format.bytes(agg.bytes[.delete] ?? 0), accent: accent, last: true)
            }
        }
    }
}

private struct SumCell: View {
    @Environment(\.colorScheme) private var scheme
    let value: String
    let unit: String?
    let caption: String
    let tint: Color

    init(count: Int, caption: String, tint: Color) {
        self.value = "\(count)"; self.unit = nil; self.caption = caption; self.tint = tint
    }
    init(bytes: Int64, caption: String, tint: Color) {
        let parts = Format.bytes(bytes).split(separator: " ", maxSplits: 1)
        self.value = parts.first.map(String.init) ?? "0"
        self.unit = parts.count > 1 ? String(parts[1]) : nil
        self.caption = caption; self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 22, weight: .heavy)).foregroundStyle(tint)
                if let unit { Text(unit).font(.system(size: 12, weight: .bold)).foregroundStyle(DGToken.ink2(scheme)) }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            Text(caption.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .monospaced)).tracking(1.4)
                .foregroundStyle(DGToken.ink3(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(DGToken.glass2(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct StepRow: View {
    @Environment(\.colorScheme) private var scheme
    let n: Int
    let label: String
    let amount: String
    let accent: Color
    let last: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Text("\(n)").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent).frame(width: 20, height: 20)
                    .background(accent.opacity(0.16), in: Circle())
                Text(label).font(.system(size: 12.5)).foregroundStyle(DGToken.ink2(scheme)).lineLimit(1)
                Spacer(minLength: 8)
                Text(amount).font(.system(size: 11, design: .monospaced)).foregroundStyle(DGToken.ink(scheme))
            }
            .padding(.vertical, 9).padding(.horizontal, 2)
            if !last { Rectangle().fill(DGToken.hair(scheme)).frame(height: 1) }
        }
    }
}
