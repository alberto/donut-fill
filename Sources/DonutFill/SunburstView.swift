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
    let hoveredID: Int?
    var onHover: (Int?) -> Void = { _ in }
    /// Called when the current folder's own "smaller items" arc is clicked.
    var onExpandSmaller: () -> Void = {}
    var isCollected: (FileNode) -> Bool = { _ in false }
    var canCollect: (FileNode) -> Bool = { _ in true }
    var onCollect: (FileNode) -> Void = { _ in }
    var onPreview: (FileNode) -> Void = { _ in }
    /// Called when the hidden space or one of its parts is clicked.
    var onShowHidden: () -> Void = {}
    /// Set only on the top level of a volume scan, to describe the drive in the center.
    var volume: VolumeSpace?
    /// Fixed per-node colors for the whole scan.
    var colors: NodeColors?
    /// Changes whenever `segments` is recomputed; starts the morph animation.
    var layoutVersion = 0

    /// The layout drawn last, so the next one can morph from it.
    @State private var shown: [SunburstSegment] = []
    @State private var morph: Morph?

    private static let morphDuration = 0.4

    private var hovered: SunburstSegment? {
        guard morph == nil, let id = hoveredID, segments.indices.contains(id) else { return nil }
        return segments[id]
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = RingGeometry(size: proxy.size)
            ZStack {
                TimelineView(.animation(paused: morph == nil)) { timeline in
                    Canvas { context, _ in
                        if let morph {
                            drawMorph(morph, at: timeline.date, in: &context, geometry: geometry)
                        } else {
                            draw(in: &context, geometry: geometry)
                        }
                    }
                }
                CenterLabel(folder: folder, folderSize: folder.size, volume: volume, hovered: hovered)
                    .frame(width: geometry.centerRadius * 1.6)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    // Only write on change: every write re-renders the list too.
                    let id = hit(point, geometry)?.id
                    if id != hoveredID { onHover(id) }
                case .ended:
                    onHover(nil)
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
                        .disabled(!canCollect(node))
                    Button("Quick Look") { onPreview(node) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                    }
                }
            }
            .help(hovered.map(tooltip) ?? "")
        }
        .padding(16)
        .onAppear { shown = segments }
        .onChange(of: layoutVersion) { startMorph() }
    }

    // MARK: Morphing between layouts

    /// Where an arc sits: angles plus ring index.
    private struct Frame {
        let start: Double
        let end: Double
        let depth: Int
    }

    private struct Morph {
        /// Old frames of arcs that also exist in the new layout.
        let from: [SegmentKey: Frame]
        /// Arcs of the old layout that are gone from the new one; they fade out.
        let outgoing: [SunburstSegment]
        let began: Date
    }

    private func startMorph() {
        let newKeys = Set(segments.map(\.key))
        var from: [SegmentKey: Frame] = [:]
        var outgoing: [SunburstSegment] = []
        for segment in shown {
            if newKeys.contains(segment.key) {
                from[segment.key] = Frame(start: segment.startAngle, end: segment.endAngle, depth: segment.depth)
            } else {
                outgoing.append(segment)
            }
        }
        shown = segments
        let began = Date()
        morph = Morph(from: from, outgoing: outgoing, began: began)
        Task {
            try? await Task.sleep(for: .seconds(Self.morphDuration))
            if morph?.began == began { morph = nil }
        }
    }

    private func drawMorph(_ morph: Morph, at date: Date, in context: inout GraphicsContext, geometry: RingGeometry) {
        let linear = min(1, max(0, date.timeIntervalSince(morph.began) / Self.morphDuration))
        let t = linear < 0.5 ? 2 * linear * linear : 1 - pow(-2 * linear + 2, 2) / 2
        let separator = Color(nsColor: .windowBackgroundColor)
        geometry.fillCenter(in: &context, opacity: 0.08)

        func fill(_ segment: SunburstSegment, _ path: Path, opacity: Double) {
            if case .space(.free, _) = segment.kind { return }
            let color = SegmentPalette.color(for: segment, colors: colors)
            context.fill(path, with: .color(color.opacity(opacity)))
            context.stroke(path, with: .color(separator.opacity(opacity)), lineWidth: 0.75)
        }

        for segment in morph.outgoing {
            fill(segment, geometry.path(for: segment), opacity: 1 - t)
        }
        for segment in segments {
            guard let old = morph.from[segment.key] else {
                fill(segment, geometry.path(for: segment), opacity: t)
                continue
            }
            let path = geometry.path(
                inner: lerp(geometry.boundaries[old.depth - 1], geometry.boundaries[segment.depth - 1], t),
                outer: lerp(geometry.boundaries[old.depth], geometry.boundaries[segment.depth], t),
                start: lerp(old.start, segment.startAngle, t),
                end: lerp(old.end, segment.endAngle, t)
            )
            fill(segment, path, opacity: 1)
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geometry: RingGeometry) {
        let separator = Color(nsColor: .windowBackgroundColor)

        geometry.fillCenter(in: &context, opacity: hovered == nil ? 0.08 : 0.04)

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
            let color = SegmentPalette.color(for: segment, colors: colors, highlighted: highlighted)
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
                onOpen(node)
            } else {
                onSelect(node)
            }
        case let .aggregate(parent, _, _):
            if parent == folder {
                onExpandSmaller()
            } else {
                onOpen(parent)
            }
        case let .space(kind, _):
            if kind.isHidden { onShowHidden() }
        }
    }

    private func tooltip(_ segment: SunburstSegment) -> String {
        switch segment.kind {
        case let .node(node):
            "\(node.path)\n\(formatBytes(node.size))" + (node.isUnreadable ? "\nCouldn't be read; its contents count as hidden space." : "")
        case let .aggregate(_, count, size): "\(count.formatted()) smaller items\n\(formatBytes(size))"
        case let .space(kind, size): "\(kind.title): \(formatBytes(size))\n\(kind.explanation)"
        }
    }
}

