import Foundation

// MARK: - Planner inputs

/// A drive as the planner sees it: capacity, connection, and best-effort hardware
/// facts. Pure value type so the planner needs no DB and is trivially testable.
public struct PlanDrive: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var key: String              // uuid ?? name — matches annotation keying
    public var name: String
    public var totalCapacity: Int64?
    public var freeCapacity: Int64?
    public var usedLogical: Int64?      // fallback when freeCapacity is unknown
    public var isConnected: Bool
    public var hardware: DriveHardware?
    public var role: DriveRole          // user-assigned routing role (default .neutral)
    public var priority: Int            // user ordering; lower = preferred (tie-break)

    public init(id: Int64, key: String, name: String, totalCapacity: Int64?, freeCapacity: Int64?,
                usedLogical: Int64? = nil, isConnected: Bool, hardware: DriveHardware? = nil,
                role: DriveRole = .neutral, priority: Int = 0) {
        self.id = id
        self.key = key
        self.name = name
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.usedLogical = usedLogical
        self.isConnected = isConnected
        self.hardware = hardware
        self.role = role
        self.priority = priority
    }

    /// Free bytes to plan against: the reported free space, or `total − usedLogical`.
    public var effectiveFree: Int64 {
        Capacity.freeBytes(total: totalCapacity, free: freeCapacity, logicalFallback: usedLogical)
    }
}

/// One top-level tagged item the planner must place (Move/Backup) or account for (Delete).
public struct PlanItemSource: Sendable, Identifiable, Equatable {
    public var id: String               // "volumeKey|relPath" — stable, used for overrides
    public var volumeKey: String
    public var volumeName: String
    public var relPath: String
    public var name: String
    public var isDir: Bool
    public var tag: Tag                  // .move | .backup | .delete
    public var sizeBytes: Int64

    public init(volumeKey: String, volumeName: String, relPath: String, name: String,
                isDir: Bool, tag: Tag, sizeBytes: Int64) {
        self.id = "\(volumeKey)|\(relPath)"
        self.volumeKey = volumeKey
        self.volumeName = volumeName
        self.relPath = relPath
        self.name = name
        self.isDir = isDir
        self.tag = tag
        self.sizeBytes = sizeBytes
    }
}

// MARK: - Planner output

public enum PlanOperation: String, Sendable, Equatable {
    case verify, copy, move, delete     // copy == Backup, move == Move
}

public enum StepFeasibility: String, Sendable, Equatable {
    case ok, needsConnect, overflow, unassigned
}

/// One ordered operation in the non-destructive plan.
public struct PlanStep: Sendable, Identifiable, Equatable {
    public var id: String
    public var orderIndex: Int
    public var operation: PlanOperation
    public var name: String
    public var sourceDriveKey: String?
    public var sourceDriveName: String?
    public var sourcePath: String?
    public var destinationDriveKey: String?
    public var destinationDriveName: String?
    public var bytes: Int64
    public var estDuration: TimeInterval
    public var feasibility: StepFeasibility
    public var dependsOn: [String]
    public var isOverride: Bool
}

/// A drive's fullness before and after the plan runs.
public struct CapacityProjection: Sendable, Identifiable, Equatable {
    public var id: String               // drive key
    public var driveName: String
    public var totalCapacity: Int64?
    public var currentFree: Int64
    public var projectedFree: Int64
    public var currentFraction: Double
    public var projectedFraction: Double
    public var willOverflow: Bool
}

/// The whole plan: ordered steps, per-drive projections, totals, and a report.
public struct OrganizationPlan: Sendable {
    public var steps: [PlanStep]
    public var projections: [CapacityProjection]
    public var isFeasible: Bool
    public var unassigned: [PlanStep]
    public var totalBytesToMove: Int64
    public var totalBytesToCopy: Int64
    public var totalBytesToFree: Int64
    public var estTotalDuration: TimeInterval
    public var drivesToConnect: [String]

    public static let empty = OrganizationPlan(
        steps: [], projections: [], isFeasible: true, unassigned: [],
        totalBytesToMove: 0, totalBytesToCopy: 0, totalBytesToFree: 0,
        estTotalDuration: 0, drivesToConnect: [])

    /// A numbered, human-readable playbook (plain text).
    public func reportText() -> String {
        renderLines(markdown: false).joined(separator: "\n")
    }

