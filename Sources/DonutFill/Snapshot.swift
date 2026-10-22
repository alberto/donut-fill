import AppKit
import ScanKit
import SwiftUI

/// Dev aid: `DonutFill --snapshot <folder> <output.png>` scans a folder, renders the
/// chart offscreen, writes a PNG and exits. Lets the chart be checked without a screen.
enum Snapshot {
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 2 < args.count else { return false }
        let folder = args[flag + 1]
        let output = URL(fileURLWithPath: args[flag + 2])

        Task { @MainActor in
            do {
                let root = try await Scanner().scan(path: folder)
                let view = HStack(spacing: 0) {
                    SunburstView(
                        folder: root,
                        segments: SunburstLayout.segments(for: root),
                        selection: root.children.first?.id,
                        onOpen: { _ in }, onSelect: { _ in }, onUp: {}
                    )
                }
                .frame(width: 800, height: 800)
                .background(Color(nsColor: .windowBackgroundColor))

                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: output)
                print("Wrote \(output.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        return true
    }
}
