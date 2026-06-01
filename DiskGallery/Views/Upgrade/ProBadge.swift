import SwiftUI
import DiskGalleryCore

/// Small "PRO" lock chip overlaid on gated controls.
struct ProBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
            Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.5)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(.tint))
        .foregroundStyle(.white)
    }
}

private struct ProGate: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let feature: Feature

    func body(content: Content) -> some View {
        let unlocked = env.license.isUnlocked(feature)
        content
            // When locked, the underlying control is inert and dimmed; a transparent
            // tap-catcher on top routes taps to the single app-level upgrade sheet.
            .disabled(!unlocked)
            .opacity(unlocked ? 1 : 0.55)
            .overlay(alignment: .topTrailing) {
                if !unlocked { ProBadge().offset(x: 6, y: -8) }
            }
            .overlay {
                if !unlocked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { env.requestUpgrade(feature) }
                        .accessibilityLabel("\(feature.displayName) — Pro feature")
                        .accessibilityAddTraits(.isButton)
                }
            }
    }
}

extension View {
    /// Marks a control as Pro: dims and disables it when locked, shows a PRO badge, and
    /// routes taps to the shared upgrade sheet (`env.upgradeFeature`). Pass-through when unlocked.
    func proGated(_ feature: Feature) -> some View {
        modifier(ProGate(feature: feature))
    }
}
