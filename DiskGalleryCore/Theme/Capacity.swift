import Foundation

/// Pure drive-fullness math, shared by capacity bars and the OLED display.
public enum Capacity {
    /// Fraction of a drive that is used, clamped to 0...1. Returns 0 when capacity is unknown.
    public static func fractionUsed(total: Int64?, free: Int64?) -> Double {
        guard let total, total > 0 else { return 0 }
        let used = max(0, total - (free ?? 0))
        return min(1, Double(used) / Double(total))
    }

    /// Whether the drive is at/above `threshold` full (default 95%).
    public static func isOverCapacity(total: Int64?, free: Int64?, threshold: Double = 0.95) -> Bool {
        guard let total, total > 0 else { return false }
        return fractionUsed(total: total, free: free) >= threshold
    }
}
