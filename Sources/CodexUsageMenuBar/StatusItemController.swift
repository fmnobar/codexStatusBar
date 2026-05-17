import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let viewModel: MenuBarStatusViewModel
    private let historyStore: UsageHistoryStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var contextMenu = StatusItemContextMenuFactory.makeMenu(
        target: self,
        quitAction: #selector(quit)
    )

    private var cancellables = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(viewModel: MenuBarStatusViewModel, historyStore: UsageHistoryStore) {
        self.viewModel = viewModel
        self.historyStore = historyStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = "CodexStatusBarStatusItem"
        super.init()

        configurePopover()
        configureStatusItem()
        bindViewModel()
        updateStatusItemTitle(viewModel.menuBarPercentText)
        updateStatusItemToolTip(viewModel.menuBarToolTipText)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                viewModel: viewModel,
                historyStore: historyStore,
                onContentSizeChange: { [weak self] size in
                    self?.updatePopoverContentSize(size)
                }
            )
        )
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .noImage
        button.image = nil
        button.appearsDisabled = false
    }

    private func bindViewModel() {
        viewModel.$menuBarPercentText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.updateStatusItemTitle(text)
            }
            .store(in: &cancellables)

        viewModel.$menuBarToolTipText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.updateStatusItemToolTip(text)
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
    }

    private func updateStatusItemToolTip(_ text: String?) {
        statusItem.button?.toolTip = text
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            showContextMenu()
        case .leftMouseUp:
            togglePopover(relativeTo: sender)
        default:
            break
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
