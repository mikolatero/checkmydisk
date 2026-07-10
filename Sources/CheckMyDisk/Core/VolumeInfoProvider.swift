import DiskArbitration
import Foundation

struct VolumeInfo: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let totalCapacity: UInt64?
    let availableCapacity: UInt64?

    var usedCapacity: UInt64? {
        guard let totalCapacity, let availableCapacity, totalCapacity >= availableCapacity else { return nil }
        return totalCapacity - availableCapacity
    }
}

/// Maps mounted volumes to the physical whole disk they live on, so the GUI can
/// show free space next to the SMART data. APFS volumes sit on a synthesized
/// container disk; `diskutil list -plist` provides the physical store mapping.
enum VolumeInfoProvider {
    /// Volumes keyed by whole-disk BSD name ("disk0", "disk4"...).
    static func volumesByDisk() async -> [String: [VolumeInfo]] {
        let containerMap = await apfsContainerToPhysicalDisk()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: collectVolumes(containerMap: containerMap))
            }
        }
    }

    private static func collectVolumes(containerMap: [String: String]) -> [String: [VolumeInfo]] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ), let session = DASessionCreate(kCFAllocatorDefault) else {
            return [:]
        }

        var result: [String: [VolumeInfo]] = [:]
        for url in urls {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let bsdPointer = DADiskGetBSDName(disk) else {
                continue
            }
            let containerDisk = wholeDiskName(String(cString: bsdPointer))
            let physicalDisk = containerMap[containerDisk] ?? containerDisk
            let values = try? url.resourceValues(forKeys: keys)
            let volume = VolumeInfo(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                totalCapacity: (values?.volumeTotalCapacity).map(UInt64.init),
                availableCapacity: (values?.volumeAvailableCapacity).map(UInt64.init)
            )
            result[physicalDisk, default: []].append(volume)
        }
        return result.mapValues { volumes in
            volumes.sorted { ($0.totalCapacity ?? 0) > ($1.totalCapacity ?? 0) }
        }
    }

    /// "disk3" (synthesized APFS container) → "disk0" (physical disk).
    private static func apfsContainerToPhysicalDisk() async -> [String: String] {
        let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
        guard let result = try? await ProcessRunner.run(diskutil, arguments: ["list", "-plist"], timeout: .seconds(20)),
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return [:]
        }
        var map: [String: String] = [:]
        for disk in disks {
            guard let identifier = disk["DeviceIdentifier"] as? String,
                  let stores = disk["APFSPhysicalStores"] as? [[String: Any]],
                  let store = stores.first?["DeviceIdentifier"] as? String else {
                continue
            }
            map[identifier] = wholeDiskName(store)
        }
        return map
    }

    /// "disk3s1s1" → "disk3".
    static func wholeDiskName(_ bsdName: String) -> String {
        guard bsdName.hasPrefix("disk") else { return bsdName }
        let digits = bsdName.dropFirst(4).prefix { $0.isNumber }
        return "disk\(digits)"
    }
}
