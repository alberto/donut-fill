import Darwin
import os

/// How a directory's entries and their sizes are fetched.
enum DirectoryReader: Sendable {
    /// `readdir`, then `fstatat` for every entry: one syscall per entry.
    case posix
    /// `getattrlistbulk`: names and attributes for many entries per syscall.
    case bulk
}

/// One directory entry as reported by a reader. `name` is only valid during the callback.
struct RawEntry {
    var name: UnsafePointer<CChar>
    var isDirectory: Bool
    /// A directory another volume is mounted on, or an automount trigger.
    var isMountPoint = false
    /// nil if the file system didn't report it; treated as the scan's own device.
    var device: dev_t?
    var inode: UInt64
    /// Allocated bytes on disk.
    var bytes: Int64
    var linkCount: UInt32
}

/// An open directory descriptor, closed when the last reference goes away.
final class DirectoryHandle: Sendable {
    let fd: Int32
    private let live: OSAllocatedUnfairLock<Int>

    init?(fd: Int32, live: OSAllocatedUnfairLock<Int>) {
        guard fd >= 0 else { return nil }
        self.fd = fd
        self.live = live
        live.withLock { $0 += 1 }
    }

    deinit {
        close(fd)
        live.withLock { $0 -= 1 }
    }
}

/// A listed directory whose subdirectories still have to be opened. They open
/// relative to its descriptor (`openat`), so the kernel doesn't resolve the
/// whole path again; the descriptor is dropped once every child has opened.
final class ParentDirectory: Sendable {
    private let state: OSAllocatedUnfairLock<(handle: DirectoryHandle?, unopened: Int)>

    init(handle: DirectoryHandle?, children: Int) {
        state = OSAllocatedUnfairLock(initialState: (children > 0 ? handle : nil, children))
    }

    func openChild(_ sub: Subdirectory, live: OSAllocatedUnfairLock<Int>) -> DirectoryHandle? {
        let handle = state.withLock { $0.handle }
        let fd = retryingInterrupts {
            if let handle { openat(handle.fd, sub.name, directoryOpenFlags) } else { open(sub.path, directoryOpenFlags) }
        }
        let opened = DirectoryHandle(fd: fd, live: live)
        skipChild()
        return opened
    }

    /// Records that a child won't be opened (e.g. after cancellation).
    func skipChild() {
        let released = state.withLock { state -> DirectoryHandle? in
            state.unopened -= 1
            guard state.unopened <= 0 else { return nil }
            defer { state.handle = nil }
            return state.handle
        }
        _ = released // closed here, outside the lock
    }
}

let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

/// Opening some app containers fails with EINTR now and then (seen under
/// ~/Library/Containers); a retry succeeds.
func retryingInterrupts(_ open: () -> Int32) -> Int32 {
    var fd = open()
    var attempts = 1
    while fd < 0 && errno == EINTR && attempts < 5 {
        fd = open()
        attempts += 1
    }
    return fd
}

struct Subdirectory: Sendable {
    let name: String
    let path: String
    let ownBytes: Int64

    func emptyNode() -> FileNode {
        FileNode(name: name, isDirectory: true, size: ownBytes, fileCount: 0)
    }
}

/// Reusable `getattrlistbulk` result buffers, so tasks don't allocate one per directory.
final class BufferPool: Sendable {
    static let bufferSize = 256 * 1024

    private struct Buffer: @unchecked Sendable {
        let pointer: UnsafeMutableRawBufferPointer
    }

    private let free = OSAllocatedUnfairLock(initialState: [Buffer]())

    func withBuffer<R>(_ body: (UnsafeMutableRawBufferPointer) -> R) -> R {
        let buffer = free.withLock { $0.popLast() }
            ?? Buffer(pointer: .allocate(byteCount: Self.bufferSize, alignment: 16))
        defer { free.withLock { $0.append(buffer) } }
        return body(buffer.pointer)
    }

    deinit {
        free.withLock { buffers in
            for buffer in buffers { buffer.pointer.deallocate() }
        }
    }
}

extension DirectoryReader {
    /// Calls `body` for every entry of the open directory `fd`, except `.` and `..`.
    /// Entries whose attributes can't be read are skipped.
    func forEachEntry(in fd: Int32, buffer: UnsafeMutableRawBufferPointer, _ body: (RawEntry) -> Void) {
        switch self {
        case .posix: forEachPOSIXEntry(in: fd, body)
        case .bulk: forEachBulkEntry(in: fd, buffer: buffer, body)
        }
    }
}

