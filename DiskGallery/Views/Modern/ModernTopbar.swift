import SwiftUI
import DiskGalleryCore

/// Modern workspace topbar — breadcrumbs · search pill · (volume) action cluster. Spec §7.
struct ModernTopbar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    var showVolumeActions: Bool = false
    var rescanEnabled: Bool = false
    /// The layout the OLED is actually rendering (may be a per-page override, e.g.
    /// `.actionDetail` on Organize). Drives the Display badge so it matches the hero.
    var displayedLayout: OLEDLayout? = nil
    var onDisplay: () -> Void = {}
    var onChanges: () -> Void = {}
    var onRescan: () -> Void = {}
    var onSearch: () -> Void = {}

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            searchPill
            if showVolumeActions { cluster }
        }
        .padding(.horizontal, 2).padding(.top, 2)
        .frame(height: 40)
    }

    // MARK: Search pill (⌘K)
    private var searchPill: some View {
        Button(action: onSearch) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(DGToken.ink3(scheme))
                Text("Search all drives").font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
                Spacer(minLength: 8)
                Text("⌘K").font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DGToken.glass2(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(DGToken.ink3(scheme))
            }
            .padding(.horizontal, 13).frame(width: 260, height: 36)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(DGToken.hair(scheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
    }

    // MARK: Volume action cluster
    private var cluster: some View {
        HStack(spacing: 8) {
            Button(action: onDisplay) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 16))
                    Text("Display")
                    Text((displayedLayout ?? env.theme.oledLayout).name.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.0)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(accent)
                }
            }
            .buttonStyle(TBtnStyle()).help("Switch the OLED display layout")

            Button(action: onChanges) {
                HStack(spacing: 8) { Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 16)); Text("Check changes") }
            }
            .buttonStyle(TBtnStyle()).help("Check for changes since the last scan")

            if rescanEnabled {
                Button(action: onRescan) {
                    HStack(spacing: 8) { Image(systemName: "arrow.clockwise").font(.system(size: 16)); Text("Re-scan") }
                }
                .buttonStyle(TBtnStyle()).help("Re-scan this drive")
            }
        }
    }
}

/// The mockup's `.tbtn` — glass pill action button.
struct TBtnStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(DGToken.ink2(scheme))
            .frame(height: 36).padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(DGToken.hair(scheme), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
