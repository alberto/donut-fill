import AppKit
import SwiftUI

@main
struct DonutFillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Donut Fill") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always dark, regardless of the system setting; covers windows, menus, alerts and panels.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if Snapshot.runIfRequested() { return }
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