extension SunburstSegment.SpaceKind {
    var title: String {
        switch self {
        case .hidden: "Hidden space"
        case .otherVolumes: "Other volumes"
        case .stillHidden: "Still hidden"
        case .purgeable: "Purgeable space"
        case .free: "Free space"
        }
    }

    var explanation: String {
        switch self {
        case .hidden: "Used, but not visible to the scan. Click for a breakdown."
        case .otherVolumes: "macOS, startup, recovery and swap volumes sharing this drive."
        case .stillHidden: "Folders without access, other users' files, snapshots and file system overhead."
        case .purgeable: "Caches and other data macOS deletes automatically when it needs room."
        case .free: "Available for new files."
        }
    }
}

/// Maps between ring/angle space and view coordinates.
/// Ring sizing: the first rings are full height, deeper ones are thin, so
/// detail stays visible without crowding out the main levels.
enum RingStyle {
    static let thickRings = 5
    static let thinRings = 5
    /// Height of a thin ring relative to a thick one.
    static let thinScale: CGFloat = 0.22
    static var totalRings: Int { thickRings + thinRings }
}

/// Maps between ring/angle space and view coordinates.
private struct RingGeometry {
    let center: CGPoint
    let centerRadius: CGFloat
    /// Inner radius of each ring; boundaries[d - 1] ..< boundaries[d] is ring d.
    let boundaries: [CGFloat]

    init(size: CGSize) {
        let radius = max(10, min(size.width, size.height) / 2)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        centerRadius = radius * 0.24
        let units = CGFloat(RingStyle.thickRings) + CGFloat(RingStyle.thinRings) * RingStyle.thinScale
        let thick = (radius - centerRadius) / units
        var edges = [centerRadius]
        for depth in 1...RingStyle.totalRings {
            edges.append(edges[depth - 1] + (depth <= RingStyle.thickRings ? thick : thick * RingStyle.thinScale))
        }
        boundaries = edges
    }

    func fillCenter(in context: inout GraphicsContext, opacity: Double) {
        let disc = Path(ellipseIn: CGRect(
            x: center.x - centerRadius,
            y: center.y - centerRadius,
            width: centerRadius * 2,
            height: centerRadius * 2
        ))
        context.fill(disc, with: .color(.secondary.opacity(opacity)))
    }

