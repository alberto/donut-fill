import Foundation
import os

/// Storage for one scanned tree. Every item is a number indexing flat arrays,
/// not an object of its own, so an item costs about 25 bytes plus its name.
///
/// Items are numbered in the order they're added. A folder's children are
/// added together, after the folder itself, so a child's number is always
/// larger than its parent's.
///
/// Not thread-safe: after building, use from one thread.
final class FileTree: @unchecked Sendable {
    static let none = UInt32.max

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let directory = Flags(rawValue: 1 << 0)
        static let unreadable = Flags(rawValue: 1 << 1)
    }

    struct Folder {
        /// The folder's children are `order[childStart ..< childStart + childCount]`.
        var childStart: UInt32 = 0
        var childCount: UInt32 = 0
        var fileCount: UInt32 = 0
    }

    let sizes = ChunkedArray<Int64>()
    let parents = ChunkedArray<UInt32>()
    let flags = ChunkedArray<Flags>()
    let nameStarts = ChunkedArray<UInt32>()
    let names = NameStore()
    /// Each item's index in `folders`, or `none` for files.
    let folderIndices = ChunkedArray<UInt32>()
    let folders = ChunkedArray<Folder>()
    /// Every folder's children as one run each, sorted by size (largest first).
    let order = ChunkedArray<UInt32>()

    var count: Int { sizes.count }

    /// A tree holding just its root.
    init(rootName: String, size: Int64, isDirectory: Bool = true, isUnreadable: Bool = false) {
        var flags: Flags = isDirectory ? .directory : []
        if isUnreadable { flags.insert(.unreadable) }
        var name = rootName
        _ = name.withUTF8 { append(name: $0, size: size, flags: flags, parent: FileTree.none) }
    }

    // MARK: Reading

    func name(of item: UInt32) -> String {
        String(decoding: names[nameStarts[item]], as: UTF8.self)
    }

    func isDirectory(_ item: UInt32) -> Bool { flags[item].contains(.directory) }

    func folder(_ item: UInt32) -> Folder? {
        let index = folderIndices[item]
        return index == FileTree.none ? nil : folders[index]
    }

    func fileCount(of item: UInt32) -> Int {
        folder(item).map { Int($0.fileCount) } ?? 1
    }

    /// The children of `item` in size order, or none for a file.
    func children(of item: UInt32) -> [UInt32] {
        guard let folder = folder(item) else { return [] }
        return (folder.childStart..<folder.childStart + folder.childCount).map { order[$0] }
    }

    // MARK: Building

    /// Adds an item. A folder's children must be added in one go, right after
    /// `startChildren(of:)`.
    @discardableResult
    func append(name: UnsafeBufferPointer<UInt8>, size: Int64, flags: Flags, parent: UInt32, fileCount: UInt32 = 0) -> UInt32 {
        let item = UInt32(count)
        sizes.append(size)
        parents.append(parent)
        self.flags.append(flags)
        nameStarts.append(names.append(name))
        order.append(item)
        if flags.contains(.directory) {
            folderIndices.append(UInt32(folders.count))
            folders.append(Folder(fileCount: fileCount))
        } else {
            folderIndices.append(FileTree.none)
        }
        if parent != FileTree.none {
            folders[folderIndices[parent]].childCount += 1
        }
        return item
    }

    /// Makes the items added next the children of `folder`, replacing any it had.
    func startChildren(of folder: UInt32) {
        let index = folderIndices[folder]
        folders[index].childStart = UInt32(count)
        folders[index].childCount = 0
    }

    func markUnreadable(_ item: UInt32) {
        flags[item].insert(.unreadable)
    }

    /// After a scan, when folders hold only their own size: adds up every
    /// folder's size and file count, then sorts each folder's children.
    func finishScan() {
        for item in stride(from: UInt32(count - 1), to: 0, by: -1) {
            let parent = parents[item]
            sizes[parent] += sizes[item]
            let own = folderIndices[item]
            folders[folderIndices[parent]].fileCount += own == FileTree.none ? 1 : folders[own].fileCount
        }
        for folder in 0..<UInt32(folders.count) {
            sortChildren(ofFolderAt: folder)
        }
    }

    private func sortChildren(ofFolderAt index: UInt32) {
        let folder = folders[index]
        guard folder.childCount > 1 else { return }
        let range = folder.childStart..<folder.childStart + folder.childCount
        let sorted = range.map { order[$0] }.sorted { sizes[$0] > sizes[$1] }
        for (slot, item) in zip(range, sorted) { order[slot] = item }
    }

    func sortChildren(of item: UInt32) {
        sortChildren(ofFolderAt: folderIndices[item])
    }

    /// Copies `source`'s children (and everything below them) from another tree
    /// in as the children of `folder`, which must be a folder.
    func copyChildren(of source: FileNode, into folder: UInt32) {
        let other = source.tree
        precondition(other !== self, "copying within one tree")
        var pending: [(source: UInt32, target: UInt32)] = [(source.index, folder)]
        while let (sourceFolder, targetFolder) = pending.popLast() {
            guard other.isDirectory(sourceFolder) else { continue }
            startChildren(of: targetFolder)
            for child in other.children(of: sourceFolder) {
                let copied = append(
                    name: other.names[other.nameStarts[child]],
                    size: other.sizes[child],
                    flags: other.flags[child],
                    parent: targetFolder,
                    fileCount: other.folder(child)?.fileCount ?? 0
                )
                if other.isDirectory(child) { pending.append((child, copied)) }
            }
        }
    }

    // MARK: Editing

    /// Takes `item` out of its parent's children and subtracts its size and
    /// file count from every ancestor, keeping each level sorted.
    func remove(_ item: UInt32) {
        let parent = parents[item]
        guard parent != FileTree.none else { return }
        let index = folderIndices[parent]
        let start = folders[index].childStart
        let end = start + folders[index].childCount
        if let slot = (start..<end).first(where: { order[$0] == item }) {
            for next in slot..<end - 1 { order[next] = order[next + 1] }
            folders[index].childCount -= 1
        }
        parents[item] = FileTree.none
        adjustAncestors(from: parent, size: -sizes[item], fileCount: -fileCount(of: item))
    }

    /// Replaces `folder`'s contents with those of `rescanned`, the root of a
    /// fresh scan of the same folder. The old contents are left unused.
    func replaceContents(of folder: UInt32, with rescanned: FileNode) {
        let index = folderIndices[folder]
        for child in children(of: folder) { parents[child] = FileTree.none }
        let oldFileCount = Int(folders[index].fileCount)
        copyChildren(of: rescanned, into: folder)

        let sizeChange = rescanned.size - sizes[folder]
        let countChange = rescanned.fileCount - oldFileCount
        sizes[folder] = rescanned.size
        folders[index].fileCount = UInt32(rescanned.fileCount)
        if rescanned.isUnreadable { flags[folder].insert(.unreadable) } else { flags[folder].remove(.unreadable) }
        let parent = parents[folder]
        if parent != FileTree.none {
            sortChildren(of: parent)
            adjustAncestors(from: parent, size: sizeChange, fileCount: countChange)
        }
    }

    /// Adds to the size and file count of `item` and everything above it, re-sorting each level.
    private func adjustAncestors(from item: UInt32, size: Int64, fileCount: Int) {
        var ancestor = item
        while ancestor != FileTree.none {
            sizes[ancestor] += size
            let index = folderIndices[ancestor]
            folders[index].fileCount = UInt32(Int(folders[index].fileCount) + fileCount)
            let next = parents[ancestor]
            if next != FileTree.none { sortChildren(of: next) }
            ancestor = next
        }
    }
}

