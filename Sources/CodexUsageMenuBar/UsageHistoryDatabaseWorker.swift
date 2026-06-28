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
    let includeAttributionCoverage: Bool

    init(
        breakdownDimension: TokenDashboardBreakdownDimension = .model,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        includeAttributionCoverage: Bool = true
    ) {
        self.breakdownDimension = breakdownDimension
        self.range = range
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.includeAttributionCoverage = includeAttributionCoverage
    }
}

struct TokenDashboardQueryTimings: Equatable {
    var availableBreakdownDimensions: TimeInterval = 0
    var points: TimeInterval = 0
    var series: TimeInterval = 0
    var attributionCoverage: TimeInterval?
    var bounds: TimeInterval = 0

    func metadata() -> [String: String] {
        var metadata: [String: String] = [
            "availableBreakdownsMs": Self.formatMilliseconds(availableBreakdownDimensions),
            "pointsMs": Self.formatMilliseconds(points),
            "seriesMs": Self.formatMilliseconds(series),
            "boundsMs": Self.formatMilliseconds(bounds),
        ]
        if let attributionCoverage {
            metadata["coverageMs"] = Self.formatMilliseconds(attributionCoverage)
        }
        return metadata
    }

    static func formatMilliseconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f", max(interval * 1_000, 0))
    }
}

struct TokenDashboardLoadResult: Equatable {
    let points: [TokenDashboardComponentPoint]
    let series: [TokenDashboardSeries]
    let attributionCoverageRows: [TokenAttributionCoverageRow]
    let availableBreakdownDimensions: [TokenDashboardBreakdownDimension]
    let historyBounds: UsageHistoryBounds?
    let modelCapabilities: [CodexModelCapability]
    var queryTimings = TokenDashboardQueryTimings()

    init(
        points: [TokenDashboardComponentPoint],
        series: [TokenDashboardSeries],
        attributionCoverageRows: [TokenAttributionCoverageRow],
        availableBreakdownDimensions: [TokenDashboardBreakdownDimension],
        historyBounds: UsageHistoryBounds?,
        modelCapabilities: [CodexModelCapability] = [],
        queryTimings: TokenDashboardQueryTimings = TokenDashboardQueryTimings()
    ) {
        self.points = points
        self.series = series
        self.attributionCoverageRows = attributionCoverageRows
        self.availableBreakdownDimensions = availableBreakdownDimensions
        self.historyBounds = historyBounds
        self.modelCapabilities = modelCapabilities
        self.queryTimings = queryTimings
    }

    static func == (lhs: TokenDashboardLoadResult, rhs: TokenDashboardLoadResult) -> Bool {
        lhs.points == rhs.points
            && lhs.series == rhs.series
            && lhs.attributionCoverageRows == rhs.attributionCoverageRows
            && lhs.availableBreakdownDimensions == rhs.availableBreakdownDimensions
            && lhs.historyBounds == rhs.historyBounds
            && lhs.modelCapabilities == rhs.modelCapabilities
    }
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
    func turnPerformanceRuntimeDimensionSummary() async -> CodexOtelRuntimeDimensionSummary
    func captureSessionTaskTimingIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexSessionTaskTimingCaptureState
    func sessionTaskTimingCaptureState() async -> CodexSessionTaskTimingCaptureState
    func captureThreadCatalogIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexThreadCatalogCaptureState
    func threadCatalogCaptureState() async -> CodexThreadCatalogCaptureState
    func captureModelCapabilitiesIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexModelCapabilitiesCaptureState
    func modelCapabilitiesCaptureState() async -> CodexModelCapabilitiesCaptureState
    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult
    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult
    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow]
    func localTokenComparisonTotals(now: Date) async throws -> LocalTokenComparisonTotals
    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult
    func localSourceStoredMetrics() async throws -> CodexLocalSourceStoredMetrics
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

protocol UsageHistoryDashboardQueryWorking: Sendable {
    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult
    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult
    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow]
    func localTokenComparisonTotals(now: Date) async throws -> LocalTokenComparisonTotals
    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult
    func localSourceStoredMetrics() async throws -> CodexLocalSourceStoredMetrics
}

extension UsageHistoryDatabaseWorking {
    func turnPerformanceRuntimeDimensionSummary() async -> CodexOtelRuntimeDimensionSummary {
        .empty
    }

    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow] {
        throw UsageHistoryStoreError.databaseOperationFailed("Token attribution coverage is unavailable.")
    }

    func localTokenComparisonTotals(now: Date) async throws -> LocalTokenComparisonTotals {
        throw UsageHistoryStoreError.databaseOperationFailed("Local token comparison totals are unavailable.")
    }

    func localSourceStoredMetrics() async throws -> CodexLocalSourceStoredMetrics {
        throw UsageHistoryStoreError.databaseOperationFailed("Local source stored metrics are unavailable.")
    }
}

