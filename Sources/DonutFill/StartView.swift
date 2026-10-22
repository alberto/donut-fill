import AppKit
import ScanKit
import SwiftUI

/// Start screen: one card per mounted drive with its used/free space, plus
/// shortcuts for the home folder and any other folder (also accepts folder drops).
struct StartView: View {
    let model: ScanModel
    @State private var isDropTargeted = false

    /// Fixed-width columns, at most 4 and never more than there are cards, so a short row stays centered.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(200), spacing: 14), count: min(4, model.volumes.count + 2))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text("What would you like to scan?")
                    .font(.title2.weight(.semibold))

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.volumes) { volume in
                        VolumeCard(volume: volume) { model.scan(path: volume.scanPath) }
                    }
                    FolderCard(
                        title: "Home Folder",
                        detail: FileManager.default.homeDirectoryForCurrentUser.path,
                        path: FileManager.default.homeDirectoryForCurrentUser.path,
                        button: "Scan"
                    ) {
                        model.scan(path: FileManager.default.homeDirectoryForCurrentUser.path)
                    }
                    FolderCard(title: "Other Folder…", detail: "Pick any folder,\nor drop one here", path: nil, button: "Choose") {
                        model.chooseFolder()
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || isDirectory(url) else { return false }
            model.scan(path: url.path)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task { await model.watchVolumes() }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

private struct VolumeCard: View {
    let volume: MountedVolume
    let onScan: () -> Void

    private var space: VolumeSpace { volume.space }
    private var usedFraction: Double {
        Double(space.capacity - space.free - space.purgeable) / Double(space.capacity)
    }
    private var purgeableFraction: Double { Double(space.purgeable) / Double(space.capacity) }

    private var kind: String {
        let location = volume.isStartupDisk ? "Startup disk" : volume.isInternal ? "Internal" : "External"
        return [location, volume.format].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Card(highlighted: volume.isStartupDisk, button: "Scan", action: onScan) {
            UsageRing(used: usedFraction, purgeable: purgeableFraction)
                .frame(width: 96, height: 96)
            Text(space.name)
                .font(.headline)
                .lineLimit(1)
            VStack(spacing: 2) {
                Text("\(formatBytes(space.free)) free of \(formatBytes(space.capacity))")
                if space.purgeable >= 500_000_000 {
                    Text("+ \(formatBytes(space.purgeable)) purgeable")
                }
                Text(kind)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .help(volume.mountPath)
    }
}

private struct FolderCard: View {
    let title: String
    let detail: String
    /// Used for the Finder icon; nil shows a generic folder.
    let path: String?
    let button: String
    let action: () -> Void

    var body: some View {
        Card(highlighted: false, button: button, action: action) {
            Group {
                if let path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
                } else {
                    Image(systemName: "folder.badge.plus")
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 96, height: 96)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

private struct Card<Content: View>: View {
    let highlighted: Bool
    let button: String
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            content
            Spacer(minLength: 0)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .tint(highlighted ? .accentColor : .gray)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 230)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(highlighted || isHovered ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: highlighted ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
    }
}

/// Donut showing used (accent) and purgeable (grey) space.
private struct UsageRing: View {
    let used: Double
    let purgeable: Double

    private var color: Color {
        used > 0.9 ? .red : used > 0.75 ? .orange : .accentColor
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: used, to: min(1, used + purgeable))
                .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 12))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: used)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Text(used.formatted(.percent.precision(.fractionLength(0))))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .padding(6)
    }
}
