import AppKit
import Combine
import SwiftUI

enum StatusItemClickIntent: Equatable {
    case togglePopover
    case showContextMenu
}

enum StatusItemDestination: Equatable {
    case settings(SettingsTabSelection)
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSViewToolTipOwner {
    nonisolated static func clickIntent(for eventType: NSEvent.EventType?) -> StatusItemClickIntent {
        eventType == .rightMouseUp ? .showContextMenu : .togglePopover
    }

    private let viewModel: MenuBarStatusViewModel
    private let updateMonitor: AppUpdateMonitor
    private let resetCreditStore: CodexResetCreditStore
    private let resetCreditClient: CodexResetCreditFetching?
    private let routeHandlerOverride: ((StatusItemDestination) -> Void)?
    private let settingsDefaults: UserDefaults
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var contextMenu = StatusItemContextMenuFactory.makeMenu(
        target: self,
        quitAction: #selector(quit)
    )

    private var cancellables = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private(set) var ringToolTipTag: NSView.ToolTipTag?

    var statusButtonForTesting: NSStatusBarButton? {
        statusItem.button
    }

    init(
        viewModel: MenuBarStatusViewModel,
        updateMonitor: AppUpdateMonitor,
        resetCreditStore: CodexResetCreditStore = .applicationSupportStore(),
        resetCreditClient: CodexResetCreditFetching? = nil,
        routeHandlerOverride: ((StatusItemDestination) -> Void)? = nil,
        settingsDefaults: UserDefaults = .standard
    ) {
        self.viewModel = viewModel
        self.updateMonitor = updateMonitor
        self.resetCreditStore = resetCreditStore
        self.resetCreditClient = resetCreditClient
        self.routeHandlerOverride = routeHandlerOverride
        self.settingsDefaults = settingsDefaults
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = "CodexStatusBarStatusItem"
        StatusItemVisibility.forceVisible(statusItem)
        super.init()

        configurePopover()
        configureStatusItem()
        bindViewModel()
        updateStatusItemTitle(
            viewModel.menuBarPercentText,
            remainingPercent: viewModel.weeklyRemainingPercent
        )
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                viewModel: viewModel,
                updateMonitor: updateMonitor,
                resetCreditStore: resetCreditStore,
                resetCreditClient: resetCreditClient,
                onOpenUpdatesSettings: { [weak self] in
                    self?.route(to: .settings(.updates))
                },
                onOpenSettings: { [weak self] in
                    self?.route(to: .settings(.general))
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
        StatusItemToolTipPolicy.apply(to: button)
        button.appearsDisabled = false
    }

    private func bindViewModel() {
        Publishers.CombineLatest(viewModel.$menuBarPercentText, viewModel.$weeklyRemainingPercent)
            .receive(on: RunLoop.main)
            .sink { [weak self] text, remainingPercent in
                self?.updateStatusItemTitle(text, remainingPercent: remainingPercent)
            }
            .store(in: &cancellables)

        viewModel.$menuBarToolTipText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.statusItem.button?.setAccessibilityHelp(text)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemTitle(_ text: String, remainingPercent: Int? = nil) {
        guard let button = statusItem.button else {
            return
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let visibleText = remainingPercent == nil
            ? StatusItemTitleLayout.visibleText(text)
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        button.image = remainingPercent.map(StatusItemRingImage.make)
        button.imagePosition = remainingPercent == nil ? .noImage : .imageLeading
        button.cell?.lineBreakMode = .byTruncatingTail
        let accessibilityLabel: String
        if let remainingPercent, !viewModel.menuBarDisplayOptions.showsRemainingPercentage {
            accessibilityLabel = "Codex usage \(remainingPercent)% remaining"
                + (visibleText.isEmpty ? "" : ", \(visibleText)")
        } else {
            accessibilityLabel = AppAccessibilitySemantics.statusItemLabel(visibleText: visibleText)
        }
        button.setAccessibilityLabel(accessibilityLabel)
        statusItem.length = StatusItemTitleLayout.length(
            for: visibleText,
            font: font,
            hasRing: remainingPercent != nil
        )
        StatusItemVisibility.forceVisible(statusItem)
        updateRingToolTip(for: button, remainingPercent: remainingPercent)
    }

    private func updateRingToolTip(for button: NSStatusBarButton, remainingPercent: Int?) {
        if let ringToolTipTag {
            button.removeToolTip(ringToolTipTag)
            self.ringToolTipTag = nil
        }

        guard remainingPercent != nil,
              !viewModel.menuBarDisplayOptions.showsRemainingPercentage else {
            return
        }

        button.layoutSubtreeIfNeeded()
        guard let ringRect = button.cell?.imageRect(forBounds: button.bounds),
              !ringRect.isEmpty else {
            return
        }
        ringToolTipTag = button.addToolTip(ringRect.insetBy(dx: -2, dy: -3), owner: self, userData: nil)
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        guard tag == ringToolTipTag, let remainingPercent = viewModel.weeklyRemainingPercent else {
            return ""
        }
        return "\(remainingPercent)% left"
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        switch Self.clickIntent(for: NSApp.currentEvent?.type) {
        case .showContextMenu:
            showContextMenu()
        case .togglePopover:
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

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
        popover.performClose(nil)
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func route(to destination: StatusItemDestination) {
        if case .settings(let tab) = destination {
            SettingsTabSelectionStore.select(tab, defaults: settingsDefaults)
        }

        if let routeHandlerOverride {
            routeHandlerOverride(destination)
            return
        }

        switch destination {
        case .settings:
            openSettings()
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitors()
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
