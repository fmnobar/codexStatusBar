@preconcurrency import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum TokenDashboardSeriesKind: String, Equatable {
    case aggregate
    case model
    case effort
    case project
    case dimension
    case unattributed
}

enum TokenDashboardBreakdownDimension: String, CaseIterable, Identifiable, Equatable {
    case model
    case effort
    case project
    case originator
    case sourceKind = "source_kind"
    case threadSource = "thread_source"
    case cliVersion = "cli_version"
    case modelProvider = "model_provider"
    case memoryMode = "memory_mode"
    case approvalPolicy = "approval_policy"
    case sandboxType = "sandbox_type"
    case permissionProfile = "permission_profile"
    case realtimeActive = "realtime_active"
    case truncationPolicy = "truncation_policy"
    case isSubagent = "is_subagent"
    case subagentParentThreadID = "subagent_parent_thread_id"
    case subagentDepth = "subagent_depth"
    case agentRole = "agent_role"
    case agentNickname = "agent_nickname"
    case usageMode = "usage_mode"

    var id: String {
        rawValue
    }

    var displayTitle: String {
        if let dimensionKey {
            return dimensionKey.dashboardDisplayTitle
        }

        switch self {
        case .model:
            return "Model"
        case .effort:
            return "Effort"
        case .project:
            return "Project"
        case .originator,
             .sourceKind,
             .threadSource,
             .cliVersion,
             .modelProvider,
             .memoryMode,
             .approvalPolicy,
             .sandboxType,
             .permissionProfile,
             .realtimeActive,
             .truncationPolicy,
             .isSubagent,
             .subagentParentThreadID,
             .subagentDepth,
             .agentRole,
             .agentNickname,
             .usageMode:
            return rawValue
        }
    }

    var dimensionKey: TokenUsageDimensionKey? {
        TokenUsageDimensionKey(rawValue: rawValue)
    }
}

struct TokenDashboardSeries: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let kind: TokenDashboardSeriesKind
    let contextID: String
    let projectPath: String?
    let dimensionKey: TokenUsageDimensionKey?

    init(
        id: String,
        name: String,
        kind: TokenDashboardSeriesKind,
        contextID: String? = nil,
        projectPath: String? = nil,
        dimensionKey: TokenUsageDimensionKey? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.contextID = contextID ?? id
        self.projectPath = projectPath
        self.dimensionKey = dimensionKey
    }

    static let aggregateID = "tokens_all"
    static let unattributedID = "tokens_unattributed"
}

struct TokenDashboardComponentPoint: Identifiable, Equatable {
    let id: String
    let bucketStart: Date
    let bucketEnd: Date
    let seriesID: String
    let seriesName: String
    let seriesKind: TokenDashboardSeriesKind
    let component: TokenHistoryComponent
    let tokenCount: Int64

    init(
        bucketStart: Date,
        bucketEnd: Date,
        seriesID: String,
        seriesName: String,
        seriesKind: TokenDashboardSeriesKind,
        component: TokenHistoryComponent,
        tokenCount: Int64
    ) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.seriesID = seriesID
        self.seriesName = seriesName
        self.seriesKind = seriesKind
        self.component = component
        self.tokenCount = tokenCount
        id = "\(Int(bucketStart.timeIntervalSince1970))-\(seriesID)-\(component.rawValue)"
    }
}

struct TokenDashboardSummaryTile: Identifiable, Equatable {
    let id: String
    let title: String
    let tokenCount: Int64
    let component: TokenHistoryComponent?
}

struct TokenDashboardBreakdownRow: Identifiable, Equatable {
    let series: TokenDashboardSeries
    let totalsByComponent: [TokenHistoryComponent: Int64]

    var id: String {
        series.id
    }

    var totalTokens: Int64 {
        TokenHistoryComponent.allCases.reduce(Int64(0)) { total, component in
            total + (totalsByComponent[component] ?? 0)
        }
    }
}

struct TokenAttributionCoverageRow: Identifiable, Equatable {
    let id: String
    let title: String
    let attributedTokenCount: Int64
    let missingTokenCount: Int64
    let distinctValueCount: Int
    let dimensionKey: TokenUsageDimensionKey?

    var totalTokenCount: Int64 {
        attributedTokenCount + missingTokenCount
    }

    var attributedPercent: Double {
        guard totalTokenCount > 0 else {
            return 0
        }

        return Double(attributedTokenCount) / Double(totalTokenCount)
    }
}

enum TokenDashboardBreakdownSortColumn: Equatable {
    case title
    case total
    case percent
    case input
    case cached
    case output
    case reasoning

    var defaultAscending: Bool {
        switch self {
        case .title:
            return true
        case .total, .percent, .input, .cached, .output, .reasoning:
            return false
        }
    }
}

enum TokenDashboardAttributionSortColumn: Equatable {
    case dimension
    case attributed
    case missing
    case percent
    case values

    var defaultAscending: Bool {
        switch self {
        case .dimension:
            return true
        case .attributed, .missing, .percent, .values:
            return false
        }
    }
}

struct TokenDashboardSortState<Column: Equatable>: Equatable {
    let column: Column
    let ascending: Bool
}

struct TokenDashboardSnapshotCacheKey: Hashable {
    let breakdownDimension: String
    let range: String
    let periodStart: Date
    let periodEnd: Date
    let calendarIdentifier: Calendar.Identifier
    let timeZoneIdentifier: String

    init(request: TokenDashboardLoadRequest, calendar: Calendar) {
        breakdownDimension = request.breakdownDimension.rawValue
        range = request.range.rawValue
        periodStart = request.periodStart
        periodEnd = UsageHistoryRange.bucketStart(
            for: request.periodEnd,
            component: request.range.chartBucketComponent,
            calendar: calendar
        )
        calendarIdentifier = calendar.identifier
        timeZoneIdentifier = calendar.timeZone.identifier
    }
}

struct TokenDashboardCoverageCacheKey: Hashable {
    let periodStart: Date
    let periodEnd: Date

    init(period: UsageHistoryPeriod) {
        periodStart = period.start
        periodEnd = period.end
    }
}

struct TokenDashboardEmptyState: Equatable {
    let title: String
    let message: String
    let systemImage: String
}

enum TokenDashboardPrimaryLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

struct TokenDashboardLoadingState: Equatable {
    let title: String
    let message: String
    let systemImage: String
}

@MainActor
final class TokenDashboardViewModel: ObservableObject {
    @Published var selectedRange: UsageHistoryRange = .month {
        didSet {
            guard selectedRange != oldValue else {
                return
            }

            selectedPeriodStart = currentPeriod.start
            selectedSeriesIDs = []
            scheduleReload(trigger: .tokenDashboardPeriodChange)
        }
    }

    @Published var selectedBreakdownDimension: TokenDashboardBreakdownDimension = .model {
        didSet {
            guard selectedBreakdownDimension != oldValue else {
                return
            }

            selectedSeriesIDs = []
            breakdownSortState = nil
            scheduleReload(trigger: .tokenDashboardBreakdownChange)
        }
    }

    @Published private(set) var selectedPeriodStart: Date
    @Published private(set) var points: [TokenDashboardComponentPoint] = []
    @Published private(set) var series: [TokenDashboardSeries] = []
    @Published private(set) var attributionCoverageRows: [TokenAttributionCoverageRow] = []
    @Published private(set) var modelCapabilities: [CodexModelCapability] = []
    @Published private(set) var availableBreakdownDimensions: [TokenDashboardBreakdownDimension] = [.model]
    @Published private(set) var selectedSeriesIDs: Set<String> = []
    @Published private(set) var historyBounds: UsageHistoryBounds?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isAttributionCoverageLoading = false
    @Published private(set) var attributionCoverageErrorMessage: String?
    @Published private(set) var breakdownSortState: TokenDashboardSortState<TokenDashboardBreakdownSortColumn>?
    @Published private(set) var attributionSortState: TokenDashboardSortState<TokenDashboardAttributionSortColumn>?
    @Published private(set) var primaryLoadState: TokenDashboardPrimaryLoadState = .idle

