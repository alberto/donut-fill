import AppKit
import Observation
import ScanKit

@MainActor
@Observable
final class ScanModel {
    enum Phase {
        case idle
        case scanning(path: String)
        case done(root: FileNode)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = ScanProgress.Snapshot()
    /// The folder currently shown when browsing results.
    var current: FileNode? {
        didSet {
            guard current !== oldValue else { return }
            refreshLayout()
        }
    }
    /// Fixed colors for every node of the current scan.
    private(set) var colors: NodeColors?
    /// Capacity of the scanned volume, when the scan started at a volume root.
    private(set) var volume: VolumeSpace?
    /// The volume, but only while showing the top level, where the chart is drawn to its scale.
    var visibleVolume: VolumeSpace? {
        current != nil && current === root ? volume : nil
    }
    /// Sunburst arcs for `current`, recomputed only when the folder changes.
    private(set) var segments: [SunburstSegment] = []
    /// Bumped each time `segments` is recomputed, so the chart can animate the change.
    private(set) var layoutVersion = 0
    /// Item selected in the list or chart; shared so both views stay in sync.
    var selection: FileNode.ID?
    /// Arc under the pointer in the chart, or of the list row under the pointer.
    private(set) var hoveredSegmentID: Int?
    /// Whether the hover comes from the chart; only then does the list preview it.
    private(set) var isChartHover = false
    /// Whether the list shows every child, or only those drawn individually in the chart.
    var showsAllChildren = false
    /// Arcs by node, giving each list row its chart color.
    private(set) var segmentsByNode: [FileNode.ID: SunburstSegment] = [:]
    /// "Smaller items" arcs by the folder whose children they merge.
    private(set) var aggregatesByParent: [FileNode.ID: SunburstSegment] = [:]

    func hover(segmentID: Int?, fromChart: Bool) {
        guard segmentID != hoveredSegmentID || fromChart != isChartHover else { return }
        hoveredSegmentID = segmentID
        isChartHover = fromChart && segmentID != nil
    }

    /// The folder whose contents the list shows: normally `current`, but while an arc
    /// is hovered in the chart, that arc's folder (or a file's parent), like DaisyDisk.
    var listFolder: FileNode? {
        guard isChartHover, let segment = hoveredSegment else { return current }
        switch segment.kind {
        case let .node(node): return node.isDirectory ? node : node.parent ?? current
        case let .aggregate(parent, _, _): return parent
        case .space: return current
        }
    }

    var hoveredSegment: SunburstSegment? {
        guard let id = hoveredSegmentID, segments.indices.contains(id) else { return nil }
        return segments[id]
    }

    /// Navigates into a folder, or selects a file within its parent folder.
    func open(_ node: FileNode) {
        if node.isDirectory {
            current = node
        } else if let parent = node.parent {
            current = parent
            selection = node.id
        }
    }

    private(set) var collector = Collector()
    private(set) var isTrashing = false
    /// Failures from the last "Move to Trash", shown as an alert.
    var trashFailures: [String] = []
    /// Bumped whenever the tree is edited in place, so views reading it re-render.
    private(set) var treeVersion = 0

    private var scanTask: Task<Void, Never>?

    var root: FileNode? {
        if case let .done(root) = phase { root } else { nil }
    }

    // MARK: Volumes

    /// Mounted drives for the start screen.
    private(set) var volumes: [MountedVolume] = []

    func refreshVolumes() async {
        volumes = await Task.detached { MountedVolume.all() }.value
    }

    /// Keeps `volumes` current while the caller's task runs: on mount, unmount,
    /// and every few seconds so free space stays fresh.
    func watchVolumes() async {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification]
        let observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshVolumes() }
            }
        }
        defer { observers.forEach(center.removeObserver) }

        while !Task.isCancelled {
            await refreshVolumes()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: Collector

    func collect(_ node: FileNode) {
        collector.add(node)
    }

    /// Collects nodes by absolute path (from a drag); returns whether any were added.
    @discardableResult
    func collect(paths: [String]) -> Bool {
        guard let root else { return false }
        var added = false
        for path in paths {
            if let node = root.descendant(atPath: path), collector.add(node) { added = true }
        }
        return added
    }

    func uncollect(_ node: FileNode) {
        collector.remove(node)
    }

    func clearCollector() {
        collector.removeAll()
    }

    func trashCollected() {
        let items = collector.items
        guard !items.isEmpty, !isTrashing else { return }
        isTrashing = true
        let paths = items.map(\.path)

        Task {
            let errors: [String?] = await Task.detached(priority: .userInitiated) {
                paths.map { path in
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                        return nil
                    } catch {
                        return "\(path): \(error.localizedDescription)"
                    }
                }
            }.value

            for (node, error) in zip(items, errors) where error == nil {
                if let current, current === node || current.isDescendant(of: node) {
                    self.current = node.parent
                }
                node.removeFromParent()
                collector.remove(node)
            }
            refreshLayout()
            trashFailures = errors.compactMap { $0 }
            isTrashing = false
        }
    }

    private func refreshLayout() {
        segments = current.map { SunburstLayout.segments(for: $0, volume: visibleVolume, maxDepth: RingStyle.totalRings) } ?? []
        layoutVersion += 1
        var byNode: [FileNode.ID: SunburstSegment] = [:]
        var byParent: [FileNode.ID: SunburstSegment] = [:]
        for segment in segments {
            switch segment.kind {
            case let .node(node): byNode[node.id] = segment
            case let .aggregate(parent, _, _): byParent[parent.id] = segment
            case .space: break
            }
        }
        segmentsByNode = byNode
        aggregatesByParent = byParent
        hoveredSegmentID = nil
        isChartHover = false
        showsAllChildren = false
        selection = nil
        treeVersion += 1
    }

    var lastScannedPath: String? {
        switch phase {
        case let .scanning(path): path
        case let .done(root): root.path
        default: nil
        }
    }

    func scan(path: String) {
        cancel()
        phase = .scanning(path: path)
        progress = ScanProgress.Snapshot()
        current = nil
        volume = nil
        colors = nil
        collector.removeAll()

        let live = ScanProgress()
        scanTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                try await Scanner().scan(path: path, progress: live)
            }
            let poller = Task {
                while !Task.isCancelled {
                    progress = live.snapshot
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { poller.cancel() }

            do {
                let root = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                progress = live.snapshot
                volume = VolumeSpace.forVolume(atPath: path)
                colors = NodeColors(root: root)
                phase = .done(root: root)
                current = root
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
    }

    func reset() {
        cancel()
        phase = .idle
        current = nil
        volume = nil
        colors = nil
        collector.removeAll()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            scan(path: url.path)
        }
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
