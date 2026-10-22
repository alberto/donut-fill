import Foundation
import Testing
@testable import ScanKit

struct ScannerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScanKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ relativePath: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    @Test func buildsTreeSortedBySize() async throws {
        try write("small.txt", bytes: 1_000)
        try write("big/a.bin", bytes: 500_000)
        try write("big/b.bin", bytes: 300_000)
        try write("medium/deep/c.bin", bytes: 100_000)

        let tree = try await Scanner().scan(path: root.path)

        #expect(tree.fileCount == 4)
        #expect(tree.children.map(\.name) == ["big", "medium", "small.txt"])
        #expect(tree.children[0].size >= 800_000)
        #expect(tree.children[0].children.map(\.name) == ["a.bin", "b.bin"])
        #expect(tree.children.allSatisfy { $0.parent === tree })
        #expect(tree.children[1].children[0].children[0].path == root.appendingPathComponent("medium/deep/c.bin").path)
    }

    @Test func directorySizeIsSumOfDescendants() async throws {
        try write("x/1", bytes: 10_000)
        try write("x/y/2", bytes: 20_000)

        let tree = try await Scanner().scan(path: root.path)
        let x = try #require(tree.children.first)
        let childTotal = x.children.reduce(0) { $0 + $1.size }

        #expect(x.size >= childTotal)
        #expect(x.size - childTotal < 64 * 1024, "only the folder's own metadata should be added")
    }

    @Test func countsHardLinkedFilesOnce() async throws {
        try write("original.bin", bytes: 200_000)
        try FileManager.default.linkItem(
            at: root.appendingPathComponent("original.bin"),
            to: root.appendingPathComponent("link.bin")
        )

        let tree = try await Scanner().scan(path: root.path)

        #expect(tree.fileCount == 1)
    }

    @Test func reportsUnreadableFolders() async throws {
        try write("locked/secret.bin", bytes: 1_000)
        let locked = root.appendingPathComponent("locked").path
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }

        let progress = ScanProgress()
        _ = try await Scanner().scan(path: root.path, progress: progress)

        #expect(progress.snapshot.unreadable == 1)
    }

    @Test func rejectsFiles() async throws {
        try write("file.txt", bytes: 10)
        await #expect(throws: ScanError.self) {
            try await Scanner().scan(path: root.appendingPathComponent("file.txt").path)
        }
    }
}
