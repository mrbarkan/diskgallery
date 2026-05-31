import SwiftUI
import DiskGalleryCore

/// Non-accent design tokens from the mockup (diskgallery.css), resolved by color scheme.
/// Spec §3.1 (dark) / §3.2 (light). Used only by Modern views — Classic never references these.
enum DGToken {
    // ink ramp
    static func ink(_ s: ColorScheme) -> Color  { s == .dark ? Color(hex: 0xEDEFF4) : Color(hex: 0x1A1D26) }
    static func ink2(_ s: ColorScheme) -> Color { s == .dark ? Color(hex: 0xA6ABB7) : Color(hex: 0x535A68) }
    static func ink3(_ s: ColorScheme) -> Color { s == .dark ? Color(hex: 0x6C7280) : Color(hex: 0x838A98) }
    static func ink4(_ s: ColorScheme) -> Color { s == .dark ? Color(hex: 0x474D5B) : Color(hex: 0xAAB0BC) }

    // hairlines / glass / inset
    static func hair(_ s: ColorScheme) -> Color   { s == .dark ? Color.white.opacity(0.085) : Color(hex: 0x0F1423).opacity(0.10) }
    static func hair2(_ s: ColorScheme) -> Color  { s == .dark ? Color.white.opacity(0.16)  : Color(hex: 0x0F1423).opacity(0.16) }
    static func glass2(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.072) : Color.white.opacity(0.82) }
    static func inset(_ s: ColorScheme) -> Color  { s == .dark ? Color.black.opacity(0.45)  : Color(hex: 0x0F1423).opacity(0.08) }

    // base surfaces (spatial backdrop)
    static let bg0 = Color(hex: 0x08090C)
    static let bg2 = Color(hex: 0x11141A)

    // status signals (fixed in both modes)
    static let ok   = Color(hex: 0x4ADE80)
    static let warn = Color(hex: 0xF7B955)
    static let bad  = Color(hex: 0xF8736B)
}
