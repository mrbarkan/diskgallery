import Foundation

/// How the Duplicates resolver chooses which copy to KEEP (the rest get tagged Delete).
public enum KeepRule: String, CaseIterable, Sendable {
    case fastestDrive, newest, largestDrive

    public var label: String {
        switch self {
        case .fastestDrive: return "Fastest drive"
        case .newest:       return "Newest"
        case .largestDrive: return "Largest drive"
        }
    }
}

/// Picks the member to keep. `capacities` maps a member's volume key
/// (`volumeUuid ?? volumeName`) to that drive's total capacity in bytes.
///
/// - `.newest`       → greatest `modifiedAt` (a `nil` date sorts oldest).
/// - `.largestDrive` → greatest capacity (a missing capacity sorts smallest).
/// - `.fastestDrive` → no drive-speed signal exists yet, so it maps to `.largestDrive`.
///
/// Ties fall back to the members' current order (first wins), so results are deterministic.
/// Returns `nil` for an empty list.
public func keptMemberID(members: [DuplicateMember],
                         rule: KeepRule,
                         capacities: [String: Int64]) -> Int64? {
    guard !members.isEmpty else { return nil }

    func capacity(_ m: DuplicateMember) -> Int64 {
        capacities[m.volumeUuid ?? m.volumeName] ?? 0
    }

    var best = members[0]
    for m in members.dropFirst() {
        let better: Bool
        switch rule {
        case .newest:
            better = (m.modifiedAt ?? .distantPast) > (best.modifiedAt ?? .distantPast)
        case .largestDrive, .fastestDrive:
            better = capacity(m) > capacity(best)
        }
        if better { best = m }
    }
    return best.entryId
}
