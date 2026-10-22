import Darwin
import Foundation

/// What makes up a volume scan's hidden space: used space the scan couldn't see.
public struct HiddenSpace: Sendable, Equatable {
    /// All hidden space, as computed from the volume's figures.
    public var total: Int64
    /// The other volumes sharing the scanned volume's APFS container, largest first.
    public var otherVolumes: [APFSVolumeUsage]
    /// Local snapshots of the scanned volume. Their space is already part of
    /// purgeable or still hidden space, and macOS doesn't report their sizes.
    public var snapshots: [APFSSnapshot]
    /// Folders the scan couldn't open; their contents are part of still hidden space.
    public var unreadableFolders: Int

    public init(total: Int64, otherVolumes: [APFSVolumeUsage] = [], snapshots: [APFSSnapshot] = [], unreadableFolders: Int = 0) {
        self.total = max(0, total)
        self.otherVolumes = otherVolumes.sorted { $0.size > $1.size }
        self.snapshots = snapshots
        self.unreadableFolders = unreadableFolders
    }

    /// Space used by other volumes, capped at the total in case the figures disagree.
    public var otherVolumesSize: Int64 {
        min(total, otherVolumes.reduce(0) { $0 + $1.size })
    }

    /// The remainder: unreadable folders, other users' files, file system overhead.
    public var stillHidden: Int64 { total - otherVolumesSize }

    /// Snapshots made by other apps (e.g. backup tools), which macOS never removes by itself.
    public var thirdPartySnapshots: [APFSSnapshot] { snapshots.filter { !$0.isMadeByMacOS } }
}

public struct APFSVolumeUsage: Sendable, Equatable {
    public var name: String
    /// APFS roles, e.g. ["System"], ["Preboot"], ["VM"]. Empty for user-created volumes.
    public var roles: [String]
    public var size: Int64

    public init(name: String, roles: [String], size: Int64) {
        self.name = name
        self.roles = roles
        self.size = size
    }

    /// What the volume is for, in plain words.
    public var purpose: String? {
        switch roles.first {
        case "System": "macOS itself"
        case "Preboot": "Startup files"
        case "Recovery": "Recovery system"
        case "VM": "Swap and sleep image"
        case "Update": "Software updates"
        case "Data": "Data volume"
        case nil: nil
        case let role?: role
        }
    }
}

public struct APFSSnapshot: Sendable, Equatable {
    public var name: String

    public init(name: String) {
        self.name = name
    }

    /// Time Machine and macOS updates name their snapshots com.apple.*.
    public var isMadeByMacOS: Bool { name.hasPrefix("com.apple.") }

}

/// Reads APFS container and snapshot details via `diskutil`, which needs no special rights.
public enum APFSInfo {
    /// The other volumes in the container holding the volume mounted at `path`,
    /// and that volume's snapshots. Empty for non-APFS volumes.
    public static func load(forVolumeAtPath path: String) -> (otherVolumes: [APFSVolumeUsage], snapshots: [APFSSnapshot]) {
        guard let device = deviceIdentifier(forPath: path) else { return ([], []) }
        let others = run(["apfs", "list", "-plist"]).map { otherVolumes(inList: $0, besides: device) } ?? []
        let snapshots = run(["apfs", "listSnapshots", device, "-plist"]).map(snapshots(inList:)) ?? []
        return (others, snapshots)
    }

    /// Parses `diskutil apfs list -plist`: every volume in the container that holds
    /// `device`, except `device` itself.
    static func otherVolumes(inList plist: Data, besides device: String) -> [APFSVolumeUsage] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]]
        else { return [] }

        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            guard volumes.contains(where: { $0["DeviceIdentifier"] as? String == device }) else { continue }
            return volumes.compactMap { volume in
                guard volume["DeviceIdentifier"] as? String != device,
                      let size = (volume["CapacityInUse"] as? NSNumber)?.int64Value
                else { return nil }
                return APFSVolumeUsage(
                    name: volume["Name"] as? String ?? "Untitled",
                    roles: volume["Roles"] as? [String] ?? [],
                    size: size
                )
            }
        }
        return []
    }

    /// Parses `diskutil apfs listSnapshots <device> -plist`.
    static func snapshots(inList plist: Data) -> [APFSSnapshot] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let snapshots = root["Snapshots"] as? [[String: Any]]
        else { return [] }
        return snapshots.compactMap { ($0["SnapshotName"] as? String).map(APFSSnapshot.init) }
    }

    /// e.g. "disk3s5" for the volume mounted at /System/Volumes/Data.
    static func deviceIdentifier(forPath path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let device = withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard device.hasPrefix("/dev/") else { return nil }
        return String(device.dropFirst("/dev/".count))
    }

    private static func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
