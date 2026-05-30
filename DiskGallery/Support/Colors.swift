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