private func forEachPOSIXEntry(in fd: Int32, _ body: (RawEntry) -> Void) {
    // fdopendir takes ownership of its descriptor; keep `fd` for openat/fstatat.
    let copy = dup(fd)
    guard copy >= 0 else { return }
    guard let dir = fdopendir(copy) else {
        close(copy)
        return
    }
    defer { closedir(dir) }
    while let entry = readdir(dir) {
        withUnsafePointer(to: &entry.pointee.d_name) { rawName in
            rawName.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cName in
                if cName[0] == 0x2E && (cName[1] == 0 || (cName[1] == 0x2E && cName[2] == 0)) { return }
                var st = stat()
                guard fstatat(fd, cName, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                body(RawEntry(
                    name: cName,
                    isDirectory: st.st_mode & S_IFMT == S_IFDIR,
                    device: st.st_dev,
                    inode: st.st_ino,
                    bytes: Int64(st.st_blocks) * 512,
                    linkCount: UInt32(st.st_nlink)
                ))
            }
        }
    }
}

private let bulkCommonAttributes = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
    | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
    | attrgroup_t(ATTR_CMN_FILEID)
// getattrlistbulk reports a mount point with the device of the directory it
// covers, so mount points need ATTR_DIR_MOUNTSTATUS to be recognized.
private let bulkDirectoryAttributes = attrgroup_t(ATTR_DIR_MOUNTSTATUS) | attrgroup_t(ATTR_DIR_ALLOCSIZE)
private let bulkFileAttributes = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

private func forEachBulkEntry(in fd: Int32, buffer: UnsafeMutableRawBufferPointer, _ body: (RawEntry) -> Void) {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = bulkCommonAttributes
    request.dirattr = bulkDirectoryAttributes
    request.fileattr = bulkFileAttributes
    let base = buffer.baseAddress!

    var firstCall = true
    while true {
        let count = getattrlistbulk(fd, &request, base, buffer.count, 0)
        if count == 0 { return }
        if count < 0 {
            if errno == EINTR { continue }
            // A file system that refuses the request outright still gets listed.
            if firstCall && (errno == ENOTSUP || errno == EINVAL) { forEachPOSIXEntry(in: fd, body) }
            return
        }
        firstCall = false

        var record = UnsafeRawPointer(base)
        for _ in 0..<count {
            let length = Int(record.loadUnaligned(as: UInt32.self))
            defer { record += length }
            // Fields follow in bit order, but only those set in `returned`
            // are present (ATTR_CMN_ERROR comes right after the returned set).
            var field = record + MemoryLayout<UInt32>.size
            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size
            func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }
            func take<T: BitwiseCopyable>(_: T.Type) -> T {
                defer { field += MemoryLayout<T>.size }
                return field.loadUnaligned(as: T.self)
            }

            if has(returned.commonattr, ATTR_CMN_ERROR), take(UInt32.self) != 0 { continue }
            guard has(returned.commonattr, ATTR_CMN_NAME) else { continue }
            let nameField = field
            let nameReference = take(attrreference_t.self)
            let name = (nameField + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            let device: dev_t? = has(returned.commonattr, ATTR_CMN_DEVID) ? take(dev_t.self) : nil
            guard has(returned.commonattr, ATTR_CMN_OBJTYPE) else { continue }
            let type = take(fsobj_type_t.self)
            let inode = has(returned.commonattr, ATTR_CMN_FILEID) ? take(UInt64.self) : 0

            var bytes: Int64 = 0
            var linkCount: UInt32 = 1
            var isMountPoint = false
            let isDirectory = type == fsobj_type_t(VDIR.rawValue)
            if isDirectory {
                if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) {
                    isMountPoint = take(UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
                }
                if has(returned.dirattr, ATTR_DIR_ALLOCSIZE) { bytes = take(off_t.self) }
            } else {
                if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { linkCount = take(UInt32.self) }
                if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) { bytes = take(off_t.self) }
            }
            body(RawEntry(
                name: name, isDirectory: isDirectory, isMountPoint: isMountPoint, device: device, inode: inode, bytes: bytes, linkCount: linkCount
            ))
        }
    }
}
