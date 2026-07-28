import AppKit
import SwiftUI

@MainActor
final class TokenDashboardWindowController: NSObject, NSWindowDelegate {
    private let database: UsageHistoryDatabaseWorking
    private let performanceInstrumentationStore: AppPerformanceInstrumentationStore
    private let collectionModeController: UsageCollectionModeController
    private let archiveController: HistoricalTokenArchiveController
    private var window: NSWindow?
    private var pendingOpenSpan: AppPerformanceSpan?

    init(
        database: UsageHistoryDatabaseWorking,
        performanceInstrumentationStore: AppPerformanceInstrumentationStore? = nil,
        collectionModeController: UsageCollectionModeController? = nil,
        archiveController: HistoricalTokenArchiveController? = nil
    ) {
        self.database = database
        self.performanceInstrumentationStore = performanceInstrumentationStore ?? .shared
        self.collectionModeController = collectionModeController ?? UsageCollectionModeController()
        self.archiveController = archiveController ?? .shared
    }

    func prepareOpenInstrumentation() {
        pendingOpenSpan = performanceInstrumentationStore.begin(
            .tokenDashboardOpen,
            metadata: ["dashboard": "token", "windowState": window == nil ? "new" : "existing"]
        )
    }

    func showWindow() {
        if let window {
            enforceMinimumFrame(for: window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            performanceInstrumentationStore.finish(
                pendingOpenSpan,
                status: .success,
                metadata: ["dashboard": "token", "windowState": "existing"]
            )
            pendingOpenSpan = nil
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Token Dashboard"
        window.minSize = TokenDashboardLayout.minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("CodexTokenDashboardWindow")
        window.contentViewController = NSHostingController(
            rootView: TokenDashboardView(
                database: database,
                performanceInstrumentationStore: performanceInstrumentationStore,
                collectionModeController: collectionModeController,
                archiveController: archiveController,
                onFirstRendered: { [weak self] in
                    self?.recordFirstRendered()
                }
            )
        )
        archiveController.beginViewing()
        window.center()
        enforceMinimumFrame(for: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func recordFirstRendered() {
        guard pendingOpenSpan != nil else {
            return
        }

        performanceInstrumentationStore.finish(
            pendingOpenSpan,
            status: .success,
            metadata: ["dashboard": "token", "windowState": "new"]
        )
        pendingOpenSpan = nil
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
        if pendingOpenSpan != nil {
            performanceInstrumentationStore.finish(
                pendingOpenSpan,
                status: .cancelled,
                metadata: ["dashboard": "token"]
            )
            pendingOpenSpan = nil
        }
        window = nil
        archiveController.endViewing()
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
