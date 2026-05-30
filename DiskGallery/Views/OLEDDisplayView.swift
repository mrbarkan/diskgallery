import SwiftUI
import DiskGalleryCore

/// CrateDigger-style OLED telemetry panel for the selected drive — the Modern skin's hero.
/// Always renders dark (it's a screen) regardless of the app's appearance mode.
struct OLEDDisplayView: View {
    let summary: VolumeSummary
    let connected: Bool
    var browsePath: String? = nil
    let layout: OLEDLayout
    let palette: AccentPalette

    private var fraction: Double { Capacity.fractionUsed(total: summary.totalCapacity, free: summary.freeCapacity) }
    private var over: Bool { Capacity.isOverCapacity(total: summary.totalCapacity, free: summary.freeCapacity) }
    private var percent: Int { Int((fraction * 100).rounded()) }
    private var usedBytes: Int64? {
        guard let total = summary.totalCapacity else { return nil }
        return max(0, total - (summary.freeCapacity ?? 0))
    }

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .background(screen)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(scanlines)
            .overlay(vignette)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.black, lineWidth: 1))
            .shadow(color: palette.glow, radius: 26)
            .shadow(color: .black.opacity(0.55), radius: 28, y: 16)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .telemetry: telemetry
        case .gauge:     gauge
        case .minimal:   minimal
        }
    }

    // MARK: Chassis

    private var screen: some View {
        LinearGradient(colors: [OLEDColor.screenTop, OLEDColor.screen], startPoint: .top, endPoint: .bottom)
            .overlay(RadialGradient(colors: [palette.accent.opacity(0.09), .clear],
                                    center: .topLeading, startRadius: 0, endRadius: 360))
    }

    private var scanlines: some View {
        Canvas { ctx, size in
            let shading = GraphicsContext.Shading.color(.white.opacity(0.022))
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: shading)
                y += 3
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var vignette: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 70, endRadius: 340))
            .blendMode(.multiply)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Layout A — Telemetry

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                OLEDTag(text: "Selected Drive", palette: palette)
                Text(summary.name.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(1)
                    .foregroundStyle(OLEDColor.ink).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    OLEDPill(text: connected ? "Connected" : "Disconnected", live: connected)
                    if let fs = summary.fsType, !fs.isEmpty { OLEDPill(text: fs.uppercased()) }
                    if let scanned = summary.scannedAt { OLEDPill(text: "Scanned \(Format.relativeDate(scanned))") }
                }
            }
            HStack(alignment: .top, spacing: 0) {
                OLEDStatCell(k: "Capacity", value: Format.bytes(summary.totalCapacity),
                             sub: summary.freeCapacity.map { "\(Format.bytes($0)) free" })
                cellDivider
                OLEDStatCell(k: "Used", value: Format.bytes(usedBytes),
                             sub: summary.totalCapacity == nil ? nil : "\(percent)% full",
                             tint: palette.accent, glow: palette.glow)
                cellDivider
                OLEDStatCell(k: "Files", value: Format.count(summary.fileCount), sub: "cataloged")
            }
            OLEDBottomBar(uuid: summary.uuid, fraction: fraction, over: over, path: browsePath, palette: palette)
        }
    }

    private var cellDivider: some View {
        Rectangle().fill(OLEDColor.ink.opacity(0.10)).frame(width: 1, height: 44).padding(.horizontal, 18)
    }

    // MARK: Layout B — Gauge

    private var gauge: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle().stroke(OLEDColor.ink.opacity(0.10), lineWidth: 13)
                if fraction > 0 {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(over ? OLEDColor.bad : palette.accent, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: palette.glow, radius: 10)
                }
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(percent)").font(.system(size: 38, weight: .bold, design: .monospaced)).foregroundStyle(OLEDColor.ink)
                        Text("%").font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
                    }
                    OLEDKey("Used")
                }
            }
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                OLEDTag(text: "Selected Drive", palette: palette)
                Text(summary.name).font(.system(size: 24, weight: .bold)).foregroundStyle(OLEDColor.ink).lineLimit(1)
                Text(gaugeSubtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
                HStack(spacing: 24) {
                    OLEDStatCell(k: "Capacity", value: Format.bytes(summary.totalCapacity))
                    OLEDStatCell(k: "Used", value: Format.bytes(usedBytes), tint: palette.accent, glow: palette.glow)
                    OLEDStatCell(k: "Files", value: Format.count(summary.fileCount))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var gaugeSubtitle: String {
        var parts: [String] = []
        if let free = summary.freeCapacity { parts.append("\(Format.bytes(free)) free") }
        if let fs = summary.fsType, !fs.isEmpty { parts.append(fs) }
        parts.append(connected ? "connected" : "disconnected")
        return parts.joined(separator: " · ")
    }

    // MARK: Layout C — Minimal

    private var minimal: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                OLEDTag(text: "Selected Drive", palette: palette)
                Spacer()
                OLEDPill(text: connected ? "Connected" : "Disconnected", live: connected)
            }
            Text(summary.name).font(.system(size: 40, weight: .heavy)).foregroundStyle(OLEDColor.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            OLEDCapacityBar(fraction: fraction, over: over, palette: palette).frame(height: 11)
            HStack(spacing: 30) {
                OLEDInline(value: Format.bytes(usedBytes), unit: "used")
                if let free = summary.freeCapacity { OLEDInline(value: Format.bytes(free), unit: "free") }
                OLEDInline(value: Format.count(summary.fileCount), unit: "files")
            }
        }
    }
}

