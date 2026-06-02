import SwiftUI
import AppKit

/// Complements `.windowStyle(.hiddenTitleBar)`: in Modern it keeps the canvas full-bleed
/// (hidden toolbar, no separator) and gives the window a sane on-screen frame; in Classic
/// it restores the standard title bar + toolbar over the hidden-title-bar base. Applied via
/// `viewDidMoveToWindow` so it reliably runs once the NSWindow exists. Spec §4.2.
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
        if fullBleed {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            // Must stay false: when the window is movable by its background, macOS treats a
            // mouse-down on a sidebar drive row as "move the window" and the drag-to-reorder
            // never starts. The window is still movable via the transparent title-bar strip.
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar?.isVisible = false   // hide the empty unified toolbar strip
            placeIfNeeded(window)
        } else {
            // Classic: restore the standard title bar + toolbar over the hidden-title-bar base.
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.titlebarSeparatorStyle = .automatic
            window.isMovableByWindowBackground = false
            window.styleMask.remove(.fullSizeContentView)
            window.toolbar?.isVisible = true
        }
    }

    /// The custom two-pane Modern shell has no intrinsic size, so a restored frame can be
    /// collapsed or off-screen. Recenter once, only when the frame is bad.
    private func placeIfNeeded(_ window: NSWindow) {
        guard !placed else { return }
        placed = true
        let frame = window.frame
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
        // Only touch the window when its frame is genuinely bad — otherwise leave ordering
        // alone so toggling the skin doesn't yank this window in front of Settings.
        if frame.width < 980 || frame.height < 640 || !onScreen, let screen = NSScreen.main {
            let vis = screen.visibleFrame
            let size = NSSize(width: min(1320, vis.width - 80), height: min(880, vis.height - 80))
            let origin = NSPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
            window.orderFront(nil)
        }
    }
}

extension View {
    /// Apply full-bleed window chrome when `fullBleed` is true (Modern); restore otherwise.
    func modernWindowChrome(_ fullBleed: Bool) -> some View {
        background(WindowChrome(fullBleed: fullBleed))
    }
}