    private let database: UsageHistoryDatabaseWorking
    private let performanceInstrumentationStore: AppPerformanceInstrumentationStore?
    private let now: () -> Date
    private let calendar: Calendar
    private let historyChangeDebounceInterval: TimeInterval
    private var reloadTask: Task<Void, Never>?
    private var coverageTask: Task<Void, Never>?
    private var historyChangeReloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var snapshotCache: [TokenDashboardSnapshotCacheKey: TokenDashboardLoadResult] = [:]
    private var snapshotCacheOrder: [TokenDashboardSnapshotCacheKey] = []
    private var coverageCache: [TokenDashboardCoverageCacheKey: [TokenAttributionCoverageRow]] = [:]
    private var coverageCacheOrder: [TokenDashboardCoverageCacheKey] = []
    private var displayedSnapshotCacheKey: TokenDashboardSnapshotCacheKey?
    private let snapshotCacheLimit = 24
    private let coverageCacheLimit = 24
    private var nextReloadInstrumentationKind: AppPerformanceEventKind = .tokenDashboardReload

    init(
        database: UsageHistoryDatabaseWorking,
        performanceInstrumentationStore: AppPerformanceInstrumentationStore? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        historyChangeDebounceInterval: TimeInterval = 0.3,
        automaticallyReload: Bool = true
    ) {
        self.database = database
        self.performanceInstrumentationStore = performanceInstrumentationStore
        self.now = now
        self.calendar = calendar
        self.historyChangeDebounceInterval = historyChangeDebounceInterval
        selectedPeriodStart = UsageHistoryRange.month.period(containing: now(), calendar: calendar).start
        if automaticallyReload {
            scheduleReload()
        }
    }

    convenience init(
        store: UsageHistoryStore,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        recentTokenHistoryImporter: @escaping UsageHistoryDatabaseWorker.RecentTokenHistoryImporter = { _, _, _, _ in CodexLiveTokenCaptureState(status: .noNewEvents) }
    ) {
        self.init(
            database: UsageHistoryDatabaseWorker(
                store: store,
                recentTokenHistoryImporter: recentTokenHistoryImporter
            ),
            performanceInstrumentationStore: nil,
            now: now,
            calendar: calendar
        )
    }

    deinit {
        reloadTask?.cancel()
        coverageTask?.cancel()
        historyChangeReloadTask?.cancel()
    }

    var selectedPeriod: UsageHistoryPeriod {
        period(startingAt: selectedPeriodStart)
    }

    var currentPeriod: UsageHistoryPeriod {
        selectedRange.period(containing: now(), calendar: calendar)
    }

    var isCurrentPeriod: Bool {
        selectedPeriod.start == currentPeriod.start
    }

    var canGoToPreviousPeriod: Bool {
        guard let historyBounds else {
            return false
        }

        return historyBounds.earliest < selectedPeriod.start
    }

    var canGoToNextPeriod: Bool {
        !isCurrentPeriod
    }

    var canJumpToCurrentPeriod: Bool {
        !isCurrentPeriod
    }

    var periodTitle: String {
        Self.periodTitle(for: selectedRange, period: selectedPeriod, calendar: calendar)
    }

    var periodDisplayNoun: String {
        selectedRange.displayTitle.lowercased()
    }

    var previousPeriodHelpText: String {
        canGoToPreviousPeriod ? "Show previous \(periodDisplayNoun)" : "No earlier token history"
    }

    var nextPeriodHelpText: String {
        canGoToNextPeriod ? "Show next \(periodDisplayNoun)" : "Already showing the current \(periodDisplayNoun)"
    }

    var currentPeriodHelpText: String {
        canJumpToCurrentPeriod ? "Jump to current \(periodDisplayNoun)" : "Already showing the current \(periodDisplayNoun)"
    }

    var hasTokenData: Bool {
        !series.isEmpty
    }

    var selectedSeries: [TokenDashboardSeries] {
        series.filter { selectedSeriesIDs.contains($0.id) }
    }

    var visibleSourcePoints: [TokenDashboardComponentPoint] {
        if selectedSeriesIDs.contains(TokenDashboardSeries.aggregateID) {
            return points.filter { $0.seriesID == TokenDashboardSeries.aggregateID }
        }

        return points.filter { selectedSeriesIDs.contains($0.seriesID) }
    }

    var chartPoints: [TokenDashboardComponentPoint] {
        var grouped = [String: TokenDashboardComponentPointAccumulator]()

        for point in visibleSourcePoints {
            let key = "\(Int(point.bucketStart.timeIntervalSince1970))-\(point.component.rawValue)"
            var accumulator = grouped[key] ?? TokenDashboardComponentPointAccumulator(
                bucketStart: point.bucketStart,
                bucketEnd: point.bucketEnd,
                component: point.component
            )
            accumulator.tokenCount += point.tokenCount
            grouped[key] = accumulator
        }

        return grouped.values
            .map { accumulator in
                TokenDashboardComponentPoint(
                    bucketStart: accumulator.bucketStart,
                    bucketEnd: accumulator.bucketEnd,
                    seriesID: "visible",
                    seriesName: "Visible",
                    seriesKind: .aggregate,
                    component: accumulator.component,
                    tokenCount: accumulator.tokenCount
                )
            }
            .sortedByDashboardDisplayOrder()
    }

    var hasVisiblePoints: Bool {
        !chartPoints.isEmpty
    }

    var canExportCSV: Bool {
        isDisplayingCurrentSnapshot
            && hasVisiblePoints
            && !isAttributionCoverageLoading
            && attributionCoverageErrorMessage == nil
            && errorMessage == nil
    }

    var isDisplayingCurrentSnapshot: Bool {
        displayedSnapshotCacheKey == currentSnapshotCacheKey()
    }

    var shouldShowPrimaryLoadingState: Bool {
        primaryLoadState == .loading && !isDisplayingCurrentSnapshot
    }

    var isRefreshingCurrentSnapshot: Bool {
        primaryLoadState == .loading && isDisplayingCurrentSnapshot
    }

    var shouldShowTokenContent: Bool {
        isDisplayingCurrentSnapshot && hasVisiblePoints
    }

    var loadingState: TokenDashboardLoadingState {
        TokenDashboardLoadingState(
            title: "Loading token dashboard",
            message: "Reading local captured token samples for \(periodTitle).",
            systemImage: "chart.bar.doc.horizontal"
        )
    }

    var summaryTiles: [TokenDashboardSummaryTile] {
        let totals = componentTotals(from: chartPoints)
        let total = TokenHistoryComponent.allCases.reduce(Int64(0)) { partial, component in
            partial + (totals[component] ?? 0)
        }

        return [
            TokenDashboardSummaryTile(id: "total", title: "Local captured", tokenCount: total, component: nil),
            TokenDashboardSummaryTile(id: TokenHistoryComponent.input.rawValue, title: "Input", tokenCount: totals[.input] ?? 0, component: .input),
            TokenDashboardSummaryTile(id: TokenHistoryComponent.cached.rawValue, title: "Cache", tokenCount: totals[.cached] ?? 0, component: .cached),
            TokenDashboardSummaryTile(id: TokenHistoryComponent.output.rawValue, title: "Output", tokenCount: totals[.output] ?? 0, component: .output),
            TokenDashboardSummaryTile(id: TokenHistoryComponent.reasoning.rawValue, title: "Reasoning", tokenCount: totals[.reasoning] ?? 0, component: .reasoning),
        ]
    }

