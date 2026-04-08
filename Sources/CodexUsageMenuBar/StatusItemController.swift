import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let viewModel: MenuBarStatusViewModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var contextMenu: NSMenu = makeContextMenu()

    private var cancellables = Set<AnyCancellable>()

    init(viewModel: MenuBarStatusViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configurePopover()
        configureStatusItem()
        bindViewModel()
        updateStatusItemTitle(viewModel.menuBarPercentText)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(viewModel: viewModel)
                .frame(width: 320)
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
        button.image = makeStatusItemImage()
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

        let attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            ]
        )

        button.attributedTitle = attributedTitle
    }

    private func makeStatusItemImage() -> NSImage? {
        let image = NSImage(named: "CodexMark")?.copy() as? NSImage
        image?.size = NSSize(width: 15, height: 15)
        image?.isTemplate = true
        return image
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
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

        Task {
            await viewModel.popoverDidAppear()
        }
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
}