/// A growable array stored in fixed-size chunks. Growing never copies what's
/// stored, so a big array costs about its contents even while it grows (a
/// Swift array doubles and copies, briefly needing three times its size).
final class ChunkedArray<Element: BitwiseCopyable> {
    private static var shift: Int { 16 }
    private static var mask: Int { (1 << shift) - 1 }

    private var chunks: [UnsafeMutablePointer<Element>] = []
    private(set) var count = 0

    deinit {
        for chunk in chunks { chunk.deallocate() }
    }

    func append(_ element: Element) {
        if count >> Self.shift == chunks.count {
            chunks.append(.allocate(capacity: 1 << Self.shift))
        }
        (chunks[count >> Self.shift] + (count & Self.mask)).initialize(to: element)
        count += 1
    }

    subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count, "index out of range")
            return chunks[index >> Self.shift][index & Self.mask]
        }
        set {
            precondition(index >= 0 && index < count, "index out of range")
            chunks[index >> Self.shift][index & Self.mask] = newValue
        }
    }

    subscript(index: UInt32) -> Element {
        get { self[Int(index)] }
        set { self[Int(index)] = newValue }
    }
}

/// Item names, NUL-terminated, packed into 1 MB chunks.
final class NameStore {
    private static var chunkSize: Int { 1 << 20 }