    var breakdownRows: [TokenDashboardBreakdownRow] {
        sortedBreakdownRows(unsortedBreakdownRows)
    }

    private var unsortedBreakdownRows: [TokenDashboardBreakdownRow] {
        let grouped = Dictionary(grouping: points, by: \.seriesID)
        return series.compactMap { series in
            let totals = componentTotals(from: grouped[series.id] ?? [])
            let row = TokenDashboardBreakdownRow(series: series, totalsByComponent: totals)
            return row.totalTokens > 0 ? row : nil
        }
    }

    var breakdownTotalForPercent: Int64 {
        if let aggregate = unsortedBreakdownRows.first(where: { $0.series.id == TokenDashboardSeries.aggregateID }) {
            return aggregate.totalTokens
        }

        return unsortedBreakdownRows.reduce(Int64(0)) { partial, row in
            row.series.kind == .unattributed ? partial : partial + row.totalTokens
        }
    }

    var sortedAttributionCoverageRows: [TokenAttributionCoverageRow] {
        sortedAttributionCoverageRows(attributionCoverageRows)
    }

    var emptyState: TokenDashboardEmptyState {
        if !hasTokenData {
            return TokenDashboardEmptyState(
                title: "No token data yet",
                message: "Import recent sessions or use Codex to start capturing token history.",
                systemImage: "chart.bar.doc.horizontal"
            )
        }

        return TokenDashboardEmptyState(
            title: "No tokens for this selection",
            message: "Choose a different period or breakdown row.",
            systemImage: "line.3.horizontal.decrease.circle"
        )
    }

    var chartYDomain: ClosedRange<Double> {
        let maximum = chartPoints
            .reduce(into: [Date: Double]()) { partial, point in
                partial[point.bucketStart, default: 0] += Double(point.tokenCount)
            }
            .values
            .max() ?? 0

        return 0...Self.tokenAxisUpperBound(for: maximum)
    }

    var chartDomainStart: Date {
        selectedPeriod.start.addingTimeInterval(-chartDomainBucketPadding)
    }

    var chartDomainEnd: Date {
        selectedPeriod.end.addingTimeInterval(chartDomainBucketPadding)
    }

    var chartXAxisLabelValues: [Date] {
        chartXAxisLabelBucketStarts().map(chartXPosition(forBucketStart:))
    }

    var exportFilename: String {
        [
            "codex-token-dashboard",
            selectedRange.rawValue,
            periodFilenameToken,
        ].joined(separator: "-") + ".csv"
    }

    var csvText: String {
        var rows = ["breakdown_dimension,range,period_start,period_end,bucket_start,bucket_end,series_id,series_name,series_kind,context_id,context_name,project_path,component,token_count,dimension_key"]
        let formatter = ISO8601DateFormatter()
        let seriesByID = Dictionary(uniqueKeysWithValues: series.map { ($0.id, $0) })

        rows += visibleSourcePoints.sortedByDashboardDisplayOrder().map { point in
            let pointSeries = seriesByID[point.seriesID]
            let contextID = pointSeries?.contextID ?? point.seriesID
            let contextName = pointSeries?.name ?? point.seriesName
            let projectPath = pointSeries?.projectPath ?? ""
            let dimensionKey = pointSeries?.dimensionKey?.rawValue ?? selectedBreakdownDimension.dimensionKey?.rawValue ?? ""
            return [
                selectedBreakdownDimension.rawValue,
                selectedRange.rawValue,
                formatter.string(from: selectedPeriod.start),
                formatter.string(from: selectedPeriod.end),
                formatter.string(from: point.bucketStart),
                formatter.string(from: point.bucketEnd),
                Self.csvEscaped(point.seriesID),
                Self.csvEscaped(contextName),
                point.seriesKind.rawValue,
                Self.csvEscaped(contextID),
                Self.csvEscaped(contextName),
                Self.csvEscaped(projectPath),
                point.component.rawValue,
                "\(point.tokenCount)",
                dimensionKey,
            ].joined(separator: ",")
        }

        if !sortedAttributionCoverageRows.isEmpty {
            rows.append("")
            rows.append("coverage_dimension,dimension_title,attributed_tokens,missing_tokens,total_tokens,attributed_percent,distinct_values,dimension_key")
            rows += sortedAttributionCoverageRows.map { row in
                [
                    row.id,
                    Self.csvEscaped(row.title),
                    "\(row.attributedTokenCount)",
                    "\(row.missingTokenCount)",
                    "\(row.totalTokenCount)",
                    String(format: "%.4f", row.attributedPercent),
                    "\(row.distinctValueCount)",
                    row.dimensionKey?.rawValue ?? "",
                ].joined(separator: ",")
            }
        }

        return rows.joined(separator: "\n") + "\n"
    }

    private var periodFilenameToken: String {
        Self.periodFilenameToken(for: selectedRange, periodStart: selectedPeriod.start, calendar: calendar)
    }

    private var chartDomainBucketPadding: TimeInterval {
        let reference = selectedPeriod.start
        let next = calendar.date(byAdding: selectedRange.chartBucketComponent, value: 1, to: reference)
            ?? reference.addingTimeInterval(3600)
        return max(next.timeIntervalSince(reference) / 2, 1)
    }

    @discardableResult
    func reload() async -> Bool {
        cancelPendingHistoryChangeReload(invalidateCaches: true)
        reloadTask?.cancel()
        reloadTask = nil
        return await performReload()
    }

