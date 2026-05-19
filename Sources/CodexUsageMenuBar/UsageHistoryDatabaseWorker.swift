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
    let availableBreakdownDimensions: [TokenDashboardBreakdownDimension]
    let historyBounds: UsageHistoryBounds?
}

protocol UsageHistoryDatabaseWorking: Sendable {
    func record(snapshot: CodexUsageSnapshot, at date: Date) async
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals?
    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals?
    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64?
    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult
    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult
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

actor UsageHistoryDatabaseWorker: UsageHistoryDatabaseWorking {
    typealias StoreFactory = @Sendable () throws -> UsageHistoryStore
    typealias RecentTokenHistoryImporter = @Sendable (UsageHistoryStore, Date, Calendar) -> Void

    static let liveRecentTokenHistoryImporter: RecentTokenHistoryImporter = { store, date, calendar in
        store.importRecentTokenHistoryIfAvailable(containing: date, calendar: calendar)
    }

    private let storeFactory: StoreFactory
    private let recentTokenHistoryImporter: RecentTokenHistoryImporter
    private var cachedStore: UsageHistoryStore?
    private var lastRecentTokenImportAt: Date?

    init(
        store: UsageHistoryStore,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = UsageHistoryDatabaseWorker.liveRecentTokenHistoryImporter
    ) {
        self.storeFactory = { store }
        self.recentTokenHistoryImporter = recentTokenHistoryImporter
        self.cachedStore = store
    }

    init(
        storeFactory: @escaping StoreFactory,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = UsageHistoryDatabaseWorker.liveRecentTokenHistoryImporter
    ) {
        self.storeFactory = storeFactory
        self.recentTokenHistoryImporter = recentTokenHistoryImporter
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
            importRecentTokenHistoryIfNeeded(store: store, at: date, calendar: calendar)
            return try store.tokenCategoryTotalsForDay(containing: date, calendar: calendar)
        } catch {
            return nil
        }
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) -> Int64? {
        do {
            let store = try store()
            importRecentTokenHistoryIfNeeded(store: store, at: date, calendar: calendar)
            return try store.tokenTotalForDay(containing: date, calendar: calendar)
        } catch {
            return nil
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
            importRecentTokenHistoryIfNeeded(store: store, at: request.now, calendar: request.calendar)
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
            availableBreakdownDimensions: availableBreakdownDimensions,
            historyBounds: try store.tokenDashboardBounds()
        )
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

    private func importRecentTokenHistoryIfNeeded(store: UsageHistoryStore, at date: Date, calendar: Calendar) {
        if let lastRecentTokenImportAt,
           date.timeIntervalSince(lastRecentTokenImportAt) < 60,
           calendar.isDate(lastRecentTokenImportAt, inSameDayAs: date)
        {
            return
        }

        recentTokenHistoryImporter(store, date, calendar)
        lastRecentTokenImportAt = date
    }
}
