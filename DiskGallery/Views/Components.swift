import SwiftUI
import DiskGalleryCore

/// A horizontal capacity gauge: how full a drive is, with a free/total caption.
struct CapacityBar: View {
    @Environment(AppEnvironment.self) private var env
    let total: Int64?
    let free: Int64?
    /// Optional second segment (e.g. bytes about to be transferred in) drawn ahead
    /// of the used segment in an accent color.
    var incoming: Int64? = nil
    var height: CGFloat = 8

    private var used: Int64 { max(0, (total ?? 0) - (free ?? 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    if let total, total > 0 {
                        let usedW = width * fraction(used, of: total)
                        let incW = width * fraction(incoming ?? 0, of: total)
                        Capsule()
                            .fill(overCapacity ? Color.red : env.theme.accent.palette.accent)
                            .frame(width: min(width, usedW))
                        if incoming ?? 0 > 0 {
                            Capsule()
                                .fill(overCapacity ? Color.red : Color.orange)
                                .frame(width: min(width - usedW, incW))
                                .offset(x: min(width, usedW))
                        }
                    }
                }
            }
            .frame(height: height)

            Text(caption)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var overCapacity: Bool {
        guard let total, let free else { return false }
        return (incoming ?? 0) > free && total > 0
    }

    private func fraction(_ part: Int64, of whole: Int64) -> Double {
        whole > 0 ? min(1, Double(part) / Double(whole)) : 0
    }

    private var caption: String {
        guard let total else { return "Capacity unknown" }
        return "\(Format.bytes(free)) free of \(Format.bytes(total))"
    }
}

/// A compact connected/disconnected indicator.
struct DriveStatusDot: View {
    let connected: Bool
    var body: some View {
        Circle()
            .fill(connected ? Color.green : Color.secondary.opacity(0.6))
            .frame(width: 8, height: 8)
            .help(connected ? "Connected" : "Disconnected")
    }
}

/// A floating banner shown while previews are being generated (drive-level cache
/// generation or a folder Detail Scan), with live count and a Cancel button.
struct PreviewProgressBanner: View {
    let progress: AppEnvironment.ThumbnailProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(progress.total == 0
                 ? "Preparing previews…"
                 : "Generating previews… \(progress.completed) of \(progress.total)")
                .font(.callout)
            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .frame(width: 120)
            }
            Button("Cancel", action: onCancel).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
        .padding(.top, 10)
    }
}

/// A single keyboard-shortcut hint drawn like a physical keycap (à la macOS's
/// Keyboard Shortcuts UI): rounded cap, hairline border, faint drop shadow.
struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 17, minHeight: 17)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.16), radius: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 0.75)
            )
    }
}

/// A small labeled count/size chip used in plan headers.
struct StatPill: View {
    let title: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(tint).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
