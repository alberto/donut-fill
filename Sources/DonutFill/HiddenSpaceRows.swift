import ScanKit
import SwiftUI

/// Rows that take the place of the list's rows to explain the hidden space: which
/// volumes share the drive, what's still unaccounted for, and which snapshots exist.
/// Rows rather than a List of their own: swapping the list's table for another one
/// makes AppKit drop the chart's hover tracking, so the chart stops reacting.
struct HiddenSpaceRows: View {
    let hidden: HiddenSpace
    let unreadable: [FileNode]
    let root: FileNode?
    /// Clicked open rather than previewed on hover, so it offers a close button.
    let isPinned: Bool
    let onClose: () -> Void
    /// Shows an unreadable folder in the list.
    let onShow: (FileNode) -> Void

    var body: some View {
        Group {
            header
                .selectionDisabled()

            if !hidden.otherVolumes.isEmpty {
                Section {
                    ForEach(hidden.otherVolumes, id: \.name) { volume in
                        row(
                            color: SegmentPalette.space(.otherVolumes),
                            title: volume.name,
                            detail: volume.purpose,
                            size: volume.size
                        )
                    }
                } header: {
                    sectionHeader("Other volumes", size: hidden.otherVolumesSize)
                }
            }

            Section {
                if hidden.unreadableFolders > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "lock.fill").foregroundStyle(.orange)
                        Text(hidden.unreadableFolders == 1 ? "1 folder couldn't be read:" : "\(hidden.unreadableFolders.formatted()) folders couldn't be read:")
                        Spacer()
                        Button("Full Disk Access…") { ScanModel.openFullDiskAccessSettings() }
                            .controlSize(.small)
                    }
                    UnreadableFolderRows(folders: unreadable, root: root, onShow: onShow, limit: 50)
                }
                Text("Also other users' files, the Spotlight index, document versions, local snapshots, and file system overhead (a few GB is normal).")
                    .foregroundStyle(.secondary)
            } header: {
                sectionHeader("Still hidden", size: hidden.stillHidden)
            }

            Section {
                if hidden.snapshots.isEmpty {
                    Text("None on this volume.").foregroundStyle(.secondary)
                } else {
                    ForEach(hidden.snapshots, id: \.name) { snapshot in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.name).lineLimit(1).truncationMode(.middle)
                            if !snapshot.isMadeByMacOS {
                                Label("Made by another app. macOS won't remove it.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .help(snapshot.name)
                    }
                    Text("Their space is part of the purgeable or still hidden space; macOS doesn't report their sizes. Manage them with tmutil or the app that made them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Local snapshots" + (hidden.snapshots.isEmpty ? "" : " (\(hidden.snapshots.count))"))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hidden space").font(.headline)
                Text("Used space the scan couldn't see.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(hidden.total)).font(.headline).monospacedDigit()
            if isPinned {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Back to the list")
            }
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(_ title: String, size: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(formatBytes(size)).monospacedDigit()
        }
    }

    private func row(color: Color, title: String, detail: String?, size: Int64) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).lineLimit(1)
            if let detail {
                Text(detail).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(formatBytes(size)).monospacedDigit()
        }
    }
}
