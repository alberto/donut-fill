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
    @Binding var hoveredID: Int?
    /// Called when the current folder's own "smaller items" arc is clicked.
    var onExpandSmaller: () -> Void = {}
    var isCollected: (FileNode) -> Bool = { _ in false }
    var onCollect: (FileNode) -> Void = { _ in }
    /// Set only on the top level of a volume scan, to describe the drive in the center.
    var volume: VolumeSpace?

    private var hovered: SunburstSegment? {
        guard let id = hoveredID, segments.indices.contains(id) else { return nil }
        return segments[id]
    }

    private let maxDepth = 6

    var body: some View {
        GeometryReader { proxy in
            let geometry = RingGeometry(size: proxy.size, rings: maxDepth)
            ZStack {
                Canvas { context, _ in
                    draw(in: &context, geometry: geometry)
                }
                CenterLabel(folder: folder, volume: volume, hovered: hovered)
                    .frame(width: geometry.centerRadius * 1.6)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    // Only write on change: every write re-renders the list too.
                    let id = hit(point, geometry)?.id
                    if id != hoveredID { hoveredID = id }
                case .ended:
                    if hoveredID != nil { hoveredID = nil }
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                handleTap(at: tap.location, geometry)
            })
            .onDrag {
                // Drag whatever arc is under the pointer; the Collector accepts paths as text.
                guard let node = hovered?.node else { return NSItemProvider() }
                return NSItemProvider(object: node.path as NSString)
            }
            .contextMenu {
                if let node = hovered?.node {
                    Button("Add “\(node.name)” to Collector") { onCollect(node) }
                        .disabled(isCollected(node))
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                    }
                }
            }
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
            if case .space(.free, _) = segment.kind {
                // Free space stays an empty gap; only hint at it on hover.
                if hovered?.id == segment.id {
                    context.fill(path, with: .color(.secondary.opacity(0.12)))
                }
                continue
            }
            let collected = segment.node.map(isCollected) ?? false
            let highlighted = isHighlighted(segment)
            let color = SegmentPalette.color(for: segment, highlighted: highlighted)
            // While something is hovered, everything outside it recedes.
            let dimmed = hovered != nil && !highlighted
            context.fill(path, with: .color(color.opacity((collected ? 0.25 : 1) * (dimmed ? 0.4 : 1))))
            context.stroke(path, with: .color(separator), lineWidth: 0.75)
        }

        if let selected = segments.first(where: { $0.node?.id == selection && selection != nil }) {
            context.stroke(geometry.path(for: selected), with: .color(.primary), lineWidth: 2)
        }
    }

    /// The hovered arc and everything nested inside it light up together.
    private func isHighlighted(_ segment: SunburstSegment) -> Bool {
        guard let hovered else { return false }
        if segment.id == hovered.id { return true }
        return segment.depth > hovered.depth
            && segment.startAngle >= hovered.startAngle - 1e-9
            && segment.endAngle <= hovered.endAngle + 1e-9
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
            if parent === folder {
                onExpandSmaller()
            } else {
                withAnimation(.easeOut(duration: 0.25)) { onOpen(parent) }
            }
        case .space:
            break
        }
    }

    private func tooltip(_ segment: SunburstSegment) -> String {
        switch segment.kind {
        case let .node(node): "\(node.path)\n\(formatBytes(node.size))"
        case let .aggregate(_, count, size): "\(count.formatted()) smaller items\n\(formatBytes(size))"
        case let .space(kind, size): "\(kind.title): \(formatBytes(size))\n\(kind.explanation)"
        }
    }
}

extension SunburstSegment.SpaceKind {
    var title: String {
        switch self {
        case .hidden: "Hidden space"
        case .purgeable: "Purgeable space"
        case .free: "Free space"
        }
    }

    var explanation: String {
        switch self {
        case .hidden: "Used, but not visible to the scan: other volumes, snapshots, folders without access."
        case .purgeable: "Caches and other data macOS deletes automatically when it needs room."
        case .free: "Available for new files."
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

    // Layout angle 0 sits on the positive x axis (3 o'clock) and grows counterclockwise.

    /// Ring index (0 = center disc) and layout angle, or nil outside the chart.
    func polar(_ point: CGPoint) -> (depth: Int, angle: Double)? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        if distance < centerRadius { return (0, 0) }
        let depth = Int((distance - centerRadius) / ringWidth) + 1
        guard depth <= rings else { return nil }
        // View y grows downward, so flip it to measure counterclockwise.
        var angle = Double(atan2(-dy, dx))
        if angle < 0 { angle += 2 * .pi }
        return (depth, angle)
    }

    func path(for segment: SunburstSegment) -> Path {
        let inner = centerRadius + CGFloat(segment.depth - 1) * ringWidth
        let outer = inner + ringWidth
        // SwiftUI angles also start at 3 o'clock but run clockwise on screen, hence the negation.
        let start = Angle(radians: -segment.startAngle)
        let span = Angle(radians: -(segment.endAngle - segment.startAngle))
        var path = Path()
        path.addRelativeArc(center: center, radius: outer, startAngle: start, delta: span)
        path.addRelativeArc(center: center, radius: inner, startAngle: start + span, delta: -span)
        path.closeSubpath()
        return path
    }
}

private struct CenterLabel: View {
    let folder: FileNode
    let volume: VolumeSpace?
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
            case let .space(kind, size):
                Text(kind.title).font(.headline)
                Text(formatBytes(size)).monospacedDigit()
            case nil:
                if let volume {
                    Text(volume.name).font(.headline).lineLimit(2)
                    Text(formatBytes(volume.capacity - volume.free)).monospacedDigit()
                    Text("\(formatBytes(volume.free)) free of \(formatBytes(volume.capacity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    folderLabel
                }
            }
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.6)
    }

    @ViewBuilder private var folderLabel: some View {
        Text(folder.displayName).font(.headline).lineLimit(2)
        Text(formatBytes(folder.size)).monospacedDigit()
        if folder.parent != nil {
            Text("Click to go up").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Colors shared by the chart and the list's dots, so a row matches its arc.
enum SegmentPalette {
    static func color(for segment: SunburstSegment, highlighted: Bool = false) -> Color {
        let depth = Double(segment.depth - 1)
        let node: FileNode
        switch segment.kind {
        case let .node(value):
            node = value
        case .aggregate:
            return aggregate(highlighted: highlighted)
        case .space(.hidden, _):
            return Color(white: 0.4, opacity: highlighted ? 0.85 : 0.6)
        case .space(.purgeable, _), .space(.free, _):
            return Color(white: 0.6, opacity: highlighted ? 0.45 : 0.25)
        }
        let hue = segment.midAngle / (2 * .pi)
        let saturation = max(0.25, (node.isDirectory ? 0.65 : 0.4) - depth * 0.06)
        let brightness = min(1, 0.82 + depth * 0.03 + (highlighted ? 0.15 : 0))
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    static func aggregate(highlighted: Bool = false) -> Color {
        Color(white: 0.6, opacity: highlighted ? 0.9 : 0.55)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
