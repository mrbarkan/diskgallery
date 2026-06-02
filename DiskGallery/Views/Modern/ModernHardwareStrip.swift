import SwiftUI
import DiskGalleryCore

/// A thin glass strip surfacing a drive's hardware facts in the Modern detail pane:
/// bus · speed · medium · connection · brand/model, with the capture time on the right.
struct ModernHardwareStrip: View {
    @Environment(\.colorScheme) private var scheme
    let display: DriveHardwareDisplay

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: display.busIcon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DGToken.ink2(scheme)).frame(width: 16)
            chip(display.generationLabel)
            if let speed = display.speedText { chip(speed) }
            if let medium = display.mediumText { chip(medium) }
            if let connection = display.connectionText { chip(connection) }
            if let brandModel = display.brandModel {
                Text(brandModel).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DGToken.ink3(scheme)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("detected \(Format.relativeDate(display.hardware.capturedAt))")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(DGToken.ink4(scheme))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(DGToken.hair(scheme), lineWidth: 1))
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(DGToken.glass2(scheme), in: Capsule())
            .foregroundStyle(DGToken.ink2(scheme))
    }
}
