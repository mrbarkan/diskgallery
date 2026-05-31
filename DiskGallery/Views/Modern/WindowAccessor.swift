import SwiftUI
import AppKit

/// Toggles full-bleed (hidden title bar) on the hosting NSWindow for the Modern skin.
/// Classic restores the standard title bar. Spec §4.2.
struct WindowChrome: NSViewRepresentable {
    var fullBleed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = fullBleed
        window.titleVisibility = fullBleed ? .hidden : .visible
        window.isMovableByWindowBackground = fullBleed
        if fullBleed {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
    }
}

extension View {
    /// Apply full-bleed window chrome when `fullBleed` is true (Modern); restore otherwise.
    func modernWindowChrome(_ fullBleed: Bool) -> some View {
        background(WindowChrome(fullBleed: fullBleed))
    }
}
