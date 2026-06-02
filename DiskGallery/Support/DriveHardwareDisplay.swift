import Foundation
import DiskGalleryCore

/// Presentation derived from a drive's raw `DriveHardware` facts — icons, labels, and the
/// compact badge pieces shown in sidebar rows and the drive detail panel.
///
/// Kept out of the model (where only raw facts live) so the marketing-name mapping can
/// evolve without a migration.
struct DriveHardwareDisplay {
    let hardware: DriveHardware

    init(_ hardware: DriveHardware) { self.hardware = hardware }

    /// SF Symbol representing the bus.
    var busIcon: String {
        switch hardware.bus {
        case .usb:         "cable.connector"
        case .thunderbolt: "bolt.fill"
        case .sata:        "internaldrive"
        case .pcie:        "memorychip"
        case .sd:          "sdcard"
        case .virtual:     "doc"
        case .unknown:     "externaldrive"
        }
    }

    /// Very short bus tag for the tight sidebar pill (icon already carries most meaning).
    var busShort: String {
        switch hardware.bus {
        case .usb:         "USB"
        case .thunderbolt: "TB"
        case .sata:        "SATA"
        case .pcie:        "PCIe"
        case .sd:          "SD"
        case .virtual:     "IMG"
        case .unknown:     "—"
        }
    }

    /// Best-effort marketing label from bus + negotiated speed.
    var generationLabel: String {
        switch hardware.bus {
        case .usb:
            switch hardware.linkSpeedMbps {
            case 12:    "USB 1.1"
            case 480:   "USB 2.0"
            case 5000:  "USB 3.0"
            case 10000: "USB 3.1 Gen 2"
            case 20000: "USB 3.2 Gen 2×2"
            default:    "USB"
            }
        case .thunderbolt: hardware.linkSpeedMbps == 40000 ? "Thunderbolt 3/4" : "Thunderbolt"
        case .sata:        "SATA"
        case .pcie:        "PCIe / NVMe"
        case .sd:          "SD Card"
        case .virtual:     "Disk Image"
        case .unknown:     "Unknown bus"
        }
    }

    /// Negotiated link speed, e.g. "10 Gb/s" or "480 Mb/s". Nil when the OS didn't report it.
    var speedText: String? {
        guard let mbps = hardware.linkSpeedMbps else { return nil }
        if mbps >= 1000 {
            let gbps = Double(mbps) / 1000.0
            return gbps == gbps.rounded() ? "\(Int(gbps)) Gb/s" : String(format: "%.1f Gb/s", gbps)
        }
        return "\(mbps) Mb/s"
    }

    /// "SSD"/"HDD", or nil when the medium is unknown.
    var mediumText: String? {
        switch hardware.medium {
        case .ssd:            "SSD"
        case .hdd:            "HDD"
        case .unknown, .none: nil
        }
    }

    var connectionText: String? {
        guard let isInternal = hardware.isInternal else { return nil }
        return isInternal ? "Internal" : "External"
    }

    var vendor: String? { hardware.vendor }
    var model: String? { hardware.model }

    /// Brand + model joined for display, when present.
    var brandModel: String? {
        let joined = [hardware.vendor, hardware.model].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Is there anything worth surfacing as a row badge?
    var hasRowBadge: Bool {
        hardware.bus != .unknown || speedText != nil || mediumText != nil
    }

    /// Compact one-liner for tooltips / the detail subtitle, e.g. "USB 3.1 Gen 2 · 10 Gb/s · SSD".
    var badgeText: String {
        var parts = [generationLabel]
        if let speedText { parts.append(speedText) }
        if let mediumText { parts.append(mediumText) }
        if let connectionText { parts.append(connectionText) }
        return parts.joined(separator: " · ")
    }

    /// Label/value rows for the drive detail panel.
    var detailRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let connectionText { rows.append(("Connection", connectionText)) }
        rows.append(("Bus", generationLabel))
        rows.append(("Speed", speedText ?? "Unknown"))
        rows.append(("Medium", mediumText ?? "Unknown"))
        if let vendor { rows.append(("Brand", vendor)) }
        if let model { rows.append(("Model", model)) }
        rows.append(("Detected", Format.relativeDate(hardware.capturedAt)))
        return rows
    }
}
