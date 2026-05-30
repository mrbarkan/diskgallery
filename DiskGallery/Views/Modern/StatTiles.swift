import SwiftUI
import DiskGalleryCore

/// Modern dashboard tiles for the volume-browser workspace. Read existing env data only.

struct ReclaimableTile: View {
    @Environment(AppEnvironment.self) private var env
    let palette: AccentPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reclaimable · Duplicates").modernTileLabel()
            Text(Format.bytes(env.totalReclaimable))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.accent)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            Button { env.selection = .duplicates } label: { Text("View →").modernTileLabel() }
                .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct ActionPlanTile: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Action Plan").modernTileLabel()
            VStack(spacing: 8) {
                ForEach([Tag.keep, .backup, .review, .delete]) { tag in
                    HStack(spacing: 8) {
                        Text(tag.label).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(tag.swiftUIColor)
                                    .frame(width: geo.size.width * share(tag))
                            }
                        }
                        .frame(height: 6)
                        Text("\(env.tagCounts[tag] ?? 0)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { env.selection = .plan } label: { Text("Open plan →").modernTileLabel() }
                .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard()
    }

    /// Bar width as a share of the largest action-tag count (0 when nothing tagged).
    private func share(_ tag: Tag) -> Double {
        let maxCount = Tag.actionTags.map { env.tagCounts[$0] ?? 0 }.max() ?? 0
        guard maxCount > 0 else { return 0 }
        return Double(env.tagCounts[tag] ?? 0) / Double(maxCount)
    }
}

private extension View {
    func modernTileLabel() -> some View {
        self.font(.system(size: 10, weight: .semibold, design: .monospaced))
            .textCase(.uppercase).tracking(1).foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview("Stat tiles") {
    HStack { ReclaimableTile(palette: Accent.violet.palette); ActionPlanTile() }
        .frame(width: 520, height: 200).padding(40)
        .background(SpatialBackdrop(palette: Accent.violet.palette))
        .environment(try! AppEnvironment())
}
#endif
