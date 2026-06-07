import SwiftUI
import DiskGalleryCore

/// The fixed OLED hero on the All Drives page — a cross-drive backup-coverage readout
/// (always dark, like the per-drive OLED). Replaces the per-drive telemetry here.
struct CoverageOLED: View {
    let summary: CoverageSummary
    let palette: AccentPalette

    private var safe: Bool { summary.atRiskCount == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                tag("All Drives")
                Spacer(minLength: 8)
                pill(safe ? "All backed up" : "\(summary.atRiskCount) at risk", danger: !safe)
            }
            HStack(alignment: .top, spacing: 0) {
                cell("At risk", value: Format.size2(summary.atRiskBytes),
                     sub: "\(summary.atRiskCount) item\(summary.atRiskCount == 1 ? "" : "s")",
                     tint: safe ? OLEDColor.ok : OLEDColor.bad)
                divider
                cell("Redundant", value: Format.size2(summary.redundantBytes), sub: "reclaimable", tint: OLEDColor.ink)
                divider
                cell("Drives", value: "\(summary.driveCount)", sub: "catalogued", tint: OLEDColor.ink)
            }
            Spacer(minLength: 0)
            key(safe ? "EVERY TOP-LEVEL ITEM HAS A BACKUP"
                     : "ITEMS ON ONLY ONE DRIVE WOULD BE LOST IF IT FAILED")
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(OLEDColor.screen)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
        .environment(\.colorScheme, .dark)
    }

    private func tag(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9))
            Text(text.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4)
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(palette.accent, in: Capsule())
    }

    private func pill(_ text: String, danger: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(danger ? OLEDColor.bad : OLEDColor.ok).frame(width: 6, height: 6)
            Text(text.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2)
        }
        .foregroundStyle(danger ? OLEDColor.bad : OLEDColor.ok)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder((danger ? OLEDColor.bad : OLEDColor.ok).opacity(0.55), lineWidth: 1))
    }

    private func cell(_ k: String, value: String, sub: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            key(k)
            Text(value).font(.system(size: 28, weight: .bold, design: .monospaced)).foregroundStyle(tint).lineLimit(1)
            key(sub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func key(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .tracking(1.6).foregroundStyle(OLEDColor.ink3).lineLimit(1)
    }

    private var divider: some View {
        Rectangle().fill(OLEDColor.ink.opacity(0.10)).frame(width: 1, height: 44).padding(.horizontal, 18)
    }
}
