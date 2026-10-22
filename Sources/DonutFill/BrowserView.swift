import AppKit
import QuickLook
import ScanKit
import SwiftUI

struct BrowserView: View {
    @Bindable var model: ScanModel
    /// Flipped to scroll the list back to its top.
    @State private var scrollsToTop = false
    /// The window's width, to size the breadcrumbs in the toolbar.
    @State private var width: CGFloat = 0

    var body: some View {
        // Read so in-place tree edits (after trashing) re-render the list.
        let _ = model.treeVersion
        if let folder = model.current {
            VStack(spacing: 0) {
                FolderHeader(folder: folder)
                Divider()
                HSplitView {
                    list(
                        of: model.listFolder ?? folder,
                        isPreview: model.listFolder != folder,
                        hidden: model.showsHiddenPanel ? model.hiddenSpace : nil
                    )
                    .frame(minWidth: 280, idealWidth: 360)
                    .background { InitialSplit(fraction: 1.0 / 3) }
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
                if !model.unreadableFolders.isEmpty {
                    Divider()
                    UnreadableBanner(folders: model.unreadableFolders, root: model.root, onShow: model.reveal)
                }
            }
            .background { KeyCommands(model: model) }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .task { await model.watchForChanges() }
            .task(id: StaleCheckKey(folder: model.listFolder?.id, treeVersion: model.treeVersion)) {
                await model.checkStale()
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: model.goBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(!model.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to the previous folder (⌘[)")
                    Button(action: model.goForward) {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .disabled(!model.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Forward again (⌘])")
                }
                ToolbarItem(placement: .navigation) {
                    // Toolbar items take their ideal width, so cap the breadcrumbs at the room
                    // left by the window controls and buttons, for them to fold to fit.
                    BreadcrumbBar(folder: folder, onHome: model.reset) { model.current = $0 }
                        .frame(maxWidth: max(160, width - 340), alignment: .leading)
                }
                // Pushes the actions to the right edge, where the window title used to.
                if #available(macOS 26, *) {
                    ToolbarSpacer(.flexible)
                }
                ToolbarItemGroup {
                    Button(action: model.togglePreview) {
                        Label("Quick Look", systemImage: "eye")
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Preview the item under the pointer, or the selected one (Space)")
                    // No separate ⇧⌘R: SwiftUI matches it to plain ⌘R presses too.
                    // ⌘R at the top level rescans everything.
                    Button(action: model.rescanCurrentFolder) {
                        if model.rescanningPath != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.rescanningPath != nil)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Rescan this folder (⌘R). At the top level, rescans everything.")
                }
            }
            .quickLookPreview($model.previewURL)
            .hidingWindowTitle(folder.displayName)
        }
    }

    /// Mirrors the chart: items drawn as their own arc get a row each and the rest
    /// collapse into one "smaller objects" row that expands to the full list.
    /// `isPreview` means the list shows a folder hovered in the chart, not `current`.
    /// With `hidden`, the list shows the hidden space breakdown instead.
    private func list(of folder: FileNode, isPreview: Bool, hidden: HiddenSpace?) -> some View {
        let aggregate = model.aggregatesByParent[folder.id]
        let collapsed = aggregate != nil && (isPreview || !model.showsAllChildren)
        let rows = model.listRows(of: folder, isPreview: isPreview)
        let hovered = model.hoveredSegment

        return ScrollViewReader { proxy in
        List(selection: $model.selection) {
            if let hidden {
                HiddenSpaceRows(
                    hidden: hidden,
                    unreadable: model.unreadableFolders,
                    root: model.root,
                    isPinned: model.showsHiddenSpace,
                    onClose: { model.showsHiddenSpace = false },
                    onShow: model.reveal
                )
            } else {
            if isPreview {
                PreviewHeader(folder: folder)
            }
            ForEach(rows) { node in
                let segment = model.segmentsByNode[node.id]
                NodeRow(
                    node: node,
                    size: node.size,
                    color: segment.map { SegmentPalette.color(for: $0, colors: model.colors) } ?? SegmentPalette.aggregate(),
                    isCollected: model.collector.contains(node),
                    isStale: model.staleIDs.contains(node.id),
                    isHighlighted: hovered?.node.map { $0 == node || $0.isDescendant(of: node) } ?? false
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
                    isExpanded: !collapsed,
                    isHighlighted: hovered?.id == aggregate.id
                )
                .onHover { inside in hover(aggregate, inside) }
                .onTapGesture { model.showsAllChildren.toggle() }
            }
            }
        }
        .onHover { inside in
            if !inside && !model.isChartHover {
                model.hover(segmentID: nil, fromChart: false)
            }
        }
        // A focused list handles ⌘↑/⌘↓ itself (first/last row), before the window's
        // shortcuts see them, so take them here.
        .onKeyPress(.upArrow, phases: .down) { press in
            guard press.modifiers.contains(.command), let parent = model.current?.parent else { return .ignored }
            model.current = parent
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.openSelection()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            model.openSelection()
            return .handled
        }
        // Keep the keyboard selection in view.
        .onChange(of: model.selection) { _, id in
            if let id { proxy.scrollTo(id) }
        }
        // Start each folder (hovered or opened) at the top, or at its selected item.
        .onChange(of: ListContent(folder: folder.id, isHidden: hidden != nil)) {
            if hidden == nil, let selection = model.selection, rows.contains(where: { $0.id == selection }) {
                proxy.scrollTo(selection)
            } else {
                scrollsToTop.toggle()
            }
        }
        .background { ScrollToTop(trigger: scrollsToTop) }
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

private extension View {
    /// The breadcrumbs and the folder header already name the folder, so the toolbar
    /// leaves the title out; on macOS 15+ it stays for the Window menu.
    @ViewBuilder func hidingWindowTitle(_ title: String) -> some View {
        if #available(macOS 15, *) {
            navigationTitle(title).toolbar(removing: .title)
        } else {
            navigationTitle("")
        }
    }
}

/// The shown folder's name, size and file count, above the list and chart.
private struct FolderHeader: View {
    let folder: FileNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(folder.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
            Text("\(formatBytes(folder.size)) · \(folder.fileCount.formatted()) files")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Home, then the path to the shown folder, in the toolbar. When the path doesn't
/// fit, its middle folders fold into a "…" menu, as toolbar items can't scroll.
private struct BreadcrumbBar: View {
    let folder: FileNode
    /// Back to the start screen, to scan something else.
    let onHome: () -> Void
    let onSelect: (FileNode) -> Void

    var body: some View {
        let path = folder.ancestry
        // No chevron after home: it leads to the start screen, not to the path's parent.
        HStack(spacing: 10) {
            Button(action: onHome) {
                Image(systemName: "house")
            }
            .help("Back to the start screen, to scan another disk or folder")
            .accessibilityLabel("New Scan")
            // The whole path, else fold more and more of the middle, keeping the first and last.
            ViewThatFits(in: .horizontal) {
                ForEach(0..<max(1, path.count - 1), id: \.self) { folding in
                    crumbs(path, folding: folding)
                }
            }
        }
        // The home button brings its own inset; the last crumb's text doesn't.
        .padding(.leading, 4)
        .padding(.trailing, 12)
    }

    /// The path with `folding` folders after the first folded into a menu.
    private func crumbs(_ path: [FileNode], folding: Int) -> some View {
        let folded = folding > 0 ? Array(path[1...folding]) : []
        return HStack(spacing: 4) {
            ForEach(path) { node in
                if folded.first == node {
                    if node != path.first { chevron }
                    Menu("…") {
                        ForEach(folded) { node in
                            Button(node.displayName) { onSelect(node) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else if !folded.contains(node) {
                    if node != path.first { chevron }
                    Button(node.displayName) { onSelect(node) }
                        .buttonStyle(.plain)
                        .fontWeight(node == folder ? .semibold : .regular)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
    }
}

private struct NodeRow: View {
    let node: FileNode
    /// Passed by value: the node stays equal after in-place edits
    /// (trashing, rescans), so SwiftUI wouldn't notice its size changing.
    let size: Int64
    let color: Color
    let isCollected: Bool
    /// No longer on disk at this path.
    let isStale: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(isStale)
                .foregroundStyle(isStale || isCollected ? .secondary : .primary)
                .help(isStale ? "No longer at this location. Rescan to update." : node.path)
            if node.isUnreadable {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .help("Couldn't be read, so its contents count as hidden space")
            }
            if isCollected {
                Image(systemName: "tray.full").foregroundStyle(.secondary).help("In the Collector")
            }
            Spacer()
            Text(formatBytes(size))
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
    let folders: [FileNode]
    let root: FileNode?
    let onShow: (FileNode) -> Void
    @State private var showsList = false

    var body: some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text(folders.count == 1 ? "1 folder couldn't be read. Grant Full Disk Access for a complete picture." : "\(folders.count.formatted()) folders couldn't be read. Grant Full Disk Access for a complete picture.")
                .font(.callout)
            Spacer()
            Button("Show Folders") { showsList = true }
                .popover(isPresented: $showsList, arrowEdge: .top) {
                    List {
                        UnreadableFolderRows(folders: folders, root: root, onShow: { node in
                            showsList = false
                            onShow(node)
                        })
                    }
                    .frame(width: 460, height: 360)
                }
            Button("Open Settings") { ScanModel.openFullDiskAccessSettings() }
        }
        .padding(10)
    }
}

/// Rows for folders the scan couldn't open: click one to show it in its folder.
struct UnreadableFolderRows: View {
    let folders: [FileNode]
    let root: FileNode?
    let onShow: (FileNode) -> Void
    var limit = 500

    var body: some View {
        ForEach(folders.prefix(limit)) { node in
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.orange).font(.caption)
                Button(relativePath(node)) { onShow(node) }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help("Show in the list: \(node.path)")
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
        }
        if folders.count > limit {
            Text("and \((folders.count - limit).formatted()) more").foregroundStyle(.secondary)
        }
        Text("Some are protected by macOS and stay locked even with Full Disk Access.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func relativePath(_ node: FileNode) -> String {
        guard let root, node.path.hasPrefix(root.path) else { return node.path }
        let relative = node.path.dropFirst(root.path.count).drop { $0 == "/" }
        return relative.isEmpty ? node.path : String(relative)
    }
}

/// What the list shows; when it changes, the list scrolls back to the top.
private struct ListContent: Equatable {
    let folder: FileNode.ID
    let isHidden: Bool
}

/// Scrolls the list next to it to the very top whenever `trigger` flips.
/// ScrollViewReader can only bring a row to the top, leaving the list's top padding hidden.
private struct ScrollToTop: NSViewRepresentable {
    let trigger: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard trigger != context.coordinator.trigger else { return }
        context.coordinator.trigger = trigger
        // After SwiftUI has put the new rows in the table.
        DispatchQueue.main.async {
            var view = nsView.superview
            while let current = view, !(current.superview is NSSplitView) {
                if let scrollView = Self.tableScrollView(in: current) {
                    scrollView.documentView?.scroll(.zero)
                    return
                }
                view = current.superview
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(trigger: trigger) }

    final class Coordinator {
        var trigger: Bool
        init(trigger: Bool) { self.trigger = trigger }
    }

    private static func tableScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView { return scrollView }
        return view.subviews.lazy.compactMap(tableScrollView).first
    }
}

/// Re-checks the list for items gone from disk whenever it shows another folder or the tree changes.
private struct StaleCheckKey: Equatable {
    let folder: FileNode.ID?
    let treeVersion: Int
}

/// Puts the enclosing split view's divider at `fraction` of its width once it
/// first has a size; HSplitView ignores ideal widths and splits in half.
/// Afterwards the divider stays wherever the user drags it.
private struct InitialSplit: NSViewRepresentable {
    let fraction: CGFloat

    func makeNSView(context: Context) -> Probe { Probe(fraction: fraction) }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        let fraction: CGFloat
        private var didPosition = false

        init(fraction: CGFloat) {
            self.fraction = fraction
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            guard !didPosition else { return }
            var view = superview
            while let current = view, !(current is NSSplitView) { view = current.superview }
            guard let split = view as? NSSplitView, split.bounds.width > 0 else { return }
            didPosition = true
            DispatchQueue.main.async { [fraction] in
                split.setPosition((split.bounds.width * fraction).rounded(), ofDividerAt: 0)
            }
        }
    }
}

/// Window-wide keys for browsing. Hidden buttons, so the keys work whether the
/// list or the chart has focus.
private struct KeyCommands: View {
    let model: ScanModel

    var body: some View {
        Group {
            Button("Previous Item") { model.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Next Item") { model.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("Open") { model.openSelection() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Open") { model.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Add to Collector") { model.collectPointedOrSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Up") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            // Esc closes the hidden space breakdown, else goes up a level.
            Button("Close or Up") {
                if model.showsHiddenSpace {
                    model.showsHiddenSpace = false
                } else {
                    model.goUp()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
