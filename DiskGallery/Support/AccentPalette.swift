import SwiftUI
import DiskGalleryCore

/// Resolved SwiftUI colors for an accent, derived from the design tokens in diskgallery.css.
struct AccentPalette {
    let accent: Color       // --accent (drives .tint)
    let accent2: Color      // --accent-2 (mid gradient stop: scan button, OLED capbar)
    let accentDeep: Color   // --accent-deep (gradient stop / brand mark)
    let ink: Color          // --accent-ink (text/icon on an accent fill)
    /// --accent-glow: the accent at glow opacity, for colored shadows.
    var glow: Color { accent.opacity(0.45) }
    /// --accent-soft: the accent at fill opacity, for selection backgrounds.
    var soft: Color { accent.opacity(0.16) }
}

extension Accent {
    /// The resolved palette. Exhaustive — the compiler guarantees every accent is covered.
    var palette: AccentPalette {
        switch self {
        case .violet:   AccentPalette(accent: Color(hex: 0xA78BFF), accent2: Color(hex: 0x8F6CFF), accentDeep: Color(hex: 0x6F4CE0), ink: Color(hex: 0x15101F))
        case .blue:     AccentPalette(accent: Color(hex: 0x5AA2FF), accent2: Color(hex: 0x3D86F0), accentDeep: Color(hex: 0x2F6AD6), ink: Color(hex: 0x04101F))
        case .green:    AccentPalette(accent: Color(hex: 0x54E0A0), accent2: Color(hex: 0x2FC586), accentDeep: Color(hex: 0x1EA372), ink: Color(hex: 0x04130C))
        case .amber:    AccentPalette(accent: Color(hex: 0xF7C14E), accent2: Color(hex: 0xEDA52F), accentDeep: Color(hex: 0xCF851E), ink: Color(hex: 0x1C1304))
        case .coral:    AccentPalette(accent: Color(hex: 0xFF855F), accent2: Color(hex: 0xF56640), accentDeep: Color(hex: 0xD6492A), ink: Color(hex: 0x1D0C05))
        case .graphite: AccentPalette(accent: Color(hex: 0x7D90B5), accent2: Color(hex: 0x6E83AA), accentDeep: Color(hex: 0x5C739E), ink: Color(hex: 0x0C1018))
        }
    }
}

