import AppKit
import ScanKit
import SwiftUI

/// Dev aid for checking UI without a screen:
///   DonutFill --snapshot <folder> <output.png> [--dark] [--hover N] [--expand]
///       scans a folder and renders the browser (list + chart), optionally hovering
///       the N-th first-ring arc or expanding the "smaller objects" row
///   DonutFill --snapshot start <output.png> [--dark]      renders the start screen
/// Writes the PNG and exits.
enum Snapshot {
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 2 < args.count else { return false }
        let target = args[flag + 1]
        let output = URL(fileURLWithPath: args[flag + 2])
        let appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)

        Task { @MainActor in
            do {
                let view: AnyView
                let size: CGSize
                if target == "start" {
                    let model = ScanModel()
                    await model.refreshVolumes()
                    view = AnyView(StartView(model: model))
                    size = CGSize(width: 900, height: 560)
                } else {
                    let model = ScanModel()
                    model.scan(path: target)
                    while true {
                        if case .done = model.phase { break }
                        if case let .failed(message) = model.phase { throw ScanError.notADirectory(path: message) }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    if let index = args.firstIndex(of: "--hover"), index + 1 < args.count, let rank = Int(args[index + 1]) {
                        // Hover the n-th first-ring arc, to check list/chart highlighting.
                        model.hoveredSegmentID = model.segments.filter { $0.depth == 1 }.dropFirst(rank).first?.id
                    }
                    if args.contains("--expand") { model.showsAllChildren = true }
                    view = AnyView(BrowserView(model: model))
                    size = CGSize(width: 1100, height: 700)
                }
                try await render(view, size: size, appearance: appearance, to: output)
                print("Wrote \(output.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    /// Renders through a real (offscreen) window so AppKit-backed controls draw properly.
    @MainActor
    private static func render(_ view: AnyView, size: CGSize, appearance: NSAppearance?, to url: URL) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
