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

        let addedFile = collector.add(a)
        let addedFolder = collector.add(big)
        #expect(addedFile && addedFolder)
        #expect(collector.items.count == 1)
        #expect(collector.totalSize == 900)

        let addedCovered = collector.add(a)
        #expect(!addedCovered, "already covered by its folder")
        let addedRoot = collector.add(root)
        #expect(!addedRoot, "the scan root itself can't be collected")
    }
}
