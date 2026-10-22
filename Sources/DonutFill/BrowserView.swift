import AppKit
import ScanKit
import SwiftUI

struct BrowserView: View {
    @Bindable var model: ScanModel

    var body: some View {
        // Read so in-place tree edits (after trashing) re-render the list.
        let _ = model.treeVersion
        if let folder = model.current {
            VStack(spacing: 0) {
                BreadcrumbBar(folder: folder) { model.current = $0 }
                Divider()
                HSplitView {
                    list(of: folder)
                        .frame(minWidth: 280, idealWidth: 360)
                    SunburstView(
                        folder: folder,
                        segments: model.segments,
                        selection: model.selection,
                        onOpen: model.open,
                        onSelect: model.open,
                        onUp: { if let parent = folder.parent { withAnimation(.easeOut(duration: 0.25)) { model.current = parent } } },
                        isCollected: model.collector.contains,
                        onCollect: model.collect
                    )
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                CollectorBar(model: model)
                if model.progress.unreadable > 0 {
                    Divider()
                    UnreadableBanner(count: model.progress.unreadable)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        model.current = folder.parent
                    } label: {
                        Label("Up", systemImage: "chevron.left")
                    }
                    .disabled(folder.parent == nil)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                }
                ToolbarItemGroup {
                    Button {
                        if let path = model.lastScannedPath { model.scan(path: path) }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    Button(action: model.reset) {
                        Label("New Scan", systemImage: "plus.magnifyingglass")
                    }
                }
            }
            .navigationTitle(folder.displayName)
            .navigationSubtitle("\(formatBytes(folder.size)) · \(folder.fileCount.formatted()) files")
        }
    }

    private func list(of folder: FileNode) -> some View {
        List(folder.children, selection: $model.selection) { node in
            NodeRow(node: node, parentSize: folder.size, isCollected: model.collector.contains(node))
                .draggable(node.path)
                .contextMenu {
                    Button("Add to Collector") { model.collect(node) }
                        .disabled(model.collector.contains(node))
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                    }
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: node.path)) }
                }
        }
        .contextMenu(forSelectionType: FileNode.ID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let node = folder.children.first(where: { $0.id == id }), node.isDirectory {
                withAnimation(.easeOut(duration: 0.25)) { model.current = node }
            }
        }
    }
}

private struct BreadcrumbBar: View {
    let folder: FileNode
    let onSelect: (FileNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(folder.ancestry) { node in
                    if node !== folder.ancestry.first {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    Button(node.displayName) { onSelect(node) }
                        .buttonStyle(.plain)
                        .fontWeight(node === folder ? .semibold : .regular)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct NodeRow: View {
    let node: FileNode
    let parentSize: Int64
    let isCollected: Bool

    private var share: Double {
        parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(isCollected)
            if isCollected {
                Image(systemName: "tray.full").foregroundStyle(.secondary).help("In the Collector")
            }
            Spacer()
            ProgressView(value: share)
                .frame(width: 120)
            Text(formatBytes(node.size))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .opacity(node.isDirectory ? 1 : 0)
        }
        .padding(.vertical, 2)
    }
}

private struct UnreadableBanner: View {
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text("\(count.formatted()) folders couldn't be read. Grant Full Disk Access for a complete picture.")
                .font(.callout)
            Spacer()
            Button("Open Settings") { ScanModel.openFullDiskAccessSettings() }
        }
        .padding(10)
    }
}
