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

/// Maps mounted volumes to the physical whole disk(s) they live on, so the GUI can
/// show free space next to the SMART data. APFS volumes sit on a synthesized
/// container; Fusion Drive (CoreStorage) and AppleRAID span several physical disks.
/// A volume is listed under every physical disk it ultimately rests on.
enum VolumeInfoProvider {
    /// The physical layout discovered from `diskutil`.
    struct DiskTopology: Sendable {
        var apfsStores: [String: [String]] = [:]       // APFS container disk → store disks
        var aggregateMembers: [String: [String]] = [:] // CoreStorage/RAID logical disk → member disks
    }

    /// Volumes keyed by whole-disk BSD name ("disk0", "disk4"...).
    static func volumesByDisk() async -> [String: [VolumeInfo]] {
        let topology = await diskTopology()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: collectVolumes(topology: topology))
            }
        }
    }

    private static func collectVolumes(topology: DiskTopology) -> [String: [VolumeInfo]] {
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
            let values = try? url.resourceValues(forKeys: keys)
            let volume = VolumeInfo(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                totalCapacity: (values?.volumeTotalCapacity).map(UInt64.init),
                availableCapacity: (values?.volumeAvailableCapacity).map(UInt64.init)
            )
            for physical in physicalDisks(forContainer: containerDisk, topology: topology) {
                result[physical, default: []].append(volume)
            }
        }
        return result.mapValues { volumes in
            volumes.sorted { ($0.totalCapacity ?? 0) > ($1.totalCapacity ?? 0) }
        }
    }

    /// The physical disk(s) an APFS container ultimately rests on, expanding
    /// CoreStorage/RAID aggregates to their members. Falls back to the container
    /// disk itself when the layout is unknown (non-APFS, or unparsed diskutil).
    static func physicalDisks(forContainer containerDisk: String, topology: DiskTopology) -> [String] {
        let stores = topology.apfsStores[containerDisk] ?? [containerDisk]
        var result: [String] = []
        for store in stores {
            for member in topology.aggregateMembers[store] ?? [store] where !result.contains(member) {
                result.append(member)
            }
        }
        return result
    }

    private static func diskTopology() async -> DiskTopology {
        var topology = DiskTopology()
        if let plist = await plist(arguments: ["list", "-plist"]) {
            topology.apfsStores = parseAPFSStores(plist)
        }
        // CoreStorage (Fusion Drive) and AppleRAID are best-effort: if the diskutil
        // output is absent or shaped differently than expected, the maps stay empty
        // and volumes simply map to their APFS store, as before.
        if let plist = await plist(arguments: ["coreStorage", "list", "-plist"]) {
            topology.aggregateMembers.merge(parseCoreStorageMembers(plist)) { current, _ in current }
        }
        if let plist = await plist(arguments: ["appleRAID", "list", "-plist"]) {
            topology.aggregateMembers.merge(parseAppleRAIDMembers(plist)) { current, _ in current }
        }
        return topology
    }

    /// APFS container disk → its physical store disks, from `diskutil list -plist`.
    static func parseAPFSStores(_ plist: [String: Any]) -> [String: [String]] {
        guard let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [:] }
        var map: [String: [String]] = [:]
        for disk in disks {
            guard let identifier = disk["DeviceIdentifier"] as? String,
                  let stores = disk["APFSPhysicalStores"] as? [[String: Any]] else {
                continue
            }
            let members = uniqued(stores.compactMap { ($0["DeviceIdentifier"] as? String).map(wholeDiskName) })
            if !members.isEmpty {
                map[identifier] = members
            }
        }
        return map
    }

    /// CoreStorage (Fusion Drive) logical-volume disk → physical member disks,
    /// from `diskutil coreStorage list -plist`.
    static func parseCoreStorageMembers(_ plist: [String: Any]) -> [String: [String]] {
        guard let groups = plist["CoreStorageLogicalVolumeGroups"] as? [[String: Any]] else { return [:] }
        var map: [String: [String]] = [:]
        for group in groups {
            let physicalVolumes = group["CoreStoragePhysicalVolumes"] as? [[String: Any]] ?? []
            let members = uniqued(physicalVolumes.compactMap { diskIdentifier(in: $0) })
            guard !members.isEmpty else { continue }
            let families = group["CoreStorageLogicalVolumeFamilies"] as? [[String: Any]] ?? []
            for family in families {
                for logicalVolume in family["CoreStorageLogicalVolumes"] as? [[String: Any]] ?? [] {
                    if let lvDisk = diskIdentifier(in: logicalVolume) {
                        map[lvDisk] = members
                    }
                }
            }
        }
        return map
    }

    /// AppleRAID set disk → member disks, from `diskutil appleRAID list -plist`.
    static func parseAppleRAIDMembers(_ plist: [String: Any]) -> [String: [String]] {
        guard let sets = plist["AppleRAIDSets"] as? [[String: Any]] else { return [:] }
        var map: [String: [String]] = [:]
        for raidSet in sets {
            guard let setDisk = (raidSet["BSDName"] as? String).map(wholeDiskName) else { continue }
            let members = uniqued((raidSet["Members"] as? [[String: Any]] ?? []).compactMap {
                ($0["BSDName"] as? String).map(wholeDiskName)
            })
            if !members.isEmpty {
                map[setDisk] = members
            }
        }
        return map
    }

    private static func diskIdentifier(in dict: [String: Any]) -> String? {
        (dict["DeviceIdentifier"] as? String ?? dict["CoreStorageDiskIdentifier"] as? String).map(wholeDiskName)
    }

    private static func plist(arguments: [String]) async -> [String: Any]? {
        let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
        guard let result = try? await ProcessRunner.run(diskutil, arguments: arguments, timeout: .seconds(20)),
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    /// "disk3s1s1" → "disk3".
    static func wholeDiskName(_ bsdName: String) -> String {
        guard bsdName.hasPrefix("disk") else { return bsdName }
        let digits = bsdName.dropFirst(4).prefix { $0.isNumber }
        return "disk\(digits)"
    }

    private static func uniqued(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }
}
