import AppKit
// Keep the app's AppIntents link explicit so Xcode's metadata pass remains warning-free.
import AppIntents
import Combine
import SwiftUI

enum UsageCollectionMode: String, CaseIterable, Sendable {
    case lightweight
    case detailedAnalytics = "detailed_analytics"

    var capturesDetailedTokenContext: Bool {
        self == .detailedAnalytics
    }
}

struct UsageCollectionPlan: Equatable, Sendable {
    static let lightweightTokenCaptureInterval: TimeInterval = 5 * 60
    static let detailedTokenCaptureInterval: TimeInterval = 30

    let mode: UsageCollectionMode
    let liveTokenCaptureInterval: TimeInterval
    let capturesDetailedTokenContext: Bool
    let capturesAdvancedMetadata: Bool

    static func plan(for mode: UsageCollectionMode) -> UsageCollectionPlan {
        switch mode {
        case .lightweight:
            UsageCollectionPlan(
                mode: mode,
                liveTokenCaptureInterval: lightweightTokenCaptureInterval,
                capturesDetailedTokenContext: false,
                capturesAdvancedMetadata: false
            )
        case .detailedAnalytics:
            UsageCollectionPlan(
                mode: mode,
                liveTokenCaptureInterval: detailedTokenCaptureInterval,
                capturesDetailedTokenContext: true,
                capturesAdvancedMetadata: true
            )
        }
    }
}

enum UsageCollectionModeStore {
    static let key = "Usage.collectionMode"

    static func load(from defaults: UserDefaults = .standard) -> UsageCollectionMode {
        guard let rawValue = defaults.string(forKey: key),
              let mode = UsageCollectionMode(rawValue: rawValue)
        else {
            return .lightweight
        }
        return mode
    }

    static func save(_ mode: UsageCollectionMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}

@MainActor
final class UsageCollectionModeController: ObservableObject {
    @Published private(set) var mode: UsageCollectionMode

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = UsageCollectionModeStore.load(from: defaults)
    }

    func setMode(_ mode: UsageCollectionMode) {
        guard self.mode != mode else {
            return
        }
        UsageCollectionModeStore.save(mode, to: defaults)
        self.mode = mode
    }
}

final class UsageCollectionDetailGate: @unchecked Sendable {
    private let lock = NSLock()
    private var capturesDetailedTokenContextValue: Bool

    init(mode: UsageCollectionMode) {
        capturesDetailedTokenContextValue = mode.capturesDetailedTokenContext
    }

    var capturesDetailedTokenContext: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capturesDetailedTokenContextValue
    }

    func update(mode: UsageCollectionMode) {
        lock.lock()
        capturesDetailedTokenContextValue = mode.capturesDetailedTokenContext
        lock.unlock()
    }
}

enum StorageMaintenanceTrigger: String, Sendable {
    case launchIdle = "launch_idle"
    case periodic
    case modeChange = "mode_change"
    case operationalImport = "operational_import"
    case backupImport = "backup_import"
    case budgetPressure = "budget_pressure"
    case manual
}

private final class NotificationObserverRegistration: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}

@MainActor
final class StorageMaintenanceCoordinator: ObservableObject {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    @Published private(set) var state = StorageMaintenanceState.idle

    private let database: UsageHistoryDatabaseWorking
    private let now: () -> Date
    private let sleeper: Sleeper
    private var periodicTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var pendingTrigger: StorageMaintenanceTrigger?
    private var maintenanceRequestObserver: NotificationObserverRegistration?

