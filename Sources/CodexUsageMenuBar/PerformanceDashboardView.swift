@preconcurrency import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum PerformanceDashboardBreakdownDimension: String, CaseIterable, Identifiable, Equatable {
    case model
    case effort
    case project
    case source
    case transport
    case wireAPI = "wire_api"

    var id: String {
        rawValue
    }

    var displayTitle: String {
        switch self {
        case .model:
            return "Model"
        case .effort:
            return "Effort"
        case .project:
            return "Project"
        case .source:
            return "Source"
        case .transport:
            return "Transport"
        case .wireAPI:
            return "Wire API"
        }
    }
}

enum PerformanceDashboardMode: String, CaseIterable, Identifiable, Equatable {
    case performance
    case efficiency

    var id: String {
        rawValue
    }

    var displayTitle: String {
        switch self {
        case .performance:
            return "Performance"
        case .efficiency:
            return "Efficiency"
        }
    }
}

enum PerformanceDashboardSeriesKind: String, Equatable {
    case aggregate
    case model
    case effort
    case project
    case source
    case transport
    case wireAPI = "wire_api"
    case unattributed
}

struct PerformanceDashboardSeries: Identifiable, Equatable, Hashable {
    static let aggregateID = "performance_all"
    static let unattributedID = "performance_unattributed"

    let id: String
    let name: String
    let kind: PerformanceDashboardSeriesKind
    let contextID: String
    let projectPath: String?

    init(
        id: String,
        name: String,
        kind: PerformanceDashboardSeriesKind,
        contextID: String? = nil,
        projectPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.contextID = contextID ?? id
        self.projectPath = projectPath
    }
}

struct PerformanceDashboardTimingSample: Equatable {
    let eventTimestamp: Date
    let sessionID: String
    let turnID: String
    let startedAt: Date?
    let completedAt: Date?
    let durationMilliseconds: Int64?
    let timeToFirstTokenMilliseconds: Int64?
    let model: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?

    var isCompleted: Bool {
        completedAt != nil
    }
}

struct PerformanceDashboardReliabilitySample: Equatable {
    let eventTimestamp: Date
    let sourceKey: String
    let sourceRowID: Int64
    let success: Bool?
    let errorSummary: String?
    let model: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?
    let transport: String?
    let wireAPI: String?
    let apiPath: String?
}

struct PerformanceDashboardEfficiencyTokenSample: Equatable {
    let eventTimestamp: Date
    let model: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?
    let modelContextWindow: Int64?
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64

    var totalTokens: Int64 {
        inputTokens + cachedInputTokens + outputTokens + reasoningOutputTokens
    }
}

struct PerformanceDashboardDurationPoint: Identifiable, Equatable {
    let id: String
    let bucketStart: Date
    let bucketEnd: Date
    let series: PerformanceDashboardSeries
    let turnCount: Int
    let completedTurnCount: Int
    let incompleteTurnCount: Int
    let durationValues: [Int64]
    let firstTokenValues: [Int64]

    init(
        bucketStart: Date,
        bucketEnd: Date,
        series: PerformanceDashboardSeries,
        turnCount: Int,
        completedTurnCount: Int,
        incompleteTurnCount: Int,
        durationValues: [Int64],
        firstTokenValues: [Int64]
    ) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.series = series
        self.turnCount = max(turnCount, 0)
        self.completedTurnCount = max(completedTurnCount, 0)
        self.incompleteTurnCount = max(incompleteTurnCount, 0)
        self.durationValues = durationValues
        self.firstTokenValues = firstTokenValues
        id = "\(Int(bucketStart.timeIntervalSince1970))-\(series.id)"
    }

    var medianDurationMilliseconds: Double? {
        PerformanceDashboardStatistics.median(durationValues)
    }

    var p95DurationMilliseconds: Double? {
        PerformanceDashboardStatistics.percentile(durationValues, percentile: 0.95)
    }

    var medianFirstTokenMilliseconds: Double? {
        PerformanceDashboardStatistics.median(firstTokenValues)
    }

    var p95FirstTokenMilliseconds: Double? {
        PerformanceDashboardStatistics.percentile(firstTokenValues, percentile: 0.95)
    }
}

struct PerformanceDashboardReliabilityPoint: Identifiable, Equatable {
    let id: String
    let bucketStart: Date
    let bucketEnd: Date
    let series: PerformanceDashboardSeries
    let successCount: Int
    let failureCount: Int
    let unknownCount: Int
    let errorCounts: [String: Int]

    init(
        bucketStart: Date,
        bucketEnd: Date,
        series: PerformanceDashboardSeries,
        successCount: Int,
        failureCount: Int,
        unknownCount: Int,
        errorCounts: [String: Int]
    ) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.series = series
        self.successCount = max(successCount, 0)
        self.failureCount = max(failureCount, 0)
        self.unknownCount = max(unknownCount, 0)
        self.errorCounts = errorCounts
        id = "\(Int(bucketStart.timeIntervalSince1970))-\(series.id)"
    }

    var eventCount: Int {
        successCount + failureCount + unknownCount
    }

    var knownEventCount: Int {
        successCount + failureCount
    }

    var failurePercent: Double {
        guard knownEventCount > 0 else {
            return 0
        }

        return Double(failureCount) / Double(knownEventCount)
    }

    var topErrorSummary: String? {
        errorCounts.max { lhs, rhs in
            lhs.value == rhs.value
                ? lhs.key.localizedStandardCompare(rhs.key) == .orderedDescending
                : lhs.value < rhs.value
        }?.key
    }
}

struct PerformanceDashboardBreakdownRow: Identifiable, Equatable {
    let series: PerformanceDashboardSeries
    let turnCount: Int
    let completedTurnCount: Int
    let incompleteTurnCount: Int
    let durationValues: [Int64]
    let firstTokenValues: [Int64]
    let eventCount: Int
    let successCount: Int
    let failureCount: Int
    let unknownCount: Int
    let errorCounts: [String: Int]

    var id: String {
        series.id
    }

    var medianDurationMilliseconds: Double? {
        PerformanceDashboardStatistics.median(durationValues)
    }

    var p95DurationMilliseconds: Double? {
        PerformanceDashboardStatistics.percentile(durationValues, percentile: 0.95)
    }

    var medianFirstTokenMilliseconds: Double? {
        PerformanceDashboardStatistics.median(firstTokenValues)
    }

    var p95FirstTokenMilliseconds: Double? {
        PerformanceDashboardStatistics.percentile(firstTokenValues, percentile: 0.95)
    }

    var knownEventCount: Int {
        successCount + failureCount
    }

    var failurePercent: Double {
        guard knownEventCount > 0 else {
            return 0
        }

        return Double(failureCount) / Double(knownEventCount)
    }

    var topErrorSummary: String? {
        errorCounts.max { lhs, rhs in
            lhs.value == rhs.value
                ? lhs.key.localizedStandardCompare(rhs.key) == .orderedDescending
                : lhs.value < rhs.value
        }?.key
    }
}

struct PerformanceDashboardEfficiencyPoint: Identifiable, Equatable {
    let id: String
    let bucketStart: Date
    let bucketEnd: Date
    let series: PerformanceDashboardSeries
    let turnCount: Int
    let completedTurnCount: Int
    let durationValues: [Int64]
    let firstTokenValues: [Int64]
    let durationTotalMilliseconds: Int64
    let eventCount: Int
    let successCount: Int
    let failureCount: Int
    let unknownCount: Int
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let contextPressureValues: [Double]

    init(
        bucketStart: Date,
        bucketEnd: Date,
        series: PerformanceDashboardSeries,
        turnCount: Int,
        completedTurnCount: Int,
        durationValues: [Int64],
        firstTokenValues: [Int64],
        durationTotalMilliseconds: Int64,
        eventCount: Int,
        successCount: Int,
        failureCount: Int,
        unknownCount: Int,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        contextPressureValues: [Double]
    ) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.series = series
        self.turnCount = max(turnCount, 0)
        self.completedTurnCount = max(completedTurnCount, 0)
        self.durationValues = durationValues
        self.firstTokenValues = firstTokenValues
        self.durationTotalMilliseconds = max(durationTotalMilliseconds, 0)
        self.eventCount = max(eventCount, 0)
        self.successCount = max(successCount, 0)
        self.failureCount = max(failureCount, 0)
        self.unknownCount = max(unknownCount, 0)
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.reasoningOutputTokens = max(reasoningOutputTokens, 0)
        self.contextPressureValues = contextPressureValues
        id = "\(Int(bucketStart.timeIntervalSince1970))-\(series.id)"
    }

    var totalTokens: Int64 {
        inputTokens + cachedInputTokens + outputTokens + reasoningOutputTokens
    }

    var tokensPerMinute: Double? {
        ratePerMinute(for: totalTokens)
    }

    var outputTokensPerMinute: Double? {
        ratePerMinute(for: outputTokens)
    }

    var medianDurationMilliseconds: Double? {
        PerformanceDashboardStatistics.median(durationValues)
    }

    var medianFirstTokenMilliseconds: Double? {
        PerformanceDashboardStatistics.median(firstTokenValues)
    }

    var cacheShare: Double {
        guard totalTokens > 0 else {
            return 0
        }
        return Double(cachedInputTokens) / Double(totalTokens)
    }

    var reasoningShare: Double {
        guard totalTokens > 0 else {
            return 0
        }
        return Double(reasoningOutputTokens) / Double(totalTokens)
    }

    var knownEventCount: Int {
        successCount + failureCount
    }

    var failurePercent: Double {
        guard knownEventCount > 0 else {
            return 0
        }
        return Double(failureCount) / Double(knownEventCount)
    }

    var contextPressure: Double? {
        contextPressureValues.max()
    }

    private func ratePerMinute(for tokens: Int64) -> Double? {
        guard tokens > 0, durationTotalMilliseconds > 0 else {
            return nil
        }
        return Double(tokens) / (Double(durationTotalMilliseconds) / 60_000)
    }
}

struct PerformanceDashboardEfficiencyRow: Identifiable, Equatable {
    let series: PerformanceDashboardSeries
    let turnCount: Int
    let completedTurnCount: Int
    let durationValues: [Int64]
    let firstTokenValues: [Int64]
    let durationTotalMilliseconds: Int64
    let eventCount: Int
    let successCount: Int
    let failureCount: Int
    let unknownCount: Int
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let contextPressureValues: [Double]

    var id: String {
        series.id
    }

    var totalTokens: Int64 {
        inputTokens + cachedInputTokens + outputTokens + reasoningOutputTokens
    }

    var tokensPerMinute: Double? {
        ratePerMinute(for: totalTokens)
    }

    var outputTokensPerMinute: Double? {
        ratePerMinute(for: outputTokens)
    }

    var medianDurationMilliseconds: Double? {
        PerformanceDashboardStatistics.median(durationValues)
    }

    var medianFirstTokenMilliseconds: Double? {
        PerformanceDashboardStatistics.median(firstTokenValues)
    }