    /// The same playbook as Markdown, for export.
    public func reportMarkdown() -> String {
        (["# Organization Plan", ""] + renderLines(markdown: true)).joined(separator: "\n")
    }

    private func renderLines(markdown: Bool) -> [String] {
        guard !steps.isEmpty else {
            return ["Nothing to organize — tag items Move, Backup, or Delete."]
        }
        var lines = steps.map { line(for: $0, markdown: markdown) }
        if !drivesToConnect.isEmpty {
            lines.append("")
            lines.append("Connect these drives first: " + drivesToConnect.joined(separator: ", "))
        }
        if !unassigned.isEmpty {
            lines.append("")
            lines.append("\(unassigned.count) item\(unassigned.count == 1 ? "" : "s") couldn't be placed — free space or add a drive:")
            lines += unassigned.map { "  • \($0.name) (\(Self.bytes($0.bytes)))" }
        }
        return lines
    }

    private func line(for step: PlanStep, markdown: Bool) -> String {
        let prefix = "\(step.orderIndex)."
        let name = markdown ? "`\(step.name)`" : "\u{201C}\(step.name)\u{201D}"
        switch step.operation {
        case .verify:
            return "\(prefix) \(step.name)"
        case .delete:
            return "\(prefix) Delete \(name) on \(step.sourceDriveName ?? "?") (frees \(Self.bytes(step.bytes)))"
        case .move, .copy:
            let verb = step.operation == .move ? "Move" : "Back up"
            let dest = step.destinationDriveName ?? "unassigned"
            let dur = step.estDuration > 0 ? ", ~\(Self.duration(step.estDuration))" : ""
            var line = "\(prefix) \(verb) \(name) — \(step.sourceDriveName ?? "?") \u{2192} \(dest) (\(Self.bytes(step.bytes))\(dur))"
            switch step.feasibility {
            case .needsConnect: line += " [connect \(dest)]"
            case .overflow:     line += " [\u{26A0} exceeds capacity]"
            case .unassigned:   line += " [\u{26A0} no destination]"
            case .ok:           break
            }
            return line
        }
    }

    private static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(seconds, 60)) ?? "<1m"
    }
}

/// Tunables for the planner.
public struct PlanOptions: Sendable {
    public var fillThreshold: Double        // a destination must stay below this fraction
    public var fallbackSpeedMbps: Int       // used when no link speed / bus is known
    public init(fillThreshold: Double = 0.95, fallbackSpeedMbps: Int = 480) {
        self.fillThreshold = fillThreshold
        self.fallbackSpeedMbps = fallbackSpeedMbps
    }
}

// MARK: - The planner

