import AppKit
import SwiftUI

@MainActor
final class PerformanceDashboardWindowController: NSObject, NSWindowDelegate {
    private let database: UsageHistoryDatabaseWorking
    private let performanceInstrumentationStore: AppPerformanceInstrumentationStore
    private let collectionModeController: UsageCollectionModeController
    private var window: NSWindow?
    private var pendingOpenSpan: AppPerformanceSpan?

    init(
        database: UsageHistoryDatabaseWorking,
        performanceInstrumentationStore: AppPerformanceInstrumentationStore = .shared,
        collectionModeController: UsageCollectionModeController = UsageCollectionModeController()
    ) {
        self.database = database
        self.performanceInstrumentationStore = performanceInstrumentationStore
        self.collectionModeController = collectionModeController
    }

    func prepareOpenInstrumentation() {
        pendingOpenSpan = performanceInstrumentationStore.begin(
            .performanceDashboardOpen,
            metadata: ["dashboard": "performance", "windowState": window == nil ? "new" : "existing"]
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
                metadata: ["dashboard": "performance", "windowState": "existing"]
            )
            pendingOpenSpan = nil
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Performance Dashboard"
        window.minSize = NSSize(width: 1280, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("CodexPerformanceDashboardWindow")
        window.contentViewController = NSHostingController(
            rootView: PerformanceDashboardView(
                database: database,
                performanceInstrumentationStore: performanceInstrumentationStore,
                collectionModeController: collectionModeController,
                onFirstRendered: { [weak self] in
                    self?.recordFirstRendered()
                }
            )
        )
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
            metadata: ["dashboard": "performance", "windowState": "new"]
        )
        pendingOpenSpan = nil
    }

    private func enforceMinimumFrame(for window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }

        let clampedFrame = PerformanceDashboardWindowFrame.clampedFrame(
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
                metadata: ["dashboard": "performance"]
            )
            pendingOpenSpan = nil
        }
        window = nil
    }
}

enum PerformanceDashboardWindowFrame {
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
