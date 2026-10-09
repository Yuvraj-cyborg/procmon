// Disks recovery can read: every physical drive, card and attached disk
// image, with the volumes on it. APFS containers are left out: they are
// views of a partition already listed under its drive.

import DiskArbitration
import Foundation
import IOKit

struct RecoveryVolume: Hashable, Sendable {
    let bsdName: String
    let name: String?
    /// e.g. "MS-DOS (FAT32)", "ExFAT".
    let format: String?
    let size: Bytes
    let mountPoint: String?
}

struct RecoveryDisk: Identifiable, Hashable, Sendable {
    let bsdName: String
    let name: String
    let size: Bytes
    /// "USB", "Secure Digital", "Thunderbolt"…
    let connection: String?
    let isInternal: Bool
    let isDiskImage: Bool
    let volumes: [RecoveryVolume]

    var id: String { bsdName }
    /// The raw device: unbuffered, and much faster for reading straight through.
    var devicePath: String { "/dev/r" + bsdName }

    /// Memory cards, USB sticks and external drives: where recovery works.
    var isExternal: Bool { !isInternal && !isDiskImage }

    var summary: String {
        var parts = [size.decimal]
        if let connection { parts.append(connection) }
        let names = volumes.compactMap(\.name)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

enum RecoverySources {
    /// The partition type of a synthesized APFS container disk.
    private static let apfsContainer = "EF57347C-0000-11AA-AA11-00306543ECAC"

    static func disks() -> [RecoveryDisk] {
        let media = allMedia()
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let whole = media.filter { $0.isWhole && $0.content != apfsContainer }
        return whole.compactMap { disk -> RecoveryDisk? in
            let description = describe(disk.bsdName, session: session)
            let partitions = media
                .filter { isPartition($0.bsdName, of: disk.bsdName) }
                .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
            let volumes = partitions.map { partition -> RecoveryVolume in
                let info = describe(partition.bsdName, session: session)
                return RecoveryVolume(
                    bsdName: partition.bsdName,
                    name: info[kDADiskDescriptionVolumeNameKey as String] as? String,
                    format: (info[kDADiskDescriptionVolumeKindKey as String] as? String).map(formatName) ?? contentName(partition.content),
                    size: Bytes(partition.size),
                    mountPoint: (info[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
                )
            }
            let connection = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces)
            let vendor = (description[kDADiskDescriptionDeviceVendorKey as String] as? String)?.trimmingCharacters(in: .whitespaces)
            let mediaName = (description[kDADiskDescriptionMediaNameKey as String] as? String)?.trimmingCharacters(in: .whitespaces)
            let name = [vendor, model].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            return RecoveryDisk(
                bsdName: disk.bsdName,
                name: name.isEmpty ? mediaName ?? disk.bsdName : name,
                size: Bytes(disk.size),
                connection: connection,
                isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false,
                isDiskImage: connection == "Disk Image",
                volumes: volumes
            )
        }
        .sorted { lhs, rhs in
            func rank(_ disk: RecoveryDisk) -> Int { disk.isExternal ? 0 : disk.isDiskImage ? 1 : 2 }
            return (rank(lhs), lhs.bsdName) < (rank(rhs), rhs.bsdName)
        }
    }

    /// `disk4s1` is a partition of `disk4`; `disk4s1s1` is not a direct one.
    static func isPartition(_ name: String, of disk: String) -> Bool {
        guard name.hasPrefix(disk + "s") else { return false }
        return name.dropFirst(disk.count + 1).allSatisfy(\.isNumber)
    }

    private struct Media {
        let bsdName: String
        let size: UInt64
        let isWhole: Bool
        let content: String
    }

    private static func allMedia() -> [Media] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var media: [Media] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let name = property("BSD Name") as? String, let size = (property("Size") as? NSNumber)?.uint64Value, size > 0 else { continue }
            media.append(Media(
                bsdName: name, size: size, isWhole: property("Whole") as? Bool ?? false, content: property("Content") as? String ?? ""
            ))
        }
        return media
    }

    private static func describe(_ bsdName: String, session: DASession) -> [String: Any] {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return [:] }
        return description
    }

    private static func formatName(_ kind: String) -> String {
        switch kind {
        case "msdos": "FAT"
        case "exfat": "exFAT"
        case "apfs": "APFS"
        case "hfs": "Mac OS Extended"
        case "ntfs": "NTFS"
        default: kind
        }
    }

    /// Partition types for volumes that are not mounted.
    private static func contentName(_ content: String) -> String? {
        switch content {
        case "DOS_FAT_12", "DOS_FAT_16", "DOS_FAT_32", "DOS_FAT_32_LBA", "Windows_FAT_32", "Windows_FAT_16": "FAT"
        case "Windows_NTFS": "NTFS or exFAT"
        case "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft Basic Data": "FAT, exFAT or NTFS"
        case "7C3457EF-0000-11AA-AA11-00306543ECAC", "Apple_APFS": "APFS"
        case "48465300-0000-11AA-AA11-00306543ECAC", "Apple_HFS": "Mac OS Extended"
        case "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": "EFI"
        default: nil
        }
    }
}
