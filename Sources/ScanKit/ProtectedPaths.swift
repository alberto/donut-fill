import Foundation

/// Paths the Collector refuses, because trashing them would break macOS, an app
/// install, or the user's account. Folders inside most of them are still fine;
/// only macOS's own folders are protected as a whole.
public struct ProtectedPaths: Sendable {
    /// The user's home folder, e.g. "/Users/alberto".
    public let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = Self.trimmed(home)
    }

    /// Owned by macOS, together with everything inside.
    private static let systemTrees = ["/System", "/bin", "/sbin", "/usr", "/private/etc", "/private/var/db"]
    /// Exceptions inside `systemTrees` whose contents the user manages.
    private static let userTreesInsideSystem = ["/usr/local"]
    /// Top-level folders that must stay, though their contents can go.
    private static let fixedFolders = [
        "/", "/Applications", "/Applications/Utilities", "/Library", "/Users", "/Volumes",
        "/private", "/private/var", "/private/tmp", "/opt", "/cores", "/usr/local",
    ]
    /// Folders in the home folder that macOS and apps expect to exist.
    private static let homeFolders = [
        "Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
    ]

    /// Why `path` can't be collected, or nil if it can.
    public func refusal(forPath path: String) -> String? {
        let path = Self.normalized(path)
        let name = (path as NSString).lastPathComponent

        if path == home {
            return "Your home folder can't be collected."
        }
        if Self.homeFolders.contains(where: { path == (home as NSString).appendingPathComponent($0) }) {
            return "“\(name)” is a standard folder in your home. Collect what’s inside it instead."
        }
        if Self.fixedFolders.contains(path) {
            return "“\(name)” is required by macOS. Collect what’s inside it instead."
        }
        if Self.isInside(path, anyOf: Self.systemTrees), !Self.isInside(path, anyOf: Self.userTreesInsideSystem) {
            return "“\(name)” is part of macOS and can't be collected."
        }
        if (path as NSString).deletingLastPathComponent == "/Volumes" {
            return "“\(name)” is a mounted volume. Collect what’s inside it instead."
        }
        return nil
    }

    /// Maps paths reached through the data volume (as in a whole-disk scan of
    /// /System/Volumes/Data) to their usual firmlinked form, so rules match either way.
    static func normalized(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        var path = trimmed(path)
        if path == data {
            path = "/"
        } else if path.hasPrefix(data + "/") {
            path = String(path.dropFirst(data.count))
        }
        return path
    }

    /// Drops a trailing slash. Not `standardizingPath`, which turns /private/var into /var.
    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func isInside(_ path: String, anyOf roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
