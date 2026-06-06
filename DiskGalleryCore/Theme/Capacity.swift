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

    /// Bytes used: `total − free` when both are known, else the catalogued logical size.
    public static func usedBytes(total: Int64?, free: Int64?, logicalFallback: Int64?) -> Int64 {
        if let total, let free { return max(0, total - free) }
        return max(0, logicalFallback ?? 0)
    }

    /// Bytes free: the reported free space, or `total − logicalFallback`. 0 when unknown.
    public static func freeBytes(total: Int64?, free: Int64?, logicalFallback: Int64?) -> Int64 {
        if let free { return max(0, free) }
        if let total, let logicalFallback { return max(0, total - logicalFallback) }
        return 0
    }
}
