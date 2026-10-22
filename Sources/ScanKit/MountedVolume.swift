import Foundation

/// A user-visible mounted volume, as offered on the start screen.
public struct MountedVolume: Sendable, Identifiable, Equatable {
    public var id: String { mountPath }
    /// Where the volume is mounted, e.g. `/` or `/Volumes/Backup`.
    public let mountPath: String
    /// What to scan. For the startup disk this is the Data volume, which holds
    /// everything writable; the sealed system volume is read-only and firmlinked into it.
    public let scanPath: String
    public let space: VolumeSpace
    public let isInternal: Bool
    public let isEjectable: Bool
    /// Filesystem description, e.g. "APFS".
    public let format: String?

    public var isStartupDisk: Bool { mountPath == "/" }

    public static func all() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeLocalizedNameKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        let volumes = urls.compactMap { url -> MountedVolume? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isRoot = values?.volumeIsRootFileSystem == true || url.path == "/"
            let dataPath = "/System/Volumes/Data"
            let scanPath = isRoot && FileManager.default.fileExists(atPath: dataPath) ? dataPath : url.path

            guard var space = VolumeSpace.forVolume(atPath: scanPath), space.capacity > 0 else { return nil }
            if let name = values?.volumeLocalizedName { space.name = name }

            return MountedVolume(
                mountPath: url.path,
                scanPath: scanPath,
                space: space,
                isInternal: values?.volumeIsInternal ?? isRoot,
                isEjectable: values?.volumeIsEjectable ?? false,
                format: values?.volumeLocalizedFormatDescription
            )
        }

        return volumes.sorted { lhs, rhs in
            if lhs.isStartupDisk != rhs.isStartupDisk { return lhs.isStartupDisk }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.space.name.localizedStandardCompare(rhs.space.name) == .orderedAscending
        }
    }
}