    init(
        database: UsageHistoryDatabaseWorking,
        now: @escaping () -> Date = Date.init,
        sleeper: @escaping Sleeper = StorageMaintenanceCoordinator.sleep
    ) {
        self.database = database
        self.now = now
        self.sleeper = sleeper
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: UsageHistoryStore.maintenanceRequestedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let rawValue = notification.userInfo?[UsageHistoryStore.maintenanceTriggerUserInfoKey] as? String,
                  let trigger = StorageMaintenanceTrigger(rawValue: rawValue)
            else {
                return
            }
            Task { @MainActor [weak self] in
                self?.enqueue(trigger)
            }
        }
        maintenanceRequestObserver = NotificationObserverRegistration(center: center, token: token)
    }

    deinit {
        periodicTask?.cancel()
        executionTask?.cancel()
    }

    func start() {
        guard periodicTask == nil else {
            return
        }
        periodicTask = Task { [weak self] in
            guard let self, await self.wait(StorageLifecyclePolicy.launchIdleDelay) else {
                return
            }
            self.enqueue(.launchIdle)
            while await self.wait(StorageLifecyclePolicy.maintenanceInterval) {
                self.enqueue(.periodic)
            }
        }
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        executionTask?.cancel()
        executionTask = nil
        pendingTrigger = nil
    }

    func enqueue(_ trigger: StorageMaintenanceTrigger) {
        pendingTrigger = trigger
        guard executionTask == nil else {
            return
        }
        executionTask = Task { [weak self] in
            await self?.drainPendingTriggers()
        }
    }

    private func drainPendingTriggers() async {
        while !Task.isCancelled, pendingTrigger != nil {
            pendingTrigger = nil
            let attemptAt = now()
            state.lastAttemptAt = attemptAt
            state.stage = .rawToHourly
            state.lastErrorText = nil
            do {
                try await database.enforceTelemetryRetention(referenceDate: attemptAt)
                guard !Task.isCancelled else {
                    break
                }
                state.lastSuccessAt = now()
                state.stage = .idle
                state.cursor = nil
            } catch {
                guard !Task.isCancelled else {
                    break
                }
                state.stage = .failed
                state.lastErrorText = StorageMaintenanceErrorSanitizer.text(for: error)
            }
        }
        executionTask = nil
    }

    private func wait(_ interval: TimeInterval) async -> Bool {
        do {
            try await sleeper(interval)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private static func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else {
            return
        }
        try await Task.sleep(nanoseconds: UInt64((interval * 1_000_000_000).rounded()))
    }
}

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
    private let collectionModeController: UsageCollectionModeController
    private let collectionDetailGate: UsageCollectionDetailGate
    private let collectionPlanProvider: (UsageCollectionMode) -> UsageCollectionPlan
    private let maintenanceCoordinator: StorageMaintenanceCoordinator
    private var statusItemController: StatusItemController?
    private var liveTokenCaptureCoordinator: CodexLiveTokenCaptureCoordinator?
    private var backgroundMetadataCaptureCoordinator: CodexBackgroundMetadataCaptureCoordinator?
    private var collectionModeCancellable: AnyCancellable?
    private var launchToMenuTitleSpan: AppPerformanceSpan?
    private var collectionGeneration = 0
    private var hasStarted = false
    private var hasAppliedCollectionPlan = false

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
            collectionModeController: collectionModeController,
            autoRefreshProfileTokens: true
        ))
    }

    init(
        collectionPlanProvider: @escaping (UsageCollectionMode) -> UsageCollectionPlan = UsageCollectionPlan.plan
    ) {
        AppFreshnessRuntime.captureLaunchFingerprint()
        let collectionModeController = UsageCollectionModeController()
        let collectionDetailGate = UsageCollectionDetailGate(mode: collectionModeController.mode)
        let resolvedHistoryWriteDatabase = UsageHistoryDatabaseWorker.applicationSupportStoreWithInMemoryFallback(
            collectionModeProvider: {
                collectionDetailGate.capturesDetailedTokenContext ? .detailedAnalytics : .lightweight
            }
        )
        let resolvedHistoryQueryDatabase = UsageHistoryDashboardQueryWorker.applicationSupportStoreWithInMemoryFallback()
        let routedHistoryDatabase = UsageHistoryDatabaseRouter(
            writer: resolvedHistoryWriteDatabase,
            dashboardQueryWorker: resolvedHistoryQueryDatabase
        )
        let historyRecorder = UsageHistoryRecorder(
            database: resolvedHistoryWriteDatabase,
            includeDetailedContext: { collectionDetailGate.capturesDetailedTokenContext }
        )
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
        self.collectionModeController = collectionModeController
        self.collectionDetailGate = collectionDetailGate
        self.collectionPlanProvider = collectionPlanProvider
        maintenanceCoordinator = StorageMaintenanceCoordinator(database: resolvedHistoryWriteDatabase)
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
        guard !hasStarted else {
            return
        }
        hasStarted = true

        statusItemController = StatusItemController(
            viewModel: viewModel,
            historyDatabase: historyDatabase,
            updateMonitor: updateMonitor,
            performanceInstrumentationStore: performanceInstrumentationStore,
            codexSourceHealthStore: codexSourceHealthStore,
            appServerDiagnosticsStore: tokenPayloadAuditDiagnosticsStore,
            resetCreditStore: resetCreditStore,
            resetCreditClient: codexClient,
            collectionModeController: collectionModeController,
            launchToMenuTitleSpan: launchToMenuTitleSpan
        )

        Task {
            if let info = try? await historyWriteDatabase.databaseInfo(),
               StorageBudgetPolicy.policy(for: info.collectionMode)
                    .isAtMaintenancePressure(info.totalByteSize)
            {
                maintenanceCoordinator.enqueue(.budgetPressure)
            }
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

        collectionModeCancellable = collectionModeController.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                guard let self else {
                    return
                }
                self.applyCollectionPlan(self.collectionPlanProvider(mode))
            }
        maintenanceCoordinator.start()
    }

    func stop() {
        guard hasStarted else {
            return
        }
        hasStarted = false
        collectionGeneration += 1
        collectionModeCancellable?.cancel()
        collectionModeCancellable = nil
        liveTokenCaptureCoordinator?.stop()
        liveTokenCaptureCoordinator = nil
        backgroundMetadataCaptureCoordinator?.stop()
        backgroundMetadataCaptureCoordinator = nil
        maintenanceCoordinator.stop()
        viewModel.stop()
    }

    private func applyCollectionPlan(_ plan: UsageCollectionPlan) {
        collectionGeneration += 1
        let generation = collectionGeneration
        collectionDetailGate.update(mode: plan.mode)
        if hasStarted && hasAppliedCollectionPlan {
            maintenanceCoordinator.enqueue(.modeChange)
        }
        hasAppliedCollectionPlan = true

        liveTokenCaptureCoordinator?.stop()
        backgroundMetadataCaptureCoordinator?.stop()

        liveTokenCaptureCoordinator = CodexLiveTokenCaptureCoordinator(
            database: historyWriteDatabase,
            interval: plan.liveTokenCaptureInterval,
            includeDetailedContext: plan.capturesDetailedTokenContext,
            onCapture: { [weak self, weak viewModel] state in
                guard let self, generation == self.collectionGeneration else {
                    return
                }
                guard state.hasSuccessfulCheck else {
                    return
                }

                viewModel?.refreshMenuBarTokenDisplayIfDisplayed()
            }
        )
        liveTokenCaptureCoordinator?.start()

        if plan.capturesAdvancedMetadata {
            backgroundMetadataCaptureCoordinator = CodexBackgroundMetadataCaptureCoordinator(
                database: historyWriteDatabase
            )
            backgroundMetadataCaptureCoordinator?.start()
        } else {
            backgroundMetadataCaptureCoordinator = nil
        }
    }
}

