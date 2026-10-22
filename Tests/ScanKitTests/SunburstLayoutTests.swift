import Foundation
import Testing
@testable import ScanKit

struct SunburstLayoutTests {
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

    @Test func anglesAreProportionalToSize() throws {
        let root = folder("/", [file("a", 750), file("b", 250)])

        let segments = SunburstLayout.segments(for: root)

        #expect(segments.count == 2)
        #expect(segments[0].node?.name == "a")
        #expect(abs(segments[0].endAngle - 1.5 * .pi) < 1e-9)
        #expect(abs(segments[1].startAngle - 1.5 * .pi) < 1e-9)
        #expect(abs(segments[1].endAngle - 2 * .pi) < 1e-9)
    }

    @Test func nestedFoldersStayWithinParentArc() throws {
        let root = folder("/", [folder("dir", [file("x", 300), file("y", 100)]), file("z", 400)])

        let segments = SunburstLayout.segments(for: root)
        let dir = try #require(segments.first { $0.node?.name == "dir" })
        let nested = segments.filter { $0.depth == 2 }

        #expect(nested.map { $0.node?.name } == ["x", "y"])
        #expect(nested.allSatisfy { $0.startAngle >= dir.startAngle && $0.endAngle <= dir.endAngle + 1e-9 })
    }

    @Test func mergesTinyChildrenIntoAggregate() throws {
        let tiny = (0..<50).map { file("t\($0)", 20) }
        let root = folder("/", [file("huge", 100_000)] + tiny)

        let segments = SunburstLayout.segments(for: root, minimumAngle: 0.01)

        try #require(segments.count == 2)
        guard case let .aggregate(_, count, size) = segments[1].kind else {
            Issue.record("expected aggregate")
            return
        }
        #expect(count == 50)
        #expect(size == 1_000)
    }

    @Test func keepsAggregateEvenWhenTooThinToSee() throws {
        let tiny = (0..<50).map { file("t\($0)", 1) }
        let root = folder("/", [file("huge", 1_000_000)] + tiny)

        let segments = SunburstLayout.segments(for: root)
        let last = try #require(segments.last)

        guard case let .aggregate(_, count, _) = last.kind else {
            Issue.record("expected aggregate")
            return
        }
        #expect(count == 50)
    }

    @Test func respectsMaxDepth() {
        let root = folder("/", [folder("1", [folder("2", [folder("3", [file("f", 10)])])])])

        let segments = SunburstLayout.segments(for: root, maxDepth: 2)

        #expect(segments.map(\.depth).max() == 2)
    }

    @Test func volumeLayoutAddsSpaceSegments() throws {
        let root = folder("/", [file("a", 500)])
        let volume = VolumeSpace(name: "Disk", capacity: 1_000, available: 300, availableIncludingPurgeable: 400)

        let segments = SunburstLayout.segments(for: root, volume: volume)

        #expect(abs(segments[0].endAngle - .pi) < 1e-9, "scanned items take their share of the capacity")
        let spaces = segments.compactMap { segment -> (SunburstSegment.SpaceKind, Int64)? in
            if case let .space(kind, size) = segment.kind { (kind, size) } else { nil }
        }
        #expect(spaces.map(\.0) == [.hidden, .purgeable, .free])
        #expect(spaces.map(\.1) == [100, 100, 300])
        #expect(abs(try #require(segments.last).endAngle - 2 * .pi) < 1e-9)
    }
}
