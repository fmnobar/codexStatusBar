import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let viewModel: MenuBarStatusViewModel
    private let historyStore: UsageHistoryStore
    private let historyWindowController: UsageHistoryWindowController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var refreshMenuItem = makeMenuItem(title: "Refresh", action: #selector(refreshFromMenu))
    private lazy var historyMenuItem = makeMenuItem(title: "History", action: #selector(showHistoryFromMenu))
    private lazy var settingsMenuItem = makeMenuItem(title: "Settings", action: #selector(showSettingsFromMenu))
    private lazy var exportDiagnosticsMenuItem = makeMenuItem(title: "Export Diagnostics...", action: #selector(exportDiagnosticsFromMenu))
    private lazy var openCodexMenuItem = makeMenuItem(title: "Open Codex", action: #selector(openCodex))
    private lazy var contextMenu: NSMenu = makeContextMenu()

    private var cancellables = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(viewModel: MenuBarStatusViewModel, historyStore: UsageHistoryStore) {
        self.viewModel = viewModel
        self.historyStore = historyStore
        self.historyWindowController = UsageHistoryWindowController(store: historyStore)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configurePopover()
        configureStatusItem()
        bindViewModel()
        updateStatusItemTitle(viewModel.menuBarPercentText)
        updateStatusItemImage(viewModel.statusItemVisualState)
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
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.image = makeStatusItemImage(for: .normal)
        button.appearsDisabled = false
    }

    private func bindViewModel() {
        viewModel.$menuBarPercentText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.updateStatusItemTitle(text)
            }
            .store(in: &cancellables)

        viewModel.$statusItemVisualState
            .receive(on: RunLoop.main)
            .sink { [weak self] visualState in
                self?.updateStatusItemImage(visualState)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemTitle(_ text: String) {
        guard let button = statusItem.button else {
            return
        }

        let attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            ]
        )

        button.attributedTitle = attributedTitle
    }

    private func updateStatusItemImage(_ visualState: StatusItemVisualState) {
        statusItem.button?.image = makeStatusItemImage(for: visualState)
    }

    private func makeStatusItemImage(for visualState: StatusItemVisualState) -> NSImage? {
        switch visualState {
        case .normal:
            let image = NSImage(named: "CodexMark")?.copy() as? NSImage
            image?.size = NSSize(width: 22, height: 22)
            image?.isTemplate = true
            return image
        case .stale:
            return makeSymbolImage(systemName: "clock.badge.exclamationmark")
        case .error:
            return makeSymbolImage(systemName: "exclamationmark.triangle")
        }
    }

    private func makeSymbolImage(systemName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        return image
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(refreshMenuItem)
        menu.addItem(historyMenuItem)
        menu.addItem(settingsMenuItem)
        menu.addItem(openCodexMenuItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Quit", action: #selector(quit)))
        return menu
    }

    private func makeMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
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

        popover.contentSize = clampedSize
    }

    private func maxPopoverHeight() -> CGFloat {
        let visibleFrame = statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 820, height: 760)

        return max(320, visibleFrame.height - 36)
    }

    private func showContextMenu() {
        popover.performClose(nil)
        updateContextMenuForCurrentModifiers()
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func updateContextMenuForCurrentModifiers() {
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let shouldShowDiagnostics = modifierFlags.contains(.option)
        let diagnosticsIndex = contextMenu.index(of: exportDiagnosticsMenuItem)

        if shouldShowDiagnostics, diagnosticsIndex == -1 {
            let insertionIndex = contextMenu.index(of: historyMenuItem) + 1
            contextMenu.insertItem(exportDiagnosticsMenuItem, at: max(insertionIndex, 0))
        } else if !shouldShowDiagnostics, diagnosticsIndex != -1 {
            contextMenu.removeItem(exportDiagnosticsMenuItem)
        }
    }

    @objc
    private func refreshFromMenu() {
        Task {
            await viewModel.manualRefresh()
        }
    }

    @objc
    private func showHistoryFromMenu() {
        showHistory()
    }

    private func showHistory() {
        historyWindowController.showWindow()
    }

    @objc
    private func showSettingsFromMenu() {
        showSettings()
    }

    private func showSettings() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc
    private func exportDiagnosticsFromMenu() {
        Task {
            await exportDiagnostics()
        }
    }

    private func exportDiagnostics() async {
        guard let data = await viewModel.usageDiagnosticsJSONData() else {
            showDiagnosticsExportFailure()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "codex-usage-diagnostics.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showDiagnosticsExportFailure()
        }
    }

    private func showDiagnosticsExportFailure() {
        let alert = NSAlert()
        alert.messageText = "Diagnostics could not be exported."
        alert.informativeText = "Try again after refreshing Codex Status Bar."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc
    private func openCodex() {
        guard let applicationURL = resolvedCodexApplicationURL() else {
            return
        }

        NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init()) { _, _ in }
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

    private func resolvedCodexApplicationURL() -> URL? {
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            return applicationURL
        }

        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let fileManager = FileManager.default
        guard let appBundleURLs = try? fileManager.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return appBundleURLs
            .filter { $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.hasPrefix("Codex") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }
}
