import SwiftUI
import DiskGalleryCore

extension FinderColor {
    /// The on-screen color used for swatches and dots.
    var swiftUIColor: Color {
        switch self {
        case .none:   return .secondary
        case .gray:   return Color(red: 0.55, green: 0.55, blue: 0.57)
        case .green:  return .green
        case .purple: return .purple
        case .blue:   return .blue
        case .yellow: return .yellow
        case .red:    return .red
        case .orange: return .orange
        }
    }

    /// Exact mockup hex for Modern swatches/dots (spec §3.3). `.none` = clear.
    var modernColor: Color {
        switch self {
        case .none:   return .clear
        case .red:    return Color(hex: 0xF8736B)
        case .orange: return Color(hex: 0xF6A23C)
        case .yellow: return Color(hex: 0xF5CF52)
        case .green:  return Color(hex: 0x5FD38A)
        case .blue:   return Color(hex: 0x5AA2FF)
        case .purple: return Color(hex: 0xB78CFF)
        case .gray:   return Color(hex: 0x8A909D)
        }
    }
}

extension Tag {
    var swiftUIColor: Color {
        switch self {
        case .none:   return .secondary
        case .keep:   return .green
        case .delete: return .red
        case .review: return .yellow
        case .move:   return .blue
        case .backup: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .none:   return "circle"
        case .keep:   return "checkmark.seal.fill"
        case .delete: return "trash.fill"
        case .review: return "questionmark.circle.fill"
        case .move:   return "arrow.right.circle.fill"
        case .backup: return "shippingbox.fill"
        }
    }

    /// Exact mockup signal color for Modern chips / tag buttons / plan rows (spec §10).
    var modernColor: Color {
        switch self {
        case .none:   return Color(hex: 0x6C7280)
        case .keep:   return Color(hex: 0x4ADE80)
        case .delete: return Color(hex: 0xF8736B)
        case .review: return Color(hex: 0xF7B955)
        case .move:   return Color(hex: 0xB78CFF)
        case .backup: return Color(hex: 0x5AA2FF)
        }
    }
}

extension Color {
    /// Build a Color from a `0xRRGGBB` literal.
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }
}
