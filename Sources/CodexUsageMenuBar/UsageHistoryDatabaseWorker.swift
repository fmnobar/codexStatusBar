import Foundation

struct UsageHistoryLoadRequest: Equatable {
    let chartKind: UsageHistoryChartKind
    let range: UsageHistoryRange
    let window: UsageLimitWindow
    let periodStart: Date
    let periodEnd: Date
    let now: Date
    let calendar: Calendar
}

struct UsageHistoryLoadResult: Equatable {
    let points: [UsageHistoryPoint]
    let tokenPoints: [TokenHistoryPoint]
    let tokenComponentPoints: [TokenHistoryComponentPoint]
    let tokenComponentBucketPoints: [TokenHistoryComponentBucketPoint]
    let series: [UsageHistorySeries]
    let historyBounds: UsageHistoryBounds?
    let hasAnyHistory: Bool
}

struct TokenDashboardLoadRequest: Equatable {
    let breakdownDimension: TokenDashboardBreakdownDimension
    let range: UsageHistoryRange
    let periodStart: Date
    let periodEnd: Date

    init(
        breakdownDimension: TokenDashboardBreakdownDimension = .model,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date
    ) {
        self.breakdownDimension = breakdownDimension
        self.range = range
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}

struct TokenDashboardLoadResult: Equatable {
    let points: [TokenDashboardComponentPoint]
    let series: [TokenDashboardSeries]
    let attributionCoverageRows: [TokenAttributionCoverageRow]
    let availableBreakdownDimensions: [TokenDashboardBreakdownDimension]
    let historyBounds: UsageHistoryBounds?
}

protocol UsageHistoryDatabaseWorking: Sendable {
    func record(snapshot: CodexUsageSnapshot, at date: Date) async
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals?
    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals?
    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64?
    func captureLiveTokenHistoryIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexLiveTokenCaptureState
    func liveTokenCaptureState() async -> CodexLiveTokenCaptureState
    func captureTurnPerformanceIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexTurnPerformanceCaptureState
    func turnPerformanceCaptureState() async -> CodexTurnPerformanceCaptureState
    func captureSessionTaskTimingIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexSessionTaskTimingCaptureState
    func sessionTaskTimingCaptureState() async -> CodexSessionTaskTimingCaptureState
    func captureThreadCatalogIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexThreadCatalogCaptureState
    func threadCatalogCaptureState() async -> CodexThreadCatalogCaptureState
    func captureModelCapabilitiesIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexModelCapabilitiesCaptureState
    func modelCapabilitiesCaptureState() async -> CodexModelCapabilitiesCaptureState
    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult
    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult
    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult
    func databaseInfo() async throws -> UsageHistoryDatabaseInfo
    func exportBackup(to destinationURL: URL) async throws
    func importBackup(from sourceURL: URL) async throws
    func clearHistory() async throws
    func tokenProjectCatalogEntries() async throws -> [TokenProjectCatalogEntry]
    func tokenDimensionCatalogEntries() async throws -> [TokenUsageDimensionCatalogEntry]
    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) async throws
    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) async throws -> CodexSessionTokenBackfillSummary
}

@MainActor
final class CodexBackgroundMetadataCaptureCoordinator {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let database: UsageHistoryDatabaseWorking
    private let initialDelay: TimeInterval
    private let staggerDelay: TimeInterval
    private let now: () -> Date
    private let sleeper: Sleeper
    private var task: Task<Void, Never>?

    init(
        database: UsageHistoryDatabaseWorking,
        initialDelay: TimeInterval = 10,
        staggerDelay: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        sleeper: @escaping Sleeper = CodexBackgroundMetadataCaptureCoordinator.sleep
    ) {
        self.database = database
        self.initialDelay = initialDelay
        self.staggerDelay = staggerDelay
        self.now = now
        self.sleeper = sleeper
    }

    deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil else {
            return
        }

