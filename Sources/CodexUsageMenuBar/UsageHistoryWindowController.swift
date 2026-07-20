import AppKit
import SwiftUI

enum MenuBarApplicationLifecycle {
    static let shouldTerminateAfterLastWindowClosed = false
}

@MainActor
final class UsageHistoryWindowController: NSObject, NSWindowDelegate {
    private let database: UsageHistoryDatabaseWorking
    private let archiveController: HistoricalTokenArchiveController
    private var window: NSWindow?

    init(
        database: UsageHistoryDatabaseWorking,
        archiveController: HistoricalTokenArchiveController? = nil
    ) {
        self.database = database
        self.archiveController = archiveController ?? .shared
    }

    func showWindow() {
        if let window {
            enforceMinimumFrame(for: window)
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
        window.minSize = NSSize(width: 700, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("CodexUsageHistoryWindow")
        window.contentViewController = NSHostingController(
            rootView: UsageHistoryView(database: database, archiveController: archiveController)
        )
        archiveController.beginViewing()
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

        let clampedFrame = UsageHistoryWindowFrame.clampedFrame(
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
        archiveController.endViewing()
    }
}

enum UsageHistoryWindowFrame {
    static func clampedFrame(
        _ frame: CGRect,
        minimumSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return frame
        }

        let width = min(max(frame.width, minimumSize.width), visibleFrame.width)
        let height = min(max(frame.height, minimumSize.height), visibleFrame.height)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let originX = min(max(frame.origin.x, visibleFrame.minX), maxX)
        let originY = min(max(frame.origin.y, visibleFrame.minY), maxY)

        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}
