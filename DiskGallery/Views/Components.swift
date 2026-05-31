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
