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
                tokenPayloadAuditStore: appDelegate.tokenPayloadAuditStore,
                tokenPayloadAuditDiagnosticsStore: appDelegate.tokenPayloadAuditDiagnosticsStore,
                performanceInstrumentationStore: appDelegate.performanceInstrumentationStore
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let historyDatabase: UsageHistoryDatabaseWorker
    let updateMonitor: AppUpdateMonitor
    let tokenPayloadAuditStore: CodexTokenPayloadAuditStore
    let tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore
    let performanceInstrumentationStore: AppPerformanceInstrumentationStore
    private let viewModel: MenuBarStatusViewModel
    private var statusItemController: StatusItemController?
    private var liveTokenCaptureCoordinator: CodexLiveTokenCaptureCoordinator?
    private var backgroundMetadataCaptureCoordinator: CodexBackgroundMetadataCaptureCoordinator?
    private var launchToMenuTitleSpan: AppPerformanceSpan?

    override init() {
        AppFreshnessRuntime.captureLaunchFingerprint()
        let resolvedHistoryDatabase = UsageHistoryDatabaseWorker.applicationSupportStoreWithInMemoryFallback()
        let historyRecorder = UsageHistoryRecorder(database: resolvedHistoryDatabase)
        let codexClient = CodexAppServerClient()
        let payloadAuditStore = CodexTokenPayloadAuditStore.applicationSupportStore()
        let payloadAuditDiagnosticsStore = CodexAppServerAuditDiagnosticsStore.applicationSupportStore()
        let performanceInstrumentationStore = AppPerformanceInstrumentationStore.shared
        codexClient.onTokenUsagePayloadAudit = { audit in
            switch payloadAuditStore.record(audit) {
            case .success:
                payloadAuditDiagnosticsStore.record(.auditPersistAttempt(success: true, errorText: nil))
            case .failure(let error):
                payloadAuditDiagnosticsStore.record(.auditPersistAttempt(success: false, errorText: error.localizedDescription))
            }
        }
        codexClient.onAppServerAuditDiagnosticEvent = { event in
            payloadAuditDiagnosticsStore.record(event)
        }
        historyDatabase = resolvedHistoryDatabase
        updateMonitor = AppUpdateMonitor()
        tokenPayloadAuditStore = payloadAuditStore
        tokenPayloadAuditDiagnosticsStore = payloadAuditDiagnosticsStore
        self.performanceInstrumentationStore = performanceInstrumentationStore
        launchToMenuTitleSpan = performanceInstrumentationStore.begin(.appLaunchToFirstMenuBarTitle)
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
            updateMonitor: updateMonitor,
            performanceInstrumentationStore: performanceInstrumentationStore,
            launchToMenuTitleSpan: launchToMenuTitleSpan
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

        liveTokenCaptureCoordinator = CodexLiveTokenCaptureCoordinator(
            database: UsageHistoryDatabaseWorker.applicationSupportStoreWithInMemoryFallback(),
            onCapture: { [weak viewModel] state in
                guard state.hasSuccessfulCheck else {
                    return
                }

                viewModel?.refreshTodayTokenTotalsIfDisplayed()
            }
        )
        liveTokenCaptureCoordinator?.start()

        backgroundMetadataCaptureCoordinator = CodexBackgroundMetadataCaptureCoordinator(
            database: historyDatabase
        )
        backgroundMetadataCaptureCoordinator?.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MenuBarApplicationLifecycle.shouldTerminateAfterLastWindowClosed
    }
}

@MainActor
final class CodexLiveTokenCaptureCoordinator {
    private let database: UsageHistoryDatabaseWorking
    private let interval: TimeInterval
    private let now: () -> Date
    private let onCapture: (CodexLiveTokenCaptureState) -> Void
    private var task: Task<Void, Never>?

    init(
        database: UsageHistoryDatabaseWorking,
        interval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init,
        onCapture: @escaping (CodexLiveTokenCaptureState) -> Void = { _ in }
    ) {
        self.database = database
        self.interval = interval
        self.now = now
        self.onCapture = onCapture
    }

    deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil else {
            return
        }

        task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.capture(force: true)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                } catch {
                    return
                }

                await self.capture(force: false)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func capture(force: Bool) async {
        let state = await database.captureLiveTokenHistoryIfNeeded(
            at: now(),
            calendar: .autoupdatingCurrent,
            force: force
        )
        onCapture(state)
    }
}
