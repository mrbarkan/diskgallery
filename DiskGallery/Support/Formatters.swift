import Foundation

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.byteCount(style: .file))
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
}
