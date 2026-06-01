import SwiftUI
import DiskGalleryCore

/// Modern Duplicates page (mockup `.page--dupes`): sets list + resolve inspector + reclaim tile,
/// below the permanent OLED. Real data throughout; the "Delete N" / "Auto-resolve all" actions
/// tag the redundant copies as Delete (never touch files). File-type filter chips and keep-rule
/// chips are rendered but their real behavior is deferred (see future-sprint backlog).
struct ModernDuplicatesPage: View {
    @Environment(AppEnvironment.self) private var env

    @State private var sets: [DuplicateSet] = []
    @State private var selectedSetID: String?
    @State private var filter: String = FileCategory.all.rawValue
    @State private var members: [DuplicateMember] = []
    @State private var keepRule: String = KeepRule.fastestDrive.label
    @State private var capacities: [String: Int64] = [:]

    private var selectedSet: DuplicateSet? { sets.first { $0.id == selectedSetID } }
    private var redundantCopies: Int { sets.reduce(0) { $0 + max($1.copies - 1, 0) } }
    private var rule: KeepRule { KeepRule.allCases.first { $0.label == keepRule } ?? .fastestDrive }
    private var keptID: Int64? { keptMemberID(members: members, rule: rule, capacities: capacities) }

    var body: some View {
        ModernPageScaffold(leadingIcon: "square.on.square", crumbs: ["Duplicates", "All drives"]) {
            ModernBento {
                DupSetsCard(sets: sets, selectedSetID: $selectedSetID, filter: $filter,
                            totalReclaimable: env.totalReclaimable)
            } bottomLeft: {
                DupReclaimTile(setCount: sets.count, redundantCopies: redundantCopies,
                               onAutoResolve: { Task { await autoResolveAll() } })
            } right: {
                ResolveSetCard(set: selectedSet, members: members, keepRule: $keepRule, keptID: keptID,
                               onDelete: { Task { await deleteRedundant() } },
                               onVerify: { if let s = selectedSet { Task { await env.verify(set: s); await loadMembers() } } })
            }
        }
        .task(id: env.dataVersion) { await loadSets() }
        .onChange(of: selectedSetID) { _, _ in Task { await loadMembers() } }
    }

    private func loadSets() async {
        sets = (try? await env.catalog.duplicates.duplicateSets()) ?? []
        let stats = (try? await env.catalog.planning.driveStats()) ?? []
        capacities = Dictionary(stats.map { ($0.volumeKey, $0.totalCapacity ?? 0) },
                                uniquingKeysWith: { first, _ in first })
        if selectedSetID == nil || !sets.contains(where: { $0.id == selectedSetID }) {
            selectedSetID = sets.first?.id
        }
        await loadMembers()
    }

    private func loadMembers() async {
        guard let s = selectedSet else { members = []; return }
        members = (try? await env.catalog.duplicates.members(name: s.name, logicalSize: s.logicalSize)) ?? []
    }

    /// Tags every copy except the keep-rule's chosen one as Delete (the current set).
    private func deleteRedundant() async {
        guard members.count > 1 else { return }
        await tagRedundant(members, keepID: keptID)
    }

    /// Applies the keep-rule across every set, recomputing the kept copy per set.
    private func autoResolveAll() async {
        for s in sets {
            let ms = (try? await env.catalog.duplicates.members(name: s.name, logicalSize: s.logicalSize)) ?? []
            let keep = keptMemberID(members: ms, rule: rule, capacities: capacities)
            await tagRedundant(ms, keepID: keep)
        }
    }

    /// Tags everything except `keepID` as Delete. Never touches files (catalog + Finder tags only).
    private func tagRedundant(_ ms: [DuplicateMember], keepID: Int64?) async {
        guard ms.count > 1 else { return }
        var entries: [Entry] = []
        for m in ms where m.entryId != keepID {
            if let e = try? await env.catalog.library.entry(id: m.entryId) { entries.append(e) }
        }
        if !entries.isEmpty { await env.applyDecision(.delete, to: entries) }
    }
}

// MARK: - Sets list (area-dlist)

