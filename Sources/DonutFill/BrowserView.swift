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
                        onUp: { if let parent = folder.parent { model.current = parent } },
                        hoveredID: $model.hoveredSegmentID,
                        onExpandSmaller: { model.showsAllChildren = true },
                        isCollected: model.collector.contains,
                        onCollect: model.collect,
                        volume: model.visibleVolume,
                        colors: model.colors,
                        layoutVersion: model.layoutVersion
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

    /// Mirrors the chart's first ring: items big enough to draw get a row each and
    /// the rest collapse into one "smaller objects" row that expands to the full list.
    private func list(of folder: FileNode) -> some View {
        let aggregate = model.topAggregate
        let collapsed = aggregate != nil && !model.showsAllChildren
        let rows = collapsed ? folder.children.filter { model.topSegments[$0.id] != nil } : folder.children
        let hovered = model.hoveredSegment

        return List(selection: $model.selection) {
            ForEach(rows) { node in
                let segment = model.topSegments[node.id]
                NodeRow(
                    node: node,
                    parentSize: folder.size,
                    color: segment.map { SegmentPalette.color(for: $0, colors: model.colors) } ?? SegmentPalette.aggregate(),
                    isCollected: model.collector.contains(node),
                    isHighlighted: hovered?.node.map { $0 === node || $0.isDescendant(of: node) } ?? false
                )
                .onHover { inside in hover(segment, inside) }
                .contentShape(Rectangle())
                // Single click opens folders (like DaisyDisk) and selects files.
                .onTapGesture { open(node) }
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
            if let aggregate, case let .aggregate(_, count, size) = aggregate.kind {
                SmallerObjectsRow(
                    count: count,
                    size: size,
                    parentSize: folder.size,
                    isExpanded: model.showsAllChildren,
                    isHighlighted: hovered?.id == aggregate.id
                )
                .onHover { inside in hover(aggregate, inside) }
                .onTapGesture { model.showsAllChildren.toggle() }
            }
        }
    }

    private func open(_ node: FileNode) {
        if node.isDirectory {
            model.current = node
        } else {
            model.selection = node.id
        }
    }

    private func hover(_ segment: SunburstSegment?, _ inside: Bool) {
        if inside {
            model.hoveredSegmentID = segment?.id
        } else if model.hoveredSegmentID == segment?.id {
            model.hoveredSegmentID = nil
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
    let color: Color
    let isCollected: Bool
    let isHighlighted: Bool

    private var share: Double {
        parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
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
        .listRowBackground(isHighlighted ? Color.secondary.opacity(0.15) : Color.clear)
    }
}

private struct SmallerObjectsRow: View {
    let count: Int
    let size: Int64
    let parentSize: Int64
    let isExpanded: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(SegmentPalette.aggregate()).frame(width: 10, height: 10)
            Image(systemName: isExpanded ? "chevron.up.circle" : "ellipsis.circle")
                .font(.system(size: 16))
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
            Text(isExpanded ? "Show fewer" : "\(count.formatted()) smaller objects")
                .foregroundStyle(.secondary)
            Spacer()
            if !isExpanded {
                ProgressView(value: parentSize > 0 ? Double(size) / Double(parentSize) : 0)
                    .frame(width: 120)
                Text(formatBytes(size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
            Image(systemName: "chevron.right").opacity(0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowBackground(isHighlighted ? Color.secondary.opacity(0.15) : Color.clear)
        .help(isExpanded ? "Collapse to the items shown in the chart" : "Show all items")
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
