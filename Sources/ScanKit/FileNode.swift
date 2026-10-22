import Foundation

/// A node in the scanned file tree. Immutable after the scan completes, except for
/// the back-pointer to its parent, which is wired once during construction.
public final class FileNode: @unchecked Sendable, Identifiable {
    /// File name; for the scan root this is the full path that was scanned.
    public let name: String
    public let isDirectory: Bool
    /// Allocated bytes on disk, including all descendants.
    public let size: Int64
    /// Number of non-directory entries in this subtree.
    public let fileCount: Int
    /// Children sorted by size, largest first.
    public let children: [FileNode]
    public private(set) weak var parent: FileNode?

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, size: Int64, fileCount: Int, children: [FileNode] = []) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.fileCount = fileCount
        self.children = children.sorted { $0.size > $1.size }
        for child in self.children { child.parent = self }
    }

    public var path: String {
        guard let parent else { return name }
        return (parent.path as NSString).appendingPathComponent(name)
    }

    public var displayName: String {
        parent == nil ? FileManager.default.displayName(atPath: name) : name
    }

    /// Nodes from the root down to and including this one.
    public var ancestry: [FileNode] {
        var chain: [FileNode] = []
        var node: FileNode? = self
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        return chain.reversed()
    }
}
