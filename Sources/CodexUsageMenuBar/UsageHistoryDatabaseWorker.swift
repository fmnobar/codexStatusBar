import Foundation

final class UsageHistoryStoreReplacementGate: @unchecked Sendable {
    static let shared = UsageHistoryStoreReplacementGate()

    private let lock = NSLock()
    private var activeOperationCount = 0

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeOperationCount > 0
    }

    func begin() {
        lock.lock()
        activeOperationCount += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        activeOperationCount = max(activeOperationCount - 1, 0)
        lock.unlock()
    }
}

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

protocol UsageHistoryViewModelDatabaseWorking: Sendable {
    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult
    func clearHistory() async throws
}

protocol TokenDashboardViewModelDatabaseWorking: Sendable {
    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult
    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow]
}

protocol UsageHistoryDatabaseWorking: UsageHistoryViewModelDatabaseWorking, TokenDashboardViewModelDatabaseWorking {
    func record(snapshot: CodexUsageSnapshot, at date: Date) async
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals?
    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) async -> TokenCategoryTotals?
    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals?
    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64?
    func captureLiveTokenHistoryIfNeeded(at date: Date, calendar: Calendar, force: Bool) async -> CodexLiveTokenCaptureState
    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool,
        includeDetailedContext: Bool
    ) async -> CodexLiveTokenCaptureState
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
    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult
    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow]
    func localTokenComparisonTotals(now: Date) async throws -> LocalTokenComparisonTotals
    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult
    func localSourceStoredMetrics() async throws -> CodexLocalSourceStoredMetrics
    func enforceTelemetryRetention(referenceDate: Date) async throws
    func optimizeStorage(reason: StorageOptimizationReason) async throws -> StorageOptimizationResult
    func databaseInfo() async throws -> UsageHistoryDatabaseInfo
    func exportBackup(to destinationURL: URL) async throws
    func importBackup(from sourceURL: URL) async throws
    func clearAnalyticsData() async throws
    func tokenProjectCatalogEntries() async throws -> [TokenProjectCatalogEntry]
    func tokenDimensionCatalogEntries() async throws -> [TokenUsageDimensionCatalogEntry]
    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) async throws
    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) async throws -> CodexSessionTokenBackfillSummary
    func buildHistoricalTokenArchive(
        importer: CodexSessionTokenBackfillImporting,
        destinationURL: URL,
        replaceExisting: Bool
    ) async throws -> HistoricalTokenArchiveBuildResult
}

protocol UsageHistoryDashboardQueryWorking: Sendable {
    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult
    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult
    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow]
    func localTokenComparisonTotals(now: Date) async throws -> LocalTokenComparisonTotals
    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult
    func localSourceStoredMetrics() async throws -> CodexLocalSourceStoredMetrics
    func invalidateCachedStore() async
}

