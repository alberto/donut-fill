import Foundation
import Testing
@testable import ScanKit

struct NodeColorsTests {
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

    @Test func huesFollowSizeOrderFromTheRoot() throws {
        let root = folder("/", [file("a", 750), folder("b", [file("c", 200), file("d", 50)])])
        let colors = NodeColors(root: root)
        let b = root.children[1]

        #expect(abs(colors.hue(for: root.children[0]) - 0.375) < 1e-9)
        #expect(abs(colors.hue(for: b) - 0.875) < 1e-9)
        #expect(abs(colors.hue(for: b.children[0]) - 0.85) < 1e-9, "c gets the first 80% of b's 0.75...1 range")
        #expect(colors.depth(of: b.children[1]) == 2)
    }

    @Test func huesDontChangeAfterDeletion() throws {
        let root = folder("/", [file("a", 500), file("b", 300), file("c", 200)])
        let colors = NodeColors(root: root)
        let c = root.children[2]
        let before = colors.hue(for: c)

        root.children[0].removeFromParent()

        #expect(colors.hue(for: c) == before)
    }
}
