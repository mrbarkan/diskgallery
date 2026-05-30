import Foundation

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.byteCount(style: .file))
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }

    static func count(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted()
    }
}
