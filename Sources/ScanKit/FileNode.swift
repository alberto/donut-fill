import Foundation

/// A node in the scanned file tree. Built by the scanner; afterwards it is only
/// mutated through `removeFromParent()`, which callers must do from one thread.
public final class FileNode: @unchecked Sendable, Identifiable {
    /// File name; for the scan root this is the full path that was scanned.
    public let name: String
    public let isDirectory: Bool
    /// Allocated bytes on disk, including all descendants.
    public private(set) var size: Int64
    /// Number of non-directory entries in this subtree.
    public private(set) var fileCount: Int
    /// Children sorted by size, largest first.
    public private(set) var children: [FileNode]
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

    public func isDescendant(of other: FileNode) -> Bool {
        var node = parent
        while let current = node {
            if current === other { return true }
            node = current.parent
        }
        return false
    }

    /// Finds the node at an absolute path inside this subtree.
    public func descendant(atPath target: String) -> FileNode? {
        let base = path
        if target == base { return self }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard target.hasPrefix(prefix) else { return nil }

        var node = self
        for component in target.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    /// Detaches this node (e.g. after it was deleted on disk), subtracting its size
    /// from every ancestor and keeping each level sorted by size.
    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var ancestor: FileNode? = parent
        while let node = ancestor {
            node.size -= size
            node.fileCount -= fileCount
            node.parent?.children.sort { $0.size > $1.size }
            ancestor = node.parent
        }
        self.parent = nil
    }
}
