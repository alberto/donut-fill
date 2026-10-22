import AppKit
import ScanKit
import SwiftUI

/// Dev aid for checking UI without a screen:
///   DonutFill --snapshot <folder> <output.png> [--light] [--hover N] [--expand] [--hidden] [--open <path>] [--zoom <path>] [--remove <path>] [--keys k,k,...]
///       scans a folder and renders the browser (list + chart), optionally hovering
///       the N-th first-ring arc, expanding the "smaller objects" row, or opening
///       a subfolder with --open <absolute path>; --hidden opens the hidden space breakdown
///       (volume scans only); --remove <path> deletes that path after scanning, to check
///       that the list marks it as gone; --keys presses keys before capturing
///       (up, down, return, esc, cmd-up, cmd-down, cmd-delete, cmd-r; prefixes cmd- and shift- combine); --zoom <path> also saves
///       frames of the zoom animation as <output>-1.png, -2.png, ...
///   DonutFill --snapshot start <output.png> [--light]     renders the start screen
/// Writes the PNG and exits.
enum Snapshot {
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 2 < args.count else { return false }
        let target = args[flag + 1]
        let output = URL(fileURLWithPath: args[flag + 2])
        // Snapshots follow the app's (dark) appearance unless --light is passed.
        let appearance = args.contains("--light") ? NSAppearance(named: .aqua) : nil

        Task { @MainActor in
            do {
                let view: AnyView
                let size: CGSize
                var zoom: (action: () -> Void, delays: [Double])?
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
                        model.hover(segmentID: model.segments.filter { $0.depth == 1 }.dropFirst(rank).first?.id, fromChart: true)
                    }
                    if args.contains("--hidden") { model.showsHiddenSpace = true }
                    if let index = args.firstIndex(of: "--open"), index + 1 < args.count,
                       let node = model.root?.descendant(atPath: args[index + 1]) {
                        // Navigate into a subfolder, e.g. to check colors stay put when zooming.
                        model.current = node
                    }
                    if args.contains("--expand") { model.showsAllChildren = true }
                    if let index = args.firstIndex(of: "--zoom"), index + 1 < args.count,
                       let node = model.root?.descendant(atPath: args[index + 1]) {
                        // Capture the zoom animation into that folder as extra frames.
                        zoom = (action: { model.current = node }, delays: [0.08, 0.16, 0.24, 0.32, 0.5])
                    }
                    if let index = args.firstIndex(of: "--remove"), index + 1 < args.count {
                        try FileManager.default.removeItem(atPath: args[index + 1])
                    }
                    view = AnyView(BrowserView(model: model))
                    size = CGSize(width: 1100, height: 700)
                }
                let keys = args.firstIndex(of: "--keys").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?
                    .split(separator: ",").map(String.init) ?? []
                try await render(view, size: size, appearance: appearance, to: output, keys: keys, then: zoom)
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
    /// With `then`, runs that action after the first capture and saves extra frames
    /// (`<name>-1.png`, ...) at the given delays, to inspect animations.
    @MainActor
    private static func render(
        _ view: AnyView,
        size: CGSize,
        appearance: NSAppearance?,
        to url: URL,
        keys: [String] = [],
        then: (action: () -> Void, delays: [Double])? = nil
    ) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))
        for key in keys {
            try press(key, in: window)
            try await Task.sleep(for: .milliseconds(300))
        }
        // Toolbar changes (e.g. a progress spinner) can make SwiftUI resize this
        // toolbar-less window; restore the requested size before capturing.
        window.setContentSize(size)
        hosting.frame = CGRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(100))
        try capture(hosting, to: url)

        guard let then else { return }
        then.action()
        let start = ContinuousClock.now
        for (index, delay) in then.delays.enumerated() {
            try await Task.sleep(until: start + .milliseconds(Int(delay * 1000)))
            let frameURL = URL(fileURLWithPath: url.deletingPathExtension().path + "-\(index + 1).png")
            try capture(hosting, to: frameURL)
        }
    }

    /// Sends a key through the app, like a real key press (so `NSApp.currentEvent` is set).
    @MainActor
    private static func press(_ key: String, in window: NSWindow) throws {
        var name = Substring(key)
        var flags: NSEvent.ModifierFlags = []
        for (prefix, flag) in [("cmd-", NSEvent.ModifierFlags.command), ("shift-", .shift)] where name.hasPrefix(prefix) {
            flags.insert(flag)
            name = name.dropFirst(prefix.count)
        }
        let characters: String
        switch name {
        case "up": characters = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": characters = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "return": characters = "\r"
        case "delete": characters = String(UnicodeScalar(NSBackspaceCharacter)!)
        case "r": characters = flags.contains(.shift) ? "R" : "r"
        case "esc": characters = "\u{1b}"
        default: throw CocoaError(.featureUnsupported)
        }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: 0
        )
        guard let event else { throw CocoaError(.featureUnsupported) }
        window.makeKey()
        NSApp.sendEvent(event)
    }

    @MainActor
    private static func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
