import Foundation

/// One arc in the sunburst. Angles are in radians, measured clockwise from 12 o'clock.
public struct SunburstSegment: Sendable, Identifiable {
    public enum Kind: Sendable {
        case node(FileNode)
        /// Children of `parent` too small to draw individually, merged into one arc.
        case aggregate(parent: FileNode, count: Int, size: Int64)
        /// Volume space outside the scanned tree (only on the top level of a volume scan).
        case space(SpaceKind, size: Int64)
    }

    public enum SpaceKind: Sendable {
        case hidden, purgeable, free
    }

    public let id: Int
    public let kind: Kind
    /// Ring index: 1 is the innermost ring around the center.
    public let depth: Int
    public let startAngle: Double
    public let endAngle: Double

    public var midAngle: Double { (startAngle + endAngle) / 2 }

    public var node: FileNode? {
        if case let .node(node) = kind { node } else { nil }
    }

    public var size: Int64 {
        switch kind {
        case let .node(node): node.size
        case let .aggregate(_, _, size): size
        case let .space(_, size): size
        }
    }

    public func contains(angle: Double) -> Bool {
        angle >= startAngle && angle < endAngle
    }
}

public enum SunburstLayout {
    /// Lays out `root`'s descendants as concentric rings. `root` itself is the center.
    /// Arcs narrower than `minimumAngle` are merged per parent into an aggregate arc.
    /// With `volume`, the full circle is the volume's capacity and the space outside
    /// the scan follows the scanned items on the first ring.
    public static func segments(
        for root: FileNode,
        volume: VolumeSpace? = nil,
        maxDepth: Int = 6,
        minimumAngle: Double = 0.012
    ) -> [SunburstSegment] {
        var segments: [SunburstSegment] = []
        guard root.size > 0 else { return segments }

        func layout(_ node: FileNode, depth: Int, start: Double, span: Double) {
            guard depth <= maxDepth, node.size > 0 else { return }
            let scale = span / Double(node.size)
            var angle = start

            for (index, child) in node.children.enumerated() {
                let childSpan = Double(child.size) * scale
                if childSpan < minimumAngle {
                    // Children are sorted by size, so everything after this one is smaller too.
                    let rest = node.children[index...]
                    let restSize = rest.reduce(Int64(0)) { $0 + $1.size }
                    let restSpan = Double(restSize) * scale
                    if restSpan >= minimumAngle / 2 {
                        segments.append(SunburstSegment(
                            id: segments.count,
                            kind: .aggregate(parent: node, count: rest.count, size: restSize),
                            depth: depth,
                            startAngle: angle,
                            endAngle: angle + restSpan
                        ))
                    }
                    return
                }

                segments.append(SunburstSegment(
                    id: segments.count,
                    kind: .node(child),
                    depth: depth,
                    startAngle: angle,
                    endAngle: angle + childSpan
                ))
                if child.isDirectory {
                    layout(child, depth: depth + 1, start: angle, span: childSpan)
                }
                angle += childSpan
            }
        }

        guard let volume else {
            layout(root, depth: 1, start: 0, span: 2 * .pi)
            return segments
        }

        let spaces: [(SunburstSegment.SpaceKind, Int64)] = [
            (.hidden, volume.hidden(scanned: root.size)),
            (.purgeable, volume.purgeable),
            (.free, volume.free),
        ]
        let total = Double(root.size + spaces.reduce(0) { $0 + $1.1 })
        let rootSpan = 2 * .pi * Double(root.size) / total
        layout(root, depth: 1, start: 0, span: rootSpan)

        var angle = rootSpan
        for (kind, size) in spaces where size > 0 {
            let span = 2 * .pi * Double(size) / total
            segments.append(SunburstSegment(
                id: segments.count,
                kind: .space(kind, size: size),
                depth: 1,
                startAngle: angle,
                endAngle: angle + span
            ))
            angle += span
        }
        return segments
    }
}
