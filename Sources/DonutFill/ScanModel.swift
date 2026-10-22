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
    /// Other volumes and snapshots of the scanned volume, for the hidden space breakdown.
    private var apfs: (otherVolumes: [APFSVolumeUsage], snapshots: [APFSSnapshot]) = ([], [])
    /// What the hidden space is made of; only for volume scans.
    var hiddenSpace: HiddenSpace? {
        guard let volume, let root else { return nil }
        return HiddenSpace(
            total: volume.hidden(scanned: root.size),
            otherVolumes: apfs.otherVolumes,
            snapshots: apfs.snapshots,
            unreadableFolders: progress.unreadable
        )
    }
    /// The hidden space breakdown was clicked open, replacing the list until closed.
    var showsHiddenSpace = false
    /// Whether the list shows the hidden space breakdown: clicked open, or previewed
    /// while its arc is hovered in the chart.
    var showsHiddenPanel: Bool {
        if showsHiddenSpace { return true }
        guard isChartHover, case let .space(kind, _)? = hoveredSegment?.kind else { return false }
        return kind.isHidden
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
    /// Why the last item couldn't be collected; shown briefly in the Collector bar.
    private(set) var collectorNotice: String?
    private var noticeTask: Task<Void, Never>?
    /// Items moved to the Trash in this session. They still take up space until
    /// the Trash is emptied, so the Collector bar offers to delete them for good.
    private(set) var trashed: [TrashedItem] = []
    private(set) var isDeletingTrashed = false
    /// Failures from the last trash or delete, shown as an alert.
    var failures: Failures?

    struct TrashedItem {
        /// Where the item now sits in the Trash.
        let url: URL
        let size: Int64
    }

    struct Failures {
        let title: String
        let lines: [String]
    }

    var trashedSize: Int64 { trashed.reduce(0) { $0 + $1.size } }

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

    // MARK: Quick Look

    /// File shown in the Quick Look panel, if open.
    var previewURL: URL?

    func preview(_ node: FileNode) {
        previewURL = URL(fileURLWithPath: node.path)
    }

    /// Space bar: previews the item under the pointer (like DaisyDisk), else the
    /// selected one; closes the panel if it's already open.
    func togglePreview() {
        if previewURL != nil {
            previewURL = nil
        } else if let node = hoveredSegment?.node ?? selectedNode {
            preview(node)
        }
    }

    private var selectedNode: FileNode? {
        guard let selection else { return nil }
        let folders = [listFolder, current].compactMap { $0 }
        return folders.lazy.flatMap(\.children).first { $0.id == selection }
    }

    // MARK: Collector

    /// Whether `node` could be added to the Collector right now.
    func canCollect(_ node: FileNode) -> Bool {
        collector.refusal(for: node) == nil && !collector.contains(node)
    }

    func collect(_ node: FileNode) {
        if case let .refused(reason) = collector.add(node) {
            showNotice(reason)
        }
    }

    /// Collects nodes by absolute path (from a drag); returns whether any were added.
    @discardableResult
    func collect(paths: [String]) -> Bool {
        guard let root else { return false }
        var added = false
        for path in paths {
            guard let node = root.descendant(atPath: path) else { continue }
            switch collector.add(node) {
            case .added: added = true
            case .alreadyCollected: break
            case let .refused(reason): showNotice(reason)
            }
        }
        return added
    }

    private func showNotice(_ text: String) {
        collectorNotice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            collectorNotice = nil
        }
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
            let results: [Result<URL?, Error>] = await Task.detached(priority: .userInitiated) {
                paths.map { path in
                    Result {
                        var trashedURL: NSURL?
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashedURL)
                        return trashedURL as URL?
                    }
                }
            }.value

            var errors: [String] = []
            for (node, result) in zip(items, results) {
                switch result {
                case let .success(url):
                    if let url { trashed.append(TrashedItem(url: url, size: node.size)) }
                    if let current, current === node || current.isDescendant(of: node) {
                        self.current = node.parent
                    }
                    node.removeFromParent()
                    collector.remove(node)
                case let .failure(error):
                    errors.append("\(node.path): \(error.localizedDescription)")
                }
            }
            refreshLayout()
            if !errors.isEmpty {
                failures = Failures(title: "Some items couldn't be moved to the Trash", lines: errors)
            }
            isTrashing = false
        }
    }

    /// Permanently deletes what this session moved to the Trash, freeing its space.
    /// Items the user already restored or emptied are skipped.
    func deleteTrashed() {
        let items = trashed
        guard !items.isEmpty, !isDeletingTrashed else { return }
        isDeletingTrashed = true

        Task {
            let errors: [String] = await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                return items.compactMap { item in
                    guard fileManager.fileExists(atPath: item.url.path) else { return nil }
                    do {
                        try fileManager.removeItem(at: item.url)
                        return nil
                    } catch {
                        return "\(item.url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }.value

            trashed = []
            if !errors.isEmpty {
                failures = Failures(title: "Some items couldn't be deleted", lines: errors)
            }
            isDeletingTrashed = false
        }
    }

    /// Forgets the trashed items, leaving them in the Trash.
    func dismissTrashed() {
        trashed = []
    }

    private func refreshLayout() {
        let volume = visibleVolume
        let hidden = volume == nil ? nil : hiddenSpace
        segments = current.map { SunburstLayout.segments(for: $0, volume: volume, hidden: hidden, maxDepth: RingStyle.totalRings) } ?? []
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
        showsHiddenSpace = false
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
        apfs = ([], [])
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
                apfs = volume == nil ? ([], []) : await Task.detached { APFSInfo.load(forVolumeAtPath: path) }.value
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
