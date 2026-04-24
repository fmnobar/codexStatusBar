import AppKit
import SwiftUI

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let historyStore: UsageHistoryStore
    private let viewModel: MenuBarStatusViewModel
    private var statusItemController: StatusItemController?

    override init() {
        let resolvedHistoryStore = (try? UsageHistoryStore.applicationSupportStore()) ?? (try! UsageHistoryStore.inMemory())
        historyStore = resolvedHistoryStore
        viewModel = MenuBarStatusViewModel(
            client: CodexAppServerClient(),
            historyRecorder: UsageHistoryRecorder(store: resolvedHistoryStore)
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(viewModel: viewModel, historyStore: historyStore)

        Task {
            await viewModel.start()
        }
    }
}
