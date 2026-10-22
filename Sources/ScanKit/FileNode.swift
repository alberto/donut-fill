import Foundation

/// A node in the scanned file tree: a handle to one item of a `FileTree`.
/// Built by the scanner; afterwards the tree is only mutated through
/// `removeFromParent()` and `replaceContents(with:)`, which callers must do
/// from one thread.
public struct FileNode: Hashable, Identifiable, Sendable {
    let tree: FileTree
    let index: UInt32

    init(tree: FileTree, index: UInt32) {
        self.tree = tree
        self.index = index
    }

    /// The root of a new tree holding copies of `children` and their contents; for tests.
    init(name: String, isDirectory: Bool, size: Int64, fileCount: Int, children: [FileNode] = [], isUnreadable: Bool = false) {
        tree = FileTree(rootName: name, size: size, isDirectory: isDirectory, isUnreadable: isUnreadable)
        index = 0
        guard isDirectory else { return }
        tree.folders[0].fileCount = UInt32(fileCount)
        tree.startChildren(of: 0)
        let copies = children.sorted { $0.size > $1.size }.map { child in
            var name = child.name
            let copy = name.withUTF8 {
                tree.append(
                    name: $0,
                    size: child.size,
                    flags: child.tree.flags[Int(child.index)],
                    parent: 0,
                    fileCount: child.isDirectory ? UInt32(child.fileCount) : 0
                )
            }
            return (child, copy)
        }
        for (child, copy) in copies where child.isDirectory {
            tree.copyChildren(of: child, into: copy)
        }
    }

    public var id: FileNode { self }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.index == rhs.index && lhs.tree === rhs.tree
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(index)
        hasher.combine(ObjectIdentifier(tree))
    }

    /// File name; for the scan root this is the full path that was scanned.
    public var name: String { tree.name(of: index) }
    public var isDirectory: Bool { tree.isDirectory(index) }
    /// A folder the scan couldn't open, so its size (beyond its own entry) is unknown.
    public var isUnreadable: Bool { tree.flags[Int(index)].contains(.unreadable) }
    /// Allocated bytes on disk, including all descendants.
    public var size: Int64 { tree.sizes[Int(index)] }
    /// Number of non-directory entries in this subtree.
    public var fileCount: Int { tree.fileCount(of: index) }

    /// Children sorted by size, largest first, as they are now: later changes
    /// to the tree don't show in a collection taken earlier.
    public var children: Children {
        Children(tree: tree, items: tree.children(of: index))
    }

    public var parent: FileNode? {
        let parent = tree.parents[Int(index)]
        return parent == FileTree.none ? nil : FileNode(tree: tree, index: parent)
    }

    public struct Children: RandomAccessCollection, Sendable {
        let tree: FileTree
        let items: [UInt32]

        public var startIndex: Int { 0 }
        public var endIndex: Int { items.count }

        public subscript(position: Int) -> FileNode {
            FileNode(tree: tree, index: items[position])
        }
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
        guard tree === other.tree else { return false }
        var item = tree.parents[Int(index)]
        while item != FileTree.none {
            if item == other.index { return true }
            item = tree.parents[Int(item)]
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
        tree.remove(index)
    }

    /// Takes over the contents of `rescanned` (a fresh scan of this folder),
    /// updating the sizes of every ancestor. Keeps this node, so its identity
    /// (and color) stays the same. The old contents stay in memory, unused.
    public func replaceContents(with rescanned: FileNode) {
        tree.replaceContents(of: index, with: rescanned)
    }

    /// Whether this node is still part of the tree under `root` (not deleted or replaced).
    public func isAttached(to root: FileNode) -> Bool {
        self == root || isDescendant(of: root)
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
