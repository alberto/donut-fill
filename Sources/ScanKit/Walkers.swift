import Darwin
import Foundation
import os

/// State shared by every directory of one scan: what to skip, what was seen, what was counted.
final class WalkContext: Sendable {
    let reader: DirectoryReader
    let options: ScanOptions
    let progress: ScanProgress
    let rootDevice: dev_t
    /// Hard links and clones already counted, so shared data is only billed once.
    let seenShared = OSAllocatedUnfairLock(initialState: Set<SharedDataKey>())
    let buffers = BufferPool()
    /// Open directory descriptors; above `handleBudget`, children open by path instead.
    let liveHandles = OSAllocatedUnfairLock(initialState: 0)
    let handleBudget = 128

    init(reader: DirectoryReader, options: ScanOptions, progress: ScanProgress, rootDevice: dev_t) {
        self.reader = reader
        self.options = options
        self.progress = progress
        self.rootDevice = rootDevice
    }

    struct Listing {
        var children: [FileNode] = []
        var subdirectories: [Subdirectory] = []
    }

    /// Opens and lists a directory, then hands its descriptor on to its subdirectories.
    /// Returns nil (and counts the folder as unreadable) if it can't be opened.
    func read(_ sub: Subdirectory, from parent: ParentDirectory?, buffer: UnsafeMutableRawBufferPointer)
        -> (Listing, ParentDirectory)?
    {
        let opened = if let parent {
            parent.openChild(sub, live: liveHandles)
        } else {
            DirectoryHandle(fd: retryingInterrupts { Darwin.open(sub.path, directoryOpenFlags) }, live: liveHandles)
        }
        guard let handle = opened else {
            progress.recordUnreadable()
            return nil
        }
        let listing = list(handle, path: sub.path, buffer: buffer)
        return (listing, share(handle, children: listing.subdirectories.count))
    }

    /// Reads one open directory: files become nodes, subdirectories are returned for the caller to schedule.
    private func list(_ handle: DirectoryHandle, path: String, buffer: UnsafeMutableRawBufferPointer) -> Listing {
        var listing = Listing()
        var fileBytes: Int64 = 0
        reader.forEachEntry(in: handle.fd, buffer: buffer) { entry in
            let name = String(cString: entry.name)
            if entry.isDirectory {
                // A different device means a mount point (another volume).
                if !options.crossDevices {
                    if entry.isMountPoint { return }
                    if let device = entry.device, device != rootDevice { return }
                }
                let childPath = path == "/" ? "/" + name : path + "/" + name
                listing.subdirectories.append(Subdirectory(name: name, path: childPath, ownBytes: entry.bytes))
                return
            }
            let device = entry.device ?? rootDevice
            if entry.linkCount > 1 {
                // Later hard links are left out, as they're the same file.
                let key = SharedDataKey.inode(device: device, inode: ino_t(entry.inode))
                guard seenShared.withLock({ $0.insert(key).inserted }) else { return }
            }
            var bytes = entry.bytes
            if entry.cloneCount > 1, let cloneID = entry.cloneID {
                let key = SharedDataKey.clone(device: device, cloneID: cloneID)
                if !seenShared.withLock({ $0.insert(key).inserted }) {
                    // Later clones stay listed, but at 0 bytes: their data is already counted.
                    bytes = 0
                }
            }
            fileBytes += bytes
            listing.children.append(FileNode(name: name, isDirectory: false, size: bytes, fileCount: 1))
        }
        progress.record(files: listing.children.count, bytes: fileBytes)
        listing.children.reserveCapacity(listing.children.count + listing.subdirectories.count)
        return listing
    }

    /// Hands the descriptor to the subdirectories, unless too many are open already.
    private func share(_ handle: DirectoryHandle, children: Int) -> ParentDirectory {
        let underBudget = liveHandles.withLock { $0 <= handleBudget }
        return ParentDirectory(handle: underBudget ? handle : nil, children: children)
    }
}

func directoryNode(name: String, ownBytes: Int64, children: [FileNode]) -> FileNode {
    var size = ownBytes
    var fileCount = 0
    for child in children {
        size += child.size
        fileCount += child.fileCount
    }
    return FileNode(name: name, isDirectory: true, size: size, fileCount: fileCount, children: children)
}

/// Recursive walk on Swift tasks. Subdirectories get their own child task
/// while the spawn policy allows it and are walked inline otherwise.
final class TaskWalk: Sendable {
    enum Policy: Sendable {
        /// Every subdirectory shallower than this depth gets a task (the original scheme).
        case depth(Int)
        /// At most this many child tasks exist at once, at any depth.
        case slots(Int)
    }

    let context: WalkContext
    let policy: Policy
    private let usedSlots = OSAllocatedUnfairLock(initialState: 0)

    init(context: WalkContext, policy: Policy) {
        self.context = context
        self.policy = policy
    }

    private func claimTask(depth: Int) -> Bool {
        switch policy {
        case let .depth(limit):
            return depth < limit
        case let .slots(limit):
            return usedSlots.withLock { used in
                guard used < limit else { return false }
                used += 1
                return true
            }
        }
    }

    private func releaseTask() {
        if case .slots = policy { usedSlots.withLock { $0 -= 1 } }
    }

