import Foundation

/// Sidebar drag identifiers encoded as plain strings.
///
/// We deliberately use `String` (which is `Transferable` out of the box) rather than a
/// custom `Transferable` with a bespoke `UTType`: the app ships a *generated* Info.plist,
/// so a custom exported type can't be declared, and macOS won't reliably vend/accept an
/// undeclared drag type. A prefixed string sidesteps all of that and Just Works in-process.
enum DriveDragID {
    private static let drivePrefix = "dg-drive:"
    private static let groupPrefix = "dg-group:"

    static func drive(_ id: Int64) -> String { drivePrefix + String(id) }
    static func group(_ id: Int64) -> String { groupPrefix + String(id) }

    static func parseDrive(_ s: String) -> Int64? {
        s.hasPrefix(drivePrefix) ? Int64(s.dropFirst(drivePrefix.count)) : nil
    }
    static func parseGroup(_ s: String) -> Int64? {
        s.hasPrefix(groupPrefix) ? Int64(s.dropFirst(groupPrefix.count)) : nil
    }
}
