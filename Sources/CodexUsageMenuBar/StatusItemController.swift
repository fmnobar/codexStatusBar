import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let viewModel: MenuBarStatusViewModel
    private let historyDatabase: UsageHistoryDatabaseWorking
    private let updateMonitor: AppUpdateMonitor
    private let performanceInstrumentationStore: AppPerformanceInstrumentationStore
    private let codexSourceHealthStore: CodexSourceHealthStore
    private let popoverOpenInstrumentation: AppPerformanceSpanTracker
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var tokenDashboardWindowController = TokenDashboardWindowController(
        database: historyDatabase,
        performanceInstrumentationStore: performanceInstrumentationStore
    )
    private lazy var performanceDashboardWindowController = PerformanceDashboardWindowController(
        database: historyDatabase,
        performanceInstrumentationStore: performanceInstrumentationStore
    )
    private lazy var contextMenu = StatusItemContextMenuFactory.makeMenu(
        target: self,
        quitAction: #selector(quit)
    )

    private var cancellables = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var pendingLaunchToMenuTitleSpan: AppPerformanceSpan?

    init(
        viewModel: MenuBarStatusViewModel,
        historyDatabase: UsageHistoryDatabaseWorking,
        updateMonitor: AppUpdateMonitor,
        performanceInstrumentationStore: AppPerformanceInstrumentationStore = .shared,
        codexSourceHealthStore: CodexSourceHealthStore = .shared,
        launchToMenuTitleSpan: AppPerformanceSpan? = nil
    ) {
        self.viewModel = viewModel
        self.historyDatabase = historyDatabase
        self.updateMonitor = updateMonitor
        self.performanceInstrumentationStore = performanceInstrumentationStore
        self.codexSourceHealthStore = codexSourceHealthStore
        self.popoverOpenInstrumentation = AppPerformanceSpanTracker(
            kind: .menuPopoverOpenToContent,
            instrumentationStore: performanceInstrumentationStore,
            baseMetadata: ["surface": "menuPopover"]
        )
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = "CodexStatusBarStatusItem"
        self.pendingLaunchToMenuTitleSpan = launchToMenuTitleSpan
        StatusItemVisibility.forceVisible(statusItem)
        super.init()

        configurePopover()
        configureStatusItem()
        bindViewModel()
        updateStatusItemTitle(viewModel.menuBarPercentText)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                viewModel: viewModel,
                historyDatabase: historyDatabase,
                updateMonitor: updateMonitor,
                performanceInstrumentationStore: performanceInstrumentationStore,
                codexSourceHealthStore: codexSourceHealthStore,
                onOpenTokenDashboard: { [weak self] in
                    self?.openTokenDashboard()
                },
                onOpenPerformanceDashboard: { [weak self] in
                    self?.openPerformanceDashboard()
                },
                onOpenUpdatesSettings: { [weak self] in
                    self?.openUpdatesSettings()
                },
                onOpenDataSettings: { [weak self] in
                    self?.openDataSettings()
                },
                onFirstRendered: { [weak self] in
                    self?.recordPopoverContentRendered()
                },
                onContentSizeChange: { [weak self] size in
                    self?.updatePopoverContentSize(size)
                }
            )
        )
    }

    private func configureStatusItem() {
        StatusItemVisibility.forceVisible(statusItem)

        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .noImage
        button.image = nil
        StatusItemToolTipPolicy.apply(to: button)
        button.appearsDisabled = false
    }

    private func bindViewModel() {
        viewModel.$menuBarPercentText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.updateStatusItemTitle(text)
            }
            .store(in: &cancellables)

    }

    private func updateStatusItemTitle(_ text: String) {
        guard let button = statusItem.button else {
            return
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let visibleText = StatusItemTitleLayout.visibleText(text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributedTitle = NSAttributedString(
            string: visibleText,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
            ]
        )

        button.title = visibleText
        button.attributedTitle = attributedTitle
        button.cell?.lineBreakMode = .byTruncatingTail
        statusItem.length = StatusItemTitleLayout.length(for: visibleText, font: font)
        StatusItemVisibility.forceVisible(statusItem)

        if visibleText != "--",
           !visibleText.isEmpty,
           pendingLaunchToMenuTitleSpan != nil
        {
            performanceInstrumentationStore.finish(
                pendingLaunchToMenuTitleSpan,
                status: .success,
                metadata: ["surface": "menuBar"]
            )
            pendingLaunchToMenuTitleSpan = nil
        }
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            showContextMenu()
        case .leftMouseUp:
            togglePopover(relativeTo: sender)
        default:
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popoverOpenInstrumentation.discardPendingSpan()
            popover.performClose(nil)
            return
        }

        popoverOpenInstrumentation.begin()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startOutsideClickMonitors()

        Task {
            await viewModel.popoverDidAppear()
        }

        Task {
            await updateMonitor.checkIfNeeded()
        }
    }

    private func updatePopoverContentSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else {
            return
        }

        let maxHeight = maxPopoverHeight()
        let clampedSize = NSSize(
            width: size.width,
            height: min(size.height, maxHeight)
        )

        guard abs(popover.contentSize.width - clampedSize.width) > 0.5
            || abs(popover.contentSize.height - clampedSize.height) > 0.5
        else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            popover.contentSize = clampedSize
        }
    }

    private func maxPopoverHeight() -> CGFloat {
        let visibleFrame = statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 820, height: 760)

        return max(320, visibleFrame.height - 36)
    }

    private func showContextMenu() {
        popoverOpenInstrumentation.discardPendingSpan()
        popover.performClose(nil)
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func openTokenDashboard() {
        tokenDashboardWindowController.prepareOpenInstrumentation()
        popoverOpenInstrumentation.discardPendingSpan()
        popover.performClose(nil)
        tokenDashboardWindowController.showWindow()
    }

    private func openPerformanceDashboard() {
        performanceDashboardWindowController.prepareOpenInstrumentation()
        popoverOpenInstrumentation.discardPendingSpan()
        popover.performClose(nil)
        performanceDashboardWindowController.showWindow()
    }

    private func openUpdatesSettings() {
        popoverOpenInstrumentation.discardPendingSpan()
        popover.performClose(nil)
        SettingsTabSelectionStore.select(.updates)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openDataSettings() {
        popoverOpenInstrumentation.discardPendingSpan()
        popover.performClose(nil)
        SettingsTabSelectionStore.select(.data)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverOpenInstrumentation.discardPendingSpan()
        stopOutsideClickMonitors()
    }

    private func recordPopoverContentRendered() {
        guard popoverOpenInstrumentation.hasPendingSpan else {
            return
        }

        popoverOpenInstrumentation.finish()
    }

    private func startOutsideClickMonitors() {
        stopOutsideClickMonitors()

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.closePopoverIfNeeded(for: event)
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            Task { @MainActor in
                self?.closePopoverIfNeeded(for: event)
            }
        }
    }

    private func stopOutsideClickMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func closePopoverIfNeeded(for event: NSEvent) {
        guard popover.isShown else {
            return
        }

        let screenLocation = screenLocation(for: event)

        if clickIsInsidePopover(at: screenLocation) || clickIsOnStatusItem(at: screenLocation) {
            return
        }

        popover.performClose(nil)
    }

    private func clickIsInsidePopover(at screenLocation: NSPoint) -> Bool {
        guard let popoverWindow = popover.contentViewController?.view.window else {
            return false
        }

        return popoverWindow.frame.contains(screenLocation)
    }

    private func clickIsOnStatusItem(at screenLocation: NSPoint) -> Bool {
        guard
            let button = statusItem.button,
            let buttonWindow = button.window
        else {
            return false
        }

        let buttonLocation = buttonWindow.convertPoint(fromScreen: screenLocation)
        let pointInButton = button.convert(buttonLocation, from: nil)
        return button.bounds.contains(pointInButton)
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        event.window.map { window in
            window.convertPoint(toScreen: event.locationInWindow)
        } ?? event.locationInWindow
    }

}
