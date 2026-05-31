import SwiftUI
import DiskGalleryCore

/// Modern bento stat tiles (spec §11). Read existing env data only — counts, not fabricated sizes.

struct ReclaimableTile: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reclaimable · Duplicates").modernMonoLabel(size: 9.5, tracking: 1.9)
            bigNum.padding(.top, 10)
            stackBar.padding(.top, 12)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 0) {
                    Text("Across ").foregroundStyle(DGToken.ink2(scheme))
                    Text("\(env.volumeSummaries.count)").fontWeight(.bold).foregroundStyle(DGToken.ink(scheme))
                    Text(" drives").foregroundStyle(DGToken.ink2(scheme))
                }
                .font(.system(size: 12))
                Spacer(minLength: 8)
                Text("View →").modernMonoLabel(size: 9.5, tracking: 1.9)
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
        .contentShape(Rectangle())
        .onTapGesture { env.selection = .duplicates }
    }

    private var bigNum: some View {
        let parts = Format.bytes(env.totalReclaimable).split(separator: " ", maxSplits: 1)
        let value = parts.first.map(String.init) ?? "0"
        let unit = parts.count > 1 ? String(parts[1]) : ""
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value).font(.system(size: 48, weight: .heavy)).foregroundStyle(accent)
            if !unit.isEmpty { Text(unit).font(.system(size: 21, weight: .bold)).foregroundStyle(DGToken.ink2(scheme)) }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
    }

    /// Decorative stacked bar matching the mockup (no per-category reclaimable data exists).
    private var stackBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(accent).frame(width: geo.size.width * 0.46)
                Rectangle().fill(Color(hex: 0x5AA2FF)).frame(width: geo.size.width * 0.30)
                Rectangle().fill(DGToken.ink4(scheme))
            }
        }
        .frame(height: 8).clipShape(Capsule())
    }
}

struct ActionPlanTile: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Action Plan · \(plannedCount) tagged").modernMonoLabel(size: 9.5, tracking: 1.9)
                VStack(spacing: 11) {
                    ForEach([Tag.keep, .backup, .review, .delete]) { planRow($0) }
                }
                .padding(.top, 13)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 0) {
                        Text("\(disconnectedCount)").fontWeight(.bold).foregroundStyle(DGToken.ink(scheme))
                        Text(" drives to connect").foregroundStyle(DGToken.ink2(scheme))
                    }
                    .font(.system(size: 12))
                    Spacer(minLength: 8)
                    Text("Open plan →").modernMonoLabel(size: 9.5, tracking: 1.9)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { env.selection = .plan }
    }

    private func planRow(_ tag: Tag) -> some View {
        let count = env.tagCounts[tag] ?? 0
        return HStack(spacing: 11) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tag.modernColor).frame(width: 8, height: 8)
                Text(tag.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(DGToken.ink2(scheme))
            }
            .frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DGToken.inset(scheme))
                    Capsule().fill(tag.modernColor).frame(width: geo.size.width * share(tag))
                }
            }
            .frame(height: 7)
            Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(DGToken.ink(scheme))
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private func share(_ tag: Tag) -> Double {
        let maxCount = [Tag.keep, .backup, .review, .delete].map { env.tagCounts[$0] ?? 0 }.max() ?? 0
        guard maxCount > 0 else { return 0 }
        return Double(env.tagCounts[tag] ?? 0) / Double(maxCount)
    }
    private var plannedCount: Int { Tag.actionTags.reduce(0) { $0 + (env.tagCounts[$1] ?? 0) } }
    private var disconnectedCount: Int {
        env.volumeSummaries.filter { !env.volumes.isConnected(key: $0.uuid ?? $0.name) }.count
    }
}

#if DEBUG
#Preview("Stat tiles") {
    HStack(spacing: 14) { ReclaimableTile(); ActionPlanTile() }
        .frame(width: 560, height: 210).padding(40)
        .background(SpatialBackdrop(palette: Accent.violet.palette))
        .environment(try! AppEnvironment())
}
#endif
