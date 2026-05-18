import AppKit
import SwiftUI

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            DataManagementSettingsView(
                database: appDelegate.historyDatabase,
                updateMonitor: appDelegate.updateMonitor
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyDatabase: UsageHistoryDatabaseWorker
    let updateMonitor: AppUpdateMonitor
    private let viewModel: MenuBarStatusViewModel
    private var statusItemController: StatusItemController?

    override init() {
        AppFreshnessRuntime.captureLaunchFingerprint()
        let resolvedHistoryDatabase = UsageHistoryDatabaseWorker.applicationSupportStoreWithInMemoryFallback()
        let historyRecorder = UsageHistoryRecorder(database: resolvedHistoryDatabase)
        historyDatabase = resolvedHistoryDatabase
        updateMonitor = AppUpdateMonitor()
        viewModel = MenuBarStatusViewModel(
            client: CodexAppServerClient(),
            historyRecorder: historyRecorder,
            tokenUsageRecorder: historyRecorder
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            viewModel: viewModel,
            historyDatabase: historyDatabase,
            updateMonitor: updateMonitor
        )

        Task {
            _ = try? await historyDatabase.databaseInfo()
        }

        Task {
            await viewModel.start()
        }

        Task {
            await updateMonitor.checkIfNeeded()
        }
    }
}