    var cacheShare: Double {
        guard totalTokens > 0 else {
            return 0
        }
        return Double(cachedInputTokens) / Double(totalTokens)
    }

    var reasoningShare: Double {
        guard totalTokens > 0 else {
            return 0
        }
        return Double(reasoningOutputTokens) / Double(totalTokens)
    }

    var knownEventCount: Int {
        successCount + failureCount
    }

    var failurePercent: Double {
        guard knownEventCount > 0 else {
            return 0
        }
        return Double(failureCount) / Double(knownEventCount)
    }

    var contextPressure: Double? {
        contextPressureValues.max()
    }

    private func ratePerMinute(for tokens: Int64) -> Double? {
        guard tokens > 0, durationTotalMilliseconds > 0 else {
            return nil
        }
        return Double(tokens) / (Double(durationTotalMilliseconds) / 60_000)
    }
}

struct PerformanceDashboardSummaryTile: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let tint: Color
}

struct PerformanceDashboardLoadRequest: Equatable {
    let range: UsageHistoryRange
    let periodStart: Date
    let periodEnd: Date
}

struct PerformanceDashboardLoadResult: Equatable {
    let timingSamples: [PerformanceDashboardTimingSample]
    let reliabilitySamples: [PerformanceDashboardReliabilitySample]
    let efficiencyTokenSamples: [PerformanceDashboardEfficiencyTokenSample]
    let modelCapabilities: [CodexModelCapability]
    let historyBounds: UsageHistoryBounds?
}

enum PerformanceDashboardBreakdownSortColumn: Equatable {
    case title
    case turns
    case medianDuration
    case p95Duration
    case medianFirstToken
    case events
    case failurePercent
    case topError

    var defaultAscending: Bool {
        switch self {
        case .title, .failurePercent:
            return true
        case .turns, .medianDuration, .p95Duration, .medianFirstToken, .events, .topError:
            return false
        }
    }
}

enum PerformanceDashboardEfficiencySortColumn: Equatable {
    case title
    case turns
    case tokens
    case tokensPerMinute
    case outputTokensPerMinute
    case cacheShare
    case reasoningShare
    case medianDuration
    case failurePercent
    case contextPressure

    var defaultAscending: Bool {
        switch self {
        case .title, .failurePercent:
            return true
        case .turns, .tokens, .tokensPerMinute, .outputTokensPerMinute, .cacheShare,
             .reasoningShare, .medianDuration, .contextPressure:
            return false
        }
    }
}

struct PerformanceDashboardSortState<Column: Equatable>: Equatable {
    let column: Column
    let ascending: Bool
}

struct PerformanceDashboardEmptyState: Equatable {
    let title: String
    let message: String
    let systemImage: String
}

enum PerformanceDashboardStatistics {
    static func median(_ values: [Int64]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        let sortedValues = values.sorted()
        let midpoint = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (Double(sortedValues[midpoint - 1]) + Double(sortedValues[midpoint])) / 2
        }

        return Double(sortedValues[midpoint])
    }

    static func percentile(_ values: [Int64], percentile: Double) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        let sortedValues = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let rank = Int(ceil(clampedPercentile * Double(sortedValues.count))) - 1
        return Double(sortedValues[min(max(rank, 0), sortedValues.count - 1)])
    }
}

@MainActor
final class PerformanceDashboardViewModel: ObservableObject {
    @Published var selectedMode: PerformanceDashboardMode = .performance {
        didSet {
            guard selectedMode != oldValue else {
                return
            }

            if selectedMode == .efficiency,
               !availableBreakdownDimensions.contains(selectedBreakdownDimension)
            {
                selectedBreakdownDimension = .model
            }
            selectedSeriesIDs = []
            breakdownSortState = nil
            efficiencySortState = nil
            rebuildPresentation()
        }
    }

    @Published var selectedRange: UsageHistoryRange = .month {
        didSet {
            guard selectedRange != oldValue else {
                return
            }

            selectedPeriodStart = currentPeriod.start
            selectedSeriesIDs = []
            scheduleReload()
        }
    }

    @Published var selectedBreakdownDimension: PerformanceDashboardBreakdownDimension = .model {
        didSet {
            guard selectedBreakdownDimension != oldValue else {
                return
            }

            selectedSeriesIDs = []
            breakdownSortState = nil
            rebuildPresentation()
        }
    }

    @Published private(set) var selectedPeriodStart: Date
    @Published private(set) var timingSamples: [PerformanceDashboardTimingSample] = []
    @Published private(set) var reliabilitySamples: [PerformanceDashboardReliabilitySample] = []
    @Published private(set) var efficiencyTokenSamples: [PerformanceDashboardEfficiencyTokenSample] = []
    @Published private(set) var modelCapabilities: [CodexModelCapability] = []
    @Published private(set) var durationPoints: [PerformanceDashboardDurationPoint] = []
    @Published private(set) var reliabilityPoints: [PerformanceDashboardReliabilityPoint] = []
    @Published private(set) var breakdownRows: [PerformanceDashboardBreakdownRow] = []
    @Published private(set) var efficiencyPoints: [PerformanceDashboardEfficiencyPoint] = []
    @Published private(set) var efficiencyRows: [PerformanceDashboardEfficiencyRow] = []
    @Published private(set) var series: [PerformanceDashboardSeries] = []
    @Published private(set) var selectedSeriesIDs: Set<String> = []
    @Published private(set) var historyBounds: UsageHistoryBounds?
    @Published private(set) var errorMessage: String?
    @Published private(set) var breakdownSortState: PerformanceDashboardSortState<PerformanceDashboardBreakdownSortColumn>?
    @Published private(set) var efficiencySortState: PerformanceDashboardSortState<PerformanceDashboardEfficiencySortColumn>?

    private let database: UsageHistoryDatabaseWorking
    private let now: () -> Date
    private let calendar: Calendar
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    init(
        database: UsageHistoryDatabaseWorking,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.database = database
        self.now = now
        self.calendar = calendar
        selectedPeriodStart = UsageHistoryRange.month.period(containing: now(), calendar: calendar).start
        scheduleReload()
    }

    convenience init(
        store: UsageHistoryStore,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.init(
            database: UsageHistoryDatabaseWorker(store: store),
            now: now,
            calendar: calendar
        )
    }

    deinit {
        reloadTask?.cancel()
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

    var previousPeriodHelpText: String {
        canGoToPreviousPeriod ? "Show previous \(periodDisplayNoun)" : "No earlier performance data"
    }

    var nextPeriodHelpText: String {
        canGoToNextPeriod ? "Show next \(periodDisplayNoun)" : "Already showing the current \(periodDisplayNoun)"
    }

    var currentPeriodHelpText: String {
        canJumpToCurrentPeriod ? "Jump to current \(periodDisplayNoun)" : "Already showing the current \(periodDisplayNoun)"
    }

    var hasAnyData: Bool {
        switch selectedMode {
        case .performance:
            return !timingSamples.isEmpty || !reliabilitySamples.isEmpty
        case .efficiency:
            return !efficiencyTokenSamples.isEmpty || !timingSamples.isEmpty || !reliabilitySamples.isEmpty
        }
    }

    var hasVisibleData: Bool {
        switch selectedMode {
        case .performance:
            return visibleSummaryRow.turnCount > 0 || visibleSummaryRow.eventCount > 0
        case .efficiency:
            return visibleEfficiencySummaryRow.totalTokens > 0
                || visibleEfficiencySummaryRow.turnCount > 0
                || visibleEfficiencySummaryRow.eventCount > 0
        }
    }

    var selectedSeries: [PerformanceDashboardSeries] {
        series.filter { selectedSeriesIDs.contains($0.id) }
    }

    var availableBreakdownDimensions: [PerformanceDashboardBreakdownDimension] {
        switch selectedMode {
        case .performance:
            return PerformanceDashboardBreakdownDimension.allCases
        case .efficiency:
            return [.model, .project, .effort, .source]
        }
    }

    var visibleDurationPoints: [PerformanceDashboardDurationPoint] {
        combinedDurationPoints(from: selectedSourceDurationPoints)
    }

    var visibleReliabilityPoints: [PerformanceDashboardReliabilityPoint] {
        combinedReliabilityPoints(from: selectedSourceReliabilityPoints)
    }

    var reliabilityChartPoints: [PerformanceDashboardReliabilityChartPoint] {
        visibleReliabilityPoints.flatMap { point in
            [
                PerformanceDashboardReliabilityChartPoint(
                    bucketStart: point.bucketStart,
                    bucketEnd: point.bucketEnd,
                    status: .success,
                    count: point.successCount
                ),
                PerformanceDashboardReliabilityChartPoint(
                    bucketStart: point.bucketStart,
                    bucketEnd: point.bucketEnd,
                    status: .failure,
                    count: point.failureCount
                ),
            ].filter { $0.count > 0 }
        }
    }

    var sortedBreakdownRows: [PerformanceDashboardBreakdownRow] {
        sortedRows(breakdownRows)
    }

    var sortedEfficiencyRows: [PerformanceDashboardEfficiencyRow] {
        sortedRows(efficiencyRows)
    }

    var visibleSummaryRow: PerformanceDashboardBreakdownRow {
        combinedRow(from: selectedSourceRows)
    }

    var visibleEfficiencyPoints: [PerformanceDashboardEfficiencyPoint] {
        combinedEfficiencyPoints(from: selectedSourceEfficiencyPoints)
    }

    var visibleEfficiencySummaryRow: PerformanceDashboardEfficiencyRow {
        combinedEfficiencyRow(from: selectedSourceEfficiencyRows)
    }

    var summaryTiles: [PerformanceDashboardSummaryTile] {
        switch selectedMode {
        case .performance:
            return performanceSummaryTiles
        case .efficiency:
            return efficiencySummaryTiles
        }
    }

    var performanceSummaryTiles: [PerformanceDashboardSummaryTile] {
        let row = visibleSummaryRow
        return [
            PerformanceDashboardSummaryTile(
                id: "turns",
                title: "Turns",
                value: Self.integerFormatter.string(from: NSNumber(value: row.turnCount)) ?? "\(row.turnCount)",
                tint: .secondary
            ),
            PerformanceDashboardSummaryTile(
                id: "median_duration",
                title: "Median duration",
                value: formattedDuration(row.medianDurationMilliseconds),
                tint: .blue
            ),
            PerformanceDashboardSummaryTile(
                id: "p95_duration",
                title: "P95 duration",
                value: formattedDuration(row.p95DurationMilliseconds),
                tint: .orange
            ),
            PerformanceDashboardSummaryTile(
                id: "median_first_token",
                title: "First token",
                value: formattedDuration(row.medianFirstTokenMilliseconds),
                tint: .green
            ),
            PerformanceDashboardSummaryTile(
                id: "failure_rate",
                title: "Failure rate",
                value: formattedPercent(row.failurePercent),
                tint: row.failureCount > 0 ? .red : .secondary
            ),
        ]
    }

    var efficiencySummaryTiles: [PerformanceDashboardSummaryTile] {
        let row = visibleEfficiencySummaryRow
        return [
            PerformanceDashboardSummaryTile(
                id: "total_tokens",
                title: "Total tokens",
                value: formattedTokenCount(row.totalTokens),
                tint: .secondary
            ),
            PerformanceDashboardSummaryTile(
                id: "tokens_per_minute",
                title: "Tokens/min",
                value: formattedRate(row.tokensPerMinute),
                tint: .blue
            ),
            PerformanceDashboardSummaryTile(
                id: "output_per_minute",
                title: "Output/min",
                value: formattedRate(row.outputTokensPerMinute),
                tint: .orange
            ),
            PerformanceDashboardSummaryTile(
                id: "cache_share",
                title: "Cache %",
                value: formattedPercent(row.cacheShare),
                tint: .green
            ),
            PerformanceDashboardSummaryTile(
                id: "reasoning_share",
                title: "Reasoning %",
                value: formattedPercent(row.reasoningShare),
                tint: .purple
            ),
        ]
    }

    var emptyState: PerformanceDashboardEmptyState {
        if !hasAnyData {
            switch selectedMode {
            case .performance:
                return PerformanceDashboardEmptyState(
                    title: "No performance data yet",
                    message: "Use Codex or refresh diagnostics to capture local turn timing and reliability data.",
                    systemImage: "speedometer"
                )
            case .efficiency:
                return PerformanceDashboardEmptyState(
                    title: "No efficiency data yet",
                    message: "Use Codex or refresh diagnostics to capture local token, timing, and reliability data.",
                    systemImage: "chart.xyaxis.line"
                )
            }
        }

        return PerformanceDashboardEmptyState(
            title: selectedMode == .performance ? "No data for this selection" : "No efficiency data for this selection",
            message: "Choose a different period or breakdown row.",
            systemImage: "line.3.horizontal.decrease.circle"
        )
    }

    var durationYDomain: ClosedRange<Double> {
        let maximum = visibleDurationPoints
            .compactMap(\.p95DurationMilliseconds)
            .max() ?? 0
        return 0...Self.durationAxisUpperBound(for: maximum)
    }

    var reliabilityYDomain: ClosedRange<Double> {
        let maximum = visibleReliabilityPoints
            .map { Double($0.successCount + $0.failureCount) }
            .max() ?? 0
        return 0...Self.countAxisUpperBound(for: maximum)
    }

    var efficiencyYDomain: ClosedRange<Double> {
        let maximum = visibleEfficiencyPoints
            .compactMap(\.tokensPerMinute)
            .max() ?? 0
        return 0...Self.countAxisUpperBound(for: maximum)
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
            selectedMode == .performance ? "codex-performance-dashboard" : "codex-efficiency-dashboard",
            selectedRange.rawValue,
            periodFilenameToken,
        ].joined(separator: "-") + ".csv"
    }

