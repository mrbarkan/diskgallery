import SwiftUI
import AppKit

/// Toggles full-bleed (hidden title bar) on the hosting NSWindow for the Modern skin,
/// and guarantees a sane, on-screen, correctly-sized window. Classic restores the
/// standard title bar. Spec §4.2.
struct WindowChrome: NSViewRepresentable {
    var fullBleed: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var didPlace = false }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(view.window, context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(nsView.window, context.coordinator) }
    }

    private func apply(_ window: NSWindow?, _ coord: Coordinator) {
        guard let window else { return }
        window.titlebarAppearsTransparent = fullBleed
        window.titleVisibility = fullBleed ? .hidden : .visible
        window.isMovableByWindowBackground = fullBleed
        if fullBleed {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }

        // The custom two-pane Modern shell has no intrinsic size, so a restored frame
        // can be collapsed or off-screen. Fix only bad frames (preserve good ones).
        if fullBleed, !coord.didPlace {
            coord.didPlace = true
            let frame = window.frame
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
            if frame.width < 980 || frame.height < 640 || !onScreen, let screen = NSScreen.main {
                let vis = screen.visibleFrame
                let size = NSSize(width: min(1320, vis.width - 80), height: min(880, vis.height - 80))
                let origin = NSPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2)
                window.setFrame(NSRect(origin: origin, size: size), display: true)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension View {
    /// Apply full-bleed window chrome when `fullBleed` is true (Modern); restore otherwise.
    func modernWindowChrome(_ fullBleed: Bool) -> some View {
        background(WindowChrome(fullBleed: fullBleed))
    }
}
