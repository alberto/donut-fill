import ScanKit
import SwiftUI

struct ContentView: View {
    @State private var model = ScanModel()

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                StartView(model: model)
            case let .scanning(path):
                ScanningView(path: path, progress: model.progress, estimate: model.estimate, started: model.scanStarted, onCancel: model.reset)
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

private struct ScanningView: View {
    let path: String
    let progress: ScanProgress.Snapshot
    let estimate: ScanEstimate?
    let started: ContinuousClock.Instant
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let estimate {
                ProgressView(value: estimate.fraction(of: progress))
                    .frame(width: 360)
            } else {
                ProgressView()
            }
            Text("Scanning \(path)")
                .font(.headline)
            Text(details)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Cancel", action: onCancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var details: String {
        let counts = "\(progress.files.formatted()) files · \(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))"
        guard let estimate else { return counts }
        if let remaining = estimate.remaining(after: .now - started, progress: progress) {
            return counts + " · " + Self.describe(remaining)
        }
        return counts + (estimate.fraction(of: progress) >= 0.99 ? " · Almost done" : " · Estimating time left")
    }

    /// Rounded, so the figure doesn't flicker as the rate wobbles.
    private static func describe(_ remaining: Duration) -> String {
        let seconds = Int(remaining.components.seconds)
        if seconds < 60 { return "About \(max(5, (seconds + 4) / 5 * 5)) s left" }
        return "About \((seconds + 30) / 60) min left"
    }
}