    var csvText: String {
        switch selectedMode {
        case .performance:
            return performanceCSVText
        case .efficiency:
            return efficiencyCSVText
        }
    }

    private var performanceCSVText: String {
        var rows = [
            "section,range,period_start,period_end,bucket_start,bucket_end,breakdown_dimension,series_id,series_name,series_kind,context_id,project_path,turn_count,completed_turns,incomplete_turns,median_duration_ms,p95_duration_ms,median_first_token_ms,p95_first_token_ms,event_count,success_count,failure_count,unknown_count,failure_percent,top_error"
        ]
        let formatter = ISO8601DateFormatter()

        rows += selectedSourceDurationPoints.sortedByDashboardDisplayOrder().map { point in
            [
                "duration_bucket",
                selectedRange.rawValue,
                formatter.string(from: selectedPeriod.start),
                formatter.string(from: selectedPeriod.end),
                formatter.string(from: point.bucketStart),
                formatter.string(from: point.bucketEnd),
                selectedBreakdownDimension.rawValue,
                Self.csvEscaped(point.series.id),
                Self.csvEscaped(point.series.name),
                point.series.kind.rawValue,
                Self.csvEscaped(point.series.contextID),
                Self.csvEscaped(point.series.projectPath ?? ""),
                "\(point.turnCount)",
                "\(point.completedTurnCount)",
                "\(point.incompleteTurnCount)",
                Self.csvNumber(point.medianDurationMilliseconds),
                Self.csvNumber(point.p95DurationMilliseconds),
                Self.csvNumber(point.medianFirstTokenMilliseconds),
                Self.csvNumber(point.p95FirstTokenMilliseconds),
                "",
                "",
                "",
                "",
                "",
                "",
            ].joined(separator: ",")
        }

        rows += selectedSourceReliabilityPoints.sortedByDashboardDisplayOrder().map { point in
            [
                "reliability_bucket",
                selectedRange.rawValue,
                formatter.string(from: selectedPeriod.start),
                formatter.string(from: selectedPeriod.end),
                formatter.string(from: point.bucketStart),
                formatter.string(from: point.bucketEnd),
                selectedBreakdownDimension.rawValue,
                Self.csvEscaped(point.series.id),
                Self.csvEscaped(point.series.name),
                point.series.kind.rawValue,
                Self.csvEscaped(point.series.contextID),
                Self.csvEscaped(point.series.projectPath ?? ""),
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "\(point.eventCount)",
                "\(point.successCount)",
                "\(point.failureCount)",
                "\(point.unknownCount)",
                String(format: "%.4f", point.failurePercent),
                Self.csvEscaped(point.topErrorSummary ?? ""),
            ].joined(separator: ",")
        }

        rows.append("")
        rows.append("section,breakdown_dimension,series_id,series_name,series_kind,context_id,project_path,turn_count,completed_turns,incomplete_turns,median_duration_ms,p95_duration_ms,median_first_token_ms,p95_first_token_ms,event_count,success_count,failure_count,unknown_count,failure_percent,top_error")
        rows += sortedRows(selectedSourceRows).map { row in
            [
                "breakdown_row",
                selectedBreakdownDimension.rawValue,
                Self.csvEscaped(row.series.id),
                Self.csvEscaped(row.series.name),
                row.series.kind.rawValue,
                Self.csvEscaped(row.series.contextID),
                Self.csvEscaped(row.series.projectPath ?? ""),
                "\(row.turnCount)",
                "\(row.completedTurnCount)",
                "\(row.incompleteTurnCount)",
                Self.csvNumber(row.medianDurationMilliseconds),
                Self.csvNumber(row.p95DurationMilliseconds),
                Self.csvNumber(row.medianFirstTokenMilliseconds),
                Self.csvNumber(row.p95FirstTokenMilliseconds),
                "\(row.eventCount)",
                "\(row.successCount)",
                "\(row.failureCount)",
                "\(row.unknownCount)",
                String(format: "%.4f", row.failurePercent),
                Self.csvEscaped(row.topErrorSummary ?? ""),
            ].joined(separator: ",")
        }

        return rows.joined(separator: "\n") + "\n"
    }

    private var efficiencyCSVText: String {
        var rows = [
            "section,range,period_start,period_end,bucket_start,bucket_end,breakdown_dimension,series_id,series_name,series_kind,context_id,project_path,turn_count,completed_turns,total_tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,tokens_per_minute,output_tokens_per_minute,cache_share,reasoning_share,median_duration_ms,median_first_token_ms,event_count,success_count,failure_count,unknown_count,failure_percent,context_pressure"
        ]
        let formatter = ISO8601DateFormatter()

        rows += selectedSourceEfficiencyPoints.sortedByDashboardDisplayOrder().map { point in
            [
                "efficiency_bucket",
                selectedRange.rawValue,
                formatter.string(from: selectedPeriod.start),
                formatter.string(from: selectedPeriod.end),
                formatter.string(from: point.bucketStart),
                formatter.string(from: point.bucketEnd),
                selectedBreakdownDimension.rawValue,
                Self.csvEscaped(point.series.id),
                Self.csvEscaped(point.series.name),
                point.series.kind.rawValue,
                Self.csvEscaped(point.series.contextID),
                Self.csvEscaped(point.series.projectPath ?? ""),
                "\(point.turnCount)",
                "\(point.completedTurnCount)",
                "\(point.totalTokens)",
                "\(point.inputTokens)",
                "\(point.cachedInputTokens)",
                "\(point.outputTokens)",
                "\(point.reasoningOutputTokens)",
                Self.csvNumber(point.tokensPerMinute),
                Self.csvNumber(point.outputTokensPerMinute),
                String(format: "%.4f", point.cacheShare),
                String(format: "%.4f", point.reasoningShare),
                Self.csvNumber(point.medianDurationMilliseconds),
                Self.csvNumber(point.medianFirstTokenMilliseconds),
                "\(point.eventCount)",
                "\(point.successCount)",
                "\(point.failureCount)",
                "\(point.unknownCount)",
                String(format: "%.4f", point.failurePercent),
                Self.csvNumber(point.contextPressure),
            ].joined(separator: ",")
        }

        rows.append("")
        rows.append("section,breakdown_dimension,series_id,series_name,series_kind,context_id,project_path,turn_count,completed_turns,total_tokens,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,tokens_per_minute,output_tokens_per_minute,cache_share,reasoning_share,median_duration_ms,median_first_token_ms,event_count,success_count,failure_count,unknown_count,failure_percent,context_pressure")
        rows += sortedRows(selectedSourceEfficiencyRows).map { row in
            [
                "efficiency_breakdown_row",
                selectedBreakdownDimension.rawValue,
                Self.csvEscaped(row.series.id),
                Self.csvEscaped(row.series.name),
                row.series.kind.rawValue,
                Self.csvEscaped(row.series.contextID),
                Self.csvEscaped(row.series.projectPath ?? ""),
                "\(row.turnCount)",
                "\(row.completedTurnCount)",
                "\(row.totalTokens)",
                "\(row.inputTokens)",
                "\(row.cachedInputTokens)",
                "\(row.outputTokens)",
                "\(row.reasoningOutputTokens)",
                Self.csvNumber(row.tokensPerMinute),
                Self.csvNumber(row.outputTokensPerMinute),
                String(format: "%.4f", row.cacheShare),
                String(format: "%.4f", row.reasoningShare),
                Self.csvNumber(row.medianDurationMilliseconds),
                Self.csvNumber(row.medianFirstTokenMilliseconds),
                "\(row.eventCount)",
                "\(row.successCount)",
                "\(row.failureCount)",
                "\(row.unknownCount)",
                String(format: "%.4f", row.failurePercent),
                Self.csvNumber(row.contextPressure),
            ].joined(separator: ",")
        }

        return rows.joined(separator: "\n") + "\n"
    }

    var breakdownColumnTitle: String {
        selectedBreakdownDimension.displayTitle
    }

    private var periodDisplayNoun: String {
        selectedRange.displayTitle.lowercased()
    }

