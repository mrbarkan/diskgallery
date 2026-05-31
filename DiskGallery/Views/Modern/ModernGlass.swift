import SwiftUI
import DiskGalleryCore

/// The design's frosted-glass `.card` surface.
struct GlassCard<Content: View>: View {
    var radius: CGFloat = 20
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.10),
                                  lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 22, y: 14)
    }
}

extension View {
    /// Wrap any view in the Modern glass-card surface.
    func glassCard(radius: CGFloat = 20) -> some View { GlassCard(radius: radius) { self } }

    /// In Modern, let the backdrop show through a List/Form. No-op in Classic.
    @ViewBuilder
    func modernListChrome(_ modern: Bool) -> some View {
        if modern { self.scrollContentBackground(.hidden) } else { self }
    }
}

// MARK: - Card header (spec §B/§9/§10)

/// The mockup's `.card-h` — accent icon + bold title + trailing mono meta.
struct ModernCardHeader: View {
    @Environment(\.colorScheme) private var scheme
    let systemImage: String
    let title: String
    var meta: String = ""
    var accent: Color

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).font(.system(size: 16)).foregroundStyle(accent)
                Text(title).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DGToken.ink(scheme))
            }
            Spacer(minLength: 8)
            if !meta.isEmpty {
                Text(meta).font(.system(size: 9.5, design: .monospaced))
                    .tracking(0.8).foregroundStyle(DGToken.ink3(scheme))
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 26))
    }
}

// MARK: - Chips & dots (spec §9)

/// The mockup's `.chip` — mono micro-cap label on a 16%-tinted fill in the tag color.
struct ChipView: View {
    let tag: Tag
    var body: some View {
        Text(tag.label.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.0)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tag.modernColor.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(tag.modernColor)
    }
}

/// The mockup's `.cdot` — a 10px Finder-color dot with a 2px glass ring.
struct ColorDot: View {
    let color: FinderColor
    var body: some View {
        Circle().fill(color.modernColor).frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.regularMaterial, lineWidth: 2))
    }
}

// MARK: - Mono micro-cap label (spec §3.5)

private struct ModernMonoLabel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var size: CGFloat
    var tracking: CGFloat
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .textCase(.uppercase).tracking(tracking)
            .foregroundStyle(DGToken.ink3(scheme))
    }
}

extension View {
    /// The mockup's `.lbl` — mono uppercase micro-caps in ink-3.
    func modernMonoLabel(size: CGFloat = 9.5, tracking: CGFloat = 1.6) -> some View {
        modifier(ModernMonoLabel(size: size, tracking: tracking))
    }
}