/// Turns cross-drive tagged items into an ordered, capacity-aware, non-destructive
/// plan. Pure and deterministic: same inputs → same plan.
public enum OrganizationPlanner {
    public static func plan(drives: [PlanDrive],
                            items: [PlanItemSource],
                            overrides: [String: String] = [:],
                            options: PlanOptions = PlanOptions()) -> OrganizationPlan {
        let byKey = Dictionary(drives.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let initialFree = Dictionary(drives.map { ($0.key, $0.effectiveFree) }, uniquingKeysWith: { a, _ in a })
        var working = initialFree
        var creditedBy: [String: [String]] = [:]   // driveKey -> ids of steps that freed it
        var steps: [PlanStep] = []
        var unassigned: [PlanStep] = []

        /// Max bytes writable to `drive` while staying under the fill threshold.
        func maxWrite(_ drive: PlanDrive, freeNow: Int64) -> Int64 {
            guard let total = drive.totalCapacity else { return freeNow }
            return freeNow - Int64(Double(total) * (1 - options.fillThreshold))
        }
        func freeNow(_ key: String) -> Int64 { working[key] ?? byKey[key]?.effectiveFree ?? 0 }

        // Verify covers everything first.
        if !items.isEmpty {
            let touched = items.reduce(0) { $0 + $1.sizeBytes }
            steps.append(PlanStep(id: "verify", orderIndex: 0, operation: .verify,
                name: "Verify \(items.count) tagged item\(items.count == 1 ? "" : "s")",
                sourceDriveKey: nil, sourceDriveName: nil, sourcePath: nil,
                destinationDriveKey: nil, destinationDriveName: nil,
                bytes: touched, estDuration: 0, feasibility: .ok, dependsOn: [], isOverride: false))
        }

        // Deletes free their source — process first so later fills can use the space.
        for item in items.filter({ $0.tag == .delete }).sorted(by: Self.bySizeThenID) {
            working[item.volumeKey] = freeNow(item.volumeKey) + item.sizeBytes
            creditedBy[item.volumeKey, default: []].append(item.id)
            let offline = byKey[item.volumeKey]?.isConnected == false
            steps.append(PlanStep(id: item.id, orderIndex: 0, operation: .delete, name: item.name,
                sourceDriveKey: item.volumeKey, sourceDriveName: item.volumeName, sourcePath: item.relPath,
                destinationDriveKey: nil, destinationDriveName: nil,
                bytes: item.sizeBytes, estDuration: 0,
                feasibility: offline ? .needsConnect : .ok, dependsOn: [], isOverride: false))
        }

        func assignFill(_ item: PlanItemSource, operation: PlanOperation) {
            let source = byKey[item.volumeKey]
            var destKey: String?
            var isOverride = false

            if let override = overrides[item.id], override != item.volumeKey, byKey[override] != nil {
                destKey = override
                isOverride = true
            } else {
                let candidates = drives.filter { drive in
                    drive.key != item.volumeKey && drive.totalCapacity != nil
                        && drive.role.canReceive(item.tag)
                        && item.sizeBytes <= maxWrite(drive, freeNow: freeNow(drive.key))
                }
                // Rank by: role preference, then user priority (lower first), then the
                // capacity/speed heuristic, then most free-after, then smallest id.
                // Larger tuple == better; `max(by:)` returns the best candidate.
                func rankKey(_ d: PlanDrive) -> (Int, Int, Double, Int64, Int64) {
                    (d.role.rank(for: item.tag), -d.priority,
                     Self.score(d, for: item.tag, options: options),
                     freeNow(d.key) - item.sizeBytes, -d.id)
                }
                destKey = candidates.max(by: { rankKey($0) < rankKey($1) })?.key
            }

            guard let dest = destKey, let destDrive = byKey[dest] else {
                let step = PlanStep(id: item.id, orderIndex: 0, operation: operation, name: item.name,
                    sourceDriveKey: item.volumeKey, sourceDriveName: item.volumeName, sourcePath: item.relPath,
                    destinationDriveKey: nil, destinationDriveName: nil,
                    bytes: item.sizeBytes, estDuration: 0, feasibility: .unassigned,
                    dependsOn: [], isOverride: false)
                steps.append(step); unassigned.append(step)
                return
            }

            let fits = item.sizeBytes <= maxWrite(destDrive, freeNow: freeNow(dest))
            // Did it only fit thanks to space freed earlier? Then it depends on those steps.
            let origFree = initialFree[dest] ?? destDrive.effectiveFree
            let neededCredit = item.sizeBytes > maxWrite(destDrive, freeNow: origFree)
            let deps = neededCredit ? (creditedBy[dest] ?? []) : []

            working[dest] = freeNow(dest) - item.sizeBytes
            if operation == .move {
                working[item.volumeKey] = freeNow(item.volumeKey) + item.sizeBytes
                creditedBy[item.volumeKey, default: []].append(item.id)
            }

            let mbps = min(Self.speed(source, options: options), Self.speed(destDrive, options: options))
            let duration = Self.estimatedDuration(bytes: item.sizeBytes, mbps: mbps, options: options)

            let feasibility: StepFeasibility
            if !fits { feasibility = .overflow }
            else if source?.isConnected == false || !destDrive.isConnected { feasibility = .needsConnect }
            else { feasibility = .ok }

            steps.append(PlanStep(id: item.id, orderIndex: 0, operation: operation, name: item.name,
                sourceDriveKey: item.volumeKey, sourceDriveName: item.volumeName, sourcePath: item.relPath,
                destinationDriveKey: dest, destinationDriveName: destDrive.name,
                bytes: item.sizeBytes, estDuration: duration, feasibility: feasibility,
                dependsOn: deps, isOverride: isOverride))
        }

        // Moves then backups (moves also free their source, helping later backups fit).
        for item in items.filter({ $0.tag == .move }).sorted(by: Self.bySizeThenID) {
            assignFill(item, operation: .move)
        }
        for item in items.filter({ $0.tag == .backup }).sorted(by: Self.bySizeThenID) {
            assignFill(item, operation: .copy)
        }

        for index in steps.indices { steps[index].orderIndex = index + 1 }

        let projections = drives.map { drive -> CapacityProjection in
            let current = initialFree[drive.key] ?? drive.effectiveFree
            let projected = working[drive.key] ?? drive.effectiveFree
            let projectedFraction = Capacity.fractionUsed(total: drive.totalCapacity, free: projected)
            return CapacityProjection(
                id: drive.key, driveName: drive.name, totalCapacity: drive.totalCapacity,
                currentFree: current, projectedFree: projected,
                currentFraction: Capacity.fractionUsed(total: drive.totalCapacity, free: current),
                projectedFraction: projectedFraction,
                willOverflow: drive.totalCapacity != nil && projectedFraction >= options.fillThreshold)
        }

        let moves = items.filter { $0.tag == .move }
        let backups = items.filter { $0.tag == .backup }
        let deletes = items.filter { $0.tag == .delete }

        var connectSeen = Set<String>(); var connect: [String] = []
        for step in steps {
            for key in [step.sourceDriveKey, step.destinationDriveKey].compactMap({ $0 }) {
                if let drive = byKey[key], !drive.isConnected, connectSeen.insert(key).inserted {
                    connect.append(drive.name)
                }
            }
        }

        return OrganizationPlan(
            steps: steps, projections: projections, isFeasible: unassigned.isEmpty, unassigned: unassigned,
            totalBytesToMove: moves.reduce(0) { $0 + $1.sizeBytes },
            totalBytesToCopy: backups.reduce(0) { $0 + $1.sizeBytes },
            totalBytesToFree: deletes.reduce(0) { $0 + $1.sizeBytes } + moves.reduce(0) { $0 + $1.sizeBytes },
            estTotalDuration: steps.reduce(0) { $0 + $1.estDuration },
            drivesToConnect: connect)
    }

    // MARK: Heuristics

    private static func bySizeThenID(_ a: PlanItemSource, _ b: PlanItemSource) -> Bool {
        a.sizeBytes != b.sizeBytes ? a.sizeBytes > b.sizeBytes : a.id < b.id
    }

    /// Destination desirability. Medium suitability dominates (Backup → HDD/archive,
    /// Move → SSD), then link speed, then a small bonus for being already connected.
    private static func score(_ drive: PlanDrive, for tag: Tag, options: PlanOptions) -> Double {
        var score = 0.0
        if tag == .backup, drive.hardware?.medium == .hdd { score += 1000 }
        if tag == .move, drive.hardware?.medium == .ssd { score += 1000 }
        score += Double(speedBucket(drive))
        if drive.isConnected { score += 5 }
        return score
    }

    private static func speedBucket(_ drive: PlanDrive) -> Int {
        let mbps = drive.hardware?.linkSpeedMbps ?? busFallback(drive.hardware?.bus) ?? 0
        switch mbps {
        case 40000...: return 40
        case 10000...: return 30
        case 5000...:  return 20
        case 1...:     return 10
        default:       return 0
        }
    }

    private static func speed(_ drive: PlanDrive?, options: PlanOptions) -> Int {
        guard let drive else { return options.fallbackSpeedMbps }
        if let mbps = drive.hardware?.linkSpeedMbps, mbps > 0 { return mbps }
        return busFallback(drive.hardware?.bus) ?? options.fallbackSpeedMbps
    }

    private static func busFallback(_ bus: DriveHardware.Bus?) -> Int? {
        switch bus {
        case .thunderbolt: return 40000
        case .pcie, .virtual: return 8000
        case .sata: return 6000
        case .usb: return 5000
        case .sd: return 90
        case .unknown, .none: return nil
        }
    }

    private static func estimatedDuration(bytes: Int64, mbps: Int, options: PlanOptions) -> TimeInterval {
        let speed = mbps > 0 ? mbps : options.fallbackSpeedMbps
        let efficiency = 0.7   // real-world throughput is well below the negotiated link rate
        return Double(bytes) * 8.0 / (Double(speed) * 1_000_000.0 * efficiency)
    }
}