    private var chunks: [UnsafeMutablePointer<UInt8>] = []
    /// Bytes used in the last chunk.
    private var used = chunkSize

    deinit {
        for chunk in chunks { chunk.deallocate() }
    }

    /// Stores `name`; returns where it starts.
    func append(_ name: UnsafeBufferPointer<UInt8>) -> UInt32 {
        precondition(name.count < Self.chunkSize, "name too long")
        if used + name.count + 1 > Self.chunkSize {
            chunks.append(.allocate(capacity: Self.chunkSize))
            used = 0
        }
        let start = (chunks.count - 1) * Self.chunkSize + used
        precondition(start <= Int(UInt32.max), "names too large")
        let destination = chunks[chunks.count - 1] + used
        if let source = name.baseAddress {
            destination.update(from: source, count: name.count)
        }
        destination[name.count] = 0
        used += name.count + 1
        return UInt32(start)
    }

    /// The name starting at `start`, valid as long as the store is.
    subscript(start: UInt32) -> UnsafeBufferPointer<UInt8> {
        let start = Int(start)
        let pointer = chunks[start / Self.chunkSize] + start % Self.chunkSize
        return UnsafeBufferPointer(start: pointer, count: strlen(pointer))
    }
}

/// Builds a `FileTree` from many scanning threads at once: each folder's
/// listing is added in one locked step.
final class TreeBuilder: @unchecked Sendable {
    private let tree: FileTree
    private let lock = OSAllocatedUnfairLock()

    init(rootName: String, rootBytes: Int64) {
        tree = FileTree(rootName: rootName, size: rootBytes)
    }

    /// One folder's entries, collected before they're added.
    struct Listing {
        fileprivate var names: [UInt8] = []
        fileprivate var nameEnds: [Int] = []
        fileprivate var sizes: [Int64] = []
        fileprivate var isDirectory: [Bool] = []

        var count: Int { sizes.count }

        /// Adds an entry; returns its position, which `add` turns into its item number.
        @discardableResult
        mutating func append(name: UnsafePointer<CChar>, bytes: Int64, isDirectory: Bool) -> Int {
            name.withMemoryRebound(to: UInt8.self, capacity: 1) { pointer in
                names.append(contentsOf: UnsafeBufferPointer(start: pointer, count: strlen(name)))
            }
            nameEnds.append(names.count)
            sizes.append(bytes)
            self.isDirectory.append(isDirectory)
            return sizes.count - 1
        }
    }

    /// Adds `listing` as the children of `folder`; returns the first child's item
    /// number (the others follow in listing order).
    func add(_ listing: Listing, to folder: UInt32) -> UInt32 {
        lock.withLockUnchecked {
            tree.startChildren(of: folder)
            let first = UInt32(tree.count)
            listing.names.withUnsafeBufferPointer { names in
                var start = 0
                for entry in 0..<listing.count {
                    let end = listing.nameEnds[entry]
                    tree.append(
                        name: UnsafeBufferPointer(rebasing: names[start..<end]),
                        size: listing.sizes[entry],
                        flags: listing.isDirectory[entry] ? .directory : [],
                        parent: folder
                    )
                    start = end
                }
            }
            return first
        }
    }

    func markUnreadable(_ folder: UInt32) {
        lock.withLockUnchecked { tree.markUnreadable(folder) }
    }

    /// Call once every folder has been added.
    func finish() -> FileNode {
        lock.withLockUnchecked { tree.finishScan() }
        return FileNode(tree: tree, index: 0)
    }
}
