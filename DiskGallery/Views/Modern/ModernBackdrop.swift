import SwiftUI

/// The Modern skin's full-bleed spatial canvas: a near-black (dark) / soft (light)
/// gradient base with accent radial glows. Sits behind the whole window in Modern.
struct SpatialBackdrop: View {
    let palette: AccentPalette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(hex: 0x08090C), Color(hex: 0x0C0E13), Color(hex: 0x11141A)]
                    : [Color(hex: 0xE9EAEF), Color(hex: 0xEEF0F4), Color(hex: 0xF4F6F9)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [palette.accent.opacity(dark ? 0.22 : 0.11), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [palette.accent.opacity(dark ? 0.12 : 0.06), .clear],
                           center: UnitPoint(x: 1.02, y: 0.14), startRadius: 0, endRadius: 720)
            RadialGradient(colors: [Color(hex: 0x5078FF).opacity(dark ? 0.10 : 0.05), .clear],
                           center: UnitPoint(x: 0.6, y: 1.16), startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
