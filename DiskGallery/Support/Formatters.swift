import Foundation

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.byteCount(style: .file))
    }

    /// Consistent-precision size (always 2 decimals for KB and up), so a column of
    /// sizes lines up cleanly — e.g. "1.00 TB", "1.59 TB", "644.66 GB", "48 B".
    static func size2(_ value: Int64?) -> String {
        guard let value else { return "—" }
        guard value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var n = Double(value)
        var i = 0
        while n >= 1000 && i < units.count - 1 { n /= 1000; i += 1 }
        let digits = i == 0 ? 0 : 2
        return n.formatted(.number.precision(.fractionLength(digits))) + " " + units[i]
    }

    /// Signed byte count, e.g. "+1.2 GB" / "−400 MB" — for change reports.
    static func signedBytes(_ value: Int64) -> String {
        let sign = value < 0 ? "−" : "+"
        return sign + Format.bytes(abs(value))
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }

    /// "3 days ago" — for a quick "last scanned" glance.
    static func relativeDate(_ value: Date?) -> String {
        guard let value else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: value, relativeTo: Date())
    }

    static func count(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted()
    }

    static func count(_ value: Int) -> String { value.formatted() }

    /// "62%" from a 0…1 fraction.
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "2h 40m" — a coarse transfer-time estimate. Floors at a minute.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(seconds, 60)) ?? "<1m"
    }
}