    private var periodFilenameToken: String {
        Self.periodFilenameToken(
            for: selectedRange,
            periodStart: selectedPeriod.start,
            calendar: calendar
        )
    }

    private var chartDomainBucketPadding: TimeInterval {
        let reference = selectedPeriod.start
        let next = calendar.date(byAdding: selectedRange.chartBucketComponent, value: 1, to: reference)
            ?? reference.addingTimeInterval(3600)
        return max(next.timeIntervalSince(reference) / 2, 1)
    }

    private var selectedSourceDurationPoints: [PerformanceDashboardDurationPoint] {
        if selectedSeriesIDs.contains(PerformanceDashboardSeries.aggregateID) {
            return durationPoints.filter { $0.series.id == PerformanceDashboardSeries.aggregateID }
        }

        return durationPoints.filter { selectedSeriesIDs.contains($0.series.id) }
    }

    private var selectedSourceReliabilityPoints: [PerformanceDashboardReliabilityPoint] {
        if selectedSeriesIDs.contains(PerformanceDashboardSeries.aggregateID) {
            return reliabilityPoints.filter { $0.series.id == PerformanceDashboardSeries.aggregateID }
        }

        return reliabilityPoints.filter { selectedSeriesIDs.contains($0.series.id) }
    }

    private var selectedSourceRows: [PerformanceDashboardBreakdownRow] {
        if selectedSeriesIDs.contains(PerformanceDashboardSeries.aggregateID),
           let aggregate = breakdownRows.first(where: { $0.series.id == PerformanceDashboardSeries.aggregateID })
        {
            return [aggregate]
        }

        return breakdownRows.filter { selectedSeriesIDs.contains($0.series.id) }
    }

    private var selectedSourceEfficiencyPoints: [PerformanceDashboardEfficiencyPoint] {
        if selectedSeriesIDs.contains(PerformanceDashboardSeries.aggregateID) {
            return efficiencyPoints.filter { $0.series.id == PerformanceDashboardSeries.aggregateID }
        }

        return efficiencyPoints.filter { selectedSeriesIDs.contains($0.series.id) }
    }

    private var selectedSourceEfficiencyRows: [PerformanceDashboardEfficiencyRow] {
        if selectedSeriesIDs.contains(PerformanceDashboardSeries.aggregateID),
           let aggregate = efficiencyRows.first(where: { $0.series.id == PerformanceDashboardSeries.aggregateID })
        {
            return [aggregate]
        }

        return efficiencyRows.filter { selectedSeriesIDs.contains($0.series.id) }
    }

