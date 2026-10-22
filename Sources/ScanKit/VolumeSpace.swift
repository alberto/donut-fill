import Foundation

/// Capacity figures for the volume a scan started at, used to show the scan in
/// proportion to the whole drive (free space as a gap, unscanned space as grey).
public struct VolumeSpace: Sendable, Equatable {
    public var name: String
    /// Total capacity. On APFS this is the container, shared with sibling volumes.
    public var capacity: Int64
    /// Bytes free right now.
    public var available: Int64
    /// Bytes macOS says it can free for important work, which includes purgeable data.
    public var availableIncludingPurgeable: Int64

    public init(name: String, capacity: Int64, available: Int64, availableIncludingPurgeable: Int64) {
        self.name = name
        self.capacity = capacity
        self.available = available
        self.availableIncludingPurgeable = availableIncludingPurgeable
    }

    public var free: Int64 { max(0, available) }
    public var purgeable: Int64 { max(0, availableIncludingPurgeable - available) }

    /// Space in use that the scan didn't find: other volumes in the container,
    /// snapshots, and folders that couldn't be read.
    public func hidden(scanned: Int64) -> Int64 {
        max(0, capacity - free - purgeable - scanned)
    }

    /// Returns nil unless `path` is the root of a mounted volume.
    public static func forVolume(atPath path: String) -> VolumeSpace? {
        let keys: Set<URLResourceKey> = [
            .isVolumeKey,
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              values.isVolume == true,
              let capacity = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity
        else { return nil }

        return VolumeSpace(
            name: values.volumeLocalizedName ?? path,
            capacity: Int64(capacity),
            available: Int64(available),
            availableIncludingPurgeable: values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        )
    }
}
