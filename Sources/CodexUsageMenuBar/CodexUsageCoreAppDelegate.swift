import AppKit
// Keep the app's AppIntents link explicit so Xcode's metadata pass remains warning-free.
import AppIntents
import SwiftUI

@MainActor
protocol CodexUsageApplicationRuntime: AnyObject {
    var settingsView: AnyView { get }
    func start()
    func stop()
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: any CodexUsageApplicationRuntime

    public override convenience init() {
        self.init(runtime: CodexUsageProductionRuntime())
    }

    init(runtime: any CodexUsageApplicationRuntime) {
        self.runtime = runtime
        super.init()
    }

    public var settingsView: some View {
        runtime.settingsView
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MenuBarApplicationLifecycle.shouldTerminateAfterLastWindowClosed
    }

    public func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }
}

@MainActor
final class CodexUsageProductionRuntime: CodexUsageApplicationRuntime {
    private let historyDatabase: UsageHistoryDatabaseWorking
    private let updateMonitor: AppUpdateMonitor
    private let tokenPayloadAuditStore: CodexTokenPayloadAuditStore
    private let tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore
    private let performanceInstrumentationStore: AppPerformanceInstrumentationStore
    private let profileTokenUsageStore: CodexProfileTokenUsageStore
    private let resetCreditStore: CodexResetCreditStore
    private let codexSourceHealthStore: CodexSourceHealthStore
    private let codexClient: CodexAppServerClient
    private let historyWriteDatabase: UsageHistoryDatabaseWorker
    private let viewModel: MenuBarStatusViewModel
    private var statusItemController: StatusItemController?
    private var liveTokenCaptureCoordinator: CodexLiveTokenCaptureCoordinator?
    private var backgroundMetadataCaptureCoordinator: CodexBackgroundMetadataCaptureCoordinator?
    private var launchToMenuTitleSpan: AppPerformanceSpan?

    var settingsView: AnyView {
        AnyView(DataManagementSettingsView(
            database: historyDatabase,
            updateMonitor: updateMonitor,
            tokenPayloadAuditStore: tokenPayloadAuditStore,
            tokenPayloadAuditDiagnosticsStore: tokenPayloadAuditDiagnosticsStore,
            performanceInstrumentationStore: performanceInstrumentationStore,
            profileTokenUsageStore: profileTokenUsageStore,
            profileTokenClient: codexClient,
            codexSourceHealthStore: codexSourceHealthStore,
            autoRefreshProfileTokens: true
        ))
    }

    init() {
        AppFreshnessRuntime.captureLaunchFingerprint()
        let resolvedHistoryWriteDatabase = UsageHistoryDatabaseWorker.applicationSupportStoreWithInMemoryFallback()
        let resolvedHistoryQueryDatabase = UsageHistoryDashboardQueryWorker.applicationSupportStoreWithInMemoryFallback()
        let routedHistoryDatabase = UsageHistoryDatabaseRouter(
            writer: resolvedHistoryWriteDatabase,
            dashboardQueryWorker: resolvedHistoryQueryDatabase
        )
        let historyRecorder = UsageHistoryRecorder(database: resolvedHistoryWriteDatabase)
        let codexClient = CodexAppServerClient()
        let payloadAuditStore = CodexTokenPayloadAuditStore.applicationSupportStore()
        let payloadAuditDiagnosticsStore = CodexAppServerAuditDiagnosticsStore.applicationSupportStore()
        let performanceInstrumentationStore = AppPerformanceInstrumentationStore.shared
        let profileTokenUsageStore = CodexProfileTokenUsageStore.applicationSupportStore()
        let resetCreditStore = CodexResetCreditStore.applicationSupportStore()
        let codexSourceHealthStore = CodexSourceHealthStore.shared
        codexClient.onTokenUsagePayloadAudit = { audit in
            Task { @MainActor in
                switch payloadAuditStore.record(audit) {
                case .success:
                    payloadAuditDiagnosticsStore.record(.auditPersistAttempt(success: true, errorText: nil))
                case .failure(let error):
                    payloadAuditDiagnosticsStore.record(.auditPersistAttempt(success: false, errorText: error.localizedDescription))
                }
            }
        }
        codexClient.onAppServerAuditDiagnosticEvent = { event in
            payloadAuditDiagnosticsStore.record(event)
        }
        historyWriteDatabase = resolvedHistoryWriteDatabase
        historyDatabase = routedHistoryDatabase
        updateMonitor = AppUpdateMonitor()
        tokenPayloadAuditStore = payloadAuditStore
        tokenPayloadAuditDiagnosticsStore = payloadAuditDiagnosticsStore
        self.performanceInstrumentationStore = performanceInstrumentationStore
        self.profileTokenUsageStore = profileTokenUsageStore
        self.resetCreditStore = resetCreditStore
        self.codexSourceHealthStore = codexSourceHealthStore
        self.codexClient = codexClient
        launchToMenuTitleSpan = performanceInstrumentationStore.begin(.appLaunchToFirstMenuBarTitle)
        viewModel = MenuBarStatusViewModel(
            client: codexClient,
            historyRecorder: historyRecorder,
            tokenUsageRecorder: historyRecorder,
            accountTokenUsageClient: codexClient,
            recordAccountTokenUsageSnapshot: { snapshot in
                profileTokenUsageStore.recordSuccess(snapshot)
            }
        )
    }

    func start() {
        statusItemController = StatusItemController(
            viewModel: viewModel,
            historyDatabase: historyDatabase,
            updateMonitor: updateMonitor,
            performanceInstrumentationStore: performanceInstrumentationStore,
            codexSourceHealthStore: codexSourceHealthStore,
            appServerDiagnosticsStore: tokenPayloadAuditDiagnosticsStore,
            resetCreditStore: resetCreditStore,
            resetCreditClient: codexClient,
            launchToMenuTitleSpan: launchToMenuTitleSpan
        )

        Task {
            _ = try? await historyWriteDatabase.databaseInfo()
        }

        Task {
            await viewModel.start()
        }

        Task {
            await updateMonitor.checkIfNeeded()
        }

        Task {
            await codexSourceHealthStore.refreshIfStale()
        }

        Task {
            await tokenPayloadAuditDiagnosticsStore.refreshRemoteControlHealth()
        }

        liveTokenCaptureCoordinator = CodexLiveTokenCaptureCoordinator(
            database: historyWriteDatabase,
            onCapture: { [weak viewModel] state in
                guard state.hasSuccessfulCheck else {
                    return
                }

                viewModel?.refreshMenuBarTokenDisplayIfDisplayed()
            }
        )
        liveTokenCaptureCoordinator?.start()

        backgroundMetadataCaptureCoordinator = CodexBackgroundMetadataCaptureCoordinator(
            database: historyWriteDatabase
        )
        backgroundMetadataCaptureCoordinator?.start()
    }

    func stop() {
        liveTokenCaptureCoordinator?.stop()
        backgroundMetadataCaptureCoordinator?.stop()
        viewModel.stop()
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
