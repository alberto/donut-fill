import ScanKit
import SwiftUI

struct ContentView: View {
    @State private var model = ScanModel()

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                WelcomeView(model: model)
            case let .scanning(path):
                ScanningView(path: path, progress: model.progress, onCancel: model.reset)
            case .done:
                BrowserView(model: model)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Scan failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Back", action: model.reset)
                }
            }
        }
    }
}

private struct WelcomeView: View {
    let model: ScanModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("What would you like to scan?")
                .font(.title2)
            HStack(spacing: 12) {
                Button {
                    model.scan(path: "/System/Volumes/Data")
                } label: {
                    Label("Macintosh HD", systemImage: "internaldrive")
                }
                Button {
                    model.scan(path: FileManager.default.homeDirectoryForCurrentUser.path)
                } label: {
                    Label("Home Folder", systemImage: "house")
                }
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanningView: View {
    let path: String
    let progress: ScanProgress.Snapshot
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Scanning \(path)")
                .font(.headline)
            Text("\(progress.files.formatted()) files · \(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Cancel", action: onCancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
