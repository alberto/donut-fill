import Darwin
import Foundation
import os

/// State shared by every directory of one scan: what to skip, what was seen, what was counted.
final class WalkContext: Sendable {
    let reader: DirectoryReader
    let options: ScanOptions
    let progress: ScanProgress
    let rootDevice: dev_t
    let builder: TreeBuilder
    /// Hard links and clones already counted, so shared data is only billed once.
    let seenShared = OSAllocatedUnfairLock(initialState: Set<SharedDataKey>())
    let buffers = BufferPool()
    /// Open directory descriptors; above `handleBudget`, children open by path instead.
    let liveHandles = OSAllocatedUnfairLock(initialState: 0)
    let handleBudget = 128

    init(reader: DirectoryReader, options: ScanOptions, progress: ScanProgress, rootDevice: dev_t, builder: TreeBuilder) {
        self.reader = reader
        self.options = options
        self.progress = progress
        self.rootDevice = rootDevice
        self.builder = builder
    }

    /// Opens and lists a directory into the tree, then hands its descriptor on to
    /// its subdirectories, which it returns for the caller to schedule.
    /// Returns nil (and marks the folder unreadable) if it can't be opened.
    func read(_ sub: Subdirectory, from parent: ParentDirectory?, buffer: UnsafeMutableRawBufferPointer)
        -> ([Subdirectory], ParentDirectory)?
    {
        let opened = if let parent {
            parent.openChild(sub, live: liveHandles)
        } else {
            DirectoryHandle(fd: retryingInterrupts { Darwin.open(sub.path, directoryOpenFlags) }, live: liveHandles)
        }
        guard let handle = opened else {
            progress.recordUnreadable()
            builder.markUnreadable(sub.index)
            return nil
        }
        let subdirectories = list(handle, folder: sub, buffer: buffer)
        return (subdirectories, share(handle, children: subdirectories.count))
    }

    /// Reads one open directory into the tree and returns its subdirectories.
    private func list(_ handle: DirectoryHandle, folder: Subdirectory, buffer: UnsafeMutableRawBufferPointer) -> [Subdirectory] {
        var listing = TreeBuilder.Listing()
        var subdirectories: [Subdirectory] = []
        var files = 0
        var fileBytes: Int64 = 0
        reader.forEachEntry(in: handle.fd, buffer: buffer) { entry in
            if entry.isDirectory {
                // A different device means a mount point (another volume).
                if !options.crossDevices {
                    if entry.isMountPoint { return }
                    if let device = entry.device, device != rootDevice { return }
                }
                let name = String(cString: entry.name)
                let childPath = folder.path == "/" ? "/" + name : folder.path + "/" + name
                let position = listing.append(name: entry.name, bytes: entry.bytes, isDirectory: true)
                subdirectories.append(Subdirectory(name: name, path: childPath, index: UInt32(position)))
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
            files += 1
            fileBytes += bytes
            listing.append(name: entry.name, bytes: bytes, isDirectory: false)
        }
        progress.record(files: files, bytes: fileBytes)
        // Positions in the listing become item numbers once it's in the tree.
        let first = builder.add(listing, to: folder.index)
        for index in subdirectories.indices { subdirectories[index].index += first }
        if options.sealedFolders.contains(folder.path) {
            for sub in subdirectories {
                progress.recordUnreadable()
                builder.markUnreadable(sub.index)
            }
            return []
        }
        return subdirectories
    }

    /// Hands the descriptor to the subdirectories, unless too many are open already.
    private func share(_ handle: DirectoryHandle, children: Int) -> ParentDirectory {
        let underBudget = liveHandles.withLock { $0 <= handleBudget }
        return ParentDirectory(handle: underBudget ? handle : nil, children: children)
    }
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

    func directory(_ sub: Subdirectory, parent: ParentDirectory?, depth: Int) async {
        if Task.isCancelled {
            parent?.skipChild()
            return
        }
        guard let (subdirectories, shared) = context.buffers.withBuffer({ context.read(sub, from: parent, buffer: $0) }) else {
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for sub in subdirectories {
                if claimTask(depth: depth) {
                    group.addTask {
                        defer { self.releaseTask() }
                        await self.directory(sub, parent: shared, depth: depth + 1)
                    }
                } else {
                    await directory(sub, parent: shared, depth: depth + 1)
                }
            }
        }
    }
}

/// Walk on a fixed pool of dedicated threads pulling directories from a shared
/// stack. Blocking file system calls then never tie up Swift's cooperative
/// thread pool, and the number of concurrent readers is exactly `workers`.
final class ThreadWalk: @unchecked Sendable {
    private struct Item {
        let sub: Subdirectory
        let parent: ParentDirectory?
    }

    let context: WalkContext
    let workers: Int

    // Guarded by `condition`.
    private let condition = NSCondition()
    private var stack: [Item] = []
    private var busy = 0
    private var running = 0
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(context: WalkContext, workers: Int) {
        self.context = context
        self.workers = max(1, workers)
    }

    func run(_ rootDirectory: Subdirectory) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.withLock {
                    self.continuation = continuation
                    stack.append(Item(sub: rootDirectory, parent: nil))
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

        let finished = condition.withLock { () -> CheckedContinuation<Void, Never>? in
            running -= 1
            guard running == 0, let continuation else { return nil }
            self.continuation = nil
            return continuation
        }
        finished?.resume()
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
        if cancelled {
            item.parent?.skipChild()
            return
        }
        guard let (subdirectories, shared) = context.read(item.sub, from: item.parent, buffer: buffer),
              !subdirectories.isEmpty
        else { return }
        let items = subdirectories.reversed().map { Item(sub: $0, parent: shared) }
        condition.withLock {
            stack.append(contentsOf: items)
            if items.count > 1 { condition.broadcast() } else { condition.signal() }
        }
    }
}
