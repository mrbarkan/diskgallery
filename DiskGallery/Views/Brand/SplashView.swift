import SwiftUI

/// The borderless launch screen, shown over the spatial backdrop while the catalog database
/// opens — a beat — before the workspace fades in. Recreates the design bundle's `.splash`:
/// the Vault mark with an accent glow, the wordmark, tagline, an indeterminate loading bar,
/// a mono status line, and the version footer. Always dark (it's a launch screen).
struct SplashView: View {
    var status: String = "Opening catalog…"

    private let accent = BrandPalette.violet.accent
    private let accent2 = BrandPalette.violet.bodyBottom

    var body: some View {
        ZStack {
            // Spatial base + accent bloom from the top.
            LinearGradient(colors: [Color(hex: 0x0C0E13), Color(hex: 0x07080B)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.24), .clear],
                           center: UnitPoint(x: 0.5, y: -0.05), startRadius: 0, endRadius: 460)
            Scanlines().opacity(0.5)

            VStack(spacing: 0) {
                BrandMark(size: 112)
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 14)
                    .shadow(color: accent.opacity(0.45), radius: 40)

                BrandWordmark(size: 30).padding(.top, 24)

                Text(AppInfo.tagline)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xA6ABB7))
                    .padding(.top, 10)

                LoadingBar(accent: accent, accent2: accent2)
                    .frame(width: 200, height: 4)
                    .padding(.top, 34)

                Text(status.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color(hex: 0x6C7280))
                    .padding(.top, 15)
            }

            VStack {
                Spacer()
                Text(AppInfo.splashVersionLine.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color(hex: 0x474D5B))
                    .padding(.bottom, 22)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

/// Indeterminate accent sweep, matching the splash's `@keyframes load`.
private struct LoadingBar: View {
    let accent: Color
    let accent2: Color
    @State private var run = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule().fill(.white.opacity(0.08))
            Capsule()
                .fill(LinearGradient(colors: [accent2, accent], startPoint: .leading, endPoint: .trailing))
                .frame(width: w * 0.38)
                .shadow(color: accent.opacity(0.6), radius: 7)
                .offset(x: run ? w * 1.0 : -w * 0.5)
                .animation(.timingCurve(0.5, 0, 0.3, 1, duration: 1.7).repeatForever(autoreverses: false), value: run)
        }
        .clipShape(Capsule())
        .onAppear { run = true }
    }
}

/// Faint horizontal scanlines (the splash's screen-blended overlay), drawn cheaply.
private struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            let line = GraphicsContext.Shading.color(.white.opacity(0.018))
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: line)
                y += 3
            }
        }
        .allowsHitTesting(false)
        .blendMode(.screen)
    }
}

#if DEBUG
#Preview("Splash") {
    SplashView().frame(width: 560, height: 350)
}
#endif
