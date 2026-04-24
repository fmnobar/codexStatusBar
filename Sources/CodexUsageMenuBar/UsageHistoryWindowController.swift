import AppKit
import SwiftUI

@MainActor
final class UsageHistoryWindowController: NSObject, NSWindowDelegate {
    private let store: UsageHistoryStore
    private weak var window: NSWindow?

    init(store: UsageHistoryStore) {
        self.store = store
    }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Usage History"
        window.minSize = NSSize(width: 760, height: 460)
        window.delegate = self
        window.setFrameAutosaveName("CodexUsageHistoryWindow")
        window.contentViewController = NSHostingController(rootView: UsageHistoryView(store: store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
