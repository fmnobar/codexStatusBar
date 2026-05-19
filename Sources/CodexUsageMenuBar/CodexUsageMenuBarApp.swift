import AppKit
import SwiftUI

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            DataManagementSettingsView(
                database: appDelegate.historyDatabase,
                updateMonitor: appDelegate.updateMonitor,
                tokenPayloadAuditStore: appDelegate.tokenPayloadAuditStore
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyDatabase: UsageHistoryDatabaseWorker
    let updateMonitor: AppUpdateMonitor
    let tokenPayloadAuditStore: CodexTokenPayloadAuditStore
    private let viewModel: MenuBarStatusViewModel
    private var statusItemController: StatusItemController?

    override init() {
        AppFreshnessRuntime.captureLaunchFingerprint()
        let resolvedHistoryDatabase = UsageHistoryDatabaseWorker.applicationSupportStoreWithInMemoryFallback()
        let historyRecorder = UsageHistoryRecorder(database: resolvedHistoryDatabase)
        let codexClient = CodexAppServerClient()
        let payloadAuditStore = CodexTokenPayloadAuditStore.applicationSupportStore()
        codexClient.onTokenUsagePayloadAudit = { audit in
            payloadAuditStore.record(audit)
        }
        historyDatabase = resolvedHistoryDatabase
        updateMonitor = AppUpdateMonitor()
        tokenPayloadAuditStore = payloadAuditStore
        viewModel = MenuBarStatusViewModel(
            client: codexClient,
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
