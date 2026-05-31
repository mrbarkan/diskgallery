import SwiftUI
import DiskGalleryCore

/// Shared Modern page chrome built from the mockup's reusable bits (diskgallery.css):
/// `.cta`, `.fchip`, `.sec-h`, `.finder-note`, `.stack-bar`, `.big-num`, `.plan-rows`.
/// Used only by the Modern page views — Classic never references these.

/// The mockup's `.cta` — gradient accent action button (primary) or ghost (secondary).
struct CTAButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let title: String
    var systemImage: String
    var ghost: Bool = false
    var tint: Color? = nil          // override fill (e.g. `.bad` for Delete)
    let action: () -> Void

    private var accent: Color { tint ?? env.theme.accent.palette.accent }
    private var accent2: Color { tint ?? env.theme.accent.palette.accent2 }
    private var inkOnAccent: Color { env.theme.accent.palette.ink }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1.6)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity).frame(height: 42)
            .foregroundStyle(ghost ? DGToken.ink(scheme) : inkOnAccent)
            .background {
                if ghost {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DGToken.glass2(scheme))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DGToken.hair2(scheme), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [accent, accent2], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 1).blendMode(.overlay))
                }
            }
            .shadow(color: ghost ? .clear : accent.opacity(0.40), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
    }
}

/// The mockup's `.fchip` — mono micro-cap filter chip with a selected accent state.
struct ModernFilterChip: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let label: String
    let selected: Bool
    let action: () -> Void
    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.9)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(selected ? accent : DGToken.ink3(scheme))
                .background(selected ? accent.opacity(0.16) : DGToken.glass2(scheme),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.40) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The mockup's `.sec-h` — mono uppercase section header.
struct SecHeader: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.8)
            .foregroundStyle(DGToken.ink3(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The mockup's `.finder-note` — leaf/warn icon + caption. `ok` (default) or `warn` tone.
struct ModernNote: View {
    let text: String
    var systemImage: String = "checkmark.shield"
    var warn: Bool = false
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 13))
            Text(text).font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(warn ? DGToken.warn : DGToken.ok)
    }
}

/// The mockup's `.stack-bar` — decorative 3-segment capsule (no per-category data exists).
struct StackBar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(env.theme.accent.palette.accent).frame(width: geo.size.width * 0.46)
                Rectangle().fill(Color(hex: 0x5AA2FF)).frame(width: geo.size.width * 0.30)
                Rectangle().fill(DGToken.ink4(scheme))
            }
        }
        .frame(height: 8).clipShape(Capsule())
    }
}

/// The mockup's `.big-num` — 48px headline numeral + small unit. Splits a `Format.bytes` string.
struct BigNum: View {
    @Environment(\.colorScheme) private var scheme
    let bytes: Int64
    var tint: Color
    var body: some View {
        let parts = Format.bytes(bytes).split(separator: " ", maxSplits: 1)
        let value = parts.first.map(String.init) ?? "0"
        let unit = parts.count > 1 ? String(parts[1]) : ""
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value).font(.system(size: 48, weight: .heavy)).foregroundStyle(tint)
            if !unit.isEmpty {
                Text(unit).font(.system(size: 21, weight: .bold)).foregroundStyle(DGToken.ink2(scheme))
            }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// The mockup's `.plan-rows` — label · proportional track · amount, one row per tag.
struct PlanBreakdownRows: View {
    @Environment(\.colorScheme) private var scheme
    let rows: [(tag: Tag, bytes: Int64)]
    private var maxBytes: Int64 { max(rows.map(\.bytes).max() ?? 0, 1) }

    var body: some View {
        VStack(spacing: 11) {
            ForEach(rows, id: \.tag) { row in
                HStack(spacing: 11) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(row.tag.modernColor).frame(width: 8, height: 8)
                        Text(row.tag.label).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DGToken.ink2(scheme))
                    }
                    .frame(width: 70, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DGToken.inset(scheme))
                            Capsule().fill(row.tag.modernColor)
                                .frame(width: geo.size.width * (Double(row.bytes) / Double(maxBytes)))
                        }
                    }
                    .frame(height: 7)
                    Text(Format.bytes(row.bytes)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DGToken.ink(scheme)).frame(minWidth: 52, alignment: .trailing)
                }
            }
        }
    }
}
