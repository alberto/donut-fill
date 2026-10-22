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
            guard current != oldValue else { return }
            refreshLayout()
        }
    }
    /// Fixed colors for every node of the current scan.
    private(set) var colors: NodeColors?
    /// Capacity of the scanned volume, when the scan started at a volume root.
    private(set) var volume: VolumeSpace?
    /// The volume, but only while showing the top level, where the chart is drawn to its scale.
    var visibleVolume: VolumeSpace? {
        current != nil && current == root ? volume : nil
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
            unreadableFolders: unreadableFolders.count
        )
    }
    /// Folders the scan couldn't open, still in the tree, in tree order.
    private(set) var unreadableFolders: [FileNode] = []
    /// Listed items found missing on disk (deleted or moved outside the app since the scan).
    private(set) var staleIDs: Set<FileNode.ID> = []
    /// Path of the folder being rescanned in place, if any.
    private(set) var rescanningPath: String?
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
                    if let current, current == node || current.isDescendant(of: node) {
                        self.current = node.parent
                    }
                    node.removeFromParent()
                    collector.remove(node)
                case let .failure(error):
                    errors.append("\(node.path): \(error.localizedDescription)")
                }
            }
            pruneDetached()
            refreshLayout()
            if !errors.isEmpty {
                failures = Failures(title: "Some items couldn't be moved to the Trash", lines: errors)
            }
            isTrashing = false
            refreshVolumeSpaceSoon()
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
            refreshVolumeSpaceSoon()
        }
    }

    /// Forgets the trashed items, leaving them in the Trash.
    func dismissTrashed() {
        trashed = []
    }

    /// Recomputes the chart and resets per-folder state (hover, selection, expanded rows).
    private func refreshLayout() {
        recomputeSegments()
        hoveredSegmentID = nil
        isChartHover = false
        showsAllChildren = false
        showsHiddenSpace = false
        selection = nil
        treeVersion += 1
    }

    /// Recomputes the chart only, e.g. when the volume's figures change.
    private func recomputeSegments() {
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
        unreadableFolders = []
        staleIDs = []
        colors = nil
        collector.removeAll()

        let live = ScanProgress()
        scanTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                try await Self.scanner().scan(path: path, progress: live)
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
                unreadableFolders = await Task.detached { root.unreadableDescendants() }.value
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

    /// Rescans the folder being viewed and splices the result into the tree, so
    /// the rest of the scan (and the colors) stay. The top level rescans everything.
    /// Hard links shared with files outside the folder may be counted again.
    func rescanCurrentFolder() {
        guard let folder = current, let root, rescanningPath == nil else { return }
        guard folder != root else {
            scan(path: root.path)
            return
        }
        let path = folder.path
        rescanningPath = path
        Task {
            defer { rescanningPath = nil }
            do {
                let fresh = try await Task.detached(priority: .userInitiated) { try await Self.scanner().scan(path: path) }.value
                guard self.root == root, folder.isAttached(to: root) else { return }
                for item in collector.items where item.isDescendant(of: folder) {
                    collector.remove(item)
                }
                folder.replaceContents(with: fresh)
                unreadableFolders = await Task.detached { root.unreadableDescendants() }.value
                staleIDs = []
                refreshLayout()
                await refreshVolumeSpace()
            } catch {
                failures = Failures(title: "Couldn't rescan “\(folder.name)”", lines: [error.localizedDescription])
            }
        }
    }

    /// Drops references to nodes no longer in the tree (after trashing).
    private func pruneDetached() {
        guard let root else { return }
        unreadableFolders.removeAll { !$0.isAttached(to: root) }
        staleIDs = []
    }

    // MARK: Live updates

    /// While browsing: keeps the volume's figures current, so space freed by
    /// deleting (here or elsewhere) shows up, and marks listed items that
    /// disappeared from disk.
    func watchForChanges() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await refreshVolumeSpace()
            await checkStale()
        }
    }

    /// macOS updates free and purgeable space a moment after a deletion.
    private func refreshVolumeSpaceSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshVolumeSpace()
        }
    }

    func refreshVolumeSpace() async {
        guard let root, let old = volume else { return }
        let path = root.path
        guard var fresh = await Task.detached(operation: { VolumeSpace.forVolume(atPath: path) }).value,
              self.root == root
        else { return }
        fresh.name = old.name
        guard fresh.differsNoticeably(from: old) else { return }
        volume = fresh
        apfs = await Task.detached { APFSInfo.load(forVolumeAtPath: path) }.value
        guard self.root == root, visibleVolume != nil else { return }
        recomputeSegments()
        hoveredSegmentID = nil
        isChartHover = false
    }

    /// Checks whether the listed folder's items still exist on disk.
    func checkStale() async {
        guard let folder = listFolder else { return }
        let children = Array(folder.children)
        // Paths, not nodes, go to the background: the tree is only read on the main actor.
        let paths = children.map { ($0.id, $0.path) }
        let missing = await Task.detached {
            Set(paths.filter { path in
                var info = stat()
                return lstat(path.1, &info) != 0
            }.map(\.0))
        }.value
        var updated = staleIDs
        updated.subtract(children.map(\.id))
        updated.formUnion(missing)
        if updated != staleIDs { staleIDs = updated }
    }

    // MARK: Keyboard

    /// The items the list shows for `folder`, in order: those drawn as their own arc,
    /// or every child once "smaller objects" is expanded (never while previewing).
    func listRows(of folder: FileNode, isPreview: Bool) -> [FileNode] {
        let collapsed = aggregatesByParent[folder.id] != nil && (isPreview || !showsAllChildren)
        return collapsed ? folder.children.filter { segmentsByNode[$0.id] != nil } : Array(folder.children)
    }

    var selectedNode: FileNode? {
        guard let selection else { return nil }
        let folders = [listFolder, current].compactMap { $0 }
        return folders.lazy.flatMap(\.children).first { $0.id == selection }
    }

    /// ↑/↓: moves the selection within the current folder's list.
    func moveSelection(by offset: Int) {
        guard let folder = current else { return }
        hover(segmentID: nil, fromChart: false)
        let rows = listRows(of: folder, isPreview: false)
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection }.map { $0 + offset } ?? (offset > 0 ? 0 : rows.count - 1)
        selection = rows[min(max(index, 0), rows.count - 1)].id
    }

    /// Return: opens the selected folder.
    func openSelection() {
        if let node = selectedNode, node.isDirectory { current = node }
    }

    /// ⌘⌫: collects the item under the pointer, else the selected one.
    func collectPointedOrSelected() {
        if let node = hoveredSegment?.node ?? selectedNode { collect(node) }
    }

    /// Shows `node` in its folder, selected.
    func reveal(_ node: FileNode) {
        guard let parent = node.parent else { return }
        current = parent
        selection = node.id
        showsAllChildren = segmentsByNode[node.id] == nil
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
        unreadableFolders = []
        staleIDs = []
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

    /// A scanner that won't set off macOS's "access data from other apps" prompt,
    /// which would hold up the scan until answered.
    nonisolated static func scanner() -> ScanKit.Scanner {
        var options = ScanOptions()
        options.sealedFolders = PrivacyPrompts.foldersToSeal()
        return ScanKit.Scanner(options: options)
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