extension UsageHistoryDashboardQueryWorking {
    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow] {
        throw UsageHistoryStoreError.databaseOperationFailed("Token attribution coverage is unavailable.")
    }

    func localTokenComparisonTotals(now: Date) async throws -> LocalTokenComparisonTotals {
        throw UsageHistoryStoreError.databaseOperationFailed("Local token comparison totals are unavailable.")
    }

    func localSourceStoredMetrics() async throws -> CodexLocalSourceStoredMetrics {
        throw UsageHistoryStoreError.databaseOperationFailed("Local source stored metrics are unavailable.")
    }
}

enum UsageHistorySnapshotReader {
    static func usageHistorySnapshot(
        store: UsageHistoryStore,
        request: UsageHistoryLoadRequest
    ) throws -> UsageHistoryLoadResult {
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

    static func tokenDashboardSnapshot(
        store: UsageHistoryStore,
        request: TokenDashboardLoadRequest
    ) throws -> TokenDashboardLoadResult {
        var timings = TokenDashboardQueryTimings()
        let availableBreakdownDimensions = try measure(&timings.availableBreakdownDimensions) {
            try store.tokenDashboardAvailableBreakdownDimensions(
                periodStart: request.periodStart,
                periodEnd: request.periodEnd
            )
        }
        let points = try measure(&timings.points) {
            try store.tokenDashboardPoints(
                breakdownDimension: request.breakdownDimension,
                range: request.range,
                periodStart: request.periodStart,
                periodEnd: request.periodEnd
            )
        }
        let series = try measure(&timings.series) {
            try store.tokenDashboardSeries(
                breakdownDimension: request.breakdownDimension,
                periodStart: request.periodStart,
                periodEnd: request.periodEnd
            )
        }
        let attributionCoverageRows: [TokenAttributionCoverageRow]
        if request.includeAttributionCoverage {
            attributionCoverageRows = try measureOptional(&timings.attributionCoverage) {
                try store.tokenAttributionCoverageRows(
                    periodStart: request.periodStart,
                    periodEnd: request.periodEnd
                )
            }
        } else {
            attributionCoverageRows = []
        }
        let historyBounds = try measure(&timings.bounds) {
            try store.tokenDashboardBounds()
        }
        let modelCapabilities = request.breakdownDimension == .model
            ? try store.codexModelCapabilities()
            : []
        return TokenDashboardLoadResult(
            points: points,
            series: series,
            attributionCoverageRows: attributionCoverageRows,
            availableBreakdownDimensions: availableBreakdownDimensions,
            historyBounds: historyBounds,
            modelCapabilities: modelCapabilities,
            queryTimings: timings
        )
    }

    private static func measure<T>(_ destination: inout TimeInterval, operation: () throws -> T) rethrows -> T {
        let start = Date()
        let value = try operation()
        destination = Date().timeIntervalSince(start)
        return value
    }

    private static func measureOptional<T>(_ destination: inout TimeInterval?, operation: () throws -> T) rethrows -> T {
        let start = Date()
        let value = try operation()
        destination = Date().timeIntervalSince(start)
        return value
    }

    static func performanceDashboardSnapshot(
        store: UsageHistoryStore,
        request: PerformanceDashboardLoadRequest
    ) throws -> PerformanceDashboardLoadResult {
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
                modelCapabilities: request.breakdownDimension == .model ? try store.codexModelCapabilities() : [],
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
                modelCapabilities: Self.performanceDashboardShouldLoadModelCapabilities(for: request)
                    ? try store.codexModelCapabilities()
                    : [],
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

    private static func performanceDashboardShouldLoadModelCapabilities(
        for request: PerformanceDashboardLoadRequest
    ) -> Bool {
        switch request.mode {
        case .performance:
            return request.breakdownDimension == .model
        case .efficiency:
            switch request.breakdownDimension {
            case .model, .transport, .wireAPI:
                return true
            case .effort, .project, .source:
                return false
            }
        }
    }
}

actor UsageHistoryDashboardQueryWorker: UsageHistoryDashboardQueryWorking {
    typealias StoreFactory = @Sendable () throws -> UsageHistoryStore

    private let storeFactory: StoreFactory
    private let fallbackStoreFactory: StoreFactory
    private var cachedStore: UsageHistoryStore?

    init(
        store: UsageHistoryStore,
        fallbackStoreFactory: @escaping StoreFactory = { try UsageHistoryStore.inMemory() }
    ) {
        self.storeFactory = { store }
        self.fallbackStoreFactory = fallbackStoreFactory
        self.cachedStore = store
    }

    init(
        storeFactory: @escaping StoreFactory,
        fallbackStoreFactory: @escaping StoreFactory = { try UsageHistoryStore.inMemory() }
    ) {
        self.storeFactory = storeFactory
        self.fallbackStoreFactory = fallbackStoreFactory
    }

    static func applicationSupportStore() -> UsageHistoryDashboardQueryWorker {
        UsageHistoryDashboardQueryWorker(storeFactory: {
            try UsageHistoryStore.applicationSupportReadOnlyStore()
        })
    }

    static func applicationSupportStoreWithInMemoryFallback() -> UsageHistoryDashboardQueryWorker {
        UsageHistoryDashboardQueryWorker(storeFactory: {
            try UsageHistoryStore.applicationSupportReadOnlyStore()
        })
    }

    static func inMemory() throws -> UsageHistoryDashboardQueryWorker {
        try UsageHistoryDashboardQueryWorker(store: UsageHistoryStore.inMemory())
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) throws -> UsageHistoryLoadResult {
        try UsageHistorySnapshotReader.usageHistorySnapshot(store: store(), request: request)
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) throws -> TokenDashboardLoadResult {
        try UsageHistorySnapshotReader.tokenDashboardSnapshot(store: store(), request: request)
    }

    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow] {
        try store().tokenAttributionCoverageRows(periodStart: periodStart, periodEnd: periodEnd)
    }

    func localTokenComparisonTotals(now: Date) async throws -> LocalTokenComparisonTotals {
        try store().localTokenComparisonTotals(now: now)
    }

    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) throws -> PerformanceDashboardLoadResult {
        try UsageHistorySnapshotReader.performanceDashboardSnapshot(store: store(), request: request)
    }

