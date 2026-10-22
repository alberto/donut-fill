import Foundation
import Testing
@testable import ScanKit

struct TreeEditingTests {
    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, size: size, fileCount: 1)
    }

    private func folder(_ name: String, _ children: [FileNode]) -> FileNode {
        FileNode(
            name: name,
            isDirectory: true,
            size: children.reduce(0) { $0 + $1.size },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            children: children
        )
    }

    /// /data
    ///   big/      (a 600, b 300)
    ///   small/    (c 500)
    private func makeTree() -> FileNode {
        folder("/data", [
            folder("big", [file("a", 600), file("b", 300)]),
            folder("small", [file("c", 500)]),
        ])
    }

    @Test func removingPropagatesSizesAndResorts() throws {
        let root = makeTree()
        let big = root.children[0]
        let a = try #require(root.descendant(atPath: "/data/big/a"))

        a.removeFromParent()

        #expect(a.parent == nil)
        #expect(big.size == 300)
        #expect(big.fileCount == 1)
        #expect(root.size == 800)
        #expect(root.fileCount == 2)
        #expect(root.children.map(\.name) == ["small", "big"])
    }

    @Test func findsDescendantsByPath() {
        let root = makeTree()

        #expect(root.descendant(atPath: "/data") === root)
        #expect(root.descendant(atPath: "/data/small/c")?.name == "c")
        #expect(root.descendant(atPath: "/data/missing") == nil)
        #expect(root.descendant(atPath: "/database") == nil)
    }

    @Test func collectorReplacesNestedItems() throws {
        let root = makeTree()
        let big = root.children[0]
        let a = try #require(root.descendant(atPath: "/data/big/a"))
        var collector = Collector()

        #expect(collector.add(a) == .added)
        #expect(collector.add(big) == .added)
        #expect(collector.items.count == 1)
        #expect(collector.totalSize == 900)

        #expect(collector.add(a) == .alreadyCollected, "already covered by its folder")
        guard case .refused = collector.add(root) else {
            Issue.record("the scan root itself can't be collected")
            return
        }
    }

    @Test func collectorRefusesProtectedFolders() {
        let home = folder("/Users/me", [folder("Documents", [file("report.pdf", 10)])])
        var collector = Collector(protected: ProtectedPaths(home: "/Users/me"))

        guard case .refused = collector.add(home.children[0]) else {
            Issue.record("standard home folders are refused")
            return
        }
        #expect(collector.add(home.children[0].children[0]) == .added)
        #expect(collector.isEmpty == false)
    }
}

struct RescanTests {
    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, size: size, fileCount: 1)
    }

    private func folder(_ name: String, _ children: [FileNode], unreadable: Bool = false) -> FileNode {
        FileNode(
            name: name,
            isDirectory: true,
            size: children.reduce(0) { $0 + $1.size },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            children: children,
            isUnreadable: unreadable
        )
    }

    @Test func replacingContentsUpdatesAncestorsAndKeepsTheNode() throws {
        let root = folder("/data", [
            folder("a", [folder("inner", [file("x", 100)])]),
            folder("b", [file("y", 300)]),
        ])
        let a = root.children[1]
        let inner = try #require(root.descendant(atPath: "/data/a/inner"))
        let oldX = try #require(inner.children.first)

        inner.replaceContents(with: folder("inner", [file("x", 400), file("z", 100)]))

        #expect(root.descendant(atPath: "/data/a/inner") === inner)
        #expect(inner.size == 500)
        #expect(a.size == 500)
        #expect(root.size == 800)
        #expect(root.fileCount == 3)
        #expect(root.children.map(\.name) == ["a", "b"], "re-sorted by the new size")
        #expect(oldX.parent == nil)
        #expect(!oldX.isAttached(to: root))
        #expect(try #require(inner.children.first).isAttached(to: root))
    }

    @Test func findsUnreadableFolders() {
        let root = folder("/data", [
            folder("ok", [folder("locked", [], unreadable: true)]),
            folder("private", [], unreadable: true),
            file("f", 10),
        ])

        #expect(root.unreadableDescendants().map(\.path).sorted() == ["/data/ok/locked", "/data/private"])
    }

    @Test func checksWhetherItemsStillExist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hi".utf8).write(to: dir.appendingPathComponent("here"))
        let root = folder(dir.path, [file("here", 1), file("gone", 1)])

        #expect(root.children.first { $0.name == "here" }?.existsOnDisk == true)
        #expect(root.children.first { $0.name == "gone" }?.existsOnDisk == false)
    }
}
