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
            segments = current.map { SunburstLayout.segments(for: $0) } ?? []
            selection = nil
        }
    }
    /// Sunburst arcs for `current`, recomputed only when the folder changes.
    private(set) var segments: [SunburstSegment] = []
    /// Item selected in the list or chart; shared so both views stay in sync.
    var selection: FileNode.ID?

    /// Navigates into a folder, or selects a file within its parent folder.
    func open(_ node: FileNode) {
        if node.isDirectory {
            current = node
        } else if let parent = node.parent {
            current = parent
            selection = node.id
        }
    }

    private var scanTask: Task<Void, Never>?

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
                current = root
                phase = .done(root: root)
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