    func localSourceStoredMetrics() throws -> CodexLocalSourceStoredMetrics {
        try store().localSourceStoredMetrics()
    }

    private func store() throws -> UsageHistoryStore {
        if let cachedStore {
            return cachedStore
        }

        do {
            let store = try storeFactory()
            cachedStore = store
            return store
        } catch {
            return try fallbackStoreFactory()
        }
    }
}

struct UsageHistoryDatabaseRouter: UsageHistoryDatabaseWorking {
    let writer: UsageHistoryDatabaseWorking
    let dashboardQueryWorker: UsageHistoryDashboardQueryWorking

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {
        await writer.record(snapshot: snapshot, at: date)
    }

    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        await writer.record(tokenUsage: tokenUsage, at: date)
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        await writer.todayTokenCategoryTotals(at: date, calendar: calendar)
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        await writer.todayTotalTokens(at: date, calendar: calendar)
    }

    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexLiveTokenCaptureState {
        await writer.captureLiveTokenHistoryIfNeeded(at: date, calendar: calendar, force: force)
    }

    func liveTokenCaptureState() async -> CodexLiveTokenCaptureState {
        await writer.liveTokenCaptureState()
    }

    func captureTurnPerformanceIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexTurnPerformanceCaptureState {
        await writer.captureTurnPerformanceIfNeeded(at: date, calendar: calendar, force: force)
    }

    func turnPerformanceCaptureState() async -> CodexTurnPerformanceCaptureState {
        await writer.turnPerformanceCaptureState()
    }

    func turnPerformanceRuntimeDimensionSummary() async -> CodexOtelRuntimeDimensionSummary {
        await writer.turnPerformanceRuntimeDimensionSummary()
    }

    func captureSessionTaskTimingIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexSessionTaskTimingCaptureState {
        await writer.captureSessionTaskTimingIfNeeded(at: date, calendar: calendar, force: force)
    }

    func sessionTaskTimingCaptureState() async -> CodexSessionTaskTimingCaptureState {
        await writer.sessionTaskTimingCaptureState()
    }

    func captureThreadCatalogIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexThreadCatalogCaptureState {
        await writer.captureThreadCatalogIfNeeded(at: date, calendar: calendar, force: force)
    }

    func threadCatalogCaptureState() async -> CodexThreadCatalogCaptureState {
        await writer.threadCatalogCaptureState()
    }

    func captureModelCapabilitiesIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexModelCapabilitiesCaptureState {
        await writer.captureModelCapabilitiesIfNeeded(at: date, calendar: calendar, force: force)
    }

    func modelCapabilitiesCaptureState() async -> CodexModelCapabilitiesCaptureState {
        await writer.modelCapabilitiesCaptureState()
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult {
        try await dashboardQueryWorker.usageHistorySnapshot(for: request)
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult {
        try await dashboardQueryWorker.tokenDashboardSnapshot(for: request)
    }

    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow] {
        try await dashboardQueryWorker.tokenAttributionCoverageRows(periodStart: periodStart, periodEnd: periodEnd)
    }

    func localTokenComparisonTotals(now: Date) async throws -> LocalTokenComparisonTotals {
        try await dashboardQueryWorker.localTokenComparisonTotals(now: now)
    }

    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult {
        try await dashboardQueryWorker.performanceDashboardSnapshot(for: request)
    }

    func localSourceStoredMetrics() async throws -> CodexLocalSourceStoredMetrics {
        try await dashboardQueryWorker.localSourceStoredMetrics()
    }

    func databaseInfo() async throws -> UsageHistoryDatabaseInfo {
        try await writer.databaseInfo()
    }

    func exportBackup(to destinationURL: URL) async throws {
        try await writer.exportBackup(to: destinationURL)
    }

    func importBackup(from sourceURL: URL) async throws {
        try await writer.importBackup(from: sourceURL)
    }

    func clearHistory() async throws {
        try await writer.clearHistory()
    }

    func tokenProjectCatalogEntries() async throws -> [TokenProjectCatalogEntry] {
        try await writer.tokenProjectCatalogEntries()
    }

    func tokenDimensionCatalogEntries() async throws -> [TokenUsageDimensionCatalogEntry] {
        try await writer.tokenDimensionCatalogEntries()
    }

    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) async throws {
        try await writer.updateTokenProjectDisplayName(projectPath: projectPath, displayName: displayName)
    }

    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) async throws -> CodexSessionTokenBackfillSummary {
        try await writer.importTokenHistory(importer: importer, request: request)
    }
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
        store.captureLiveCodexLogTokenHistory(
            at: date,
            calendar: calendar,
            force: force,
            sessionTokenBackfillImporter: CodexSessionTokenBackfillImporter(
                sourceDirectories: CodexSessionTokenBackfillImporter.defaultActiveSourceDirectories()
            )
        )
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
    private let cacheStoreOnOpen: Bool
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
        self.cacheStoreOnOpen = true
        self.cachedStore = store
    }

    init(
        storeFactory: @escaping StoreFactory,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = UsageHistoryDatabaseWorker.liveRecentTokenHistoryImporter,
        turnPerformanceImporter: @escaping TurnPerformanceImporter = UsageHistoryDatabaseWorker.liveTurnPerformanceImporter,
        sessionTaskTimingImporter: @escaping SessionTaskTimingImporter = UsageHistoryDatabaseWorker.liveSessionTaskTimingImporter,
        threadCatalogImporter: @escaping ThreadCatalogImporter = UsageHistoryDatabaseWorker.liveThreadCatalogImporter,
        modelCapabilitiesImporter: @escaping ModelCapabilitiesImporter = UsageHistoryDatabaseWorker.liveModelCapabilitiesImporter,
        cacheStoreOnOpen: Bool = true
    ) {
        self.storeFactory = storeFactory
        self.recentTokenHistoryImporter = recentTokenHistoryImporter
        self.turnPerformanceImporter = turnPerformanceImporter
        self.sessionTaskTimingImporter = sessionTaskTimingImporter
        self.threadCatalogImporter = threadCatalogImporter
        self.modelCapabilitiesImporter = modelCapabilitiesImporter
        self.cacheStoreOnOpen = cacheStoreOnOpen
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
        }, cacheStoreOnOpen: false)
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
            return try store.tokenCategoryTotalsForDay(containing: date, calendar: calendar) ?? .zero
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
            return (try store.tokenCategoryTotalsForDay(containing: date, calendar: calendar) ?? .zero).totalTokens
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

    func turnPerformanceRuntimeDimensionSummary() -> CodexOtelRuntimeDimensionSummary {
        do {
            return try store().turnPerformanceRuntimeDimensionSummary()
        } catch {
            return .empty
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
        try UsageHistorySnapshotReader.usageHistorySnapshot(store: store(), request: request)
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) throws -> TokenDashboardLoadResult {
        try UsageHistorySnapshotReader.tokenDashboardSnapshot(store: store(), request: request)
    }

    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow] {
        try store().tokenAttributionCoverageRows(periodStart: periodStart, periodEnd: periodEnd)
    }

    func localTokenComparisonTotals(now: Date) throws -> LocalTokenComparisonTotals {
        try store().localTokenComparisonTotals(now: now)
    }

    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) throws -> PerformanceDashboardLoadResult {
        try UsageHistorySnapshotReader.performanceDashboardSnapshot(store: store(), request: request)
    }

    func localSourceStoredMetrics() throws -> CodexLocalSourceStoredMetrics {
        try store().localSourceStoredMetrics()
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
        if cacheStoreOnOpen {
            cachedStore = store
        }
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
