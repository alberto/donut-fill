import Foundation

/// A node in the scanned file tree. Built by the scanner; afterwards it is only
/// mutated through `removeFromParent()` and `replaceContents(with:)`, which
/// callers must do from one thread.
public final class FileNode: @unchecked Sendable, Identifiable {
    /// File name; for the scan root this is the full path that was scanned.
    public let name: String
    public let isDirectory: Bool
    /// A folder the scan couldn't open, so its size (beyond its own entry) is unknown.
    public private(set) var isUnreadable: Bool
    // 32 bits, next to the flags, so a node fits in 64 bytes rather than 80.
    private var storedFileCount: Int32
    /// Allocated bytes on disk, including all descendants.
    public private(set) var size: Int64
    /// Number of non-directory entries in this subtree.
    public private(set) var fileCount: Int {
        get { Int(storedFileCount) }
        set { storedFileCount = Int32(newValue) }
    }
    /// Children sorted by size, largest first.
    public private(set) var children: [FileNode]
    public private(set) weak var parent: FileNode?

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, size: Int64, fileCount: Int, children: [FileNode] = [], isUnreadable: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isUnreadable = isUnreadable
        self.size = size
        self.storedFileCount = Int32(fileCount)
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

    /// Takes over the children of `rescanned` (a fresh scan of this folder),
    /// updating the sizes of every ancestor. Keeps this node, so its identity
    /// (and color) stays the same.
    public func replaceContents(with rescanned: FileNode) {
        let sizeChange = rescanned.size - size
        let countChange = rescanned.fileCount - fileCount
        for child in children where child.parent === self { child.parent = nil }
        children = rescanned.children
        for child in children { child.parent = self }
        rescanned.children = []
        size = rescanned.size
        fileCount = rescanned.fileCount
        isUnreadable = rescanned.isUnreadable

        var ancestor = parent
        parent?.children.sort { $0.size > $1.size }
        while let node = ancestor {
            node.size += sizeChange
            node.fileCount += countChange
            node.parent?.children.sort { $0.size > $1.size }
            ancestor = node.parent
        }
    }

    /// Whether this node is still part of the tree under `root` (not deleted or replaced).
    public func isAttached(to root: FileNode) -> Bool {
        self === root || isDescendant(of: root)
    }

    /// Folders in this subtree the scan couldn't open, in tree order.
    public func unreadableDescendants() -> [FileNode] {
        var found: [FileNode] = []
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if node.isUnreadable { found.append(node) }
            stack.append(contentsOf: node.children.lazy.filter(\.isDirectory).reversed())
        }
        return found
    }

    /// Whether something still exists at this node's path. It may be gone if it
    /// was deleted, moved or renamed outside the app since the scan.
    public var existsOnDisk: Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