    @discardableResult
    func reload() async -> Bool {
        reloadTask?.cancel()
        reloadTask = nil
        return await performReload()
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.performReload()
        }
    }

    @discardableResult
    private func performReload() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }

        let generation = nextReloadGeneration()
        let queryPeriod = periodForQuery()
        let request = PerformanceDashboardLoadRequest(
            range: selectedRange,
            periodStart: queryPeriod.start,
            periodEnd: queryPeriod.end
        )

        do {
            let result = try await database.performanceDashboardSnapshot(for: request)
            guard generation == reloadGeneration, !Task.isCancelled else {
                return false
            }

            timingSamples = result.timingSamples
            reliabilitySamples = result.reliabilitySamples
            efficiencyTokenSamples = result.efficiencyTokenSamples
            modelCapabilities = result.modelCapabilities
            historyBounds = result.historyBounds
            rebuildPresentation()
            errorMessage = nil
            return true
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else {
                return false
            }

            timingSamples = []
            reliabilitySamples = []
            efficiencyTokenSamples = []
            modelCapabilities = []
            durationPoints = []
            reliabilityPoints = []
            breakdownRows = []
            efficiencyPoints = []
            efficiencyRows = []
            series = []
            selectedSeriesIDs = []
            historyBounds = nil
            errorMessage = "Performance dashboard could not be loaded."
            return false
        }
    }

    private func rebuildPresentation() {
        if selectedMode == .efficiency,
           !availableBreakdownDimensions.contains(selectedBreakdownDimension)
        {
            selectedBreakdownDimension = .model
            return
        }

        switch selectedMode {
        case .performance:
            let presentation = PerformanceDashboardPresentationBuilder.build(
                timingSamples: timingSamples,
                reliabilitySamples: reliabilitySamples,
                breakdownDimension: selectedBreakdownDimension,
                range: selectedRange,
                calendar: calendar
            )
            durationPoints = presentation.durationPoints
            reliabilityPoints = presentation.reliabilityPoints
            breakdownRows = presentation.breakdownRows
            efficiencyPoints = []
            efficiencyRows = []
            series = presentation.series
        case .efficiency:
            let presentation = PerformanceDashboardPresentationBuilder.buildEfficiency(
                tokenSamples: efficiencyTokenSamples,
                timingSamples: timingSamples,
                reliabilitySamples: reliabilitySamples,
                modelCapabilities: modelCapabilities,
                breakdownDimension: selectedBreakdownDimension,
                range: selectedRange,
                calendar: calendar
            )
            durationPoints = []
            reliabilityPoints = []
            breakdownRows = []
            efficiencyPoints = presentation.points
            efficiencyRows = presentation.rows
            series = presentation.series
        }
        reconcileSelection()
    }

    private func nextReloadGeneration() -> Int {
        reloadGeneration += 1
        return reloadGeneration
    }

    func goToPreviousPeriod() {
        guard canGoToPreviousPeriod,
              let previous = calendar.date(byAdding: selectedRange.periodComponent, value: -1, to: selectedPeriod.start)
        else {
            return
        }

        selectedPeriodStart = previous
        scheduleReload()
    }

    func goToNextPeriod() {
        guard canGoToNextPeriod,
              let next = calendar.date(byAdding: selectedRange.periodComponent, value: 1, to: selectedPeriod.start)
        else {
            return
        }

        selectedPeriodStart = min(next, currentPeriod.start)
        scheduleReload()
    }

    func jumpToCurrentPeriod() {
        guard canJumpToCurrentPeriod else {
            return
        }

        selectedPeriodStart = currentPeriod.start
        scheduleReload()
    }

    func selectSeries(_ id: String) {
        guard series.contains(where: { $0.id == id }) else {
            return
        }

        if id == PerformanceDashboardSeries.aggregateID {
            selectedSeriesIDs = [PerformanceDashboardSeries.aggregateID]
            return
        }

        var updated = selectedSeriesIDs
        updated.remove(PerformanceDashboardSeries.aggregateID)

        if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }

        selectedSeriesIDs = updated.isEmpty ? [PerformanceDashboardSeries.aggregateID] : updated
    }

    func isSelected(_ series: PerformanceDashboardSeries) -> Bool {
        selectedSeriesIDs.contains(series.id)
    }

    func exportCSV() {
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
            errorMessage = "Performance dashboard could not be exported."
        }
    }

    func chartXPosition(for point: PerformanceDashboardDurationPoint) -> Date {
        chartXPosition(forBucketStart: point.bucketStart)
    }

    func chartXPosition(for point: PerformanceDashboardReliabilityChartPoint) -> Date {
        chartXPosition(forBucketStart: point.bucketStart)
    }

    func chartXPosition(for point: PerformanceDashboardEfficiencyPoint) -> Date {
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

    func formattedDuration(_ milliseconds: Double?) -> String {
        guard let milliseconds else {
            return "—"
        }

        return Self.durationFormatter(milliseconds)
    }

    func formattedPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    func formattedOptionalPercent(_ value: Double?) -> String {
        guard let value else {
            return "—"
        }

        return formattedPercent(value)
    }

    func formattedInteger(_ value: Int) -> String {
        Self.integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func formattedTokenCount(_ value: Int64) -> String {
        Self.compactNumber(Double(value))
    }

    func formattedRate(_ value: Double?) -> String {
        guard let value else {
            return "—"
        }

        return Self.compactNumber(value)
    }

    func formattedCountAxisValue(_ value: Double) -> String {
        Self.compactNumber(value)
    }

    func formattedDurationAxisValue(_ value: Double) -> String {
        Self.durationFormatter(value)
    }

    func color(for tile: PerformanceDashboardSummaryTile) -> Color {
        tile.tint
    }

    func color(for status: PerformanceDashboardReliabilityStatus) -> Color {
        switch status {
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    func compactSeriesTitle(_ name: String) -> String {
        Self.compactSeriesTitle(name)
    }

    func sortBreakdownRows(by column: PerformanceDashboardBreakdownSortColumn) {
        breakdownSortState = nextSortState(current: breakdownSortState, column: column)
    }

    func sortEfficiencyRows(by column: PerformanceDashboardEfficiencySortColumn) {
        efficiencySortState = nextSortState(current: efficiencySortState, column: column)
    }

    func breakdownSortIndicator(for column: PerformanceDashboardBreakdownSortColumn) -> String? {
        guard let breakdownSortState, breakdownSortState.column == column else {
            return nil
        }

        return breakdownSortState.ascending ? "chevron.up" : "chevron.down"
    }

    func efficiencySortIndicator(for column: PerformanceDashboardEfficiencySortColumn) -> String? {
        guard let efficiencySortState, efficiencySortState.column == column else {
            return nil
        }

        return efficiencySortState.ascending ? "chevron.up" : "chevron.down"
    }

    private func reconcileSelection() {
        let availableIDs = Set(series.map(\.id))
        let retained = selectedSeriesIDs.intersection(availableIDs)

        if retained.isEmpty, availableIDs.contains(PerformanceDashboardSeries.aggregateID) {
            selectedSeriesIDs = [PerformanceDashboardSeries.aggregateID]
        } else {
            selectedSeriesIDs = retained
        }
    }

    private func nextSortState(
        current: PerformanceDashboardSortState<PerformanceDashboardBreakdownSortColumn>?,
        column: PerformanceDashboardBreakdownSortColumn
    ) -> PerformanceDashboardSortState<PerformanceDashboardBreakdownSortColumn> {
        if let current, current.column == column {
            return PerformanceDashboardSortState(column: column, ascending: !current.ascending)
        }

        return PerformanceDashboardSortState(column: column, ascending: column.defaultAscending)
    }

    private func nextSortState(
        current: PerformanceDashboardSortState<PerformanceDashboardEfficiencySortColumn>?,
        column: PerformanceDashboardEfficiencySortColumn
    ) -> PerformanceDashboardSortState<PerformanceDashboardEfficiencySortColumn> {
        if let current, current.column == column {
            return PerformanceDashboardSortState(column: column, ascending: !current.ascending)
        }

        return PerformanceDashboardSortState(column: column, ascending: column.defaultAscending)
    }

    private func sortedRows(_ rows: [PerformanceDashboardBreakdownRow]) -> [PerformanceDashboardBreakdownRow] {
        guard let breakdownSortState else {
            return rows
        }

        return rows.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch breakdownSortState.column {
            case .title:
                comparison = lhs.series.name.localizedStandardCompare(rhs.series.name)
            case .turns:
                comparison = compare(lhs.turnCount, rhs.turnCount)
            case .medianDuration:
                comparison = compareOptional(lhs.medianDurationMilliseconds, rhs.medianDurationMilliseconds)
            case .p95Duration:
                comparison = compareOptional(lhs.p95DurationMilliseconds, rhs.p95DurationMilliseconds)
            case .medianFirstToken:
                comparison = compareOptional(lhs.medianFirstTokenMilliseconds, rhs.medianFirstTokenMilliseconds)
            case .events:
                comparison = compare(lhs.eventCount, rhs.eventCount)
            case .failurePercent:
                comparison = compare(lhs.failurePercent, rhs.failurePercent)
            case .topError:
                comparison = (lhs.topErrorSummary ?? "").localizedStandardCompare(rhs.topErrorSummary ?? "")
            }

            return orderedBefore(
                lhsID: lhs.id,
                rhsID: rhs.id,
                comparison: comparison,
                ascending: breakdownSortState.ascending
            )
        }
    }

    private func sortedRows(_ rows: [PerformanceDashboardEfficiencyRow]) -> [PerformanceDashboardEfficiencyRow] {
        guard let efficiencySortState else {
            return rows
        }

        return rows.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch efficiencySortState.column {
            case .title:
                comparison = lhs.series.name.localizedStandardCompare(rhs.series.name)
            case .turns:
                comparison = compare(lhs.turnCount, rhs.turnCount)
            case .tokens:
                comparison = compare(lhs.totalTokens, rhs.totalTokens)
            case .tokensPerMinute:
                comparison = compareOptional(lhs.tokensPerMinute, rhs.tokensPerMinute)
            case .outputTokensPerMinute:
                comparison = compareOptional(lhs.outputTokensPerMinute, rhs.outputTokensPerMinute)
            case .cacheShare:
                comparison = compare(lhs.cacheShare, rhs.cacheShare)
            case .reasoningShare:
                comparison = compare(lhs.reasoningShare, rhs.reasoningShare)
            case .medianDuration:
                comparison = compareOptional(lhs.medianDurationMilliseconds, rhs.medianDurationMilliseconds)
            case .failurePercent:
                comparison = compare(lhs.failurePercent, rhs.failurePercent)
            case .contextPressure:
                comparison = compareOptional(lhs.contextPressure, rhs.contextPressure)
            }

            return orderedBefore(
                lhsID: lhs.id,
                rhsID: rhs.id,
                comparison: comparison,
                ascending: efficiencySortState.ascending
            )
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

    private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none):
            return .orderedSame
        case (.none, .some):
            return .orderedAscending
        case (.some, .none):
            return .orderedDescending
        case let (.some(lhs), .some(rhs)):
            return compare(lhs, rhs)
        }
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

    private func combinedDurationPoints(
        from points: [PerformanceDashboardDurationPoint]
    ) -> [PerformanceDashboardDurationPoint] {
        var accumulators = [Date: PerformanceDashboardDurationAccumulator]()
        for point in points {
            var accumulator = accumulators[point.bucketStart] ?? PerformanceDashboardDurationAccumulator(
                bucketStart: point.bucketStart,
                bucketEnd: point.bucketEnd,
                series: .visible
            )
            accumulator.turnCount += point.turnCount
            accumulator.completedTurnCount += point.completedTurnCount
            accumulator.incompleteTurnCount += point.incompleteTurnCount
            accumulator.durationValues += point.durationValues
            accumulator.firstTokenValues += point.firstTokenValues
            accumulators[point.bucketStart] = accumulator
        }

        return accumulators.values
            .map(\.point)
            .sortedByDashboardDisplayOrder()
    }

    private func combinedReliabilityPoints(
        from points: [PerformanceDashboardReliabilityPoint]
    ) -> [PerformanceDashboardReliabilityPoint] {
        var accumulators = [Date: PerformanceDashboardReliabilityAccumulator]()
        for point in points {
            var accumulator = accumulators[point.bucketStart] ?? PerformanceDashboardReliabilityAccumulator(
                bucketStart: point.bucketStart,
                bucketEnd: point.bucketEnd,
                series: .visible
            )
            accumulator.successCount += point.successCount
            accumulator.failureCount += point.failureCount
            accumulator.unknownCount += point.unknownCount
            accumulator.merge(errorCounts: point.errorCounts)
            accumulators[point.bucketStart] = accumulator
        }

        return accumulators.values
            .map(\.point)
            .sortedByDashboardDisplayOrder()
    }

    private func combinedRow(from rows: [PerformanceDashboardBreakdownRow]) -> PerformanceDashboardBreakdownRow {
        var durationValues: [Int64] = []
        var firstTokenValues: [Int64] = []
        var turnCount = 0
        var completedTurnCount = 0
        var incompleteTurnCount = 0
        var eventCount = 0
        var successCount = 0
        var failureCount = 0
        var unknownCount = 0
        var errorCounts = [String: Int]()

        for row in rows {
            durationValues += row.durationValues
            firstTokenValues += row.firstTokenValues
            turnCount += row.turnCount
            completedTurnCount += row.completedTurnCount
            incompleteTurnCount += row.incompleteTurnCount
            eventCount += row.eventCount
            successCount += row.successCount
            failureCount += row.failureCount
            unknownCount += row.unknownCount
            for (error, count) in row.errorCounts {
                errorCounts[error, default: 0] += count
            }
        }

        return PerformanceDashboardBreakdownRow(
            series: .visible,
            turnCount: turnCount,
            completedTurnCount: completedTurnCount,
            incompleteTurnCount: incompleteTurnCount,
            durationValues: durationValues,
            firstTokenValues: firstTokenValues,
            eventCount: eventCount,
            successCount: successCount,
            failureCount: failureCount,
            unknownCount: unknownCount,
            errorCounts: errorCounts
        )
    }

    private func combinedEfficiencyPoints(
        from points: [PerformanceDashboardEfficiencyPoint]
    ) -> [PerformanceDashboardEfficiencyPoint] {
        var accumulators = [Date: PerformanceDashboardEfficiencyAccumulator]()
        for point in points {
            var accumulator = accumulators[point.bucketStart] ?? PerformanceDashboardEfficiencyAccumulator(
                bucketStart: point.bucketStart,
                bucketEnd: point.bucketEnd,
                series: .visible
            )
            accumulator.add(point)
            accumulators[point.bucketStart] = accumulator
        }

        return accumulators.values
            .map(\.point)
            .sortedByDashboardDisplayOrder()
    }

    private func combinedEfficiencyRow(
        from rows: [PerformanceDashboardEfficiencyRow]
    ) -> PerformanceDashboardEfficiencyRow {
        var accumulator = PerformanceDashboardEfficiencyAccumulator(
            bucketStart: selectedPeriod.start,
            bucketEnd: selectedPeriod.end,
            series: .visible
        )
        for row in rows {
            accumulator.add(row)
        }
        return accumulator.row
    }

    static func periodTitle(
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

    static func chartXAxisLabel(
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

    static func periodFilenameToken(
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

    static func compactSeriesTitle(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return name
        }

        if trimmed == "gpt-5.4-mini" {
            return "5.4 Mini"
        }
        if trimmed.hasPrefix("gpt-") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.hasPrefix("codex-") {
            return String(trimmed.dropFirst(6))
        }
        return trimmed
    }

    static func durationAxisUpperBound(for maximum: Double) -> Double {
        guard maximum > 0 else {
            return 1_000
        }

        let padded = maximum * 1.2
        if padded <= 1_000 {
            return ceil(padded / 100) * 100
        }
        if padded <= 60_000 {
            return ceil(padded / 5_000) * 5_000
        }
        return ceil(padded / 60_000) * 60_000
    }

    static func countAxisUpperBound(for maximum: Double) -> Double {
        guard maximum > 0 else {
            return 1
        }

        let padded = maximum * 1.2
        if padded <= 10 {
            return ceil(padded)
        }
        if padded <= 100 {
            return ceil(padded / 10) * 10
        }
        return ceil(padded / 100) * 100
    }

    static func durationFormatter(_ milliseconds: Double) -> String {
        if milliseconds < 1_000 {
            return "\(Int(milliseconds.rounded()))ms"
        }

        let seconds = milliseconds / 1_000
        if seconds < 60 {
            return String(format: seconds < 10 ? "%.1fs" : "%.0fs", seconds)
        }

        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.rounded()) % 60
        return "\(minutes)m \(remainder)s"
    }

    static func compactNumber(_ value: Double) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        }
        return integerFormatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    static func csvEscaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }

        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func csvNumber(_ value: Double?) -> String {
        guard let value else {
            return ""
        }

        return String(format: "%.0f", value)
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static func formattedDate(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

struct PerformanceDashboardReliabilityChartPoint: Identifiable, Equatable {
    let id: String
    let bucketStart: Date
    let bucketEnd: Date
    let status: PerformanceDashboardReliabilityStatus
    let count: Int

    init(
        bucketStart: Date,
        bucketEnd: Date,
        status: PerformanceDashboardReliabilityStatus,
        count: Int
    ) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.status = status
        self.count = max(count, 0)
        id = "\(Int(bucketStart.timeIntervalSince1970))-\(status.rawValue)"
    }
}

enum PerformanceDashboardReliabilityStatus: String, Equatable {
    case success
    case failure

    var displayTitle: String {
        switch self {
        case .success:
            return "Success"
        case .failure:
            return "Failure"
        }
    }
}

struct PerformanceDashboardPresentation {
    let durationPoints: [PerformanceDashboardDurationPoint]
    let reliabilityPoints: [PerformanceDashboardReliabilityPoint]
    let breakdownRows: [PerformanceDashboardBreakdownRow]
    let series: [PerformanceDashboardSeries]
}

struct PerformanceDashboardEfficiencyPresentation {
    let points: [PerformanceDashboardEfficiencyPoint]
    let rows: [PerformanceDashboardEfficiencyRow]
    let series: [PerformanceDashboardSeries]
}

enum PerformanceDashboardPresentationBuilder {
    static func build(
        timingSamples: [PerformanceDashboardTimingSample],
        reliabilitySamples: [PerformanceDashboardReliabilitySample],
        breakdownDimension: PerformanceDashboardBreakdownDimension,
        range: UsageHistoryRange,
        calendar: Calendar
    ) -> PerformanceDashboardPresentation {
        var durationAccumulators = [PerformanceDashboardBucketSeriesKey: PerformanceDashboardDurationAccumulator]()
        var reliabilityAccumulators = [PerformanceDashboardBucketSeriesKey: PerformanceDashboardReliabilityAccumulator]()
        var rowAccumulators = [String: PerformanceDashboardRowAccumulator]()

        for sample in timingSamples {
            let bucketStart = UsageHistoryRange.bucketStart(
                for: sample.eventTimestamp,
                component: range.chartBucketComponent,
                calendar: calendar
            )
            let bucketEnd = calendar.date(byAdding: range.chartBucketComponent, value: 1, to: bucketStart)
                ?? bucketStart

            for series in [
                PerformanceDashboardSeries.aggregate,
                seriesIdentity(for: sample, breakdownDimension: breakdownDimension),
            ] {
                let key = PerformanceDashboardBucketSeriesKey(bucketStart: bucketStart, seriesID: series.id)
                var bucketAccumulator = durationAccumulators[key] ?? PerformanceDashboardDurationAccumulator(
                    bucketStart: bucketStart,
                    bucketEnd: bucketEnd,
                    series: series
                )
                bucketAccumulator.add(sample)
                durationAccumulators[key] = bucketAccumulator

                var rowAccumulator = rowAccumulators[series.id] ?? PerformanceDashboardRowAccumulator(series: series)
                rowAccumulator.add(sample)
                rowAccumulators[series.id] = rowAccumulator
            }
        }

        for sample in reliabilitySamples {
            let bucketStart = UsageHistoryRange.bucketStart(
                for: sample.eventTimestamp,
                component: range.chartBucketComponent,
                calendar: calendar
            )
            let bucketEnd = calendar.date(byAdding: range.chartBucketComponent, value: 1, to: bucketStart)
                ?? bucketStart

            for series in [
                PerformanceDashboardSeries.aggregate,
                seriesIdentity(for: sample, breakdownDimension: breakdownDimension),
            ] {
                let key = PerformanceDashboardBucketSeriesKey(bucketStart: bucketStart, seriesID: series.id)
                var bucketAccumulator = reliabilityAccumulators[key] ?? PerformanceDashboardReliabilityAccumulator(
                    bucketStart: bucketStart,
                    bucketEnd: bucketEnd,
                    series: series
                )
                bucketAccumulator.add(sample)
                reliabilityAccumulators[key] = bucketAccumulator

                var rowAccumulator = rowAccumulators[series.id] ?? PerformanceDashboardRowAccumulator(series: series)
                rowAccumulator.add(sample)
                rowAccumulators[series.id] = rowAccumulator
            }
        }

        let rows = rowAccumulators.values
            .map(\.row)
            .filter { $0.turnCount > 0 || $0.eventCount > 0 }
            .sortedByDashboardSeriesOrder()

        return PerformanceDashboardPresentation(
            durationPoints: durationAccumulators.values.map(\.point).sortedByDashboardDisplayOrder(),
            reliabilityPoints: reliabilityAccumulators.values.map(\.point).sortedByDashboardDisplayOrder(),
            breakdownRows: rows,
            series: rows.map(\.series)
        )
    }

    static func buildEfficiency(
        tokenSamples: [PerformanceDashboardEfficiencyTokenSample],
        timingSamples: [PerformanceDashboardTimingSample],
        reliabilitySamples: [PerformanceDashboardReliabilitySample],
        modelCapabilities: [CodexModelCapability],
        breakdownDimension: PerformanceDashboardBreakdownDimension,
        range: UsageHistoryRange,
        calendar: Calendar
    ) -> PerformanceDashboardEfficiencyPresentation {
        var bucketAccumulators = [PerformanceDashboardBucketSeriesKey: PerformanceDashboardEfficiencyAccumulator]()
        var rowAccumulators = [String: PerformanceDashboardEfficiencyAccumulator]()
        let capabilityContextWindows = Dictionary(
            uniqueKeysWithValues: modelCapabilities.map { capability in
                (capability.slug, capability.maxContextWindow ?? capability.contextWindow)
            }.compactMap { slug, contextWindow in
                contextWindow.map { (slug, $0) }
            }
        )

        func add(to series: PerformanceDashboardSeries, at date: Date, update: (inout PerformanceDashboardEfficiencyAccumulator) -> Void) {
            let bucketStart = UsageHistoryRange.bucketStart(
                for: date,
                component: range.chartBucketComponent,
                calendar: calendar
            )
            let bucketEnd = calendar.date(byAdding: range.chartBucketComponent, value: 1, to: bucketStart)
                ?? bucketStart
            let key = PerformanceDashboardBucketSeriesKey(bucketStart: bucketStart, seriesID: series.id)
            var bucketAccumulator = bucketAccumulators[key] ?? PerformanceDashboardEfficiencyAccumulator(
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                series: series
            )
            update(&bucketAccumulator)
            bucketAccumulators[key] = bucketAccumulator

            var rowAccumulator = rowAccumulators[series.id] ?? PerformanceDashboardEfficiencyAccumulator(
                bucketStart: date,
                bucketEnd: date,
                series: series
            )
            update(&rowAccumulator)
            rowAccumulators[series.id] = rowAccumulator
        }

        for sample in tokenSamples where sample.totalTokens > 0 {
            for series in [
                PerformanceDashboardSeries.aggregate,
                seriesIdentity(for: sample, breakdownDimension: breakdownDimension),
            ] {
                add(to: series, at: sample.eventTimestamp) { accumulator in
                    accumulator.add(
                        sample,
                        contextWindow: contextWindow(
                            for: sample,
                            capabilityContextWindows: capabilityContextWindows
                        )
                    )
                }
            }
        }

        for sample in timingSamples {
            for series in [
                PerformanceDashboardSeries.aggregate,
                seriesIdentity(for: sample, breakdownDimension: breakdownDimension),
            ] {
                add(to: series, at: sample.eventTimestamp) { accumulator in
                    accumulator.add(sample)
                }
            }
        }

        for sample in reliabilitySamples {
            for series in [
                PerformanceDashboardSeries.aggregate,
                seriesIdentity(for: sample, breakdownDimension: breakdownDimension),
            ] {
                add(to: series, at: sample.eventTimestamp) { accumulator in
                    accumulator.add(sample)
                }
            }
        }

        let rows = rowAccumulators.values
            .map(\.row)
            .filter { row in
                row.totalTokens > 0 || row.turnCount > 0 || row.eventCount > 0
            }
            .sortedByDashboardSeriesOrder()

        return PerformanceDashboardEfficiencyPresentation(
            points: bucketAccumulators.values
                .map(\.point)
                .filter { point in
                    point.totalTokens > 0 || point.turnCount > 0 || point.eventCount > 0
                }
                .sortedByDashboardDisplayOrder(),
            rows: rows,
            series: rows.map(\.series)
        )
    }

    private static func seriesIdentity(
        for sample: PerformanceDashboardTimingSample,
        breakdownDimension: PerformanceDashboardBreakdownDimension
    ) -> PerformanceDashboardSeries {
        switch breakdownDimension {
        case .model:
            return contextSeries(value: sample.model, kind: .model, prefix: "model")
        case .effort:
            return contextSeries(value: sample.effort, kind: .effort, prefix: "effort")
        case .project:
            return projectSeries(path: sample.projectPath, name: sample.projectName)
        case .source:
            return contextSeries(value: sample.source, kind: .source, prefix: "source")
        case .transport:
            return .unattributed
        case .wireAPI:
            return .unattributed
        }
    }

    private static func seriesIdentity(
        for sample: PerformanceDashboardReliabilitySample,
        breakdownDimension: PerformanceDashboardBreakdownDimension
    ) -> PerformanceDashboardSeries {
        switch breakdownDimension {
        case .model:
            return contextSeries(value: sample.model, kind: .model, prefix: "model")
        case .effort:
            return contextSeries(value: sample.effort, kind: .effort, prefix: "effort")
        case .project:
            return projectSeries(path: sample.projectPath, name: sample.projectName)
        case .source:
            return contextSeries(value: sample.source, kind: .source, prefix: "source")
        case .transport:
            return contextSeries(value: sample.transport, kind: .transport, prefix: "transport")
        case .wireAPI:
            return contextSeries(value: sample.wireAPI, kind: .wireAPI, prefix: "wire-api")
        }
    }

    private static func seriesIdentity(
        for sample: PerformanceDashboardEfficiencyTokenSample,
        breakdownDimension: PerformanceDashboardBreakdownDimension
    ) -> PerformanceDashboardSeries {
        switch breakdownDimension {
        case .model:
            return contextSeries(value: sample.model, kind: .model, prefix: "model")
        case .effort:
            return contextSeries(value: sample.effort, kind: .effort, prefix: "effort")
        case .project:
            return projectSeries(path: sample.projectPath, name: sample.projectName)
        case .source:
            return contextSeries(value: sample.source, kind: .source, prefix: "source")
        case .transport, .wireAPI:
            return .unattributed
        }
    }

    private static func contextWindow(
        for sample: PerformanceDashboardEfficiencyTokenSample,
        capabilityContextWindows: [String: Int64]
    ) -> Int64? {
        if let model = CodexModelIdentifier.normalized(sample.model),
           let contextWindow = capabilityContextWindows[model],
           contextWindow > 0
        {
            return contextWindow
        }

        guard let contextWindow = sample.modelContextWindow, contextWindow > 0 else {
            return nil
        }
        return contextWindow
    }

    private static func contextSeries(
        value: String?,
        kind: PerformanceDashboardSeriesKind,
        prefix: String
    ) -> PerformanceDashboardSeries {
        guard let value, !value.isEmpty else {
            return .unattributed
        }

        return PerformanceDashboardSeries(
            id: "\(prefix):\(value)",
            name: value,
            kind: kind,
            contextID: value
        )
    }

    private static func projectSeries(path: String?, name: String?) -> PerformanceDashboardSeries {
        guard let path, !path.isEmpty else {
            return .unattributed
        }

        let displayName = name ?? URL(fileURLWithPath: path).lastPathComponent
        return PerformanceDashboardSeries(
            id: "project:\(path)",
            name: displayName.isEmpty ? path : displayName,
            kind: .project,
            contextID: path,
            projectPath: path
        )
    }
}

private struct PerformanceDashboardBucketSeriesKey: Hashable {
    let bucketStart: Date
    let seriesID: String
}

private struct PerformanceDashboardDurationAccumulator {
    let bucketStart: Date
    let bucketEnd: Date
    let series: PerformanceDashboardSeries
    var turnCount = 0
    var completedTurnCount = 0
    var incompleteTurnCount = 0
    var durationValues: [Int64] = []
    var firstTokenValues: [Int64] = []

    mutating func add(_ sample: PerformanceDashboardTimingSample) {
        turnCount += 1
        if sample.isCompleted {
            completedTurnCount += 1
        } else {
            incompleteTurnCount += 1
        }
        if let durationMilliseconds = sample.durationMilliseconds {
            durationValues.append(durationMilliseconds)
        }
        if let timeToFirstTokenMilliseconds = sample.timeToFirstTokenMilliseconds {
            firstTokenValues.append(timeToFirstTokenMilliseconds)
        }
    }

    var point: PerformanceDashboardDurationPoint {
        PerformanceDashboardDurationPoint(
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            series: series,
            turnCount: turnCount,
            completedTurnCount: completedTurnCount,
            incompleteTurnCount: incompleteTurnCount,
            durationValues: durationValues,
            firstTokenValues: firstTokenValues
        )
    }
}

private struct PerformanceDashboardReliabilityAccumulator {
    let bucketStart: Date
    let bucketEnd: Date
    let series: PerformanceDashboardSeries
    var successCount = 0
    var failureCount = 0
    var unknownCount = 0
    var errorCounts: [String: Int] = [:]

    mutating func add(_ sample: PerformanceDashboardReliabilitySample) {
        switch sample.success {
        case true:
            successCount += 1
        case false:
            failureCount += 1
            if let errorSummary = sample.errorSummary {
                errorCounts[errorSummary, default: 0] += 1
            }
        case nil:
            unknownCount += 1
        }
    }

    mutating func merge(errorCounts incomingErrorCounts: [String: Int]) {
        for (error, count) in incomingErrorCounts {
            errorCounts[error, default: 0] += count
        }
    }

    var point: PerformanceDashboardReliabilityPoint {
        PerformanceDashboardReliabilityPoint(
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            series: series,
            successCount: successCount,
            failureCount: failureCount,
            unknownCount: unknownCount,
            errorCounts: errorCounts
        )
    }
}

private struct PerformanceDashboardRowAccumulator {
    let series: PerformanceDashboardSeries
    var durationAccumulator: PerformanceDashboardDurationAccumulator?
    var reliabilityAccumulator: PerformanceDashboardReliabilityAccumulator?

    init(series: PerformanceDashboardSeries) {
        self.series = series
    }

    mutating func add(_ sample: PerformanceDashboardTimingSample) {
        if durationAccumulator == nil {
            durationAccumulator = PerformanceDashboardDurationAccumulator(
                bucketStart: sample.eventTimestamp,
                bucketEnd: sample.eventTimestamp,
                series: series
            )
        }
        durationAccumulator?.add(sample)
    }

    mutating func add(_ sample: PerformanceDashboardReliabilitySample) {
        if reliabilityAccumulator == nil {
            reliabilityAccumulator = PerformanceDashboardReliabilityAccumulator(
                bucketStart: sample.eventTimestamp,
                bucketEnd: sample.eventTimestamp,
                series: series
            )
        }
        reliabilityAccumulator?.add(sample)
    }

    var row: PerformanceDashboardBreakdownRow {
        PerformanceDashboardBreakdownRow(
            series: series,
            turnCount: durationAccumulator?.turnCount ?? 0,
            completedTurnCount: durationAccumulator?.completedTurnCount ?? 0,
            incompleteTurnCount: durationAccumulator?.incompleteTurnCount ?? 0,
            durationValues: durationAccumulator?.durationValues ?? [],
            firstTokenValues: durationAccumulator?.firstTokenValues ?? [],
            eventCount: (reliabilityAccumulator?.successCount ?? 0)
                + (reliabilityAccumulator?.failureCount ?? 0)
                + (reliabilityAccumulator?.unknownCount ?? 0),
            successCount: reliabilityAccumulator?.successCount ?? 0,
            failureCount: reliabilityAccumulator?.failureCount ?? 0,
            unknownCount: reliabilityAccumulator?.unknownCount ?? 0,
            errorCounts: reliabilityAccumulator?.errorCounts ?? [:]
        )
    }
}

private struct PerformanceDashboardEfficiencyAccumulator {
    let bucketStart: Date
    let bucketEnd: Date
    let series: PerformanceDashboardSeries
    var turnCount = 0
    var completedTurnCount = 0
    var durationValues: [Int64] = []
    var firstTokenValues: [Int64] = []
    var durationTotalMilliseconds: Int64 = 0
    var eventCount = 0
    var successCount = 0
    var failureCount = 0
    var unknownCount = 0
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var contextPressureValues: [Double] = []

    mutating func add(_ sample: PerformanceDashboardEfficiencyTokenSample, contextWindow: Int64?) {
        inputTokens += sample.inputTokens
        cachedInputTokens += sample.cachedInputTokens
        outputTokens += sample.outputTokens
        reasoningOutputTokens += sample.reasoningOutputTokens

        if let contextWindow, contextWindow > 0 {
            contextPressureValues.append(Double(sample.totalTokens) / Double(contextWindow))
        }
    }

    mutating func add(_ sample: PerformanceDashboardTimingSample) {
        turnCount += 1
        if sample.isCompleted {
            completedTurnCount += 1
        }
        if let durationMilliseconds = sample.durationMilliseconds {
            durationValues.append(durationMilliseconds)
            durationTotalMilliseconds += max(durationMilliseconds, 0)
        }
        if let timeToFirstTokenMilliseconds = sample.timeToFirstTokenMilliseconds {
            firstTokenValues.append(timeToFirstTokenMilliseconds)
        }
    }

    mutating func add(_ sample: PerformanceDashboardReliabilitySample) {
        eventCount += 1
        switch sample.success {
        case true:
            successCount += 1
        case false:
            failureCount += 1
        case nil:
            unknownCount += 1
        }
    }

    mutating func add(_ point: PerformanceDashboardEfficiencyPoint) {
        turnCount += point.turnCount
        completedTurnCount += point.completedTurnCount
        durationValues += point.durationValues
        firstTokenValues += point.firstTokenValues
        durationTotalMilliseconds += point.durationTotalMilliseconds
        eventCount += point.eventCount
        successCount += point.successCount
        failureCount += point.failureCount
        unknownCount += point.unknownCount
        inputTokens += point.inputTokens
        cachedInputTokens += point.cachedInputTokens
        outputTokens += point.outputTokens
        reasoningOutputTokens += point.reasoningOutputTokens
        contextPressureValues += point.contextPressureValues
    }

    mutating func add(_ row: PerformanceDashboardEfficiencyRow) {
        turnCount += row.turnCount
        completedTurnCount += row.completedTurnCount
        durationValues += row.durationValues
        firstTokenValues += row.firstTokenValues
        durationTotalMilliseconds += row.durationTotalMilliseconds
        eventCount += row.eventCount
        successCount += row.successCount
        failureCount += row.failureCount
        unknownCount += row.unknownCount
        inputTokens += row.inputTokens
        cachedInputTokens += row.cachedInputTokens
        outputTokens += row.outputTokens
        reasoningOutputTokens += row.reasoningOutputTokens
        contextPressureValues += row.contextPressureValues
    }

    var point: PerformanceDashboardEfficiencyPoint {
        PerformanceDashboardEfficiencyPoint(
            bucketStart: bucketStart,
            bucketEnd: bucketEnd,
            series: series,
            turnCount: turnCount,
            completedTurnCount: completedTurnCount,
            durationValues: durationValues,
            firstTokenValues: firstTokenValues,
            durationTotalMilliseconds: durationTotalMilliseconds,
            eventCount: eventCount,
            successCount: successCount,
            failureCount: failureCount,
            unknownCount: unknownCount,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            contextPressureValues: contextPressureValues
        )
    }

    var row: PerformanceDashboardEfficiencyRow {
        PerformanceDashboardEfficiencyRow(
            series: series,
            turnCount: turnCount,
            completedTurnCount: completedTurnCount,
            durationValues: durationValues,
            firstTokenValues: firstTokenValues,
            durationTotalMilliseconds: durationTotalMilliseconds,
            eventCount: eventCount,
            successCount: successCount,
            failureCount: failureCount,
            unknownCount: unknownCount,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            contextPressureValues: contextPressureValues
        )
    }
}

private extension PerformanceDashboardSeries {
    static let aggregate = PerformanceDashboardSeries(
        id: PerformanceDashboardSeries.aggregateID,
        name: "All",
        kind: .aggregate,
        contextID: "all"
    )

    static let visible = PerformanceDashboardSeries(
        id: "performance_visible",
        name: "Visible",
        kind: .aggregate,
        contextID: "visible"
    )

    static let unattributed = PerformanceDashboardSeries(
        id: PerformanceDashboardSeries.unattributedID,
        name: "Unattributed",
        kind: .unattributed,
        contextID: "unattributed"
    )
}

private extension Array where Element == PerformanceDashboardDurationPoint {
    func sortedByDashboardDisplayOrder() -> [PerformanceDashboardDurationPoint] {
        sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }
            return lhs.series.id.localizedStandardCompare(rhs.series.id) == .orderedAscending
        }
    }
}

