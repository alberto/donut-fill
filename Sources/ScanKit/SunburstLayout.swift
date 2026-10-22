import Foundation

/// One arc in the sunburst. Angles are in radians from 0 to 2π in layout order;
/// the view decides where 0 sits and which way the angle runs.
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
        /// Parts of the hidden space, drawn on the second ring inside its arc.
        case otherVolumes, stillHidden

        /// Whether this is the hidden space or one of its parts.
        public var isHidden: Bool { self == .hidden || self == .otherVolumes || self == .stillHidden }
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
    /// With `volume`, the full circle is the volume's capacity: hidden space comes
    /// first on the first ring, then the scanned items, then purgeable and free space.
    /// With `hidden` too, the second ring splits the hidden arc into other volumes and
    /// what's still hidden.
    public static func segments(
        for root: FileNode,
        volume: VolumeSpace? = nil,
        hidden breakdown: HiddenSpace? = nil,
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
                    // Emitted even when too thin to see, so the list can still offer
                    // a "smaller objects" row for these items.
                    segments.append(SunburstSegment(
                        id: segments.count,
                        kind: .aggregate(parent: node, count: rest.count, size: restSize),
                        depth: depth,
                        startAngle: angle,
                        endAngle: angle + restSpan
                    ))
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

        // Order around the ring: hidden space, the scanned items, purgeable, free.
        let hidden = volume.hidden(scanned: root.size)
        let total = Double(root.size + hidden + volume.purgeable + volume.free)
        var angle = 0.0

        func appendSpace(_ kind: SunburstSegment.SpaceKind, _ size: Int64, depth: Int = 1) {
            guard size > 0 else { return }
            let span = 2 * .pi * Double(size) / total
            segments.append(SunburstSegment(
                id: segments.count,
                kind: .space(kind, size: size),
                depth: depth,
                startAngle: angle,
                endAngle: angle + span
            ))
            angle += span
        }

        appendSpace(.hidden, hidden)
        if let breakdown, breakdown.otherVolumesSize > 0, maxDepth >= 2 {
            // Re-walk the hidden arc on the second ring, split into its parts.
            angle = 0
            let otherVolumes = min(hidden, breakdown.otherVolumesSize)
            appendSpace(.otherVolumes, otherVolumes, depth: 2)
            appendSpace(.stillHidden, hidden - otherVolumes, depth: 2)
        }
        let rootSpan = 2 * .pi * Double(root.size) / total
        layout(root, depth: 1, start: angle, span: rootSpan)
        angle += rootSpan
        appendSpace(.purgeable, volume.purgeable)
        appendSpace(.free, volume.free)
        return segments
    }
}