// MARK: - Shared OLED subviews

private struct OLEDTag: View {
    let text: String
    let palette: AccentPalette
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(palette.ink).frame(width: 6, height: 6)
            Text(text.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4)
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(palette.accent, in: Capsule())
    }
}

private struct OLEDPill: View {
    let text: String
    var live: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            if live { Circle().fill(OLEDColor.ok).frame(width: 6, height: 6).shadow(color: OLEDColor.ok, radius: 4) }
            Text(text.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2)
        }
        .foregroundStyle(live ? OLEDColor.ok : OLEDColor.ink2)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(live ? OLEDColor.ok.opacity(0.55) : OLEDColor.ink3, lineWidth: 1))
    }
}

private struct OLEDKey: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .tracking(1.8).foregroundStyle(OLEDColor.ink3).lineLimit(1)
    }
}

private struct OLEDStatCell: View {
    let k: String
    let value: String
    var sub: String? = nil
    var tint: Color = OLEDColor.ink
    var glow: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OLEDKey(k)
            Text(value).font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 14).lineLimit(1)
            if let sub { OLEDKey(sub) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OLEDInline: View {
    let value: String
    let unit: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(OLEDColor.ink)
            Text(unit.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
        }
    }
}

private struct OLEDCapacityBar: View {
    let fraction: Double
    let over: Bool
    let palette: AccentPalette
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(OLEDColor.ink.opacity(0.08))
                Capsule()
                    .fill(over ? AnyShapeStyle(OLEDColor.bad)
                               : AnyShapeStyle(LinearGradient(colors: [palette.accentDeep, palette.accent],
                                                              startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(0, geo.size.width * fraction))
                    .shadow(color: over ? OLEDColor.bad.opacity(0.6) : palette.glow, radius: 8)
            }
        }
    }
}

private struct OLEDBottomBar: View {
    let uuid: String?
    let fraction: Double
    let over: Bool
    let path: String?
    let palette: AccentPalette
    var body: some View {
        HStack(spacing: 14) {
            if let uuid, !uuid.isEmpty { OLEDKey("VOL \(uuid.prefix(8))") }
            OLEDCapacityBar(fraction: fraction, over: over, palette: palette).frame(height: 9)
            if let path, !path.isEmpty {
                Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(.top, 4)
    }
}

#if DEBUG
private extension VolumeSummary {
    static var preview: VolumeSummary {
        VolumeSummary(id: 1, uuid: "8F2AC71D-AB12", name: "Archive Vault",
                      latestSnapshotId: 1, scannedAt: Date(timeIntervalSinceNow: -172_800),
                      totalCapacity: 4_000_000_000_000, freeCapacity: 842_000_000_000,
                      fsType: "APFS", fileCount: 248_193, totalLogical: 3_160_000_000_000,
                      rootEntryId: 1, latestSnapshotComplete: true)
    }
    static var previewEmpty: VolumeSummary {
        VolumeSummary(id: 2, uuid: nil, name: "Scratch NVMe", latestSnapshotId: nil, scannedAt: nil,
                      totalCapacity: nil, freeCapacity: nil, fsType: nil, fileCount: nil,
                      totalLogical: nil, rootEntryId: nil, latestSnapshotComplete: nil)
    }
}

#Preview("Telemetry · Violet") {
    OLEDDisplayView(summary: .preview, connected: true, browsePath: "/Volumes/Archive Vault/Photography",
                    layout: .telemetry, palette: Accent.violet.palette)
        .padding(24).frame(width: 860).background(.black)
}
#Preview("Gauge · Blue") {
    OLEDDisplayView(summary: .preview, connected: true, layout: .gauge, palette: Accent.blue.palette)
        .padding(24).frame(width: 860).background(.black)
}
#Preview("Minimal · Green") {
    OLEDDisplayView(summary: .preview, connected: false, layout: .minimal, palette: Accent.green.palette)
        .padding(24).frame(width: 860).background(.black)
}
#Preview("Gauge · Unscanned/empty") {
    OLEDDisplayView(summary: .previewEmpty, connected: false, layout: .gauge, palette: Accent.amber.palette)
        .padding(24).frame(width: 860).background(.black)
}
#endif