    func directory(_ sub: Subdirectory, parent: ParentDirectory?, depth: Int) async -> FileNode {
        if Task.isCancelled {
            parent?.skipChild()
            return sub.emptyNode()
        }
        guard let (listing, shared) = context.buffers.withBuffer({ context.read(sub, from: parent, buffer: $0) }) else {
            return sub.unreadableNode()
        }
        var children = listing.children
        await withTaskGroup(of: FileNode.self) { group in
            for sub in listing.subdirectories {
                if claimTask(depth: depth) {
                    group.addTask {
                        defer { self.releaseTask() }
                        return await self.directory(sub, parent: shared, depth: depth + 1)
                    }
                } else {
                    children.append(await directory(sub, parent: shared, depth: depth + 1))
                }
            }
            for await node in group { children.append(node) }
        }
        return directoryNode(name: sub.name, ownBytes: sub.ownBytes, children: children)
    }
}

/// Walk on a fixed pool of dedicated threads pulling directories from a shared
/// stack. Blocking file system calls then never tie up Swift's cooperative
/// thread pool, and the number of concurrent readers is exactly `workers`.
final class ThreadWalk: @unchecked Sendable {
    /// A directory whose subdirectories are still being walked.
    private final class Pending: Sendable {
        let name: String
        let ownBytes: Int64
        let parent: Pending?
        let state: OSAllocatedUnfairLock<(children: [FileNode], unfinished: Int)>

        init(name: String, ownBytes: Int64, parent: Pending?, children: [FileNode], unfinished: Int) {
            self.name = name
            self.ownBytes = ownBytes
            self.parent = parent
            state = OSAllocatedUnfairLock(initialState: (children, unfinished))
        }
    }

    private struct Item {
        let sub: Subdirectory
        let parent: ParentDirectory?
        let pendingParent: Pending?
    }

    let context: WalkContext
    let workers: Int

    // Guarded by `condition`.
    private let condition = NSCondition()
    private var stack: [Item] = []
    private var busy = 0
    private var running = 0
    private var cancelled = false
    private var root: FileNode?
    private var continuation: CheckedContinuation<FileNode, Never>?

    init(context: WalkContext, workers: Int) {
        self.context = context
        self.workers = max(1, workers)
    }

    func run(_ rootDirectory: Subdirectory) async -> FileNode {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.withLock {
                    self.continuation = continuation
                    stack.append(Item(sub: rootDirectory, parent: nil, pendingParent: nil))
                    running = workers
                }
                for index in 0..<workers {
                    let thread = Thread { [self] in work() }
                    thread.name = "ScanKit walker \(index)"
                    thread.qualityOfService = .userInitiated
                    thread.start()
                }
            }
        } onCancel: {
            condition.withLock { cancelled = true }
        }
    }

    private func work() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BufferPool.bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while let (item, isCancelled) = next() {
            process(item, cancelled: isCancelled, buffer: buffer)
            condition.withLock {
                busy -= 1
                if stack.isEmpty && busy == 0 { condition.broadcast() }
            }
        }

        let finished = condition.withLock { () -> (CheckedContinuation<FileNode, Never>, FileNode)? in
            running -= 1
            guard running == 0, let continuation, let root else { return nil }
            self.continuation = nil
            return (continuation, root)
        }
        if let (continuation, root) = finished { continuation.resume(returning: root) }
    }

    /// Blocks until there is work; nil once the whole tree is done.
    private func next() -> (Item, Bool)? {
        condition.withLock {
            while stack.isEmpty {
                if busy == 0 { return nil }
                condition.wait()
            }
            busy += 1
            return (stack.removeLast(), cancelled)
        }
    }

    private func process(_ item: Item, cancelled: Bool, buffer: UnsafeMutableRawBufferPointer) {
        let sub = item.sub
        if cancelled {
            item.parent?.skipChild()
            finish(sub.emptyNode(), parent: item.pendingParent)
            return
        }
        guard let (listing, shared) = context.read(sub, from: item.parent, buffer: buffer) else {
            finish(sub.unreadableNode(), parent: item.pendingParent)
            return
        }
        if listing.subdirectories.isEmpty {
            finish(directoryNode(name: sub.name, ownBytes: sub.ownBytes, children: listing.children), parent: item.pendingParent)
            return
        }
        let pending = Pending(
            name: sub.name, ownBytes: sub.ownBytes, parent: item.pendingParent,
            children: listing.children, unfinished: listing.subdirectories.count
        )
        let items = listing.subdirectories.reversed().map { Item(sub: $0, parent: shared, pendingParent: pending) }
        condition.withLock {
            stack.append(contentsOf: items)
            if items.count > 1 { condition.broadcast() } else { condition.signal() }
        }
    }

    /// Attaches a finished directory to its parent, completing every ancestor whose last child this was.
    private func finish(_ node: FileNode, parent: Pending?) {
        var node = node
        var parent = parent
        while let pending = parent {
            let child = node
            let children = pending.state.withLock { state -> [FileNode]? in
                state.children.append(child)
                state.unfinished -= 1
                guard state.unfinished == 0 else { return nil }
                defer { state.children = [] }
                return state.children
            }
            guard let children else { return }
            node = directoryNode(name: pending.name, ownBytes: pending.ownBytes, children: children)
            parent = pending.parent
        }
        condition.withLock { root = node }
    }
}
