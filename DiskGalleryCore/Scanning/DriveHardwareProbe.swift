import Foundation
import IOKit
import DiskArbitration

/// Reads best-effort hardware facts (bus, medium, brand/model, negotiated link speed)
/// for the device backing a mounted volume.
///
/// READ-ONLY: only copies device descriptions and registry properties — it never opens
/// the device for I/O and never sets a property. `MutationGuardTests` enforces this.
///
/// Two sources, each best-effort:
///   • DiskArbitration — protocol/bus, vendor, model, internal flag (reliable)
///   • IOKit registry  — medium type (SSD/HDD) and negotiated USB link speed (often available)
///
/// Anything the OS won't report stays nil; callers degrade to "Unknown".
public enum DriveHardwareProbe {

    /// Probes the device behind `url` (a volume root or any path on it). Returns nil only
    /// when the volume can't be resolved to a BSD device at all.
    public static func read(_ url: URL) -> DriveHardware? {
        guard let bsdName = bsdDeviceName(for: url) else { return nil }
        let now = Date()

        var bus: DriveHardware.Bus = .unknown
        var isInternal: Bool?
        var vendor: String?
        var model: String?

        // --- DiskArbitration: device-level identity ---
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) {
            // Device keys live on the whole disk (e.g. disk3), not the partition (disk3s2).
            let deviceDisk = DADiskCopyWholeDisk(disk) ?? disk
            if let desc = DADiskCopyDescription(deviceDisk) as? [String: Any] {
                if let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String {
                    bus = busType(from: proto)
                }
                isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool
                vendor = clean(desc[kDADiskDescriptionDeviceVendorKey as String] as? String)
                model  = clean(desc[kDADiskDescriptionDeviceModelKey as String] as? String)
            }
        }

        // --- IOKit registry: medium + USB link speed ---
        var medium: DriveHardware.Medium?
        var linkSpeedMbps: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)

            if let chars = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "Device Characteristics" as CFString,
                kCFAllocatorDefault, opts) as? [String: Any],
               let mediumType = chars["Medium Type"] as? String {
                switch mediumType {
                case "Solid State": medium = .ssd
                case "Rotational":  medium = .hdd
                default:            medium = .unknown
                }
            }

            // Negotiated USB device speed (enum 0…5). Only meaningful on the USB bus.
            if bus == .usb,
               let speed = IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, "Device Speed" as CFString,
                    kCFAllocatorDefault, opts) as? Int {
                linkSpeedMbps = usbSpeedMbps(speed)
            }
        }

        return DriveHardware(bus: bus, isInternal: isInternal, medium: medium,
                             vendor: vendor, model: model, linkSpeedMbps: linkSpeedMbps,
                             capturedAt: now)
    }

    // MARK: - Helpers

    /// The BSD device node for `url`'s filesystem, e.g. "disk3s2" (the "/dev/" prefix stripped).
    static func bsdDeviceName(for url: URL) -> String? {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return nil }
        let mount = withUnsafeBytes(of: &st.f_mntfromname) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        guard let dev = mount, dev.hasPrefix("/dev/") else { return nil }
        return String(dev.dropFirst("/dev/".count))
    }

    static func busType(from proto: String) -> DriveHardware.Bus {
        let p = proto.lowercased()
        if p.contains("usb") { return .usb }
        if p.contains("thunderbolt") { return .thunderbolt }
        if p.contains("sata") || p == "ata" || p.contains("serial ata") { return .sata }
        if p.contains("pci") || p.contains("fabric") || p.contains("nvme") { return .pcie }
        if p.contains("secure digital") || p == "sd" || p.hasPrefix("sd ") { return .sd }
        if p.contains("disk image") || p.contains("virtual") || p.contains("network") { return .virtual }
        return .unknown
    }

    /// IOUSBHostDevice "Device Speed" enum → negotiated bitrate in Mbps.
    static func usbSpeedMbps(_ speed: Int) -> Int? {
        switch speed {
        case 0: return 2        // low speed (1.5 Mbps, rounded up — never a drive)
        case 1: return 12       // full speed
        case 2: return 480      // high speed (USB 2.0)
        case 3: return 5000     // SuperSpeed (USB 3.0 / 3.1 Gen 1)
        case 4: return 10000    // SuperSpeed+ (USB 3.1 Gen 2)
        case 5: return 20000    // SuperSpeed+ x2 (USB 3.2 Gen 2x2)
        default: return nil
        }
    }

    /// Trims whitespace that DiskArbitration commonly pads device strings with; nil if empty.
    static func clean(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