private extension Array where Element == PerformanceDashboardReliabilityPoint {
    func sortedByDashboardDisplayOrder() -> [PerformanceDashboardReliabilityPoint] {
        sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }
            return lhs.series.id.localizedStandardCompare(rhs.series.id) == .orderedAscending
        }
    }
}

private extension Array where Element == PerformanceDashboardEfficiencyPoint {
    func sortedByDashboardDisplayOrder() -> [PerformanceDashboardEfficiencyPoint] {
        sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }
            return lhs.series.id.localizedStandardCompare(rhs.series.id) == .orderedAscending
        }
    }
}

private extension Array where Element == PerformanceDashboardBreakdownRow {
    func sortedByDashboardSeriesOrder() -> [PerformanceDashboardBreakdownRow] {
        sorted { lhs, rhs in
            if lhs.series.kind == .aggregate, rhs.series.kind != .aggregate {
                return true
            }
            if lhs.series.kind != .aggregate, rhs.series.kind == .aggregate {
                return false
            }
            if lhs.series.kind != .unattributed, rhs.series.kind == .unattributed {
                return true
            }
            if lhs.series.kind == .unattributed, rhs.series.kind != .unattributed {
                return false
            }
            if lhs.turnCount != rhs.turnCount {
                return lhs.turnCount > rhs.turnCount
            }
            if lhs.eventCount != rhs.eventCount {
                return lhs.eventCount > rhs.eventCount
            }
            return lhs.series.name.localizedStandardCompare(rhs.series.name) == .orderedAscending
        }
    }
}

