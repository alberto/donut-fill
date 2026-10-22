import Darwin
import Foundation
import os

/// How the scanner reads directories and schedules work.
public enum ScanEngine: String, Sendable, CaseIterable {
    /// `readdir` + `fstatat` per entry, depth-limited TaskGroups (the original scanner).
    case posix
    /// `getattrlistbulk`, depth-limited TaskGroups.
    case bulk
    /// `readdir` + `fstatat`, at most `workers` concurrent Swift tasks at any depth.
    case posixTasks = "posix-tasks"
    /// `getattrlistbulk`, at most `workers` concurrent Swift tasks at any depth.
    case bulkTasks = "bulk-tasks"
    /// `readdir` + `fstatat` on `workers` dedicated threads.
    case posixThreads = "posix-threads"
    /// `getattrlistbulk` on `workers` dedicated threads.
    case bulkThreads = "bulk-threads"
}

public struct ScanOptions: Sendable {
    /// Benchmarked fastest on APFS: see bench/RESULTS.md.
    public var engine = ScanEngine.bulkThreads
    /// Descend into other mounted volumes found below the scan root.
    public var crossDevices = false
    /// Directories shallower than this are scanned in parallel; deeper ones sequentially.
    public var parallelDepth = 4
    /// Concurrent directory readers, for engines that use a worker pool.
    public var workers = 8
    /// Folders whose subfolders aren't opened: they're listed with their own
    /// size and counted as unreadable. See `PrivacyPrompts`.
    public var sealedFolders: Set<String> = []

    public init() {}
}

/// Live counters a UI can poll while a scan is running.
public final class ScanProgress: Sendable {
    public struct Snapshot: Sendable {
        public var files = 0
        public var directories = 0
        public var bytes: Int64 = 0
        /// Directories that could not be opened (usually missing Full Disk Access).
        public var unreadable = 0

        public init() {}
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    public init() {}

    public var snapshot: Snapshot { state.withLock { $0 } }

    func record(files: Int, bytes: Int64) {
        state.withLock {
            $0.files += files
            $0.directories += 1
            $0.bytes += bytes
        }
    }

    func recordUnreadable() {
        state.withLock { $0.unreadable += 1 }
    }
}

public enum ScanError: Error, LocalizedError {
    case cannotStat(path: String, errno: Int32)
    case notADirectory(path: String)

    public var errorDescription: String? {
        switch self {
        case let .cannotStat(path, code): "Cannot read \(path): \(String(cString: strerror(code)))"
        case let .notADirectory(path): "\(path) is not a folder"
        }
    }
}

/// Walks a directory tree using POSIX calls (`readdir` + `fstatat`), which is
/// considerably faster than `FileManager` enumeration.
public struct Scanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public func scan(path: String, progress: ScanProgress = ScanProgress()) async throws -> FileNode {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ScanError.cannotStat(path: path, errno: errno) }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw ScanError.notADirectory(path: path) }

        let builder = TreeBuilder(rootName: path, rootBytes: Int64(st.st_blocks) * 512)
        // A sealed folder's subfolder (e.g. rescanning one) isn't opened either.
        if options.sealedFolders.contains((path as NSString).deletingLastPathComponent) {
            progress.recordUnreadable()
            builder.markUnreadable(0)
            return builder.finish()
        }
        let reader: DirectoryReader
        switch options.engine {
        case .posix:
            let walk = Walk(options: options, progress: progress, rootDevice: st.st_dev, builder: builder)
            await walk.directory(path: path, index: 0, depth: 0)
            try Task.checkCancellation()
            return builder.finish()
        case .bulk, .bulkTasks, .bulkThreads: reader = .bulk
        case .posixTasks, .posixThreads: reader = .posix
        }

        let context = WalkContext(reader: reader, options: options, progress: progress, rootDevice: st.st_dev, builder: builder)
        let rootDirectory = Subdirectory(name: path, path: path, index: 0)
        switch options.engine {
        case .posix, .bulk:
            await TaskWalk(context: context, policy: .depth(options.parallelDepth))
                .directory(rootDirectory, parent: nil, depth: 0)
        case .posixTasks, .bulkTasks:
            await TaskWalk(context: context, policy: .slots(options.workers))
                .directory(rootDirectory, parent: nil, depth: 0)
        case .posixThreads, .bulkThreads:
            await ThreadWalk(context: context, workers: options.workers).run(rootDirectory)
        }
        try Task.checkCancellation()
        return builder.finish()
    }
}

