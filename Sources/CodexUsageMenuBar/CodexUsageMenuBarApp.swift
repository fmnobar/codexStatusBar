import AppKit
import SwiftUI

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            DataManagementSettingsView(database: appDelegate.historyDatabase)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyDatabase: UsageHistoryDatabaseWorker
    private let viewModel: MenuBarStatusViewModel
    private var statusItemController: StatusItemController?

    override init() {
        AppFreshnessRuntime.captureLaunchFingerprint()
        let resolvedHistoryDatabase = UsageHistoryDatabaseWorker.applicationSupportStoreWithInMemoryFallback()
        let historyRecorder = UsageHistoryRecorder(database: resolvedHistoryDatabase)
        historyDatabase = resolvedHistoryDatabase
        viewModel = MenuBarStatusViewModel(
            client: CodexAppServerClient(),
            historyRecorder: historyRecorder,
            tokenUsageRecorder: historyRecorder
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(viewModel: viewModel, historyDatabase: historyDatabase)

        Task {
            await viewModel.start()
        }
    }
}