        task = Task { [weak self] in
            await self?.runOnce()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func runOnce() async {
        guard await sleep(for: initialDelay) else {
            return
        }

        _ = await database.captureTurnPerformanceIfNeeded(
            at: now(),
            calendar: .autoupdatingCurrent,
            force: false
        )
        guard await sleep(for: staggerDelay) else {
            return
        }

        _ = await database.captureSessionTaskTimingIfNeeded(
            at: now(),
            calendar: .autoupdatingCurrent,
            force: false
        )
        guard await sleep(for: staggerDelay) else {
            return
        }

        _ = await database.captureThreadCatalogIfNeeded(
            at: now(),
            calendar: .autoupdatingCurrent,
            force: false
        )
        guard await sleep(for: staggerDelay) else {
            return
        }

        _ = await database.captureModelCapabilitiesIfNeeded(
            at: now(),
            calendar: .autoupdatingCurrent,
            force: false
        )
    }

    private func sleep(for interval: TimeInterval) async -> Bool {
        do {
            try await sleeper(interval)
            return true
        } catch {
            return false
        }
    }

    private static func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else {
            return
        }

        let nanoseconds = UInt64((interval * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

actor UsageHistoryDatabaseWorker: UsageHistoryDatabaseWorking {
    typealias StoreFactory = @Sendable () throws -> UsageHistoryStore
    typealias RecentTokenHistoryImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexLiveTokenCaptureState
    typealias TurnPerformanceImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexTurnPerformanceCaptureState
    typealias SessionTaskTimingImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexSessionTaskTimingCaptureState
    typealias ThreadCatalogImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexThreadCatalogCaptureState
    typealias ModelCapabilitiesImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexModelCapabilitiesCaptureState

    static let liveRecentTokenHistoryImporter: RecentTokenHistoryImporter = { store, date, calendar, force in
        store.captureLiveCodexLogTokenHistory(at: date, calendar: calendar, force: force)
    }

    static let liveTurnPerformanceImporter: TurnPerformanceImporter = { store, date, calendar, force in
        store.captureCodexOtelTurnPerformance(at: date, calendar: calendar, force: force)
    }

    static let liveSessionTaskTimingImporter: SessionTaskTimingImporter = { store, date, calendar, force in
        store.captureCodexSessionTaskTiming(at: date, calendar: calendar, force: force)
    }

    static let liveThreadCatalogImporter: ThreadCatalogImporter = { store, date, _, force in
        store.captureCodexThreadCatalog(at: date, force: force)
    }

    static let liveModelCapabilitiesImporter: ModelCapabilitiesImporter = { store, date, _, force in
        store.captureCodexModelCapabilities(at: date, force: force)
    }

    private let storeFactory: StoreFactory
    private let recentTokenHistoryImporter: RecentTokenHistoryImporter
    private let turnPerformanceImporter: TurnPerformanceImporter
    private let sessionTaskTimingImporter: SessionTaskTimingImporter
    private let threadCatalogImporter: ThreadCatalogImporter
    private let modelCapabilitiesImporter: ModelCapabilitiesImporter
    private var cachedStore: UsageHistoryStore?
    private var lastRecentTokenImportAt: Date?
    private var lastTurnPerformanceImportAt: Date?
    private var lastSessionTaskTimingImportAt: Date?
    private var lastThreadCatalogImportAt: Date?
    private var lastModelCapabilitiesImportAt: Date?

    init(
        store: UsageHistoryStore,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = UsageHistoryDatabaseWorker.liveRecentTokenHistoryImporter,
        turnPerformanceImporter: @escaping TurnPerformanceImporter = UsageHistoryDatabaseWorker.liveTurnPerformanceImporter,
        sessionTaskTimingImporter: @escaping SessionTaskTimingImporter = UsageHistoryDatabaseWorker.liveSessionTaskTimingImporter,
        threadCatalogImporter: @escaping ThreadCatalogImporter = UsageHistoryDatabaseWorker.liveThreadCatalogImporter,
        modelCapabilitiesImporter: @escaping ModelCapabilitiesImporter = UsageHistoryDatabaseWorker.liveModelCapabilitiesImporter
    ) {
        self.storeFactory = { store }
        self.recentTokenHistoryImporter = recentTokenHistoryImporter
        self.turnPerformanceImporter = turnPerformanceImporter
        self.sessionTaskTimingImporter = sessionTaskTimingImporter
        self.threadCatalogImporter = threadCatalogImporter
        self.modelCapabilitiesImporter = modelCapabilitiesImporter
        self.cachedStore = store
    }

    init(
        storeFactory: @escaping StoreFactory,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = UsageHistoryDatabaseWorker.liveRecentTokenHistoryImporter,
        turnPerformanceImporter: @escaping TurnPerformanceImporter = UsageHistoryDatabaseWorker.liveTurnPerformanceImporter,
        sessionTaskTimingImporter: @escaping SessionTaskTimingImporter = UsageHistoryDatabaseWorker.liveSessionTaskTimingImporter,
        threadCatalogImporter: @escaping ThreadCatalogImporter = UsageHistoryDatabaseWorker.liveThreadCatalogImporter,
        modelCapabilitiesImporter: @escaping ModelCapabilitiesImporter = UsageHistoryDatabaseWorker.liveModelCapabilitiesImporter
    ) {
        self.storeFactory = storeFactory
        self.recentTokenHistoryImporter = recentTokenHistoryImporter
        self.turnPerformanceImporter = turnPerformanceImporter
        self.sessionTaskTimingImporter = sessionTaskTimingImporter
        self.threadCatalogImporter = threadCatalogImporter
        self.modelCapabilitiesImporter = modelCapabilitiesImporter
    }

    static func applicationSupportStore() -> UsageHistoryDatabaseWorker {
        UsageHistoryDatabaseWorker(storeFactory: {
            try UsageHistoryStore.applicationSupportStore()
        })
    }

    static func applicationSupportStoreWithInMemoryFallback() -> UsageHistoryDatabaseWorker {
        UsageHistoryDatabaseWorker(storeFactory: {
            if let applicationSupportStore = try? UsageHistoryStore.applicationSupportStore() {
                return applicationSupportStore
            }

            return try UsageHistoryStore.inMemory()
        })
    }

    static func inMemory() throws -> UsageHistoryDatabaseWorker {
        try UsageHistoryDatabaseWorker(store: UsageHistoryStore.inMemory())
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) {
        do {
            let store = try store()
            try store.record(snapshot: snapshot, at: date)
        } catch {
            // History should never interrupt the live menu bar status.
        }
    }

    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) -> TokenCategoryTotals? {
        do {
            let store = try store()
            try store.record(tokenUsage: tokenUsage, at: date)
            return try store.tokenCategoryTotalsForDay(containing: date, calendar: .autoupdatingCurrent)
        } catch {
            // Token telemetry should never interrupt the live menu bar status.
            return nil
        }
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) -> TokenCategoryTotals? {
        do {
            let store = try store()
            let captureState = try store.codexLiveTokenCaptureState()
            guard captureState.hasSuccessfulCheck(containing: date, calendar: calendar) else {
                return nil
            }
            return try store.tokenCategoryTotalsForDay(containing: date, calendar: calendar)
        } catch {
            return nil
        }
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) -> Int64? {
        do {
            let store = try store()
            let captureState = try store.codexLiveTokenCaptureState()
            guard captureState.hasSuccessfulCheck(containing: date, calendar: calendar) else {
                return nil
            }
            return try store.tokenTotalForDay(containing: date, calendar: calendar)
        } catch {
            return nil
        }
    }

    func captureLiveTokenHistoryIfNeeded(at date: Date, calendar: Calendar, force: Bool = false) -> CodexLiveTokenCaptureState {
        do {
            let store = try store()
            return importRecentTokenHistoryIfNeeded(store: store, at: date, calendar: calendar, force: force)
        } catch {
            return CodexLiveTokenCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func liveTokenCaptureState() -> CodexLiveTokenCaptureState {
        do {
            let store = try store()
            return try store.codexLiveTokenCaptureState()
        } catch {
            return CodexLiveTokenCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func captureTurnPerformanceIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexTurnPerformanceCaptureState {
        do {
            let store = try store()
            return importTurnPerformanceIfNeeded(store: store, at: date, calendar: calendar, force: force)
        } catch {
            return CodexTurnPerformanceCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func turnPerformanceCaptureState() -> CodexTurnPerformanceCaptureState {
        do {
            let store = try store()
            return try store.codexTurnPerformanceCaptureState()
        } catch {
            return CodexTurnPerformanceCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func captureSessionTaskTimingIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexSessionTaskTimingCaptureState {
        do {
            let store = try store()
            return importSessionTaskTimingIfNeeded(store: store, at: date, calendar: calendar, force: force)
        } catch {
            return CodexSessionTaskTimingCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func sessionTaskTimingCaptureState() -> CodexSessionTaskTimingCaptureState {
        do {
            let store = try store()
            return try store.codexSessionTaskTimingCaptureState()
        } catch {
            return CodexSessionTaskTimingCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func captureThreadCatalogIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexThreadCatalogCaptureState {
        do {
            let store = try store()
            return importThreadCatalogIfNeeded(store: store, at: date, calendar: calendar, force: force)
        } catch {
            return CodexThreadCatalogCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func threadCatalogCaptureState() -> CodexThreadCatalogCaptureState {
        do {
            let store = try store()
            return try store.codexThreadCatalogCaptureState()
        } catch {
            return CodexThreadCatalogCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func captureModelCapabilitiesIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexModelCapabilitiesCaptureState {
        do {
            let store = try store()
            return importModelCapabilitiesIfNeeded(store: store, at: date, calendar: calendar, force: force)
        } catch {
            return CodexModelCapabilitiesCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func modelCapabilitiesCaptureState() -> CodexModelCapabilitiesCaptureState {
        do {
            let store = try store()
            return try store.codexModelCapabilitiesCaptureState()
        } catch {
            return CodexModelCapabilitiesCaptureState(status: .failed, lastErrorText: error.localizedDescription)
        }
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) throws -> UsageHistoryLoadResult {
        let store = try store()
        let points: [UsageHistoryPoint]
        let tokenComponentBucketPoints: [TokenHistoryComponentBucketPoint]
        let series: [UsageHistorySeries]
        let historyBounds: UsageHistoryBounds?

        switch request.chartKind {
        case .capacity, .usage:
            points = try store.points(
                range: request.range,
                window: request.window,
                periodStart: request.periodStart,
                periodEnd: request.periodEnd
            )
            tokenComponentBucketPoints = []
            series = try store.availableSeries(window: request.window)
            historyBounds = try store.historyBounds(
                window: request.window,
                granularity: request.range.storageGranularity
            )
        case .tokens:
            points = []
            tokenComponentBucketPoints = try store.tokenComponentBucketPoints(
                range: request.range,
                periodStart: request.periodStart,
                periodEnd: request.periodEnd,
                now: request.now,
                calendar: request.calendar
            )
            series = try store.availableTokenComponentSeries()
                .filter { $0.kind == .aggregate }
            historyBounds = try store.tokenComponentHistoryBounds()
        }

        return UsageHistoryLoadResult(
            points: points,
            tokenPoints: [],
            tokenComponentPoints: [],
            tokenComponentBucketPoints: tokenComponentBucketPoints,
            series: series,
            historyBounds: historyBounds,
            hasAnyHistory: try store.hasAnyHistory()
        )
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) throws -> TokenDashboardLoadResult {
        let store = try store()
        let availableBreakdownDimensions = try store.tokenDashboardAvailableBreakdownDimensions(
            periodStart: request.periodStart,
            periodEnd: request.periodEnd
        )
        return TokenDashboardLoadResult(
            points: try store.tokenDashboardPoints(
                breakdownDimension: request.breakdownDimension,
                range: request.range,
                periodStart: request.periodStart,
                periodEnd: request.periodEnd
            ),
            series: try store.tokenDashboardSeries(
                breakdownDimension: request.breakdownDimension,
                periodStart: request.periodStart,
                periodEnd: request.periodEnd
            ),
            attributionCoverageRows: try store.tokenAttributionCoverageRows(
                periodStart: request.periodStart,
                periodEnd: request.periodEnd
            ),
            availableBreakdownDimensions: availableBreakdownDimensions,
            historyBounds: try store.tokenDashboardBounds()
        )
    }

    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) throws -> PerformanceDashboardLoadResult {
        let store = try store()

        switch request.mode {
        case .performance:
            let presentation = try store.performanceDashboardPresentation(
                breakdownDimension: request.breakdownDimension,
                range: request.range,
                periodStart: request.periodStart,
                periodEnd: request.periodEnd,
                calendar: request.calendar
            )
            return PerformanceDashboardLoadResult(
                timingSamples: [],
                reliabilitySamples: [],
                efficiencyTokenSamples: [],
                modelCapabilities: [],
                durationPoints: presentation.durationPoints,
                reliabilityPoints: presentation.reliabilityPoints,
                breakdownRows: presentation.breakdownRows,
                efficiencyPoints: [],
                efficiencyRows: [],
                series: presentation.series,
                historyBounds: try store.performanceDashboardBounds(includeEfficiencyTokens: false)
            )
        case .efficiency:
            let presentation = try store.performanceDashboardEfficiencyPresentation(
                breakdownDimension: request.breakdownDimension,
                range: request.range,
                periodStart: request.periodStart,
                periodEnd: request.periodEnd,
                calendar: request.calendar
            )
            return PerformanceDashboardLoadResult(
                timingSamples: [],
                reliabilitySamples: [],
                efficiencyTokenSamples: [],
                modelCapabilities: [],
                durationPoints: [],
                reliabilityPoints: [],
                breakdownRows: [],
                efficiencyPoints: presentation.points,
                efficiencyRows: presentation.rows,
                series: presentation.series,
                historyBounds: try store.performanceDashboardBounds(includeEfficiencyTokens: true)
            )
        }
    }

    func databaseInfo() throws -> UsageHistoryDatabaseInfo {
        let store = try store()
        return try store.databaseInfo()
    }

    func exportBackup(to destinationURL: URL) throws {
        let store = try store()
        try store.exportBackup(to: destinationURL)
    }

    func importBackup(from sourceURL: URL) throws {
        let store = try store()
        try store.importBackup(from: sourceURL)
    }

    func clearHistory() throws {
        let store = try store()
        try store.clearHistory()
    }

    func tokenProjectCatalogEntries() throws -> [TokenProjectCatalogEntry] {
        let store = try store()
        return try store.tokenProjectCatalogEntries()
    }

    func tokenDimensionCatalogEntries() throws -> [TokenUsageDimensionCatalogEntry] {
        let store = try store()
        return try store.tokenDimensionCatalogEntries()
    }

    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) throws {
        let store = try store()
        try store.updateTokenProjectDisplayName(projectPath: projectPath, displayName: displayName)
    }

    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) throws -> CodexSessionTokenBackfillSummary {
        let store = try store()
        return try importer.importTokenHistory(into: store, request: request)
    }

    private func store() throws -> UsageHistoryStore {
        if let cachedStore {
            return cachedStore
        }

        let store = try storeFactory()
        cachedStore = store
        return store
    }

    private func importRecentTokenHistoryIfNeeded(
        store: UsageHistoryStore,
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexLiveTokenCaptureState {
        if let lastRecentTokenImportAt,
           date.timeIntervalSince(lastRecentTokenImportAt) < 30,
           calendar.isDate(lastRecentTokenImportAt, inSameDayAs: date),
           !force
        {
            return (try? store.codexLiveTokenCaptureState()) ?? CodexLiveTokenCaptureState()
        }

        let state = recentTokenHistoryImporter(store, date, calendar, force)
        lastRecentTokenImportAt = date
        return state
    }

    private func importTurnPerformanceIfNeeded(
        store: UsageHistoryStore,
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexTurnPerformanceCaptureState {
        if let lastTurnPerformanceImportAt,
           date.timeIntervalSince(lastTurnPerformanceImportAt) < 30,
           calendar.isDate(lastTurnPerformanceImportAt, inSameDayAs: date),
           !force
        {
            return (try? store.codexTurnPerformanceCaptureState()) ?? CodexTurnPerformanceCaptureState()
        }

        let state = turnPerformanceImporter(store, date, calendar, force)
        lastTurnPerformanceImportAt = date
        return state
    }

    private func importSessionTaskTimingIfNeeded(
        store: UsageHistoryStore,
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexSessionTaskTimingCaptureState {
        if let lastSessionTaskTimingImportAt,
           date.timeIntervalSince(lastSessionTaskTimingImportAt) < 30,
           calendar.isDate(lastSessionTaskTimingImportAt, inSameDayAs: date),
           !force
        {
            return (try? store.codexSessionTaskTimingCaptureState()) ?? CodexSessionTaskTimingCaptureState()
        }

        let state = sessionTaskTimingImporter(store, date, calendar, force)
        lastSessionTaskTimingImportAt = date
        return state
    }

    private func importThreadCatalogIfNeeded(
        store: UsageHistoryStore,
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexThreadCatalogCaptureState {
        if let lastThreadCatalogImportAt,
           date.timeIntervalSince(lastThreadCatalogImportAt) < 30,
           calendar.isDate(lastThreadCatalogImportAt, inSameDayAs: date),
           !force
        {
            return (try? store.codexThreadCatalogCaptureState()) ?? CodexThreadCatalogCaptureState()
        }

        let state = threadCatalogImporter(store, date, calendar, force)
        lastThreadCatalogImportAt = date
        return state
    }

    private func importModelCapabilitiesIfNeeded(
        store: UsageHistoryStore,
        at date: Date,
        calendar: Calendar,
        force: Bool = false
    ) -> CodexModelCapabilitiesCaptureState {
        if let lastModelCapabilitiesImportAt,
           date.timeIntervalSince(lastModelCapabilitiesImportAt) < 30,
           calendar.isDate(lastModelCapabilitiesImportAt, inSameDayAs: date),
           !force
        {
            return (try? store.codexModelCapabilitiesCaptureState()) ?? CodexModelCapabilitiesCaptureState()
        }

        let state = modelCapabilitiesImporter(store, date, calendar, force)
        lastModelCapabilitiesImportAt = date
        return state
    }

    private func isApplicationSupportStore(_ store: UsageHistoryStore) -> Bool {
        guard let path = store.databaseURL?.standardizedFileURL.path else {
            return false
        }

        return path.contains("/Library/Application Support/CodexStatusBar/")
    }
}
