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
    @State private var showSheet = false

    func body(content: Content) -> some View {
        let unlocked = env.license.isUnlocked(feature)
        content
            .overlay(alignment: .topTrailing) {
                if !unlocked { ProBadge().offset(x: 6, y: -8) }
            }
            // When locked, a transparent overlay on top captures every tap before the
            // underlying control can act, and opens the upgrade sheet instead.
            .overlay {
                if !unlocked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showSheet = true }
                }
            }
            .sheet(isPresented: $showSheet) { UpgradeSheet(feature: feature).environment(env) }
    }
}

extension View {
    /// Marks a control as Pro: shows a PRO badge and, when locked, intercepts taps to
    /// present the upgrade sheet instead of running the underlying action.
    func proGated(_ feature: Feature) -> some View {
        modifier(ProGate(feature: feature))
    }
}
