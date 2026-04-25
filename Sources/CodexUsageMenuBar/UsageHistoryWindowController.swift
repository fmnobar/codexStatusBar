import AppKit
import SwiftUI

@MainActor
final class UsageHistoryWindowController: NSObject, NSWindowDelegate {
    private let store: UsageHistoryStore
    private var window: NSWindow?

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
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Usage History"
        window.minSize = NSSize(width: 760, height: 640)
        window.delegate = self
        window.setFrameAutosaveName("CodexUsageHistoryWindow")
        window.contentViewController = NSHostingController(rootView: UsageHistoryView(store: store))
        window.center()
        enforceMinimumFrame(for: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func enforceMinimumFrame(for window: NSWindow) {
        var frame = window.frame
        var didChangeFrame = false

        if frame.width < window.minSize.width {
            frame.size.width = window.minSize.width
            didChangeFrame = true
        }

        if frame.height < window.minSize.height {
            let heightDelta = window.minSize.height - frame.height
            frame.origin.y -= heightDelta
            frame.size.height = window.minSize.height
            didChangeFrame = true
        }

        if didChangeFrame {
            window.setFrame(frame, display: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
