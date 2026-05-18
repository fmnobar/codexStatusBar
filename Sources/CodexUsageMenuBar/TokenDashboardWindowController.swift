import AppKit
import SwiftUI

@MainActor
final class TokenDashboardWindowController: NSObject, NSWindowDelegate {
    private let database: UsageHistoryDatabaseWorking
    private var window: NSWindow?

    init(database: UsageHistoryDatabaseWorking) {
        self.database = database
    }

    func showWindow() {
        if let window {
            enforceMinimumFrame(for: window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Token Dashboard"
        window.minSize = NSSize(width: 1120, height: 560)
        window.delegate = self
        window.setFrameAutosaveName("CodexTokenDashboardWindow")
        window.contentViewController = NSHostingController(rootView: TokenDashboardView(database: database))
        window.center()
        enforceMinimumFrame(for: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func enforceMinimumFrame(for window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }

        let clampedFrame = TokenDashboardWindowFrame.clampedFrame(
            window.frame,
            minimumSize: window.minSize,
            visibleFrame: visibleFrame
        )

        if clampedFrame != window.frame {
            window.setFrame(clampedFrame, display: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

enum TokenDashboardWindowFrame {
    static func clampedFrame(
        _ frame: CGRect,
        minimumSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        UsageHistoryWindowFrame.clampedFrame(
            frame,
            minimumSize: minimumSize,
            visibleFrame: visibleFrame
        )
    }
}
