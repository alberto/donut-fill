import AppKit
import ScanKit
import SwiftUI

struct SunburstView: View {
    let folder: FileNode
    let segments: [SunburstSegment]
    let selection: FileNode.ID?
    let onOpen: (FileNode) -> Void
    let onSelect: (FileNode) -> Void
    let onUp: () -> Void

    @State private var hovered: SunburstSegment?

    private let maxDepth = 6

    var body: some View {
        GeometryReader { proxy in
            let geometry = RingGeometry(size: proxy.size, rings: maxDepth)
            ZStack {
                Canvas { context, _ in
                    draw(in: &context, geometry: geometry)
                }
                CenterLabel(folder: folder, hovered: hovered)
                    .frame(width: geometry.centerRadius * 1.6)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hovered = hit(point, geometry)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                handleTap(at: tap.location, geometry)
            })
            .help(hovered.map(tooltip) ?? "")
        }
        .padding(16)
        .id(folder.id)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geometry: RingGeometry) {
        let separator = Color(nsColor: .windowBackgroundColor)

        let center = Path(ellipseIn: CGRect(
            x: geometry.center.x - geometry.centerRadius,
            y: geometry.center.y - geometry.centerRadius,
            width: geometry.centerRadius * 2,
            height: geometry.centerRadius * 2
        ))
        context.fill(center, with: .color(.secondary.opacity(hovered == nil ? 0.08 : 0.04)))

        for segment in segments {
            let path = geometry.path(for: segment)
            context.fill(path, with: .color(color(for: segment)))
            context.stroke(path, with: .color(separator), lineWidth: 0.75)
        }

        if let selected = segments.first(where: { $0.node?.id == selection && selection != nil }) {
            context.stroke(geometry.path(for: selected), with: .color(.primary), lineWidth: 2)
        }
    }

    private func color(for segment: SunburstSegment) -> Color {
        let depth = Double(segment.depth - 1)
        let isHovered = hovered?.id == segment.id
        guard let node = segment.node else {
            return Color(white: 0.6, opacity: isHovered ? 0.9 : 0.55)
        }
        let hue = segment.midAngle / (2 * .pi)
        let saturation = max(0.25, (node.isDirectory ? 0.65 : 0.4) - depth * 0.06)
        let brightness = min(1, 0.82 + depth * 0.03 + (isHovered ? 0.15 : 0))
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    // MARK: Interaction

    private func hit(_ point: CGPoint, _ geometry: RingGeometry) -> SunburstSegment? {
        guard let (depth, angle) = geometry.polar(point), depth > 0 else { return nil }
        return segments.first { $0.depth == depth && $0.contains(angle: angle) }
    }

    private func handleTap(at point: CGPoint, _ geometry: RingGeometry) {
        guard let (depth, _) = geometry.polar(point) else { return }
        if depth == 0 {
            onUp()
            return
        }
        guard let segment = hit(point, geometry) else { return }
        switch segment.kind {
        case let .node(node):
            if node.isDirectory {
                withAnimation(.easeOut(duration: 0.25)) { onOpen(node) }
            } else {
                onSelect(node)
            }
        case let .aggregate(parent, _, _):
            if parent !== folder {
                withAnimation(.easeOut(duration: 0.25)) { onOpen(parent) }
            }
        }
    }

    private func tooltip(_ segment: SunburstSegment) -> String {
        switch segment.kind {
        case let .node(node): "\(node.path)\n\(formatBytes(node.size))"
        case let .aggregate(_, count, size): "\(count.formatted()) smaller items\n\(formatBytes(size))"
        }
    }
}

/// Maps between ring/angle space and view coordinates.
private struct RingGeometry {
    let center: CGPoint
    let centerRadius: CGFloat
    let ringWidth: CGFloat
    let rings: Int

    init(size: CGSize, rings: Int) {
        let radius = max(10, min(size.width, size.height) / 2)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        centerRadius = radius * 0.24
        ringWidth = (radius - centerRadius) / CGFloat(rings)
        self.rings = rings
    }

    /// Ring index (0 = center disc) and clockwise angle from 12 o'clock, or nil outside the chart.
    func polar(_ point: CGPoint) -> (depth: Int, angle: Double)? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        if distance < centerRadius { return (0, 0) }
        let depth = Int((distance - centerRadius) / ringWidth) + 1
        guard depth <= rings else { return nil }
        var angle = Double(atan2(dx, -dy))
        if angle < 0 { angle += 2 * .pi }
        return (depth, angle)
    }

    func path(for segment: SunburstSegment) -> Path {
        let inner = centerRadius + CGFloat(segment.depth - 1) * ringWidth
        let outer = inner + ringWidth
        // Our angles start at 12 o'clock; SwiftUI's start at 3 o'clock.
        let start = Angle(radians: segment.startAngle - .pi / 2)
        let span = Angle(radians: segment.endAngle - segment.startAngle)
        var path = Path()
        path.addRelativeArc(center: center, radius: outer, startAngle: start, delta: span)
        path.addRelativeArc(center: center, radius: inner, startAngle: start + span, delta: -span)
        path.closeSubpath()
        return path
    }
}

private struct CenterLabel: View {
    let folder: FileNode
    let hovered: SunburstSegment?

    var body: some View {
        VStack(spacing: 2) {
            switch hovered?.kind {
            case let .node(node):
                Text(node.name).font(.headline).lineLimit(2)
                Text(formatBytes(node.size)).monospacedDigit()
            case let .aggregate(_, count, size):
                Text("\(count.formatted()) smaller items").font(.headline)
                Text(formatBytes(size)).monospacedDigit()
            case nil:
                Text(folder.displayName).font(.headline).lineLimit(2)
                Text(formatBytes(folder.size)).monospacedDigit()
                if folder.parent != nil {
                    Text("Click to go up").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.6)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
