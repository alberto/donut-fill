import Darwin
import Foundation

/// Keeps scans from setting off macOS privacy prompts. Without Full Disk Access,
/// opening another app's container makes macOS ask whether the app may "access
/// data from other apps", and the scan waits until the user answers.
public enum PrivacyPrompts {
    /// Whether this process has Full Disk Access, judged by opening a file only
    /// it unlocks. Unlike opening a container, that never prompts.
    public static var hasFullDiskAccess: Bool {
        let fd = open(NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// The folders holding other apps' containers, also as seen from a scan of
    /// the Data volume.
    public static func appDataFolders(home: String = NSHomeDirectory()) -> Set<String> {
        let folders = [home + "/Library/Containers", home + "/Library/Group Containers"]
        return Set(folders + folders.map { "/System/Volumes/Data" + $0 })
    }

    /// Folders to pass as `ScanOptions.sealedFolders`: other apps' containers,
    /// unless the app has Full Disk Access.
    public static func foldersToSeal() -> Set<String> {
        hasFullDiskAccess ? [] : appDataFolders()
    }
}
