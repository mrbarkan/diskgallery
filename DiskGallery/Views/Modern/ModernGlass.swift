import SwiftUI

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

/// An integrated frosted-glass capsule button for the Modern workspace (the design's pill).
struct ModernPillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(
                scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 6, y: 3)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Capsule())
    }
}