private extension Array where Element == PerformanceDashboardEfficiencyRow {
    func sortedByDashboardSeriesOrder() -> [PerformanceDashboardEfficiencyRow] {
        sorted { lhs, rhs in
            if lhs.series.kind == .aggregate, rhs.series.kind != .aggregate {
                return true
            }
            if lhs.series.kind != .aggregate, rhs.series.kind == .aggregate {
                return false
            }
            if lhs.series.kind != .unattributed, rhs.series.kind == .unattributed {
                return true
            }
            if lhs.series.kind == .unattributed, rhs.series.kind != .unattributed {
                return false
            }
            if lhs.totalTokens != rhs.totalTokens {
                return lhs.totalTokens > rhs.totalTokens
            }
            if lhs.turnCount != rhs.turnCount {
                return lhs.turnCount > rhs.turnCount
            }
            return lhs.series.name.localizedStandardCompare(rhs.series.name) == .orderedAscending
        }
    }
}

struct PerformanceDashboardView: View {
    @StateObject private var viewModel: PerformanceDashboardViewModel

    init(database: UsageHistoryDatabaseWorking) {
        _viewModel = StateObject(wrappedValue: PerformanceDashboardViewModel(database: database))
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            summaryTiles
            content
        }
        .padding(16)
        .frame(minWidth: 1120, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 20) {
            Picker("Range", selection: $viewModel.selectedRange) {
                ForEach(UsageHistoryRange.allCases) { range in
                    Text(range.displayTitle).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)

            Picker("View", selection: $viewModel.selectedMode) {
                ForEach(PerformanceDashboardMode.allCases) { mode in
                    Text(mode.displayTitle).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)

            Picker("Breakdown", selection: $viewModel.selectedBreakdownDimension) {
                ForEach(viewModel.availableBreakdownDimensions) { dimension in
                    Text(dimension.displayTitle).tag(dimension)
                }
            }
            .labelsHidden()
            .frame(width: 240)

            Spacer()

            PerformanceDashboardPeriodNavigationView(
                title: viewModel.periodTitle,
                canGoToPrevious: viewModel.canGoToPreviousPeriod,
                canGoToNext: viewModel.canGoToNextPeriod,
                canJumpToCurrent: viewModel.canJumpToCurrentPeriod,
                previousHelpText: viewModel.previousPeriodHelpText,
                nextHelpText: viewModel.nextPeriodHelpText,
                currentHelpText: viewModel.currentPeriodHelpText,
                onPrevious: viewModel.goToPreviousPeriod,
                onNext: viewModel.goToNextPeriod,
                onCurrent: viewModel.jumpToCurrentPeriod
            )

            Spacer()

            Button {
                viewModel.exportCSV()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.bordered)
            .help("Export CSV")
        }
    }

    private var summaryTiles: some View {
        HStack(spacing: 14) {
            ForEach(viewModel.summaryTiles) { tile in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(viewModel.color(for: tile))
                            .frame(width: 9, height: 9)

                        Text(tile.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Text(tile.value)
                        .font(.system(size: 21, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView(
                "Could not load performance data",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.hasVisibleData {
            ContentUnavailableView(
                viewModel.emptyState.title,
                systemImage: viewModel.emptyState.systemImage,
                description: Text(viewModel.emptyState.message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            HStack(alignment: .top, spacing: 18) {
                if viewModel.selectedMode == .performance {
                    charts
                        .frame(minWidth: 540)

                    breakdownTable
                        .frame(minWidth: 520, maxWidth: 720)
                } else {
                    efficiencyCharts
                        .frame(minWidth: 540)

                    efficiencyTable
                        .frame(minWidth: 620, maxWidth: 820)
                }
            }
        }
    }

    private var charts: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    chartLegend(color: .blue, title: "Median")
                    chartLegend(color: .orange, title: "P95")
                    Spacer()
                }

                Chart {
                    ForEach(viewModel.visibleDurationPoints) { point in
                        if let median = point.medianDurationMilliseconds {
                            LineMark(
                                x: .value("Time", viewModel.chartXPosition(for: point)),
                                y: .value("Median", median),
                                series: .value("Metric", "Median")
                            )
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                            .symbol(Circle())
                        }

                        if let p95 = point.p95DurationMilliseconds {
                            LineMark(
                                x: .value("Time", viewModel.chartXPosition(for: point)),
                                y: .value("P95", p95),
                                series: .value("Metric", "P95")
                            )
                            .foregroundStyle(.orange)
                            .interpolationMethod(.monotone)
                            .symbol(Circle())
                        }
                    }
                }
                .chartXScale(domain: viewModel.chartDomainStart...viewModel.chartDomainEnd)
                .chartYScale(domain: viewModel.durationYDomain)
                .chartXAxis {
                    AxisMarks(values: viewModel.chartXAxisLabelValues) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary.opacity(0.35))
                        AxisTick()
                            .foregroundStyle(.secondary.opacity(0.45))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(viewModel.chartXAxisLabel(for: date))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                            .foregroundStyle(.secondary.opacity(0.35))
                        AxisValueLabel {
                            if let doubleValue = value.as(Double.self) {
                                Text(viewModel.formattedDurationAxisValue(doubleValue))
                            }
                        }
                    }
                }
                .frame(minHeight: 280)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    chartLegend(color: .green, title: "Success")
                    chartLegend(color: .red, title: "Failure")
                    Spacer()
                }

                Chart {
                    ForEach(viewModel.reliabilityChartPoints) { point in
                        BarMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value("Events", point.count),
                            stacking: .standard
                        )
                        .foregroundStyle(viewModel.color(for: point.status))
                    }
                }
                .chartXScale(domain: viewModel.chartDomainStart...viewModel.chartDomainEnd)
                .chartYScale(domain: viewModel.reliabilityYDomain)
                .chartXAxis {
                    AxisMarks(values: viewModel.chartXAxisLabelValues) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary.opacity(0.35))
                        AxisTick()
                            .foregroundStyle(.secondary.opacity(0.45))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(viewModel.chartXAxisLabel(for: date))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                            .foregroundStyle(.secondary.opacity(0.35))
                        AxisValueLabel {
                            if let doubleValue = value.as(Double.self) {
                                Text(viewModel.formattedCountAxisValue(doubleValue))
                            }
                        }
                    }
                }
                .frame(height: 210)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func chartLegend(color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var efficiencyCharts: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    chartLegend(color: .blue, title: "Tokens/min")
                    Spacer()
                }

                Chart {
                    ForEach(viewModel.visibleEfficiencyPoints) { point in
                        if let tokensPerMinute = point.tokensPerMinute {
                            BarMark(
                                x: .value("Time", viewModel.chartXPosition(for: point)),
                                y: .value("Tokens/min", tokensPerMinute)
                            )
                            .foregroundStyle(.blue)
                        }
                    }
                }
                .chartXScale(domain: viewModel.chartDomainStart...viewModel.chartDomainEnd)
                .chartYScale(domain: viewModel.efficiencyYDomain)
                .chartXAxis {
                    AxisMarks(values: viewModel.chartXAxisLabelValues) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary.opacity(0.35))
                        AxisTick()
                            .foregroundStyle(.secondary.opacity(0.45))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(viewModel.chartXAxisLabel(for: date))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                            .foregroundStyle(.secondary.opacity(0.35))
                        AxisValueLabel {
                            if let doubleValue = value.as(Double.self) {
                                Text(viewModel.formattedCountAxisValue(doubleValue))
                            }
                        }
                    }
                }
                .frame(minHeight: 520)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var breakdownTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Breakdown")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    sortableHeader(viewModel.breakdownColumnTitle, column: .title)
                        .frame(minWidth: 150, alignment: .leading)
                    sortableHeader("Turns", column: .turns)
                    sortableHeader("Median", column: .medianDuration)
                    sortableHeader("P95", column: .p95Duration)
                    sortableHeader("First", column: .medianFirstToken)
                    sortableHeader("Events", column: .events)
                    sortableHeader("Fail %", column: .failurePercent)
                    sortableHeader("Top error", column: .topError)
                        .frame(minWidth: 110, alignment: .leading)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellColumns(8)