    @discardableResult
    private func performReload() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }

        let generation = nextReloadGeneration()
        coverageTask?.cancel()
        coverageTask = nil
        let queryPeriod = periodForQuery()
        let request = TokenDashboardLoadRequest(
            breakdownDimension: selectedBreakdownDimension,
            range: selectedRange,
            periodStart: queryPeriod.start,
            periodEnd: queryPeriod.end,
            includeAttributionCoverage: false
        )
        let cacheKey = TokenDashboardSnapshotCacheKey(request: request, calendar: calendar)
        let coverageKey = TokenDashboardCoverageCacheKey(period: queryPeriod)
        let instrumentationKind = nextReloadInstrumentationKind
        nextReloadInstrumentationKind = .tokenDashboardReload
        let instrumentationSpan = performanceInstrumentationStore?.begin(
            instrumentationKind,
            metadata: dashboardInstrumentationMetadata(cacheHit: false, phase: "primary")
        )

        if let cachedResult = cachedSnapshot(for: cacheKey) {
            let applied = applyLoadResult(cachedResult, updateCoverageRows: false)
            displayedSnapshotCacheKey = applied ? cacheKey : nil
            primaryLoadState = applied ? .loaded : (selectedBreakdownDimension == request.breakdownDimension ? .loaded : .loading)
            if applied {
                prepareAttributionCoverageLoad(
                    coverageKey: coverageKey,
                    queryPeriod: queryPeriod,
                    generation: generation,
                    instrumentationKind: instrumentationKind
                )
            }
            performanceInstrumentationStore?.finish(
                instrumentationSpan,
                status: applied && hasTokenData ? .success : .noData,
                metadata: instrumentationResultMetadata(result: cachedResult, cacheHit: true, phase: "primary")
            )
            return applied
        }

        primaryLoadState = .loading
        do {
            let result = try await database.tokenDashboardSnapshot(for: request)
            guard generation == reloadGeneration, !Task.isCancelled else {
                return false
            }

            cacheSnapshot(result, for: cacheKey)
            let applied = applyLoadResult(result, updateCoverageRows: false)
            displayedSnapshotCacheKey = applied ? cacheKey : nil
            primaryLoadState = applied ? .loaded : (selectedBreakdownDimension == request.breakdownDimension ? .loaded : .loading)
            if applied {
                prepareAttributionCoverageLoad(
                    coverageKey: coverageKey,
                    queryPeriod: queryPeriod,
                    generation: generation,
                    instrumentationKind: instrumentationKind
                )
            }
            performanceInstrumentationStore?.finish(
                instrumentationSpan,
                status: applied && hasTokenData ? .success : .noData,
                metadata: instrumentationResultMetadata(result: result, cacheHit: false, phase: "primary")
            )
            return applied
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else {
                return false
            }

            points = []
            series = []
            attributionCoverageRows = []
            modelCapabilities = []
            isAttributionCoverageLoading = false
            attributionCoverageErrorMessage = nil
            coverageTask?.cancel()
            coverageTask = nil
            availableBreakdownDimensions = [.model]
            historyBounds = nil
            selectedSeriesIDs = []
            errorMessage = "Token dashboard could not be loaded."
            displayedSnapshotCacheKey = nil
            primaryLoadState = .failed
            performanceInstrumentationStore?.finish(instrumentationSpan, status: .failed)
            return false
        }
    }

    func invalidateSnapshotCache() {
        snapshotCache.removeAll()
        snapshotCacheOrder.removeAll()
    }

    func invalidateCoverageCache() {
        coverageCache.removeAll()
        coverageCacheOrder.removeAll()
    }

    func invalidateSnapshotCacheAndReload() {
        invalidateSnapshotCache()
        invalidateCoverageCache()
        scheduleReload(trigger: .tokenDashboardPeriodChange)
    }

    func scheduleReload(trigger: AppPerformanceEventKind = .tokenDashboardReload) {
        cancelPendingHistoryChangeReload(invalidateCaches: true)
        nextReloadInstrumentationKind = trigger
        markLoadingIfCacheMiss()
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.performReload()
        }
    }

    func scheduleHistoryChangeReload() {
        historyChangeReloadTask?.cancel()
        historyChangeReloadTask = Task { [weak self, historyChangeDebounceInterval] in
            if historyChangeDebounceInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64((historyChangeDebounceInterval * 1_000_000_000).rounded()))
            }
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                self.historyChangeReloadTask = nil
                self.invalidateSnapshotCache()
                self.invalidateCoverageCache()
                self.scheduleReload(trigger: .tokenDashboardPeriodChange)
            }
        }
    }

    private func cancelPendingHistoryChangeReload(invalidateCaches: Bool) {
        guard historyChangeReloadTask != nil else {
            return
        }

        historyChangeReloadTask?.cancel()
        historyChangeReloadTask = nil
        if invalidateCaches {
            invalidateSnapshotCache()
            invalidateCoverageCache()
        }
    }

    private func nextReloadGeneration() -> Int {
        reloadGeneration += 1
        return reloadGeneration
    }

    private func currentSnapshotCacheKey() -> TokenDashboardSnapshotCacheKey {
        let queryPeriod = periodForQuery()
        let request = TokenDashboardLoadRequest(
            breakdownDimension: selectedBreakdownDimension,
            range: selectedRange,
            periodStart: queryPeriod.start,
            periodEnd: queryPeriod.end,
            includeAttributionCoverage: false
        )
        return TokenDashboardSnapshotCacheKey(request: request, calendar: calendar)
    }

    private func markLoadingIfCacheMiss() {
        if snapshotCache[currentSnapshotCacheKey()] == nil {
            primaryLoadState = .loading
        }
    }

    var snapshotCacheEntryCount: Int {
        snapshotCache.count
    }

    var coverageCacheEntryCount: Int {
        coverageCache.count
    }

    private func cachedSnapshot(for key: TokenDashboardSnapshotCacheKey) -> TokenDashboardLoadResult? {
        guard let result = snapshotCache[key] else {
            return nil
        }

        markSnapshotCacheKeyRecentlyUsed(key)
        return result
    }

    private func cacheSnapshot(_ result: TokenDashboardLoadResult, for key: TokenDashboardSnapshotCacheKey) {
        snapshotCache[key] = result
        markSnapshotCacheKeyRecentlyUsed(key)

        while snapshotCacheOrder.count > snapshotCacheLimit {
            let removedKey = snapshotCacheOrder.removeFirst()
            snapshotCache.removeValue(forKey: removedKey)
        }
    }

    private func markSnapshotCacheKeyRecentlyUsed(_ key: TokenDashboardSnapshotCacheKey) {
        snapshotCacheOrder.removeAll { $0 == key }
        snapshotCacheOrder.append(key)
    }

    @discardableResult
    private func applyLoadResult(_ result: TokenDashboardLoadResult, updateCoverageRows: Bool) -> Bool {
        availableBreakdownDimensions = result.availableBreakdownDimensions
        guard result.availableBreakdownDimensions.contains(selectedBreakdownDimension) else {
            points = []
            series = []
            attributionCoverageRows = []
            modelCapabilities = []
            isAttributionCoverageLoading = false
            attributionCoverageErrorMessage = nil
            historyBounds = result.historyBounds
            selectedSeriesIDs = []
            errorMessage = nil
            if selectedBreakdownDimension != .model {
                selectedBreakdownDimension = .model
            }
            return false
        }

        points = result.points
        series = result.series
        modelCapabilities = result.modelCapabilities
        if updateCoverageRows {
            attributionCoverageRows = result.attributionCoverageRows
        }
        historyBounds = result.historyBounds
        reconcileSelection()
        errorMessage = nil
        return true
    }

    private func prepareAttributionCoverageLoad(
        coverageKey: TokenDashboardCoverageCacheKey,
        queryPeriod: UsageHistoryPeriod,
        generation: Int,
        instrumentationKind: AppPerformanceEventKind
    ) {
        coverageTask?.cancel()
        coverageTask = nil
        attributionCoverageErrorMessage = nil

        if let cachedRows = cachedAttributionCoverage(for: coverageKey) {
            attributionCoverageRows = cachedRows
            isAttributionCoverageLoading = false
            performanceInstrumentationStore?.record(
                kind: instrumentationKind,
                durationMilliseconds: 0,
                metadata: coverageInstrumentationMetadata(
                    cacheHit: true,
                    rowCount: cachedRows.count,
                    coverageMilliseconds: 0
                )
            )
            return
        }

        attributionCoverageRows = []
        isAttributionCoverageLoading = true
        coverageTask = Task { [weak self] in
            await self?.loadAttributionCoverage(
                coverageKey: coverageKey,
                queryPeriod: queryPeriod,
                generation: generation,
                instrumentationKind: instrumentationKind
            )
        }
    }

    private func loadAttributionCoverage(
        coverageKey: TokenDashboardCoverageCacheKey,
        queryPeriod: UsageHistoryPeriod,
        generation: Int,
        instrumentationKind: AppPerformanceEventKind
    ) async {
        let span = performanceInstrumentationStore?.begin(
            instrumentationKind,
            metadata: dashboardInstrumentationMetadata(cacheHit: false, phase: "coverage")
        )
        let startedAt = Date()

        do {
            let rows = try await database.tokenAttributionCoverageRows(
                periodStart: queryPeriod.start,
                periodEnd: queryPeriod.end
            )
            let coverageMilliseconds = Date().timeIntervalSince(startedAt) * 1_000
            guard generation == reloadGeneration, !Task.isCancelled else {
                performanceInstrumentationStore?.finish(
                    span,
                    status: .cancelled,
                    metadata: coverageInstrumentationMetadata(
                        cacheHit: false,
                        rowCount: rows.count,
                        coverageMilliseconds: coverageMilliseconds
                    )
                )
                return
            }

            cacheAttributionCoverage(rows, for: coverageKey)
            attributionCoverageRows = rows
            isAttributionCoverageLoading = false
            attributionCoverageErrorMessage = nil
            performanceInstrumentationStore?.finish(
                span,
                status: rows.isEmpty ? .noData : .success,
                metadata: coverageInstrumentationMetadata(
                    cacheHit: false,
                    rowCount: rows.count,
                    coverageMilliseconds: coverageMilliseconds
                )
            )
        } catch {
            let coverageMilliseconds = Date().timeIntervalSince(startedAt) * 1_000
            guard generation == reloadGeneration, !Task.isCancelled else {
                performanceInstrumentationStore?.finish(
                    span,
                    status: .cancelled,
                    metadata: coverageInstrumentationMetadata(
                        cacheHit: false,
                        rowCount: 0,
                        coverageMilliseconds: coverageMilliseconds
                    )
                )
                return
            }

            attributionCoverageRows = []
            isAttributionCoverageLoading = false
            attributionCoverageErrorMessage = "Attribution coverage could not be loaded."
            performanceInstrumentationStore?.finish(
                span,
                status: .failed,
                metadata: coverageInstrumentationMetadata(
                    cacheHit: false,
                    rowCount: 0,
                    coverageMilliseconds: coverageMilliseconds
                )
            )
        }
    }

    func waitForAttributionCoverageLoad() async {
        await coverageTask?.value
    }

    private func cachedAttributionCoverage(for key: TokenDashboardCoverageCacheKey) -> [TokenAttributionCoverageRow]? {
        guard let rows = coverageCache[key] else {
            return nil
        }

        markCoverageCacheKeyRecentlyUsed(key)
        return rows
    }

    private func cacheAttributionCoverage(
        _ rows: [TokenAttributionCoverageRow],
        for key: TokenDashboardCoverageCacheKey
    ) {
        coverageCache[key] = rows
        markCoverageCacheKeyRecentlyUsed(key)

        while coverageCacheOrder.count > coverageCacheLimit {
            let removedKey = coverageCacheOrder.removeFirst()
            coverageCache.removeValue(forKey: removedKey)
        }
    }

    private func markCoverageCacheKeyRecentlyUsed(_ key: TokenDashboardCoverageCacheKey) {
        coverageCacheOrder.removeAll { $0 == key }
        coverageCacheOrder.append(key)
    }

    func goToPreviousPeriod() {
        guard canGoToPreviousPeriod,
              let previous = calendar.date(byAdding: selectedRange.periodComponent, value: -1, to: selectedPeriod.start)
        else {
            return
        }

        selectedPeriodStart = previous
        scheduleReload(trigger: .tokenDashboardPeriodChange)
    }

    func goToNextPeriod() {
        guard canGoToNextPeriod,
              let next = calendar.date(byAdding: selectedRange.periodComponent, value: 1, to: selectedPeriod.start)
        else {
            return
        }

        selectedPeriodStart = min(next, currentPeriod.start)
        scheduleReload(trigger: .tokenDashboardPeriodChange)
    }

    func jumpToCurrentPeriod() {
        guard canJumpToCurrentPeriod else {
            return
        }

        selectedPeriodStart = currentPeriod.start
        scheduleReload(trigger: .tokenDashboardPeriodChange)
    }

    func selectSeries(_ id: String) {
        guard series.contains(where: { $0.id == id }) else {
            return
        }

        if id == TokenDashboardSeries.aggregateID {
            selectedSeriesIDs = [TokenDashboardSeries.aggregateID]
            return
        }

        var updated = selectedSeriesIDs
        updated.remove(TokenDashboardSeries.aggregateID)

        if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }

        selectedSeriesIDs = updated.isEmpty ? [TokenDashboardSeries.aggregateID] : updated
    }

    func isSelected(_ series: TokenDashboardSeries) -> Bool {
        selectedSeriesIDs.contains(series.id)
    }

    func exportCSV() {
        guard canExportCSV else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = exportFilename

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try csvText.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "Token dashboard could not be exported."
        }
    }

    func chartXPosition(for point: TokenDashboardComponentPoint) -> Date {
        chartXPosition(forBucketStart: point.bucketStart)
    }

    func chartXAxisLabel(for date: Date) -> String {
        let bucketStart = UsageHistoryRange.bucketStart(
            for: date.addingTimeInterval(-chartDomainBucketPadding / 2),
            component: selectedRange.chartBucketComponent,
            calendar: calendar
        )
        return Self.chartXAxisLabel(for: bucketStart, range: selectedRange, calendar: calendar)
    }

    func formattedTokenValue(_ tokenCount: Int64) -> String {
        Self.compactTokenNumber(Double(tokenCount))
    }

    func formattedYAxisValue(_ value: Double) -> String {
        Self.compactTokenAxisText(value)
    }

    func formattedPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    func breakdownPercentOfTotal(for row: TokenDashboardBreakdownRow) -> Double {
        guard breakdownTotalForPercent > 0 else {
            return 0
        }

        return Double(row.totalTokens) / Double(breakdownTotalForPercent)
    }

    func sortBreakdownRows(by column: TokenDashboardBreakdownSortColumn) {
        breakdownSortState = nextSortState(current: breakdownSortState, column: column)
    }

    func sortAttributionCoverageRows(by column: TokenDashboardAttributionSortColumn) {
        attributionSortState = nextSortState(current: attributionSortState, column: column)
    }

    func breakdownSortIndicator(for column: TokenDashboardBreakdownSortColumn) -> String? {
        sortIndicator(for: breakdownSortState, column: column)
    }

    func attributionSortIndicator(for column: TokenDashboardAttributionSortColumn) -> String? {
        sortIndicator(for: attributionSortState, column: column)
    }

    func color(for component: TokenHistoryComponent?) -> Color {
        switch component {
        case .input:
            return .blue
        case .cached:
            return .green
        case .output:
            return .orange
        case .reasoning:
            return .purple
        case nil:
            return .secondary
        }
    }

    private func dashboardInstrumentationMetadata(cacheHit: Bool, phase: String) -> [String: String] {
        [
            "dashboard": "token",
            "range": selectedRange.rawValue,
            "breakdown": selectedBreakdownDimension.displayTitle,
            "cacheHit": cacheHit ? "true" : "false",
            "phase": phase,
        ]
    }

    private func instrumentationResultMetadata(
        result: TokenDashboardLoadResult,
        cacheHit: Bool,
        phase: String
    ) -> [String: String] {
        var metadata = dashboardInstrumentationMetadata(cacheHit: cacheHit, phase: phase)
        metadata["pointCount"] = "\(points.count)"
        metadata["rowCount"] = "\(series.count)"
        metadata["seriesCount"] = "\(series.count)"
        metadata["coverageRowCount"] = "\(attributionCoverageRows.count)"
        for (key, value) in result.queryTimings.metadata() {
            metadata[key] = value
        }
        return metadata
    }

    private func coverageInstrumentationMetadata(
        cacheHit: Bool,
        rowCount: Int,
        coverageMilliseconds: Double
    ) -> [String: String] {
        var metadata = dashboardInstrumentationMetadata(cacheHit: cacheHit, phase: "coverage")
        metadata["coverageRowCount"] = "\(rowCount)"
        metadata["coverageMs"] = String(format: "%.1f", max(coverageMilliseconds, 0))
        return metadata
    }

    func compactSeriesTitle(_ name: String) -> String {
        if name == "All captured" {
            return "All"
        }

        let lowercased = name.lowercased()
        if lowercased.contains("spark") {
            return "Spark"
        }

        if let range = name.range(
            of: #"(?i)^gpt-([0-9]+(?:\.[0-9]+)*)(?:[-_ ](.+))?$"#,
            options: .regularExpression
        ) {
            let matched = String(name[range])
            let withoutPrefix = matched.replacingOccurrences(
                of: #"(?i)^gpt-"#,
                with: "",
                options: .regularExpression
            )
            let parts = withoutPrefix.split(separator: "-", omittingEmptySubsequences: true)
            guard let version = parts.first else {
                return withoutPrefix
            }

            let suffix = parts
                .dropFirst()
                .filter { $0.localizedCaseInsensitiveCompare("codex") != .orderedSame }
                .map { Self.compactModelSuffixTitle(String($0)) }

            guard !suffix.isEmpty else {
                return String(version)
            }

            return ([String(version)] + suffix).joined(separator: " ")
        }

        return name
    }

    func modelCapabilityAnnotation(for series: TokenDashboardSeries) -> DashboardModelCapabilityAnnotation? {
        guard selectedBreakdownDimension == .model,
              series.kind == .model
        else {
            return nil
        }

        return DashboardModelCapabilityAnnotation.annotation(
            forModelValue: series.contextID,
            capabilities: modelCapabilities
        )
    }

    var breakdownColumnTitle: String {
        selectedBreakdownDimension.displayTitle
    }

    private func reconcileSelection() {
        let availableIDs = Set(series.map(\.id))
        let retained = selectedSeriesIDs.intersection(availableIDs)

        if retained.isEmpty, availableIDs.contains(TokenDashboardSeries.aggregateID) {
            selectedSeriesIDs = [TokenDashboardSeries.aggregateID]
        } else {
            selectedSeriesIDs = retained
        }
    }

    private func nextSortState(
        current: TokenDashboardSortState<TokenDashboardBreakdownSortColumn>?,
        column: TokenDashboardBreakdownSortColumn
    ) -> TokenDashboardSortState<TokenDashboardBreakdownSortColumn> {
        if let current, current.column == column {
            return TokenDashboardSortState(column: column, ascending: !current.ascending)
        }

        return TokenDashboardSortState(column: column, ascending: column.defaultAscending)
    }

    private func nextSortState(
        current: TokenDashboardSortState<TokenDashboardAttributionSortColumn>?,
        column: TokenDashboardAttributionSortColumn
    ) -> TokenDashboardSortState<TokenDashboardAttributionSortColumn> {
        if let current, current.column == column {
            return TokenDashboardSortState(column: column, ascending: !current.ascending)
        }

        return TokenDashboardSortState(column: column, ascending: column.defaultAscending)
    }

    private func sortIndicator<Column: Equatable>(
        for state: TokenDashboardSortState<Column>?,
        column: Column
    ) -> String? {
        guard let state, state.column == column else {
            return nil
        }

        return state.ascending ? "chevron.up" : "chevron.down"
    }

    private func sortedBreakdownRows(_ rows: [TokenDashboardBreakdownRow]) -> [TokenDashboardBreakdownRow] {
        guard let sortState = breakdownSortState else {
            return rows
        }

        return rows.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortState.column {
            case .title:
                comparison = lhs.series.name.localizedStandardCompare(rhs.series.name)
            case .total:
                comparison = compare(lhs.totalTokens, rhs.totalTokens)
            case .percent:
                comparison = compare(breakdownPercentOfTotal(for: lhs), breakdownPercentOfTotal(for: rhs))
            case .input:
                comparison = compare(lhs.totalsByComponent[.input] ?? 0, rhs.totalsByComponent[.input] ?? 0)
            case .cached:
                comparison = compare(lhs.totalsByComponent[.cached] ?? 0, rhs.totalsByComponent[.cached] ?? 0)
            case .output:
                comparison = compare(lhs.totalsByComponent[.output] ?? 0, rhs.totalsByComponent[.output] ?? 0)
            case .reasoning:
                comparison = compare(lhs.totalsByComponent[.reasoning] ?? 0, rhs.totalsByComponent[.reasoning] ?? 0)
            }

            return orderedBefore(lhsID: lhs.id, rhsID: rhs.id, comparison: comparison, ascending: sortState.ascending)
        }
    }

    private func sortedAttributionCoverageRows(_ rows: [TokenAttributionCoverageRow]) -> [TokenAttributionCoverageRow] {
        guard let sortState = attributionSortState else {
            return rows
        }

        return rows.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortState.column {
            case .dimension:
                comparison = lhs.title.localizedStandardCompare(rhs.title)
            case .attributed:
                comparison = compare(lhs.attributedTokenCount, rhs.attributedTokenCount)
            case .missing:
                comparison = compare(lhs.missingTokenCount, rhs.missingTokenCount)
            case .percent:
                comparison = compare(lhs.attributedPercent, rhs.attributedPercent)
            case .values:
                comparison = compare(lhs.distinctValueCount, rhs.distinctValueCount)
            }

            return orderedBefore(lhsID: lhs.id, rhsID: rhs.id, comparison: comparison, ascending: sortState.ascending)
        }
    }

    private func orderedBefore(
        lhsID: String,
        rhsID: String,
        comparison: ComparisonResult,
        ascending: Bool
    ) -> Bool {
        if comparison == .orderedSame {
            return lhsID.localizedStandardCompare(rhsID) == .orderedAscending
        }

        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }

    private func periodForQuery() -> UsageHistoryPeriod {
        let period = selectedPeriod
        let currentDate = now()
        if period.end > currentDate {
            return UsageHistoryPeriod(start: period.start, end: currentDate)
        }

        return period
    }

    private func period(startingAt start: Date) -> UsageHistoryPeriod {
        if let interval = calendar.dateInterval(of: selectedRange.periodComponent, for: start) {
            return UsageHistoryPeriod(start: interval.start, end: interval.end)
        }

        let end = calendar.date(byAdding: selectedRange.periodComponent, value: 1, to: start) ?? start
        return UsageHistoryPeriod(start: start, end: end)
    }

    private func chartXPosition(forBucketStart bucketStart: Date) -> Date {
        let bucketEnd = calendar.date(byAdding: selectedRange.chartBucketComponent, value: 1, to: bucketStart)
            ?? bucketStart.addingTimeInterval(chartDomainBucketPadding * 2)
        return bucketStart.addingTimeInterval(bucketEnd.timeIntervalSince(bucketStart) / 2)
    }

    private func chartXAxisLabelBucketStarts() -> [Date] {
        switch selectedRange {
        case .day:
            return bucketStarts(step: 4, component: .hour)
        case .week:
            return bucketStarts(step: 1, component: .day)
        case .month:
            return bucketStarts(step: 5, component: .day)
        case .year:
            return bucketStarts(step: 1, component: .month)
        }
    }

    private func bucketStarts(step: Int, component: Calendar.Component) -> [Date] {
        var values: [Date] = []
        var cursor = selectedPeriod.start

        while cursor < selectedPeriod.end {
            values.append(cursor)
            guard let next = calendar.date(byAdding: component, value: step, to: cursor), next > cursor else {
                break
            }
            cursor = next
        }

        return values
    }

    private func componentTotals(from points: [TokenDashboardComponentPoint]) -> [TokenHistoryComponent: Int64] {
        points.reduce(into: [:]) { partial, point in
            partial[point.component, default: 0] += point.tokenCount
        }
    }

    private static func periodTitle(
        for range: UsageHistoryRange,
        period: UsageHistoryPeriod,
        calendar: Calendar
    ) -> String {
        switch range {
        case .day:
            return formattedDate(period.start, template: "MMM d", calendar: calendar)
        case .week:
            let end = calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.end
            return "\(formattedDate(period.start, template: "MMM d", calendar: calendar))-\(formattedDate(end, template: "MMM d", calendar: calendar))"
        case .month:
            return formattedDate(period.start, template: "MMM yyyy", calendar: calendar)
        case .year:
            return formattedDate(period.start, template: "yyyy", calendar: calendar)
        }
    }

    private static func chartXAxisLabel(
        for date: Date,
        range: UsageHistoryRange,
        calendar: Calendar
    ) -> String {
        switch range {
        case .day:
            return formattedDate(date, template: "ha", calendar: calendar).replacingOccurrences(of: " ", with: "")
        case .week:
            return formattedDate(date, template: "EEE", calendar: calendar)
        case .month:
            return formattedDate(date, template: "d", calendar: calendar)
        case .year:
            return formattedDate(date, template: "MMM", calendar: calendar)
        }
    }

    private static func formattedDate(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func periodFilenameToken(
        for range: UsageHistoryRange,
        periodStart: Date,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = {
            switch range {
            case .day, .week:
                return "yyyy-MM-dd"
            case .month:
                return "yyyy-MM"
            case .year:
                return "yyyy"
            }
        }()
        return formatter.string(from: periodStart)
    }

    private static func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        return value
    }

    private static func compactModelSuffixTitle(_ value: String) -> String {
        guard let first = value.first else {
            return value
        }

        return first.uppercased() + value.dropFirst().lowercased()
    }

    private static func compactTokenAxisText(_ value: Double) -> String {
        if abs(value) < 1_000_000 {
            return groupedInteger(value)
        }

        return compactTokenNumber(value)
    }

    private static func compactTokenNumber(_ value: Double) -> String {
        let absolute = abs(value)
        let scaledValue: Double
        let suffix: String

        if absolute >= 1_000_000_000 {
            scaledValue = value / 1_000_000_000
            suffix = "B"
        } else if absolute >= 1_000_000 {
            scaledValue = value / 1_000_000
            suffix = "M"
        } else if absolute >= 1_000 {
            scaledValue = value / 1_000
            suffix = "k"
        } else {
            return groupedInteger(value)
        }

        let rounded = (scaledValue * 10).rounded() / 10
        if rounded == rounded.rounded() || abs(rounded) >= 100 {
            return "\(Int(rounded))\(suffix)"
        }

        return String(format: "%.1f%@", rounded, suffix)
    }

    private static func groupedInteger(_ value: Double) -> String {
        Int64(value.rounded()).formatted(.number.grouping(.automatic))
    }

    private static func tokenAxisUpperBound(for value: Double) -> Double {
        guard value > 0 else {
            return 1
        }

        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let step: Double

        if normalized <= 1 {
            step = 1
        } else if normalized <= 2 {
            step = 2
        } else if normalized <= 5 {
            step = 5
        } else {
            step = 10
        }

        return step * magnitude
    }
}