@MainActor
final class CodexLiveTokenCaptureCoordinator {
    private let database: UsageHistoryDatabaseWorking
    private let interval: TimeInterval
    private let includeDetailedContext: Bool
    private let now: () -> Date
    private let sleeper: CodexBackgroundMetadataCaptureCoordinator.Sleeper
    private let onCapture: (CodexLiveTokenCaptureState) -> Void
    private var task: Task<Void, Never>?

    init(
        database: UsageHistoryDatabaseWorking,
        interval: TimeInterval = 30,
        includeDetailedContext: Bool = true,
        now: @escaping () -> Date = Date.init,
        sleeper: @escaping CodexBackgroundMetadataCaptureCoordinator.Sleeper = CodexLiveTokenCaptureCoordinator.sleep,
        onCapture: @escaping (CodexLiveTokenCaptureState) -> Void = { _ in }
    ) {
        self.database = database
        self.interval = interval
        self.includeDetailedContext = includeDetailedContext
        self.now = now
        self.sleeper = sleeper
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
                    try await self.sleeper(self.interval)
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
            force: force,
            includeDetailedContext: includeDetailedContext
        )
        guard !Task.isCancelled else {
            return
        }
        onCapture(state)
    }

    private static func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else {
            return
        }
        try await Task.sleep(nanoseconds: UInt64((interval * 1_000_000_000).rounded()))
    }
}
