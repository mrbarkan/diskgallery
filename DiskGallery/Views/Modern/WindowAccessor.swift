import SwiftUI
import AppKit

/// Drives full-bleed window chrome for the Modern skin: transparent title bar, content
/// under it, the (empty) unified toolbar hidden, and a sane on-screen frame. Classic
/// restores the standard chrome. Applied via `viewDidMoveToWindow` so it reliably runs
/// once the hosting NSWindow exists. Spec §4.2.
struct WindowChrome: NSViewRepresentable {
    var fullBleed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ChromeNSView()
        view.fullBleed = fullBleed
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ChromeNSView else { return }
        view.fullBleed = fullBleed
        view.applyChrome()
    }
}

final class ChromeNSView: NSView {
    var fullBleed = true
    private var placed = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome()
    }

    func applyChrome() {
        guard let window else { return }
        window.titlebarAppearsTransparent = fullBleed
        window.titleVisibility = fullBleed ? .hidden : .visible
        window.titlebarSeparatorStyle = fullBleed ? .none : .automatic
        window.isMovableByWindowBackground = fullBleed
        if fullBleed {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        // The unified toolbar reserves an (empty) strip in Modern — hide it for a true
        // full-bleed canvas. Classic keeps its toolbar (scan / library menu).
        window.toolbar?.isVisible = !fullBleed

        // The custom two-pane Modern shell has no intrinsic size, so a restored frame
        // can be collapsed or off-screen. Fix only bad frames (preserve good ones).
        if fullBleed, !placed {
            placed = true
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
