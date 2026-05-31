import SwiftUI

/// The "About DiskGallery" panel — the Vault mark, version, the offline-license block, and
/// the read-only privacy promise that defines the product. Recreates the design bundle's
/// `.about` window; always dark to match the brand. Opened from the app menu.
struct AboutView: View {
    /// Who the copy is licensed to ("archive@studio.com", "Trial", "—").
    var licensedTo: String = "—"
    /// License terms ("Perpetual · 2 seats", "Trial · 14 days left", "Unlicensed").
    var license: String = "Unlicensed"

    private let accent = BrandPalette.violet.accent
    private let accent2 = BrandPalette.violet.bodyBottom
    private let ink   = Color(hex: 0xEDEFF4)
    private let ink2  = Color(hex: 0xA6ABB7)
    private let ink3  = Color(hex: 0x6C7280)
    private let ink4  = Color(hex: 0x474D5B)
    private let hair  = Color.white.opacity(0.085)

    var body: some View {
        VStack(spacing: 0) {
            BrandMark(size: 96)
                .shadow(color: .black.opacity(0.55), radius: 15, y: 12)
                .shadow(color: accent.opacity(0.4), radius: 34)

            BrandWordmark(size: 25).padding(.top, 18)

            Text(AppInfo.versionLine)
                .font(.system(size: 11, design: .monospaced)).tracking(1)
                .foregroundStyle(ink3).padding(.top, 7)

            Text(AppInfo.aboutTagline)
                .font(.system(size: 13)).foregroundStyle(ink2)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
                .padding(.top, 14)

            VStack(spacing: 0) {
                row("Licensed to", licensedTo)
                row("License", license)
                row("Catalog", AppInfo.catalogPath)
                row("Your files", "Read-only · never modified", ok: true)
            }
            .padding(.top, 22)

            HStack(spacing: 9) {
                button("Visit Website", primary: true) { open("https://diskgallery.app") }
                button("Acknowledgements") { open("https://diskgallery.app/acknowledgements") }
                button("Privacy") { open("https://diskgallery.app/privacy") }
            }
            .padding(.top, 22)

            VStack(spacing: 3) {
                Text(AppInfo.copyright)
                Text(AppInfo.readOnlyNote).multilineTextAlignment(.center)
            }
            .font(.system(size: 9, design: .monospaced)).tracking(0.6)
            .foregroundStyle(ink4).lineSpacing(3)
            .padding(.top, 22)
        }
        .padding(.horizontal, 34).padding(.top, 34).padding(.bottom, 26)
        .frame(width: 420)
        .background {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x0E1016), Color(hex: 0x0A0B10)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [accent.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.5, y: -0.05), startRadius: 0, endRadius: 260)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
    }

    private func row(_ k: String, _ v: String, ok: Bool = false) -> some View {
        HStack(spacing: 14) {
            Text(k.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(1.3)
                .foregroundStyle(ink3)
            Spacer(minLength: 8)
            Text(v)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ok ? BrandPalette.violet.led : ink)
                .multilineTextAlignment(.trailing).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(hair).frame(height: 1) }
    }

    private func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? Color(hex: 0x15101F) : ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background {
                    if primary {
                        LinearGradient(colors: [accent, accent2], startPoint: .top, endPoint: .bottom)
                    } else {
                        Color.white.opacity(0.072)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(primary ? 0 : 0.16)))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(color: primary ? accent.opacity(0.45) : .clear, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

#if DEBUG
#Preview("About") {
    AboutView(licensedTo: "archive@studio.com", license: "Perpetual · 2 seats")
}
#endif
