import AppKit
import SwiftUI

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            DataManagementSettingsView(store: appDelegate.historyStore)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyStore: UsageHistoryStore
    private let viewModel: MenuBarStatusViewModel
    private var statusItemController: StatusItemController?

    override init() {
        AppFreshnessRuntime.captureLaunchFingerprint()
        let resolvedHistoryStore = (try? UsageHistoryStore.applicationSupportStore()) ?? (try! UsageHistoryStore.inMemory())
        let historyRecorder = UsageHistoryRecorder(store: resolvedHistoryStore)
        historyStore = resolvedHistoryStore
        viewModel = MenuBarStatusViewModel(
            client: CodexAppServerClient(),
            historyRecorder: historyRecorder,
            tokenUsageRecorder: historyRecorder
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
