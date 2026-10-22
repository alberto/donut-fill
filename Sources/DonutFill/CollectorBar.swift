import AppKit
import ScanKit
import SwiftUI

/// Bottom bar holding items staged for deletion. Also the drop target for drags
/// from the list and the chart (which carry the item's path as text).
struct CollectorBar: View {
    @Bindable var model: ScanModel
    @State private var isTargeted = false
    @State private var confirmingTrash = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.title3)
                .foregroundStyle(model.collector.isEmpty ? .secondary : .primary)

            if model.collector.isEmpty, !model.trashed.isEmpty {
                trashedSummary
            } else if model.collector.isEmpty {
                Text("Drag items here, or right-click → Add to Collector, to gather them for deletion.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.collector.items) { node in
                            CollectedChip(node: node) { model.uncollect(node) }
                        }
                    }
                }
                Text(formatBytes(model.collector.totalSize))
                    .font(.headline)
                    .monospacedDigit()
                Button("Clear", action: model.clearCollector)
                Button(role: .destructive) {
                    confirmingTrash = true
                } label: {
                    if model.isTrashing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Move to Trash…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.isTrashing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(3)
            }
        }
        .overlay(alignment: .top) {
            if let notice = model.collectorNotice {
                Label(notice, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.orange.opacity(0.6)))
                    .offset(y: -40)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.collectorNotice)
        .dropDestination(for: String.self) { paths, _ in
            model.collect(paths: paths)
        } isTargeted: { isTargeted = $0 }
        .confirmationDialog(
            "Move \(model.collector.items.count) item(s) (\(formatBytes(model.collector.totalSize))) to the Trash?",
            isPresented: $confirmingTrash
        ) {
            Button("Move to Trash", role: .destructive, action: model.trashCollected)
        } message: {
            Text("Space is freed when you empty the Trash.")
        }
        .confirmationDialog(
            "Permanently delete \(formatBytes(model.trashedSize)) from the Trash?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Permanently", role: .destructive, action: model.deleteTrashed)
        } message: {
            Text("Only the items Donut Fill moved to the Trash are deleted. This can't be undone.")
        }
        .alert(
            model.failures?.title ?? "",
            isPresented: Binding(get: { model.failures != nil }, set: { if !$0 { model.failures = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.failures?.lines.prefix(5).joined(separator: "\n") ?? "")
        }
    }
}

extension CollectorBar {
    /// After trashing: the space only comes back once the Trash is emptied.
    @ViewBuilder
    private var trashedSummary: some View {
        Text("\(formatBytes(model.trashedSize)) moved to the Trash. It still takes up space until the Trash is emptied.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        Spacer()
        Button {
            confirmingDelete = true
        } label: {
            if model.isDeletingTrashed {
                ProgressView().controlSize(.small)
            } else {
                Text("Delete Now…")
            }
        }
        .disabled(model.isDeletingTrashed)
        Button {
            model.dismissTrashed()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Keep the items in the Trash")
    }
}

private struct CollectedChip: View {
    let node: FileNode
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(node.name).lineLimit(1)
            Text(formatBytes(node.size)).foregroundStyle(.secondary).monospacedDigit()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .help(node.path)
    }
}