extension UsageHistoryDatabaseWorking {
    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool,
        includeDetailedContext: Bool
    ) async -> CodexLiveTokenCaptureState {
        await captureLiveTokenHistoryIfNeeded(at: date, calendar: calendar, force: force)
    }

    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) async -> TokenCategoryTotals? {
        nil
    }

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

    func enforceTelemetryRetention(referenceDate: Date) async throws {}

    func optimizeStorage(reason: StorageOptimizationReason) async throws -> StorageOptimizationResult {
        throw UsageHistoryStoreError.databaseUnavailable
    }

    func clearAnalyticsData() async throws {
        try await clearHistory()
    }

    func buildHistoricalTokenArchive(
        importer: CodexSessionTokenBackfillImporting,
        destinationURL: URL,
        replaceExisting: Bool
    ) async throws -> HistoricalTokenArchiveBuildResult {
        throw UsageHistoryStoreError.databaseUnavailable
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

    func invalidateCachedStore() async {}
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

actor HistoricalTokenArchiveQueryWorker: UsageHistoryViewModelDatabaseWorking, TokenDashboardViewModelDatabaseWorking {
    private let descriptor: HistoricalTokenArchiveDescriptor
    private var cachedStore: UsageHistoryStore?

    init(descriptor: HistoricalTokenArchiveDescriptor) {
        self.descriptor = descriptor
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) throws -> UsageHistoryLoadResult {
        try UsageHistorySnapshotReader.usageHistorySnapshot(store: store(), request: request)
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) throws -> TokenDashboardLoadResult {
        try UsageHistorySnapshotReader.tokenDashboardSnapshot(store: store(), request: request)
    }

    func tokenAttributionCoverageRows(
        periodStart: Date,
        periodEnd: Date
    ) throws -> [TokenAttributionCoverageRow] {
        try store().tokenAttributionCoverageRows(periodStart: periodStart, periodEnd: periodEnd)
    }

    func clearHistory() throws {
        throw UsageHistoryStoreError.databaseOperationFailed("Historical archives are read-only.")
    }

    private func store() throws -> UsageHistoryStore {
        if let cachedStore {
            return cachedStore
        }
        let current = try UsageHistoryStore.historicalTokenArchiveDescriptor(at: descriptor.url)
        guard current.fileIdentifier == descriptor.fileIdentifier else {
            throw HistoricalTokenArchiveError.pathChanged
        }
        let store = try UsageHistoryStore(databaseURL: descriptor.url, openMode: .readOnly)
        cachedStore = store
        return store
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

    func invalidateCachedStore() {
        cachedStore = nil
    }

    private func store() throws -> UsageHistoryStore {
        guard !UsageHistoryStoreReplacementGate.shared.isActive else {
            throw UsageHistoryStoreError.storageMaintenanceInProgress
        }
        if let cachedStore {
            guard cachedStore.databaseURL == nil else {
                return cachedStore
            }

            do {
                let durableStore = try storeFactory()
                self.cachedStore = durableStore
                return durableStore
            } catch {
                return cachedStore
            }
        }

        do {
            let store = try storeFactory()
            cachedStore = store
            return store
        } catch {
            let fallbackStore = try fallbackStoreFactory()
            cachedStore = fallbackStore
            return fallbackStore
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

    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) async -> TokenCategoryTotals? {
        await writer.tokenCategoryTotals(periodStart: periodStart, periodEnd: periodEnd)
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

    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool,
        includeDetailedContext: Bool
    ) async -> CodexLiveTokenCaptureState {
        await writer.captureLiveTokenHistoryIfNeeded(
            at: date,
            calendar: calendar,
            force: force,
            includeDetailedContext: includeDetailedContext
        )
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

    func enforceTelemetryRetention(referenceDate: Date) async throws {
        await dashboardQueryWorker.invalidateCachedStore()
        do {
            try await writer.enforceTelemetryRetention(referenceDate: referenceDate)
            await dashboardQueryWorker.invalidateCachedStore()
        } catch {
            await dashboardQueryWorker.invalidateCachedStore()
            throw error
        }
    }

    func optimizeStorage(reason: StorageOptimizationReason) async throws -> StorageOptimizationResult {
        await dashboardQueryWorker.invalidateCachedStore()
        do {
            let result = try await writer.optimizeStorage(reason: reason)
            await dashboardQueryWorker.invalidateCachedStore()
            return result
        } catch {
            await dashboardQueryWorker.invalidateCachedStore()
            throw error
        }
    }

    func databaseInfo() async throws -> UsageHistoryDatabaseInfo {
        try await writer.databaseInfo()
    }

    func exportBackup(to destinationURL: URL) async throws {
        try await writer.exportBackup(to: destinationURL)
    }

    func importBackup(from sourceURL: URL) async throws {
        await dashboardQueryWorker.invalidateCachedStore()
        do {
            try await writer.importBackup(from: sourceURL)
            await dashboardQueryWorker.invalidateCachedStore()
        } catch {
            await dashboardQueryWorker.invalidateCachedStore()
            throw error
        }
    }

    func clearAnalyticsData() async throws {
        try await writer.clearAnalyticsData()
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
        let result = try await writer.importTokenHistory(importer: importer, request: request)
        await dashboardQueryWorker.invalidateCachedStore()
        return result
    }

    func buildHistoricalTokenArchive(
        importer: CodexSessionTokenBackfillImporting,
        destinationURL: URL,
        replaceExisting: Bool
    ) async throws -> HistoricalTokenArchiveBuildResult {
        try await writer.buildHistoricalTokenArchive(
            importer: importer,
            destinationURL: destinationURL,
            replaceExisting: replaceExisting
        )
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
    typealias RecentTokenHistoryImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool, Bool) -> CodexLiveTokenCaptureState
    typealias TurnPerformanceImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexTurnPerformanceCaptureState
    typealias SessionTaskTimingImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexSessionTaskTimingCaptureState
    typealias ThreadCatalogImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexThreadCatalogCaptureState
    typealias ModelCapabilitiesImporter = @Sendable (UsageHistoryStore, Date, Calendar, Bool) -> CodexModelCapabilitiesCaptureState

    static let liveRecentTokenHistoryImporter: RecentTokenHistoryImporter = { store, date, calendar, force, includeDetailedContext in
        store.captureLiveCodexLogTokenHistory(
            at: date,
            calendar: calendar,
            force: force,
            includeDetailedContext: includeDetailedContext,
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
    private let fallbackStoreFactory: StoreFactory?
    private let cacheStoreOnOpen: Bool
    private let canReleaseStoreForReplacement: Bool
    private let collectionModeProvider: @Sendable () -> UsageCollectionMode
    private var cachedStore: UsageHistoryStore?
    private var lastRecentTokenImportAt: Date?
    private var lastTurnPerformanceImportAt: Date?
    private var lastSessionTaskTimingImportAt: Date?
    private var lastThreadCatalogImportAt: Date?
    private var lastModelCapabilitiesImportAt: Date?
    private var storageReplacementInProgress = false

    init(
        store: UsageHistoryStore,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = UsageHistoryDatabaseWorker.liveRecentTokenHistoryImporter,
        turnPerformanceImporter: @escaping TurnPerformanceImporter = UsageHistoryDatabaseWorker.liveTurnPerformanceImporter,
        sessionTaskTimingImporter: @escaping SessionTaskTimingImporter = UsageHistoryDatabaseWorker.liveSessionTaskTimingImporter,
        threadCatalogImporter: @escaping ThreadCatalogImporter = UsageHistoryDatabaseWorker.liveThreadCatalogImporter,
        modelCapabilitiesImporter: @escaping ModelCapabilitiesImporter = UsageHistoryDatabaseWorker.liveModelCapabilitiesImporter,
        collectionModeProvider: @escaping @Sendable () -> UsageCollectionMode = { .detailedAnalytics }
    ) {
        self.storeFactory = { store }
        self.recentTokenHistoryImporter = recentTokenHistoryImporter
        self.turnPerformanceImporter = turnPerformanceImporter
        self.sessionTaskTimingImporter = sessionTaskTimingImporter
        self.threadCatalogImporter = threadCatalogImporter
        self.modelCapabilitiesImporter = modelCapabilitiesImporter
        self.fallbackStoreFactory = nil
        self.cacheStoreOnOpen = true
        self.canReleaseStoreForReplacement = false
        self.collectionModeProvider = collectionModeProvider
        self.cachedStore = store
    }

    init(
        storeFactory: @escaping StoreFactory,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = UsageHistoryDatabaseWorker.liveRecentTokenHistoryImporter,
        turnPerformanceImporter: @escaping TurnPerformanceImporter = UsageHistoryDatabaseWorker.liveTurnPerformanceImporter,
        sessionTaskTimingImporter: @escaping SessionTaskTimingImporter = UsageHistoryDatabaseWorker.liveSessionTaskTimingImporter,
        threadCatalogImporter: @escaping ThreadCatalogImporter = UsageHistoryDatabaseWorker.liveThreadCatalogImporter,
        modelCapabilitiesImporter: @escaping ModelCapabilitiesImporter = UsageHistoryDatabaseWorker.liveModelCapabilitiesImporter,
        fallbackStoreFactory: StoreFactory? = nil,
        cacheStoreOnOpen: Bool = true,
        collectionModeProvider: @escaping @Sendable () -> UsageCollectionMode = { .detailedAnalytics }
    ) {
        self.storeFactory = storeFactory
        self.recentTokenHistoryImporter = recentTokenHistoryImporter
        self.turnPerformanceImporter = turnPerformanceImporter
        self.sessionTaskTimingImporter = sessionTaskTimingImporter
        self.threadCatalogImporter = threadCatalogImporter
        self.modelCapabilitiesImporter = modelCapabilitiesImporter
        self.fallbackStoreFactory = fallbackStoreFactory
        self.cacheStoreOnOpen = cacheStoreOnOpen
        self.canReleaseStoreForReplacement = true
        self.collectionModeProvider = collectionModeProvider
    }

    static func applicationSupportStore(
        collectionModeProvider: @escaping @Sendable () -> UsageCollectionMode = { .lightweight }
    ) -> UsageHistoryDatabaseWorker {
        UsageHistoryDatabaseWorker(storeFactory: {
            try UsageHistoryStore.applicationSupportStore()
        }, collectionModeProvider: collectionModeProvider)
    }

    static func applicationSupportStoreWithInMemoryFallback(
        collectionModeProvider: @escaping @Sendable () -> UsageCollectionMode = { .lightweight }
    ) -> UsageHistoryDatabaseWorker {
        UsageHistoryDatabaseWorker(storeFactory: {
            try UsageHistoryStore.applicationSupportStore()
        }, fallbackStoreFactory: {
            try UsageHistoryStore.inMemory()
        }, collectionModeProvider: collectionModeProvider)
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
            let mode = collectionModeProvider()
            let persistedNotification: CodexTokenUsageNotification
            if mode == .detailedAnalytics,
               try !store.preflightAdvancedIngestion(mode: mode, batchKind: .tokenNotification)
            {
                persistedNotification = tokenUsage.lightweightStorageValue
            } else {
                persistedNotification = tokenUsage
            }
            try store.record(tokenUsage: persistedNotification, at: date)
            return try store.tokenCategoryTotalsForDay(containing: date, calendar: .autoupdatingCurrent)
        } catch {
            // Token telemetry should never interrupt the live menu bar status.
            return nil
        }
    }

    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) async -> TokenCategoryTotals? {
        do {
            guard periodStart < periodEnd else {
                return nil
            }

            let store = try store()
            let captureState = try store.codexLiveTokenCaptureState()
            guard captureState.hasSuccessfulCheck else {
                return nil
            }

            return try store.tokenCategoryTotals(periodStart: periodStart, periodEnd: periodEnd) ?? .zero
        } catch {
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
        captureLiveTokenHistoryIfNeeded(
            at: date,
            calendar: calendar,
            force: force,
            includeDetailedContext: true
        )
    }

    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool = false,
        includeDetailedContext: Bool
    ) -> CodexLiveTokenCaptureState {
        do {
            let store = try store()
            let shouldIncludeDetailedContext: Bool
            if includeDetailedContext, collectionModeProvider() == .detailedAnalytics {
                shouldIncludeDetailedContext = try store.preflightAdvancedIngestion(
                    mode: .detailedAnalytics,
                    batchKind: .tokenCapture
                )
            } else {
                shouldIncludeDetailedContext = false
            }
            return importRecentTokenHistoryIfNeeded(
                store: store,
                at: date,
                calendar: calendar,
                force: force,
                includeDetailedContext: shouldIncludeDetailedContext
            )
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
            guard try advancedIngestionAllowed(store: store, batchKind: .turnPerformance) else {
                return CodexTurnPerformanceCaptureState(
                    lastCheckedAt: date,
                    status: .failed,
                    lastErrorText: UsageHistoryStoreError.storageBudgetExceeded.localizedDescription
                )
            }
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
            guard try advancedIngestionAllowed(store: store, batchKind: .sessionTiming) else {
                return CodexSessionTaskTimingCaptureState(
                    lastCheckedAt: date,
                    status: .failed,
                    lastErrorText: UsageHistoryStoreError.storageBudgetExceeded.localizedDescription
                )
            }
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
            guard try advancedIngestionAllowed(store: store, batchKind: .threadCatalog) else {
                return CodexThreadCatalogCaptureState(
                    lastCheckedAt: date,
                    status: .failed,
                    lastErrorText: UsageHistoryStoreError.storageBudgetExceeded.localizedDescription
                )
            }
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
            guard try advancedIngestionAllowed(store: store, batchKind: .modelCapabilities) else {
                return CodexModelCapabilitiesCaptureState(
                    lastCheckedAt: date,
                    status: .failed,
                    lastErrorText: UsageHistoryStoreError.storageBudgetExceeded.localizedDescription
                )
            }
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

    func enforceTelemetryRetention(referenceDate: Date) async throws {
        var optimizationReason: StorageOptimizationReason?
        do {
            let store = try store()
            guard try store.beginTelemetryRetention(referenceDate: referenceDate, force: true) else {
                return
            }
            do {
                while try store.enforceNextTelemetryRetentionBatch(referenceDate: referenceDate) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                try Task.checkCancellation()

                var maintenance = try store.storageMaintenanceState()
                maintenance.stage = .backfilling
                try store.recordStorageMaintenanceState(maintenance)
                let neededV3Finalization = try store.metadataValue(
                    for: "token_dimension_v3_finalized"
                ) != "1"
                while try store.backfillNextTokenDimensionSetChunk(sampleLimit: 1_000) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                try Task.checkCancellation()
                let finalized = try store.finalizeTokenDimensionSetMigrationIfReady()
                try store.finishTelemetryRetention(referenceDate: referenceDate)
                let info = try store.enforceStorageBudget(mode: collectionModeProvider())
                if finalized, neededV3Finalization {
                    optimizationReason = .schemaMigration
                } else if info.totalByteSize > info.hardMaximumByteSize {
                    optimizationReason = .hardBudgetRecovery
                }
            } catch {
                try? store.failTelemetryRetention(referenceDate: referenceDate, error: error)
                throw error
            }
        } catch {
            throw error
        }

        if let optimizationReason {
            _ = try await optimizeStorage(reason: optimizationReason)
        }
    }

    func optimizeStorage(reason: StorageOptimizationReason) async throws -> StorageOptimizationResult {
        guard canReleaseStoreForReplacement, !storageReplacementInProgress else {
            throw UsageHistoryStoreError.storageMaintenanceInProgress
        }
        let databaseURL: URL
        do {
            let openedStore = try store()
            guard let url = openedStore.databaseURL else {
                throw UsageHistoryStoreError.databaseUnavailable
            }
            try openedStore.checkpointWriteAheadLog()
            databaseURL = url
        }
        cachedStore = nil
        storageReplacementInProgress = true
        UsageHistoryStoreReplacementGate.shared.begin()
        defer {
            UsageHistoryStoreReplacementGate.shared.end()
            storageReplacementInProgress = false
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                try UsageHistoryStore.optimizeDatabase(at: databaseURL, reason: reason)
            }.value
            cachedStore = try self.storeFactory()
            return result
        } catch {
            cachedStore = try? self.storeFactory()
            throw error
        }
    }

    func databaseInfo() throws -> UsageHistoryDatabaseInfo {
        let store = try store()
        return try store.databaseInfo(collectionMode: collectionModeProvider())
    }

    func exportBackup(to destinationURL: URL) throws {
        let store = try store()
        try store.exportBackup(to: destinationURL)
    }

    func importBackup(from sourceURL: URL) async throws {
        guard canReleaseStoreForReplacement else {
            let store = try store()
            try store.importBackup(from: sourceURL)
            requestMaintenance(.backupImport)
            return
        }

        let canonicalURL: URL
        do {
            let openedStore = try store()
            guard let databaseURL = openedStore.databaseURL else {
                throw UsageHistoryStoreError.databaseUnavailable
            }
            try openedStore.checkpointWriteAheadLog()
            canonicalURL = databaseURL
        }
        cachedStore = nil
        guard !storageReplacementInProgress else {
            throw UsageHistoryStoreError.storageMaintenanceInProgress
        }
        storageReplacementInProgress = true
        UsageHistoryStoreReplacementGate.shared.begin()
        defer {
            UsageHistoryStoreReplacementGate.shared.end()
            storageReplacementInProgress = false
        }
        let mode = collectionModeProvider()
        do {
            try await Task.detached(priority: .utility) {
                try UsageHistoryStore.restoreOperationalBackup(
                    from: sourceURL,
                    to: canonicalURL,
                    mode: mode
                )
            }.value
            cachedStore = try self.storeFactory()
            requestMaintenance(.backupImport)
        } catch {
            cachedStore = try? self.storeFactory()
            throw error
        }
    }

    func clearAnalyticsData() throws {
        let store = try store()
        try store.clearAnalyticsData()
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
        guard try advancedIngestionAllowed(store: store, batchKind: .operationalImport) else {
            throw UsageHistoryStoreError.storageBudgetExceeded
        }
        let summary = try importer.importTokenHistory(into: store, request: request)
        requestMaintenance(.operationalImport)
        return summary
    }

    func buildHistoricalTokenArchive(
        importer: CodexSessionTokenBackfillImporting,
        destinationURL: URL,
        replaceExisting: Bool
    ) throws -> HistoricalTokenArchiveBuildResult {
        let (descriptor, summary) = try UsageHistoryStore.buildHistoricalTokenArchive(
            at: destinationURL,
            importer: importer,
            replaceExisting: replaceExisting
        )
        return HistoricalTokenArchiveBuildResult(descriptor: descriptor, summary: summary)
    }

    private func advancedIngestionAllowed(
        store: UsageHistoryStore,
        batchKind: AdvancedIngestionBatchKind
    ) throws -> Bool {
        let mode = collectionModeProvider()
        guard mode == .detailedAnalytics else {
            return false
        }
        return try store.preflightAdvancedIngestion(mode: mode, batchKind: batchKind)
    }

    private func requestMaintenance(_ trigger: StorageMaintenanceTrigger) {
        NotificationCenter.default.post(
            name: UsageHistoryStore.maintenanceRequestedNotification,
            object: nil,
            userInfo: [UsageHistoryStore.maintenanceTriggerUserInfoKey: trigger.rawValue]
        )
    }

    private func store() throws -> UsageHistoryStore {
        guard !storageReplacementInProgress else {
            throw UsageHistoryStoreError.storageMaintenanceInProgress
        }
        if let cachedStore {
            guard cachedStore.databaseURL == nil else {
                return cachedStore
            }

            // An in-memory store is a temporary continuity fallback. Retry the persistent
            // factory on subsequent operations, but keep the same fallback instance until
            // opening the durable database succeeds so transient failures do not lose data
            // repeatedly within one process lifetime.
            do {
                let candidate = try storeFactory()
                if candidate.databaseURL != nil {
                    self.cachedStore = candidate
                    return candidate
                }
            } catch {
                return cachedStore
            }
            return cachedStore
        }

        do {
            let store = try storeFactory()
            if cacheStoreOnOpen {
                cachedStore = store
            }
            return store
        } catch {
            guard let fallbackStoreFactory else {
                throw error
            }
            let fallbackStore = try fallbackStoreFactory()
            cachedStore = fallbackStore
            return fallbackStore
        }
    }

    private func importRecentTokenHistoryIfNeeded(
        store: UsageHistoryStore,
        at date: Date,
        calendar: Calendar,
        force: Bool = false,
        includeDetailedContext: Bool = true
    ) -> CodexLiveTokenCaptureState {
        if let lastRecentTokenImportAt,
           date.timeIntervalSince(lastRecentTokenImportAt) < 30,
           calendar.isDate(lastRecentTokenImportAt, inSameDayAs: date),
           !force
        {
            return (try? store.codexLiveTokenCaptureState()) ?? CodexLiveTokenCaptureState()
        }

        let state = recentTokenHistoryImporter(store, date, calendar, force, includeDetailedContext)
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