private struct TokenDashboardComponentPointAccumulator {
    let bucketStart: Date
    let bucketEnd: Date
    let component: TokenHistoryComponent
    var tokenCount: Int64 = 0
}

private struct TokenDashboardSortableHeader: View {
    let title: String
    let indicatorSystemName: String?
    let alignment: Alignment
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)

                if let indicatorSystemName {
                    Image(systemName: indicatorSystemName)
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
    }
}

struct TokenDashboardView: View {
    @StateObject private var viewModel: TokenDashboardViewModel
    private let modelColumnWidth: CGFloat = 118
    private let primaryNumberColumnWidth: CGFloat = 82
    private let percentColumnWidth: CGFloat = 54
    private let numberColumnWidth: CGFloat = 78
    private let outputColumnWidth: CGFloat = 70
    private let reasoningColumnWidth: CGFloat = 86
    private let onFirstRendered: () -> Void

    init(
        database: UsageHistoryDatabaseWorking,
        performanceInstrumentationStore: AppPerformanceInstrumentationStore? = nil,
        onFirstRendered: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(
            wrappedValue: TokenDashboardViewModel(
                database: database,
                performanceInstrumentationStore: performanceInstrumentationStore
            )
        )
        self.onFirstRendered = onFirstRendered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            summaryTiles

            HStack(alignment: .top, spacing: 16) {
                chartPanel
                    .frame(minWidth: 520, maxWidth: .infinity)
                    .layoutPriority(1)

                modelBreakdown
                    .frame(width: 680)
                    .layoutPriority(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: UsageHistoryStore.didChangeNotification)) { _ in
            viewModel.scheduleHistoryChangeReload()
        }
        .onAppear {
            DispatchQueue.main.async {
                onFirstRendered()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $viewModel.selectedRange) {
                ForEach(UsageHistoryRange.allCases) { range in
                    Text(range.displayTitle).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 240)

            Picker("Breakdown", selection: $viewModel.selectedBreakdownDimension) {
                ForEach(viewModel.availableBreakdownDimensions) { dimension in
                    Text(dimension.displayTitle).tag(dimension)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190)

            Spacer(minLength: 16)

            periodNavigation

            Spacer(minLength: 16)

            if viewModel.isRefreshingCurrentSnapshot {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Refreshing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            Button {
                viewModel.exportCSV()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canExportCSV)
            .help(viewModel.canExportCSV ? "Export CSV" : "Export available after dashboard data and attribution coverage load")
            .accessibilityLabel("Export CSV")
        }
    }

    private var periodNavigation: some View {
        HStack(spacing: 5) {
            Button {
                viewModel.goToPreviousPeriod()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToPreviousPeriod)
            .help(viewModel.previousPeriodHelpText)

            Text(viewModel.periodTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 112)

            Button {
                viewModel.goToNextPeriod()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToNextPeriod)
            .help(viewModel.nextPeriodHelpText)
        }
    }

    private var summaryTiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 10), count: 5), spacing: 10) {
            ForEach(viewModel.summaryTiles) { tile in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let component = tile.component {
                            Circle()
                                .fill(viewModel.color(for: component))
                                .frame(width: 8, height: 8)
                        }

                        Text(tile.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(viewModel.shouldShowPrimaryLoadingState ? "—" : viewModel.formattedTokenValue(tile.tokenCount))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            componentLegend

            if viewModel.shouldShowPrimaryLoadingState {
                dashboardLoadingView(viewModel.loadingState)
                    .frame(minHeight: 320, maxHeight: .infinity)
            } else if viewModel.shouldShowTokenContent {
                Chart {
                    ForEach(viewModel.chartPoints) { point in
                        BarMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value("Value", Double(point.tokenCount)),
                            stacking: .standard
                        )
                        .foregroundStyle(viewModel.color(for: point.component))
                    }
                }
                .chartYScale(domain: viewModel.chartYDomain)
                .chartXScale(domain: viewModel.chartDomainStart...viewModel.chartDomainEnd)
                .chartXAxis {
                    AxisMarks(values: viewModel.chartXAxisLabelValues) { value in
                        AxisGridLine()
                        AxisTick()
                        if let date = value.as(Date.self) {
                            AxisValueLabel(viewModel.chartXAxisLabel(for: date), centered: false, anchor: .top)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()
                        if let doubleValue = value.as(Double.self) {
                            AxisValueLabel {
                                Text(viewModel.formattedYAxisValue(doubleValue))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(minHeight: 320, maxHeight: .infinity)
            } else {
                emptyState
                    .frame(minHeight: 320, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var componentLegend: some View {
        HStack(spacing: 8) {
            ForEach(TokenHistoryComponent.allCases) { component in
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.color(for: component))
                        .frame(width: 7, height: 7)

                    Text(component.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.shouldShowPrimaryLoadingState {
                dashboardLoadingView(viewModel.loadingState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                breakdownTable

                Divider()

                attributionCoverage
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func dashboardLoadingView(_ state: TokenDashboardLoadingState) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)

            Text(state.title)
                .font(.headline)

            Text(state.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var breakdownTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    breakdownHeader(viewModel.breakdownColumnTitle, column: .title, width: modelColumnWidth, alignment: .leading)
                    breakdownHeader("Total", column: .total, width: primaryNumberColumnWidth, alignment: .trailing)
                    breakdownHeader("%", column: .percent, width: percentColumnWidth, alignment: .trailing)
                    breakdownHeader("In", column: .input, width: numberColumnWidth, alignment: .trailing)
                    breakdownHeader("Cache", column: .cached, width: numberColumnWidth, alignment: .trailing)
                    breakdownHeader("Out", column: .output, width: outputColumnWidth, alignment: .trailing)
                    breakdownHeader("Reasoning", column: .reasoning, width: reasoningColumnWidth, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellColumns(7)

                ForEach(viewModel.breakdownRows) { row in
                    GridRow {
                        Button {
                            viewModel.selectSeries(row.series.id)
                        } label: {
                            HStack(spacing: 6) {
                                NeutralCheckboxMark(isSelected: viewModel.isSelected(row.series), size: 11)

                                tokenSeriesLabel(row.series)
                            }
                            .frame(width: modelColumnWidth, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tokenSeriesHelpText(row.series))

                        Text(viewModel.formattedTokenValue(row.totalTokens))
                            .fontWeight(.semibold)
                            .frame(width: primaryNumberColumnWidth, alignment: .trailing)

                        Text(viewModel.formattedPercent(viewModel.breakdownPercentOfTotal(for: row)))
                            .foregroundStyle(.secondary)
                            .frame(width: percentColumnWidth, alignment: .trailing)

                        ForEach(TokenHistoryComponent.allCases) { component in
                            Text(viewModel.formattedTokenValue(row.totalsByComponent[component] ?? 0))
                                .foregroundStyle(.secondary)
                                .frame(width: width(for: component), alignment: .trailing)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }
        }
    }

    private var attributionCoverage: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isAttributionCoverageLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Loading attribution data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let message = viewModel.attributionCoverageErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if viewModel.sortedAttributionCoverageRows.isEmpty {
                Text("No attribution data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        attributionHeader("Dimension", column: .dimension, width: modelColumnWidth, alignment: .leading)
                        attributionHeader("Attributed", column: .attributed, width: primaryNumberColumnWidth, alignment: .trailing)
                        hiddenTableColumn(width: percentColumnWidth)
                        attributionHeader("Missing", column: .missing, width: numberColumnWidth, alignment: .trailing)
                        hiddenTableColumn(width: numberColumnWidth)
                        attributionHeader("%", column: .percent, width: outputColumnWidth, alignment: .trailing)
                        attributionHeader("Values", column: .values, width: reasoningColumnWidth, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Divider()
                        .gridCellColumns(7)

                    ForEach(viewModel.sortedAttributionCoverageRows) { row in
                        GridRow {
                            Text(row.title)
                                .lineLimit(1)
                                .frame(width: modelColumnWidth, alignment: .leading)
                                .help(row.dimensionKey?.rawValue ?? row.title)

                            Text(viewModel.formattedTokenValue(row.attributedTokenCount))
                                .frame(width: primaryNumberColumnWidth, alignment: .trailing)

                            hiddenTableColumn(width: percentColumnWidth)

                            Text(viewModel.formattedTokenValue(row.missingTokenCount))
                                .foregroundStyle(.secondary)
                                .frame(width: numberColumnWidth, alignment: .trailing)

                            hiddenTableColumn(width: numberColumnWidth)

                            Text(viewModel.formattedPercent(row.attributedPercent))
                                .frame(width: outputColumnWidth, alignment: .trailing)

                            Text("\(row.distinctValueCount)")
                                .foregroundStyle(.secondary)
                                .frame(width: reasoningColumnWidth, alignment: .trailing)
                        }
                        .font(.caption)
                        .monospacedDigit()
                    }
                }
            }
        }
    }

    private func breakdownHeader(
        _ title: String,
        column: TokenDashboardBreakdownSortColumn,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        TokenDashboardSortableHeader(
            title: title,
            indicatorSystemName: viewModel.breakdownSortIndicator(for: column),
            alignment: alignment
        ) {
            viewModel.sortBreakdownRows(by: column)
        }
        .frame(width: width, alignment: alignment)
    }

    private func attributionHeader(
        _ title: String,
        column: TokenDashboardAttributionSortColumn,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        TokenDashboardSortableHeader(
            title: title,
            indicatorSystemName: viewModel.attributionSortIndicator(for: column),
            alignment: alignment
        ) {
            viewModel.sortAttributionCoverageRows(by: column)
        }
        .frame(width: width, alignment: alignment)
    }

    private func hiddenTableColumn(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: 1)
            .accessibilityHidden(true)
    }

    private func tokenSeriesLabel(_ series: TokenDashboardSeries) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(viewModel.compactSeriesTitle(series.name))
                .lineLimit(1)

            if let annotation = viewModel.modelCapabilityAnnotation(for: series) {
                Text(annotation.compactText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tokenSeriesHelpText(_ series: TokenDashboardSeries) -> String {
        if let annotation = viewModel.modelCapabilityAnnotation(for: series) {
            return annotation.detailText
        }

        return series.projectPath ?? series.name
    }

    private func width(for component: TokenHistoryComponent) -> CGFloat {
        switch component {
        case .input, .cached:
            return numberColumnWidth
        case .output:
            return outputColumnWidth
        case .reasoning:
            return reasoningColumnWidth
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.emptyState.systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)

            Text(viewModel.emptyState.title)
                .font(.headline)

            Text(viewModel.emptyState.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Array where Element == TokenDashboardComponentPoint {
    func sortedByDashboardDisplayOrder() -> [TokenDashboardComponentPoint] {
        sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }

            if lhs.seriesKind != rhs.seriesKind {
                return lhs.seriesKind.sortIndex < rhs.seriesKind.sortIndex
            }

            if lhs.seriesName != rhs.seriesName {
                return lhs.seriesName.localizedStandardCompare(rhs.seriesName) == .orderedAscending
            }

            return lhs.component.sortIndex < rhs.component.sortIndex
        }
    }
}

private extension TokenDashboardSeriesKind {
    var sortIndex: Int {
        switch self {
        case .aggregate:
            return 0
        case .model:
            return 1
        case .effort:
            return 1
        case .project:
            return 1
        case .dimension:
            return 1
        case .unattributed:
            return 2
        }
    }
}

private extension TokenHistoryComponent {
    var sortIndex: Int {
        switch self {
        case .input:
            return 0
        case .cached:
            return 1
        case .output:
            return 2
        case .reasoning:
            return 3
        }
    }
}