    // Layout angle 0 sits on the positive x axis (3 o'clock) and grows counterclockwise.

    /// Ring index (0 = center disc) and layout angle, or nil outside the chart.
    func polar(_ point: CGPoint) -> (depth: Int, angle: Double)? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        if distance < centerRadius { return (0, 0) }
        guard let depth = boundaries.indices.dropFirst().first(where: { distance < boundaries[$0] }) else { return nil }
        // View y grows downward, so flip it to measure counterclockwise.
        var angle = Double(atan2(-dy, dx))
        if angle < 0 { angle += 2 * .pi }
        return (depth, angle)
    }

    func path(for segment: SunburstSegment) -> Path {
        path(inner: boundaries[segment.depth - 1], outer: boundaries[segment.depth], start: segment.startAngle, end: segment.endAngle)
    }

    func path(inner: CGFloat, outer: CGFloat, start startAngle: Double, end endAngle: Double) -> Path {
        // SwiftUI angles also start at 3 o'clock but run clockwise on screen, hence the negation.
        let start = Angle(radians: -startAngle)
        let span = Angle(radians: -(endAngle - startAngle))
        var path = Path()
        path.addRelativeArc(center: center, radius: outer, startAngle: start, delta: span)
        path.addRelativeArc(center: center, radius: inner, startAngle: start + span, delta: -span)
        path.closeSubpath()
        return path
    }
}

private struct CenterLabel: View {
    let folder: FileNode
    /// Passed by value: the node is the same object after in-place edits, so
    /// SwiftUI wouldn't notice its size changing.
    let folderSize: Int64
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
        Text(formatBytes(folderSize)).monospacedDigit()
        if folder.parent != nil {
            Text("Click to go up").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Identifies "the same arc" across two layouts, for morphing.
enum SegmentKey: Hashable {
    case node(FileNode.ID)
    case aggregate(parent: FileNode.ID)
    case space(SunburstSegment.SpaceKind)
}

extension SunburstSegment {
    var key: SegmentKey {
        switch kind {
        case let .node(node): .node(node.id)
        case let .aggregate(parent, _, _): .aggregate(parent: parent.id)
        case let .space(kind, _): .space(kind)
        }
    }
}

private func lerp<T: BinaryFloatingPoint>(_ a: T, _ b: T, _ t: Double) -> T {
    a + (b - a) * T(t)
}

/// Colors shared by the chart and the list's dots, so a row matches its arc.
enum SegmentPalette {
    static func color(for segment: SunburstSegment, colors: NodeColors?, highlighted: Bool = false) -> Color {
        switch segment.kind {
        case let .node(node):
            return color(for: node, colors: colors, highlighted: highlighted)
        case .aggregate:
            return aggregate(highlighted: highlighted)
        case let .space(kind, _):
            return space(kind, highlighted: highlighted)
        }
    }

    static func space(_ kind: SunburstSegment.SpaceKind, highlighted: Bool = false) -> Color {
        switch kind {
        case .hidden: Color(white: 0.4, opacity: highlighted ? 0.85 : 0.6)
        case .otherVolumes: Color(white: 0.5, opacity: highlighted ? 0.85 : 0.6)
        case .stillHidden: Color(white: 0.3, opacity: highlighted ? 0.85 : 0.6)
        case .purgeable, .free: Color(white: 0.6, opacity: highlighted ? 0.45 : 0.25)
        }
    }

    /// A node's color depends only on its place in the whole scan (see NodeColors),
    /// not on the folder being viewed, so it stays the same while navigating.
    static func color(for node: FileNode, colors: NodeColors?, highlighted: Bool = false) -> Color {
        let hue = colors?.hue(for: node) ?? 0
        let depth = Double(max(0, (colors?.depth(of: node) ?? 1) - 1))
        let saturation = max(0.3, (node.isDirectory ? 0.68 : 0.42) - depth * 0.04)
        let brightness = min(1, 0.8 + depth * 0.02 + (highlighted ? 0.15 : 0))
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    static func aggregate(highlighted: Bool = false) -> Color {
        Color(white: 0.6, opacity: highlighted ? 0.9 : 0.55)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
