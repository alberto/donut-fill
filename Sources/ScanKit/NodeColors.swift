import Foundation

/// Assigns every node a fixed hue and depth based on its place in the whole scan,
/// so its color stays the same however the chart is zoomed.
///
/// The scan root spans hues 0...1; each child gets a slice of its parent's range
/// proportional to its size, in the same order as the chart. Ranges are computed
/// lazily, one sibling group at a time, and cached. The cache is never rebuilt, so
/// colors also stay put after items are deleted.
/// Not thread-safe: use from one thread (the main actor).
public final class NodeColors {
    private struct HueRange {
        let start: Double
        let span: Double
        let depth: Int
    }

    public let root: FileNode
    private var ranges: [FileNode.ID: HueRange] = [:]

    public init(root: FileNode) {
        self.root = root
        ranges[root.id] = HueRange(start: 0, span: 1, depth: 0)
    }

    /// Hue in 0...1 at the middle of the node's range.
    public func hue(for node: FileNode) -> Double {
        let range = range(for: node)
        return range.start + range.span / 2
    }

    /// Distance from the scan root (its children are depth 1).
    public func depth(of node: FileNode) -> Int {
        range(for: node).depth
    }

    private func range(for node: FileNode) -> HueRange {
        if let cached = ranges[node.id] { return cached }
        // Detached (deleted) nodes, or nodes from another tree, fall back to the root.
        guard let parent = node.parent else { return ranges[root.id]! }

        let parentRange = range(for: parent)
        var offset = parentRange.start
        let total = Double(max(parent.size, 1))
        for child in parent.children {
            let span = parentRange.span * Double(child.size) / total
            if ranges[child.id] == nil {
                ranges[child.id] = HueRange(start: offset, span: span, depth: parentRange.depth + 1)
            }
            offset += span
        }
        return ranges[node.id] ?? parentRange
    }
}
