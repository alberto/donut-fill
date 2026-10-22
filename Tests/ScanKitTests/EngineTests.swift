import Foundation
import Testing
@testable import ScanKit

/// Runs every engine over the same trees and checks they agree with the original POSIX scanner.
struct EngineTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ relativePath: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func scan(_ engine: ScanEngine, workers: Int = 4, progress: ScanProgress = ScanProgress()) async throws -> FileNode {
        var options = ScanOptions()
        options.engine = engine
        options.workers = workers
        return try await Scanner(options: options).scan(path: root.path, progress: progress)
    }

    /// A tree as comparable values: path → (size, file count, is directory).
    private func flatten(_ node: FileNode, prefix: String = "", into result: inout [String: [Int64]]) {
        let path = prefix + "/" + node.name
        result[path] = [node.size, Int64(node.fileCount), node.isDirectory ? 1 : 0]
        for child in node.children { flatten(child, prefix: path, into: &result) }
    }

    private func makeMixedTree() throws {
        try write("small.txt", bytes: 1_000)
        try write("empty", bytes: 0)
        try write("big/a.bin", bytes: 500_000)
        try write("big/b.bin", bytes: 300_000)
        for i in 0..<40 {
            try write("wide/dir\(i)/file.bin", bytes: 4_096 * (i + 1))
        }
        var deep = "deep"
        for level in 0..<60 {
            deep += "/level\(level)"
            try write(deep + "/f", bytes: 100)
        }
        // More entries than fit in one small getattrlistbulk batch.
        for i in 0..<3_000 {
            try write("many/file-with-a-fairly-long-name-\(i).txt", bytes: i % 7 == 0 ? 0 : 10)
        }
        try write("names/ünïcødé 名前 🍩.txt", bytes: 2_000)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("names/link-to-big"), withDestinationURL: root.appendingPathComponent("big")
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(
            at: root.appendingPathComponent("big/a.bin"), to: root.appendingPathComponent("wide/dir3/a-link.bin")
        )
    }

    @Test(arguments: ScanEngine.allCases)
    func matchesOriginalScanner(engine: ScanEngine) async throws {
        try makeMixedTree()
        let expectedProgress = ScanProgress()
        let expectedTree = try await scan(.posix, progress: expectedProgress)
        let progress = ScanProgress()
        let tree = try await scan(engine, progress: progress)

        var expected: [String: [Int64]] = [:]
        var actual: [String: [Int64]] = [:]
        flatten(expectedTree, into: &expected)
        flatten(tree, into: &actual)
        // Which of two hard links is billed depends on scan order, so compare the rest exactly.
        let linked: Set = ["/\(root.path)/big", "/\(root.path)/big/a.bin", "/\(root.path)/wide",
                           "/\(root.path)/wide/dir3", "/\(root.path)/wide/dir3/a-link.bin"]
        #expect(expected.filter { !linked.contains($0.key) } == actual.filter { !linked.contains($0.key) })
        let links = ["/\(root.path)/big/a.bin", "/\(root.path)/wide/dir3/a-link.bin"]
        #expect(links.filter { actual[$0] != nil }.count == 1)
        #expect(tree.size == expectedTree.size)
        #expect(tree.fileCount == expectedTree.fileCount)
        #expect(progress.snapshot.files == expectedProgress.snapshot.files)
        #expect(progress.snapshot.directories == expectedProgress.snapshot.directories)
        #expect(progress.snapshot.bytes == expectedProgress.snapshot.bytes)
        #expect(tree.children.map(\.size) == tree.children.map(\.size).sorted(by: >))
    }

    @Test(arguments: ScanEngine.allCases)
    func countsHardLinksOnce(engine: ScanEngine) async throws {
        try write("a/original.bin", bytes: 200_000)
        for i in 0..<5 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("b\(i)"), withIntermediateDirectories: true)
            try FileManager.default.linkItem(
                at: root.appendingPathComponent("a/original.bin"), to: root.appendingPathComponent("b\(i)/link.bin")
            )
        }
        let tree = try await scan(engine)
        #expect(tree.fileCount == 1)
        #expect(tree.size >= 200_000 && tree.size < 2 * 200_000)
    }

    @Test(arguments: ScanEngine.allCases)
    func countsUnreadableFolders(engine: ScanEngine) async throws {
        try write("locked/secret.bin", bytes: 1_000)
        try write("open/nested/locked2/secret.bin", bytes: 1_000)
        let locked = [root.appendingPathComponent("locked").path, root.appendingPathComponent("open/nested/locked2").path]
        for path in locked { chmod(path, 0) }
        defer { for path in locked { chmod(path, 0o755) } }

        let progress = ScanProgress()
        let tree = try await scan(engine, progress: progress)
        #expect(progress.snapshot.unreadable == 2)
        #expect(tree.fileCount == 0)
        for path in locked { #expect(tree.descendant(atPath: path)?.isUnreadable == true) }
        #expect(tree.descendant(atPath: root.appendingPathComponent("open/nested").path)?.isUnreadable == false)
        #expect(tree.isUnreadable == false)
    }

    @Test(arguments: ScanEngine.allCases)
    func stopsWhenCancelled(engine: ScanEngine) async throws {
        for i in 0..<200 { try write("d\(i)/e/f", bytes: 10) }
        let scan = Task { try await self.scan(engine) }
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
    }

    /// Cancelling halfway through a large real tree returns promptly instead of finishing the walk.
    @Test(arguments: ScanEngine.allCases)
    func stopsPromptlyWhenCancelledMidScan(engine: ScanEngine) async throws {
        var options = ScanOptions()
        options.engine = engine
        let scan = Task { try await Scanner(options: options).scan(path: "/System/Library") }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test(arguments: [1, 3, 32])
    func threadPoolSizesAgree(workers: Int) async throws {
        try makeMixedTree()
        let expected = try await scan(.posix)
        for engine in [ScanEngine.bulkThreads, .posixThreads, .bulkTasks] {
            let tree = try await scan(engine, workers: workers)
            #expect(tree.size == expected.size)
            #expect(tree.fileCount == expected.fileCount)
        }
    }

    /// Mounts a small disk image inside the tree; no engine may descend into it.
    @Test(arguments: ScanEngine.allCases)
    func doesNotCrossIntoOtherVolumes(engine: ScanEngine) async throws {
        try write("outside.bin", bytes: 10_000)
        let image = root.appendingPathComponent("volume.dmg").path
        let mountPoint = root.appendingPathComponent("mnt").path
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", "create", "-size", "8m", "-fs", "HFS+", "-volname", "ScanKitTest", "-quiet", image)
        try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-mountpoint", mountPoint, "-quiet", image)
        defer { try? run("/usr/bin/hdiutil", "detach", "-force", "-quiet", mountPoint) }
        try Data(repeating: 1, count: 1_000_000).write(to: URL(fileURLWithPath: mountPoint + "/inside.bin"))

        let tree = try await scan(engine)
        #expect(tree.children.allSatisfy { $0.name != "mnt" }, "mount points are left out, like the original scanner")
        #expect(tree.fileCount == 2) // outside.bin and volume.dmg
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments) failed"])
        }
    }
}