/// Data shared between several directory entries, counted only for the first one seen.
enum SharedDataKey: Hashable {
    /// Hard links to the same inode.
    case inode(device: dev_t, inode: ino_t)
    /// Full APFS clones (copies that share all their blocks).
    case clone(device: dev_t, cloneID: UInt64)
}

private final class Walk: Sendable {
    let options: ScanOptions
    let progress: ScanProgress
    let rootDevice: dev_t
    let builder: TreeBuilder
    /// Hard-linked files already counted, so each is only billed once.
    let seenLinks = OSAllocatedUnfairLock(initialState: Set<SharedDataKey>())

    init(options: ScanOptions, progress: ScanProgress, rootDevice: dev_t, builder: TreeBuilder) {
        self.options = options
        self.progress = progress
        self.rootDevice = rootDevice
        self.builder = builder
    }

    private struct Subdirectory {
        let path: String
        /// Position in the listing, then item number in the tree.
        var index: UInt32
    }

    /// Lists the folder at `path` (item `index` in the tree), then its subfolders.
    func directory(path: String, index: UInt32, depth: Int) async {
        if Task.isCancelled { return }

        var listing = TreeBuilder.Listing()
        var subdirectories: [Subdirectory] = []
        var files = 0
        var fileBytes: Int64 = 0

        // Read the whole directory and close it before recursing, so open
        // descriptors stay bounded by the parallelism, not the tree depth.
        guard let dir = opendir(path) else {
            progress.recordUnreadable()
            builder.markUnreadable(index)
            return
        }
        let fd = dirfd(dir)
        while let entry = readdir(dir) {
            withUnsafePointer(to: &entry.pointee.d_name) { rawName in
                rawName.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cName in
                    if cName[0] == 0x2E && (cName[1] == 0 || (cName[1] == 0x2E && cName[2] == 0)) { return }
                    var st = stat()
                    guard fstatat(fd, cName, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                    let bytes = Int64(st.st_blocks) * 512

                    if st.st_mode & S_IFMT == S_IFDIR {
                        // A different device means a mount point (another volume).
                        if st.st_dev != rootDevice && !options.crossDevices { return }
                        let entryName = String(cString: cName)
                        let entryPath = path == "/" ? "/" + entryName : path + "/" + entryName
                        let position = listing.append(name: cName, bytes: bytes, isDirectory: true)
                        subdirectories.append(Subdirectory(path: entryPath, index: UInt32(position)))
                        return
                    }
                    if st.st_nlink > 1 {
                        let key = SharedDataKey.inode(device: st.st_dev, inode: st.st_ino)
                        let isFirst = seenLinks.withLock { $0.insert(key).inserted }
                        if !isFirst { return }
                    }
                    files += 1
                    fileBytes += bytes
                    listing.append(name: cName, bytes: bytes, isDirectory: false)
                }
            }
        }
        closedir(dir)
        progress.record(files: files, bytes: fileBytes)
        let first = builder.add(listing, to: index)
        for position in subdirectories.indices { subdirectories[position].index += first }
        if options.sealedFolders.contains(path) {
            for sub in subdirectories {
                progress.recordUnreadable()
                builder.markUnreadable(sub.index)
            }
            return
        }

        if depth < options.parallelDepth && subdirectories.count > 1 {
            await withTaskGroup(of: Void.self) { group in
                for sub in subdirectories {
                    group.addTask { await self.directory(path: sub.path, index: sub.index, depth: depth + 1) }
                }
            }
        } else {
            for sub in subdirectories {
                await directory(path: sub.path, index: sub.index, depth: depth + 1)
            }
        }
    }
}
