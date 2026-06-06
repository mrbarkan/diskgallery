import SwiftUI
import DiskGalleryCore

/// CrateDigger-style OLED telemetry panel for the selected drive — the Modern skin's hero.
/// Always renders dark (it's a screen) regardless of the app's appearance mode.
struct OLEDDisplayView: View {
    let summary: VolumeSummary
    let connected: Bool
    var browsePath: String? = nil
    var reclaimable: Int64? = nil
    /// Drive hardware facts (bus · speed · medium · brand). Rendered as a bare line
    /// under the volume bar in the Telemetry layout — no card, "simple OLED" styling.
    var hardware: DriveHardwareDisplay? = nil
    let layout: OLEDLayout
    let palette: AccentPalette
    /// Present only on the Organize page — drives the `.actionDetail` layout. When nil,
    /// `.actionDetail` falls back to `.telemetry` so the layout is safe on every page.
    var plan: PlanSummary? = nil

    /// The Organize plan's headline numbers, for the OLED action-detail readout.
    struct PlanSummary: Equatable {
        var operationCount: Int
        var bytesToMove: Int64
        var bytesToCopy: Int64
        var bytesToFree: Int64
        var estDuration: TimeInterval
        var isFeasible: Bool
        var drivesToConnect: [String]
    }

    private var fraction: Double { Capacity.fractionUsed(total: summary.totalCapacity, free: summary.freeCapacity) }
    private var over: Bool { Capacity.isOverCapacity(total: summary.totalCapacity, free: summary.freeCapacity) }
    private var percent: Int { Int((fraction * 100).rounded()) }
    private var usedBytes: Int64? {
        guard let total = summary.totalCapacity else { return nil }
        return max(0, total - (summary.freeCapacity ?? 0))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .id(layout)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 12)),
                    removal: .opacity.combined(with: .offset(y: -10))))
        }
        .animation(.easeOut(duration: 0.42), value: layout)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(OLEDColor.screen)   // pitch black — a real OLED panel
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .telemetry: telemetry
        case .minimal:   minimal
        case .actionDetail:
            if let plan { actionDetail(plan) } else { telemetry }
        }
    }

    // MARK: Layout D — Action detail (Organize plan)

    private func actionDetail(_ plan: PlanSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                OLEDTag(text: "Organize Plan", palette: palette)
                Spacer(minLength: 8)
                OLEDPill(text: plan.isFeasible ? "Feasible" : "Won’t fit", live: plan.isFeasible)
                if !plan.drivesToConnect.isEmpty {
                    OLEDPill(text: "\(plan.drivesToConnect.count) to connect")
                }
            }
            HStack(alignment: .top, spacing: 0) {
                OLEDStatCell(k: "Operations", value: "\(plan.operationCount)", sub: "to run", valueSize: 30)
                cellDivider
                OLEDStatCell(k: "To move", value: Format.bytes(plan.bytesToMove),
                             tint: palette.accent, valueSize: 30)
                cellDivider
                OLEDStatCell(k: "To back up", value: Format.bytes(plan.bytesToCopy), valueSize: 30)
                cellDivider
                OLEDStatCell(k: "Frees", value: Format.bytes(plan.bytesToFree),
                             tint: OLEDColor.ok, valueSize: 30)
            }
            HStack(spacing: 14) {
                OLEDKey(plan.estDuration > 0 ? "EST \(Format.duration(plan.estDuration))" : "READY")
                Rectangle().fill(OLEDColor.ink.opacity(0.10)).frame(height: 1)
                Text(plan.drivesToConnect.isEmpty
                     ? "Non-destructive playbook"
                     : "Connect: \(plan.drivesToConnect.joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 300, alignment: .trailing)
            }
            .padding(.top, 4)
        }
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
                             sub: summary.freeCapacity.map { "\(Format.bytes($0)) free" }, valueSize: 30)
                cellDivider
                OLEDStatCell(k: "Used", value: Format.bytes(usedBytes),
                             sub: summary.totalCapacity == nil ? nil : "\(percent)% full",
                             tint: palette.accent, valueSize: 30)
                cellDivider
                OLEDStatCell(k: "Files", value: Format.count(summary.fileCount), sub: "cataloged", valueSize: 30)
                if let reclaimable, reclaimable > 0 {
                    cellDivider
                    OLEDStatCell(k: "Reclaimable", value: Format.bytes(reclaimable), sub: "duplicates",
                                 tint: OLEDColor.ok, valueSize: 30)
                }
            }
            OLEDBottomBar(uuid: summary.uuid, fraction: fraction, over: over, path: browsePath, palette: palette)
            if let hardware { hardwareRow(hardware) }
        }
    }

    /// Bare hardware line under the volume bar — a thin hairline, then monospace facts.
    private func hardwareRow(_ hw: DriveHardwareDisplay) -> some View {
        var parts = [hw.generationLabel]
        for p in [hw.speedText, hw.mediumText, hw.connectionText, hw.brandModel] { if let p { parts.append(p) } }
        return VStack(spacing: 7) {
            Rectangle().fill(OLEDColor.ink.opacity(0.10)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: hw.busIcon).font(.system(size: 10)).foregroundStyle(OLEDColor.ink3)
                Text(parts.joined(separator: "  ·  "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(OLEDColor.ink2)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text("detected \(Format.relativeDate(hw.hardware.capturedAt))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(OLEDColor.ink3)
            }
        }
        .padding(.top, 2)
    }

    private var cellDivider: some View {
        Rectangle().fill(OLEDColor.ink.opacity(0.10)).frame(width: 1, height: 44).padding(.horizontal, 18)
    }

    // MARK: Layout B — Minimal

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
                if let reclaimable, reclaimable > 0 {
                    OLEDInline(value: Format.bytes(reclaimable), unit: "reclaimable", tint: OLEDColor.ok)
                }
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
            if live { Circle().fill(OLEDColor.ok).frame(width: 6, height: 6) }
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
    var valueSize: CGFloat = 26
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OLEDKey(k)
            Text(value).font(.system(size: valueSize, weight: .bold, design: .monospaced)).foregroundStyle(tint).lineLimit(1)
            if let sub { OLEDKey(sub) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OLEDInline: View {
    let value: String
    let unit: String
    var tint: Color = OLEDColor.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(tint)
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
                               : AnyShapeStyle(LinearGradient(colors: [palette.accent2, palette.accent],
                                                              startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(0, geo.size.width * fraction))
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
#Preview("Minimal · Green") {
    OLEDDisplayView(summary: .preview, connected: false, layout: .minimal, palette: Accent.green.palette)
        .padding(24).frame(width: 860).background(.black)
}
#Preview("Minimal · Unscanned/empty") {
    OLEDDisplayView(summary: .previewEmpty, connected: false, layout: .minimal, palette: Accent.amber.palette)
        .padding(24).frame(width: 860).background(.black)
}
#endif