                ForEach(viewModel.sortedBreakdownRows) { row in
                    GridRow {
                        Button {
                            viewModel.selectSeries(row.series.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: viewModel.isSelected(row.series) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(viewModel.isSelected(row.series) ? .primary : .secondary)
                                    .frame(width: 14)

                                Text(viewModel.compactSeriesTitle(row.series.name))
                                    .lineLimit(1)
                                    .help(row.series.projectPath ?? row.series.name)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 150, alignment: .leading)

                        Text(viewModel.formattedInteger(row.turnCount))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedDuration(row.medianDurationMilliseconds))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedDuration(row.p95DurationMilliseconds))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedDuration(row.medianFirstTokenMilliseconds))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedInteger(row.eventCount))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedPercent(row.failurePercent))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(row.topErrorSummary ?? "—")
                            .foregroundStyle(row.topErrorSummary == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .help(row.topErrorSummary ?? "")
                            .frame(minWidth: 110, alignment: .leading)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sortableHeader(_ title: String, column: PerformanceDashboardBreakdownSortColumn) -> some View {
        Button {
            viewModel.sortBreakdownRows(by: column)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if let imageName = viewModel.breakdownSortIndicator(for: column) {
                    Image(systemName: imageName)
                        .font(.caption2.weight(.semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: column == .title || column == .topError ? .leading : .trailing)
    }

    private var efficiencyTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Breakdown")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 10) {
                GridRow {
                    sortableEfficiencyHeader(viewModel.breakdownColumnTitle, column: .title)
                        .frame(minWidth: 145, alignment: .leading)
                    sortableEfficiencyHeader("Turns", column: .turns)
                    sortableEfficiencyHeader("Tokens", column: .tokens)
                    sortableEfficiencyHeader("Tok/min", column: .tokensPerMinute)
                    sortableEfficiencyHeader("Out/min", column: .outputTokensPerMinute)
                    sortableEfficiencyHeader("Cache %", column: .cacheShare)
                    sortableEfficiencyHeader("Reason %", column: .reasoningShare)
                    sortableEfficiencyHeader("Median", column: .medianDuration)
                    sortableEfficiencyHeader("Fail %", column: .failurePercent)
                    sortableEfficiencyHeader("Context %", column: .contextPressure)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellColumns(10)

                ForEach(viewModel.sortedEfficiencyRows) { row in
                    GridRow {
                        Button {
                            viewModel.selectSeries(row.series.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: viewModel.isSelected(row.series) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(viewModel.isSelected(row.series) ? .primary : .secondary)
                                    .frame(width: 14)

                                Text(viewModel.compactSeriesTitle(row.series.name))
                                    .lineLimit(1)
                                    .help(row.series.projectPath ?? row.series.name)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 145, alignment: .leading)

                        Text(viewModel.formattedInteger(row.turnCount))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedTokenCount(row.totalTokens))
                            .fontWeight(row.series.kind == .aggregate ? .semibold : .regular)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedRate(row.tokensPerMinute))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedRate(row.outputTokensPerMinute))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedPercent(row.cacheShare))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedPercent(row.reasoningShare))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedDuration(row.medianDurationMilliseconds))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedPercent(row.failurePercent))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(viewModel.formattedOptionalPercent(row.contextPressure))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sortableEfficiencyHeader(
        _ title: String,
        column: PerformanceDashboardEfficiencySortColumn
    ) -> some View {
        Button {
            viewModel.sortEfficiencyRows(by: column)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if let imageName = viewModel.efficiencySortIndicator(for: column) {
                    Image(systemName: imageName)
                        .font(.caption2.weight(.semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: column == .title ? .leading : .trailing)
    }
}

private struct PerformanceDashboardPeriodNavigationView: View {
    let title: String
    let canGoToPrevious: Bool
    let canGoToNext: Bool
    let canJumpToCurrent: Bool
    let previousHelpText: String
    let nextHelpText: String
    let currentHelpText: String
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onCurrent: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!canGoToPrevious)
            .help(previousHelpText)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(minWidth: 140, alignment: .center)

            Button(action: onCurrent) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!canJumpToCurrent)
            .help(currentHelpText)

            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!canGoToNext)
            .help(nextHelpText)
        }
    }
}