private struct DupSetsCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let sets: [DuplicateSet]
    @Binding var selectedSetID: String?
    @Binding var filter: String
    let totalReclaimable: Int64

    private var accent: Color { env.theme.accent.palette.accent }
    private let chips = FileCategory.allCases

    /// Sets narrowed to the selected file-type chip (`.all` → everything).
    private var visibleSets: [DuplicateSet] {
        let category = FileCategory(rawValue: filter) ?? .all
        return sets.filter { category.matches(filename: $0.name) }
    }
    private var visibleReclaimable: Int64 { visibleSets.reduce(0) { $0 + $1.reclaimable } }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "square.on.square", title: "Duplicate Sets",
                                 meta: "\(Format.count(visibleSets.count)) sets · \(Format.bytes(visibleReclaimable))",
                                 accent: accent)
                HStack(spacing: 7) {
                    ForEach(chips, id: \.self) { c in
                        ModernFilterChip(label: c.label, selected: filter == c.rawValue) { filter = c.rawValue }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
                .proGated(.dupFilterChips)

                List(selection: $selectedSetID) {
                    ForEach(visibleSets) { set in
                        DupSetRow(set: set, accent: accent)
                            .tag(set.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 18))
                            .listRowSeparator(.hidden)
                            .listRowBackground(rowBackground(set.id == selectedSetID))
                    }
                    if visibleSets.isEmpty {
                        Text("No duplicates found").font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder private func rowBackground(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(accent.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(accent.opacity(0.42), lineWidth: 1))
                .padding(.vertical, 1)
        } else { Color.clear }
    }
}

private struct DupSetRow: View {
    @Environment(\.colorScheme) private var scheme
    let set: DuplicateSet
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.on.square").font(.system(size: 18)).frame(width: 20).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(set.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DGToken.ink(scheme))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(set.copies) copies · \(set.driveNames)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(DGToken.ink3(scheme))
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("×\(set.copies)").font(.system(size: 11, design: .monospaced)).foregroundStyle(DGToken.ink2(scheme))
            Text("+\(Format.bytes(set.reclaimable))").font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(DGToken.ok).frame(minWidth: 66, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Reclaim tile (area-dstat)

private struct DupReclaimTile: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let setCount: Int
    let redundantCopies: Int
    let onAutoResolve: () -> Void

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reclaimable across all drives").modernMonoLabel(size: 9.5, tracking: 1.9)
            BigNum(bytes: env.totalReclaimable, tint: accent).padding(.top, 10)
            StackBar().padding(.top, 12)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline) {
                (Text("\(Format.count(setCount))").fontWeight(.bold).foregroundColor(DGToken.ink(scheme))
                 + Text(" sets · ").foregroundColor(DGToken.ink2(scheme))
                 + Text("\(Format.count(redundantCopies))").fontWeight(.bold).foregroundColor(DGToken.ink(scheme))
                 + Text(" redundant copies").foregroundColor(DGToken.ink2(scheme)))
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                Button(action: onAutoResolve) {
                    Text("Auto-resolve all")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(1.6)
                        .textCase(.uppercase).foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(DGToken.hair(scheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 22, y: 14)
    }
}

// MARK: - Resolve set (area-dside)

private struct ResolveSetCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let set: DuplicateSet?
    let members: [DuplicateMember]
    @Binding var keepRule: String
    let keptID: Int64?
    let onDelete: () -> Void
    let onVerify: () -> Void

    private var accent: Color { env.theme.accent.palette.accent }
    private let rules = KeepRule.allCases.map(\.label)
    private var allVerified: Bool { !members.isEmpty && members.allSatisfy { $0.contentHash != nil } }
    private var deleteCount: Int { max((set?.copies ?? 1) - 1, 0) }

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                ModernCardHeader(systemImage: "checkmark.circle", title: "Resolve Set",
                                 meta: set.map { "×\($0.copies)" } ?? "", accent: accent)
                if let set {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            hero(set)
                            copiesSection
                            keepRuleSection
                            CTAButton(title: "Delete \(deleteCount) duplicates · free \(Format.bytes(set.reclaimable))",
                                      systemImage: "trash", tint: DGToken.bad, action: onDelete)
                            if allVerified {
                                ModernNote(text: "Verified identical by checksum (SHA-256)", systemImage: "checkmark.shield")
                            } else {
                                CTAButton(title: "Verify by checksum", systemImage: "checkmark.shield",
                                          ghost: true, action: onVerify)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "square.on.square").font(.system(size: 30)).foregroundStyle(DGToken.ink4(scheme))
                        Text("Select a duplicate set").font(.system(size: 12)).foregroundStyle(DGToken.ink3(scheme))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func hero(_ set: DuplicateSet) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.30), DGToken.bg2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DGToken.hair2(scheme), lineWidth: 1))
                Image(systemName: "square.on.square").font(.system(size: 24)).foregroundStyle(accent)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(set.name).font(.system(size: 16, weight: .bold)).foregroundStyle(DGToken.ink(scheme)).lineLimit(2)
                Text("\(Format.bytes(set.logicalSize)) each · +\(Format.bytes(set.reclaimable)) reclaimable")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(1.2)
                    .textCase(.uppercase).foregroundStyle(DGToken.ink3(scheme))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var copiesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SecHeader(title: "Copies found")
            VStack(spacing: 8) {
                ForEach(members) { m in
                    CopyRow(drive: m.volumeName, path: m.relPath, keep: m.entryId == keptID)
                }
            }
        }
    }

    private var keepRuleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SecHeader(title: "Keep rule")
            HStack(spacing: 7) {
                ForEach(rules, id: \.self) { r in
                    ModernFilterChip(label: r, selected: keepRule == r) { keepRule = r }
                }
                Spacer(minLength: 0)
            }
            if keepRule == KeepRule.fastestDrive.label {
                ModernNote(text: "No drive-speed data yet — keeping the copy on the largest drive.",
                           systemImage: "info.circle")
            }
        }
        .proGated(.keepRuleApply)
    }
}

private struct CopyRow: View {
    @Environment(\.colorScheme) private var scheme
    let drive: String
    let path: String
    let keep: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(drive).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DGToken.ink(scheme))
                Text(path).font(.system(size: 9, design: .monospaced)).foregroundStyle(DGToken.ink3(scheme))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(keep ? "KEEP" : "DELETE")
                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.0)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((keep ? DGToken.ok : DGToken.bad).opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(keep ? DGToken.ok : DGToken.bad)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(DGToken.glass2(scheme))
            if keep { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(DGToken.ok.opacity(0.10)) }
        }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(keep ? DGToken.ok.opacity(0.45) : .clear, lineWidth: 1))
    }
}
