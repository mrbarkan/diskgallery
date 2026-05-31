import SwiftUI

/// The DiskGallery brand mark — the "Vault" app icon, drawn as resolution-independent
/// vector art so a single glyph drives the Dock icon, the splash, and the About window.
///
/// Transcribed faithfully from the design bundle's `icons.js` (`makeIcon("vault", …)`):
/// a deep OLED-black squircle tile with a violet halo, a monoline drive with a live
/// green connection LED, and the two rows of an indexed listing.
///
/// Pure SwiftUI (no app/Core imports) on purpose — the same file compiles standalone in
/// `Tools/RenderAppIcon.swift` to rasterise the AppIcon PNG set, so the on-screen mark and
/// the exported icon are guaranteed identical.
///
/// The tile renders bare (no outer shadow or alpha halo, per the Mac App Store icon rules);
/// callers add atmosphere — splash/About apply `.shadow` glows around it.
struct BrandMark: View {
    /// Edge length in points. The art is defined on a 100×100 grid and scaled to fit.
    var size: CGFloat = 128
    /// Whether to clip to the squircle. Always true for the icon; kept for flexibility.
    var palette = BrandPalette.violet

    var body: some View {
        Canvas { ctx, canvasSize in
            BrandMark.draw(in: &ctx, side: min(canvasSize.width, canvasSize.height), palette: palette)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("DiskGallery")
    }

    /// Draws the Vault glyph into `ctx`, filling a `side`×`side` square from the origin.
    /// Factored out so both `Canvas` and the offline PNG exporter share one source of truth.
    static func draw(in ctx: inout GraphicsContext, side S: CGFloat, palette p: BrandPalette) {
        let f = S / 100
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * f, y: y * f) }
        func L(_ v: CGFloat) -> CGFloat { v * f }

        // ---- Squircle tile (Apple-style continuous corners), 0…100 box ----
        var tile = Path()
        tile.move(to: P(50, 2))
        tile.addCurve(to: P(2, 50),  control1: P(16, 2),  control2: P(2, 16))
        tile.addCurve(to: P(50, 98), control1: P(2, 84),  control2: P(16, 98))
        tile.addCurve(to: P(98, 50), control1: P(84, 98), control2: P(98, 84))
        tile.addCurve(to: P(50, 2),  control1: P(98, 16), control2: P(84, 2))
        tile.closeSubpath()

        // Deep OLED body gradient.
        ctx.fill(tile, with: .radialGradient(
            Gradient(stops: [
                .init(color: p.tile0, location: 0),
                .init(color: p.tile1, location: 0.5),
                .init(color: p.tile2, location: 1),
            ]),
            center: P(28, 20), startRadius: 0, endRadius: L(95)))

        // Violet halo, upper-left.
        ctx.fill(tile, with: .radialGradient(
            Gradient(colors: [p.accent.opacity(0.55), p.accent.opacity(0)]),
            center: P(30, 22), startRadius: 0, endRadius: L(50)))

        // Hairline rim.
        ctx.stroke(tile, with: .color(.white.opacity(0.10)), lineWidth: L(1))

        // ---- Monoline drive ----
        let driveRect = CGRect(x: L(26), y: L(29), width: L(48), height: L(42))
        let drive = Path(roundedRect: driveRect, cornerRadius: L(9), style: .continuous)
        let body = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [p.bodyTop, p.bodyBottom]),
            startPoint: CGPoint(x: driveRect.midX, y: driveRect.minY),
            endPoint: CGPoint(x: driveRect.midX, y: driveRect.maxY))
        ctx.stroke(drive, with: body, lineWidth: L(3.6))

        // Top separator line of the drive.
        var line = Path()
        line.move(to: P(29.5, 43.5))
        line.addLine(to: P(70.5, 43.5))
        ctx.stroke(line, with: body, style: StrokeStyle(lineWidth: L(3), lineCap: .round))

        // ---- Live connection LED (green, glowing) ----
        let led = CGRect(x: L(33.6 - 2.9), y: L(36.5 - 2.9), width: L(5.8), height: L(5.8))
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: L(2.2)))
            layer.fill(Path(ellipseIn: led), with: .color(p.led))
        }
        ctx.fill(Path(ellipseIn: led), with: .color(p.led))

        // ---- Indexed listing rows ----
        ctx.fill(Path(roundedRect: CGRect(x: L(33), y: L(50.5), width: L(30), height: L(4.2)),
                      cornerRadius: L(2.1)), with: .color(p.accent))
        ctx.fill(Path(roundedRect: CGRect(x: L(33), y: L(59.5), width: L(20), height: L(4.2)),
                      cornerRadius: L(2.1)), with: .color(p.accent.opacity(0.5)))
    }
}

/// Brand colours for the Vault mark. The icon is always the violet brand tile regardless of
/// the app's selected accent — "an app icon keeps the same tile on every background."
struct BrandPalette {
    var accent: Color
    var bodyTop: Color
    var bodyBottom: Color
    var tile0: Color
    var tile1: Color
    var tile2: Color
    var led: Color

    static let violet = BrandPalette(
        accent:     Color(red: 0xA7/255, green: 0x8B/255, blue: 0xFF/255),
        bodyTop:    Color(red: 0xBD/255, green: 0xA7/255, blue: 0xFF/255),
        bodyBottom: Color(red: 0x8F/255, green: 0x6C/255, blue: 0xFF/255),
        tile0:      Color(red: 0x15/255, green: 0x10/255, blue: 0x1F/255),
        tile1:      Color(red: 0x0A/255, green: 0x0B/255, blue: 0x11/255),
        tile2:      Color(red: 0x05/255, green: 0x06/255, blue: 0x08/255),
        led:        Color(red: 0x4A/255, green: 0xDE/255, blue: 0x80/255))
}

/// "Disk" in ink + "Gallery" in the accent — the wordmark, tight-tracked and heavy.
struct BrandWordmark: View {
    var size: CGFloat = 30
    var ink: Color = .white
    var accent: Color = BrandPalette.violet.accent

    var body: some View {
        (Text("Disk").foregroundColor(ink) + Text("Gallery").foregroundColor(accent))
            .font(.system(size: size, weight: .heavy))
            .tracking(-0.025 * size)
    }
}

#if DEBUG
#Preview("Vault mark") {
    VStack(spacing: 28) {
        HStack(spacing: 24) {
            BrandMark(size: 124)
            BrandMark(size: 64)
            BrandMark(size: 32)
            BrandMark(size: 16)
        }
        BrandWordmark(size: 40)
    }
    .padding(40)
    .background(Color(red: 0x04/255, green: 0x05/255, blue: 0x06/255))
}
#endif
