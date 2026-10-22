import AppKit
import QuickLook
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
                    Group {
                        if model.showsHiddenPanel, let hidden = model.hiddenSpace {
                            HiddenSpacePanel(
                                hidden: hidden,
                                isPinned: model.showsHiddenSpace,
                                onClose: { model.showsHiddenSpace = false }
                            )
                        } else {
                            list(of: model.listFolder ?? folder, isPreview: model.listFolder !== folder)
                        }
                    }
                    .frame(minWidth: 280, idealWidth: 360)
                    SunburstView(
                        folder: folder,
                        segments: model.segments,
                        selection: model.selection,
                        onOpen: model.open,
                        onSelect: model.open,
                        onUp: { if let parent = folder.parent { model.current = parent } },
                        hoveredID: model.hoveredSegmentID,
                        onHover: { model.hover(segmentID: $0, fromChart: true) },
                        onExpandSmaller: { model.showsAllChildren = true },
                        isCollected: model.collector.contains,
                        canCollect: model.canCollect,
                        onCollect: model.collect,
                        onPreview: model.preview,
                        onShowHidden: { model.showsHiddenSpace = true },
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
                    Button(action: model.togglePreview) {
                        Label("Quick Look", systemImage: "eye")
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Preview the item under the pointer, or the selected one (Space)")
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
            .quickLookPreview($model.previewURL)
            .navigationTitle(folder.displayName)
            .navigationSubtitle("\(formatBytes(folder.size)) · \(folder.fileCount.formatted()) files")
        }
    }

    /// Mirrors the chart: items drawn as their own arc get a row each and the rest
    /// collapse into one "smaller objects" row that expands to the full list.
    /// `isPreview` means the list shows a folder hovered in the chart, not `current`.
    private func list(of folder: FileNode, isPreview: Bool) -> some View {
        let aggregate = model.aggregatesByParent[folder.id]
        let collapsed = aggregate != nil && (isPreview || !model.showsAllChildren)
        let rows = collapsed ? folder.children.filter { model.segmentsByNode[$0.id] != nil } : folder.children
        let hovered = model.hoveredSegment

        return List(selection: $model.selection) {
            if isPreview {
                PreviewHeader(folder: folder)
            }
            ForEach(rows) { node in
                let segment = model.segmentsByNode[node.id]
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
                        .disabled(!model.canCollect(node))
                    Button("Quick Look") { model.preview(node) }
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
                    isExpanded: !collapsed,
                    isHighlighted: hovered?.id == aggregate.id
                )
                .onHover { inside in hover(aggregate, inside) }
                .onTapGesture { model.showsAllChildren.toggle() }
            }
        }
        .onHover { inside in
            if !inside && !model.isChartHover {
                model.hover(segmentID: nil, fromChart: false)
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

    /// Rows only ever set the hover; leaving a row doesn't clear it, because the
    /// pointer crosses gaps between rows and the chart would flicker. The list
    /// clears it when the pointer leaves the list as a whole.
    private func hover(_ segment: SunburstSegment?, _ inside: Bool) {
        if inside {
            model.hover(segmentID: segment?.id, fromChart: false)
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
            if node.isUnreadable {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .help("Couldn't be read, so its contents count as hidden space")
            }
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

/// Shown above the list while it previews a folder hovered in the chart.
private struct PreviewHeader: View {
    let folder: FileNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
            Text(folder.displayName).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(formatBytes(folder.size)).monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .selectionDisabled()
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
