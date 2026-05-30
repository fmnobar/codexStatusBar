@preconcurrency import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum UsageHistoryChartSemantics: Equatable {
    case independentSignals
    case comparableContributors
}

struct UsageHistoryHoverSelection: Equatable {
    let bucketStart: Date
    let bucketEnd: Date
    let points: [UsageHistoryChartPoint]
    let xPosition: CGFloat
}

struct UsageHistoryHoverBucket: Equatable {
    let bucketStart: Date
    let bucketEnd: Date
    let xDate: Date
    let points: [UsageHistoryChartPoint]
}

struct UsageHistoryHoverIndex: Equatable {
    static let empty = UsageHistoryHoverIndex(buckets: [])

    let buckets: [UsageHistoryHoverBucket]

    var isEmpty: Bool {
        buckets.isEmpty
    }

    func selection(nearestTo timestamp: Date, xPosition: CGFloat) -> UsageHistoryHoverSelection? {
        guard let bucket = nearestBucket(to: timestamp), !bucket.points.isEmpty else {
            return nil
        }

        return UsageHistoryHoverSelection(
            bucketStart: bucket.bucketStart,
            bucketEnd: bucket.bucketEnd,
            points: bucket.points,
            xPosition: xPosition
        )
    }

    private func nearestBucket(to timestamp: Date) -> UsageHistoryHoverBucket? {
        guard !buckets.isEmpty else {
            return nil
        }

        var lowerBound = 0
        var upperBound = buckets.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if buckets[midpoint].xDate < timestamp {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        if lowerBound == 0 {
            return buckets[0]
        }

        if lowerBound == buckets.count {
            return buckets[buckets.count - 1]
        }

        let previous = buckets[lowerBound - 1]
        let next = buckets[lowerBound]
        let previousDistance = abs(previous.xDate.timeIntervalSince(timestamp))
        let nextDistance = abs(next.xDate.timeIntervalSince(timestamp))
        if previousDistance == nextDistance {
            return previous.bucketStart <= next.bucketStart ? previous : next
        }

        return previousDistance < nextDistance ? previous : next
    }
}

enum UsageHistoryEmptyStateKind: Equatable {
    case loading
    case noHistory
    case noDataForSelection
    case hiddenSeries
    case loadFailed
}

struct UsageHistoryEmptyStatePresentation: Equatable {
    let kind: UsageHistoryEmptyStateKind
    let systemImage: String
    let title: String
    let message: String
}

@MainActor
final class UsageHistoryViewModel: ObservableObject {
    typealias RecentTokenHistoryImporter = UsageHistoryDatabaseWorker.RecentTokenHistoryImporter

    static let liveRecentTokenHistoryImporter: RecentTokenHistoryImporter = { store, date, calendar, force in
        store.captureLiveCodexLogTokenHistory(at: date, calendar: calendar, force: force)
    }

    @Published var selectedRange: UsageHistoryRange = .month {
        didSet {
            followsCurrentPeriod = true
            selectedPeriodStart = currentPeriodStart()
            refreshChartCachesForPendingReload()
            scheduleReload()
        }
    }
    @Published var selectedWindow: UsageLimitWindow = .sevenDay {
        didSet {
            refreshChartCachesForPendingReload()
            scheduleReload()
        }
    }
    @Published var selectedChartKind: UsageHistoryChartKind = .capacity {
        didSet {
            switch selectedChartKind {
            case .capacity:
                selectedMetric = .capacityLeft
            case .usage:
                selectedMetric = .usage
            case .tokens:
                break
            }
            refreshChartCachesForPendingReload()
            scheduleReload()
            clearHoverSelectionAndCancelPendingWork()
        }
    }
    @Published var selectedTokenCategory: TokenHistoryCategory = .total {
        didSet {
            scheduleClearHoverSelection()
        }
    }
    @Published var selectedMetric: UsageHistoryMetric = .capacityLeft {
        didSet {
            if selectedChartKind != .tokens {
                let chartKind = UsageHistoryChartKind(metric: selectedMetric)
                if selectedChartKind != chartKind {
                    selectedChartKind = chartKind
                }
            }
            scheduleClearHoverSelection()
        }
    }
    @Published var seriesSearchText = ""
    @Published private(set) var points: [UsageHistoryPoint] = []
    @Published private(set) var tokenPoints: [TokenHistoryPoint] = []
    @Published private(set) var tokenComponentPoints: [TokenHistoryComponentPoint] = []
    @Published private(set) var tokenComponentBucketPoints: [TokenHistoryComponentBucketPoint] = []
    @Published private(set) var series: [UsageHistorySeries] = []
    @Published private(set) var selectedSeriesIDs = Set<String>()
    @Published private(set) var errorMessage: String?
    @Published private(set) var hoverSelection: UsageHistoryHoverSelection?
    @Published private(set) var hasAnyRecordedHistory = false
    @Published private(set) var isLoadingHistory = true
    @Published private(set) var selectedPeriodStart = Date(timeIntervalSince1970: 0) {
        didSet {
            refreshChartCachesForPendingReload()
            scheduleReload()
        }
    }
    let chartSemantics: UsageHistoryChartSemantics

    private let database: UsageHistoryDatabaseWorking
    private let performanceInstrumentationStore: AppPerformanceInstrumentationStore?
    private let now: () -> Date
    private let calendar: Calendar
    private var historyBounds: UsageHistoryBounds?
    private var userEditedSeriesSelection = false
    private var followsCurrentPeriod = true
    private var historyObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var hoverSelectionWorkItem: DispatchWorkItem?
    private var cachedChartPoints: [UsageHistoryChartPoint] = []
    private var cachedVisibleChartPoints: [UsageHistoryChartPoint] = []
    private var cachedVisibleBarPoints: [UsageHistoryChartPoint] = []
    private var cachedVisibleContributorPoints: [UsageHistoryChartPoint] = []
    private var cachedVisibleAggregateReferencePoints: [UsageHistoryChartPoint] = []
    private var cachedTokenDetailPoints: [UsageHistoryChartPoint] = []
    private var hoverIndex = UsageHistoryHoverIndex.empty
    private var hoverCacheVersion = 0

    init(
        database: UsageHistoryDatabaseWorking,
        chartSemantics: UsageHistoryChartSemantics = .independentSignals,
        performanceInstrumentationStore: AppPerformanceInstrumentationStore? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.database = database
        self.performanceInstrumentationStore = performanceInstrumentationStore
        self.chartSemantics = chartSemantics
        self.now = now
        self.calendar = calendar
        selectedPeriodStart = selectedRange.period(containing: now(), calendar: calendar).start
        historyObserver = NotificationCenter.default.addObserver(
            forName: UsageHistoryStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleReload()
            }
        }
    }

    convenience init(
        store: UsageHistoryStore,
        chartSemantics: UsageHistoryChartSemantics = .independentSignals,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = { _, _, _, _ in CodexLiveTokenCaptureState(status: .noNewEvents) }
    ) {
        self.init(
            database: UsageHistoryDatabaseWorker(
                store: store,
                recentTokenHistoryImporter: recentTokenHistoryImporter
            ),
            chartSemantics: chartSemantics,
            performanceInstrumentationStore: nil,
            now: now,
            calendar: calendar
        )
    }

    deinit {
        reloadTask?.cancel()
        hoverSelectionWorkItem?.cancel()
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    var visiblePoints: [UsageHistoryPoint] {
        points.filter { selectedSeriesIDs.contains($0.bucketID) }
    }

    var visibleTokenPoints: [TokenHistoryPoint] {
        tokenPoints.filter { selectedSeriesIDs.contains($0.seriesID) }
    }

    var chartPoints: [UsageHistoryChartPoint] {
        cachedChartPoints
    }

    var visibleChartPoints: [UsageHistoryChartPoint] {
        cachedVisibleChartPoints
    }

    var hasVisiblePoints: Bool {
        !visibleChartPoints.isEmpty
    }

    var canExport: Bool {
        hasVisiblePoints
    }

    var chartSubtitle: String {
        switch selectedChartKind {
        case .capacity, .usage:
            return selectedMetric.subtitle(for: selectedRange)
        case .tokens:
            return "Tokens by \(selectedRange.chartBucketTitle)"
        }
    }

    var chartYAxisTitle: String {
        switch selectedChartKind {
        case .capacity, .usage:
            return selectedMetric.axisTitle
        case .tokens:
            return "Tokens"
        }
    }

    var chartYDomain: ClosedRange<Double> {
        switch selectedChartKind {
        case .capacity:
            return 0...100
        case .usage:
            let hasHighUsage = visibleChartPoints.contains { point in
                chartValue(for: point) > 50
            }
            return hasHighUsage ? 0...100 : 0...50
        case .tokens:
            let maximumValue = Self.maximumTokenStackValue(in: visibleBarPoints)
            return 0...Self.tokenAxisUpperBound(for: maximumValue)
        }
    }

    var chartValueLabel: String {
        selectedChartKind.displayTitle
    }

    var selectedPeriod: UsageHistoryPeriod {
        period(startingAt: selectedPeriodStart)
    }

    var periodTitle: String {
        Self.periodTitle(for: selectedRange, period: selectedPeriod, calendar: calendar)
    }

    var compactPeriodTitle: String {
        Self.compactPeriodTitle(for: selectedRange, period: selectedPeriod, calendar: calendar)
    }

    var isCurrentPeriod: Bool {
        selectedPeriodStart == currentPeriodStart()
    }

    var canJumpToCurrentPeriod: Bool {
        !isCurrentPeriod
    }

    var canGoToPreviousPeriod: Bool {
        guard let historyBounds else {
            return false
        }

        let earliestPeriodStart = selectedRange.period(containing: historyBounds.earliest, calendar: calendar).start
        let previousPeriodStart = periodOffset(from: selectedPeriodStart, value: -1)
        return previousPeriodStart >= earliestPeriodStart
    }

    var canGoToNextPeriod: Bool {
        selectedPeriodStart < currentPeriodStart()
    }

    var previousPeriodHelpText: String {
        if canGoToPreviousPeriod {
            return "Show previous \(periodDisplayNoun)"
        }

        if selectedChartKind == .tokens {
            return "No earlier token history"
        }

        return "No earlier history for this limit"
    }

    var previousPeriodAccessibilityLabel: String {
        if canGoToPreviousPeriod {
            return "Previous \(selectedRange.displayTitle)"
        }

        return previousPeriodHelpText
    }

    var nextPeriodHelpText: String {
        if canGoToNextPeriod {
            return "Show next \(periodDisplayNoun)"
        }

        return "Already showing the current \(periodDisplayNoun)"
    }

    var nextPeriodAccessibilityLabel: String {
        if canGoToNextPeriod {
            return "Next \(selectedRange.displayTitle)"
        }

        return nextPeriodHelpText
    }

    var currentPeriodHelpText: String {
        if canJumpToCurrentPeriod {
            return "Jump to current \(periodDisplayNoun)"
        }

        return "Already showing the current \(periodDisplayNoun)"
    }

    var currentPeriodAccessibilityLabel: String {
        currentPeriodHelpText
    }

    var exportFilename: String {
        if selectedChartKind == .tokens {
            return [
                "codex-usage",
                selectedChartKind.filenameToken,
                selectedRange.rawValue,
                periodFilenameToken
            ].joined(separator: "-") + ".csv"
        }

        return [
            "codex-usage",
            selectedRange.rawValue,
            periodFilenameToken,
            selectedWindow.filenameToken,
            selectedMetric.filenameToken,
        ].joined(separator: "-") + ".csv"
    }

    var chartXAxisLabelValues: [Date] {
        chartXAxisLabelBucketStarts().map { bucketStart in
            chartXPosition(forBucketStart: bucketStart)
        }
    }

    var chartDomainStart: Date {
        selectedPeriod.start.addingTimeInterval(-chartDomainBucketPadding)
    }

    var chartDomainEnd: Date {
        selectedPeriod.end.addingTimeInterval(chartDomainBucketPadding)
    }

    var visibleBarPoints: [UsageHistoryChartPoint] {
        cachedVisibleBarPoints
    }

    var visibleContributorPoints: [UsageHistoryChartPoint] {
        cachedVisibleContributorPoints
    }

    var visibleAggregateReferencePoints: [UsageHistoryChartPoint] {
        cachedVisibleAggregateReferencePoints
    }

    var tokenDetailPoints: [UsageHistoryChartPoint] {
        cachedTokenDetailPoints
    }

    var sortedSeries: [UsageHistorySeries] {
        series.sortedByDisplayOrder()
    }

    var filteredSeries: [UsageHistorySeries] {
        let query = seriesSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return sortedSeries
        }

        return sortedSeries.filter { series in
            series.kind == .aggregate || series.name.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedSeriesCount: Int {
        series.filter { selectedSeriesIDs.contains($0.id) }.count
    }

    var seriesSelectionSummary: String {
        "\(selectedSeriesCount) of \(series.count) selected"
    }

    var chartPointCountSummary: String {
        if selectedChartKind == .tokens {
            let stackedBarCount = Set(visibleChartPoints.map { point in
                "\(Int(point.bucketStart.timeIntervalSince1970))-\(point.bucketID)"
            }).count
            return "\(stackedBarCount) bars"
        }

        return "\(visibleChartPoints.count) bars"
    }

    var hasSelectedModels: Bool {
        series.contains { $0.kind == .model && selectedSeriesIDs.contains($0.id) }
    }

    var emptyStatePresentation: UsageHistoryEmptyStatePresentation {
        if isLoadingHistory && !hasVisiblePoints {
            return UsageHistoryEmptyStatePresentation(
                kind: .loading,
                systemImage: "clock.arrow.circlepath",
                title: "Loading history",
                message: "Reading local usage samples."
            )
        }

        if errorMessage != nil && !hasVisiblePoints {
            return UsageHistoryEmptyStatePresentation(
                kind: .loadFailed,
                systemImage: "exclamationmark.triangle",
                title: "History unavailable",
                message: "Try refreshing Codex Status Bar."
            )
        }

        if hasHistory && !hasVisiblePoints {
            return UsageHistoryEmptyStatePresentation(
                kind: .hiddenSeries,
                systemImage: "eye.slash",
                title: "No visible series",
                message: "Select at least one bucket to show it on the chart."
            )
        }

        if !hasAnyRecordedHistory {
            return UsageHistoryEmptyStatePresentation(
                kind: .noHistory,
                systemImage: "chart.xyaxis.line",
                title: "No history yet",
                message: "Usage samples will appear after Codex Status Bar refreshes."
            )
        }

        return UsageHistoryEmptyStatePresentation(
            kind: .noDataForSelection,
            systemImage: "calendar.badge.clock",
            title: noDataTitle,
            message: noDataMessage
        )
    }

    private var noDataTitle: String {
        switch selectedChartKind {
        case .capacity, .usage:
            return "No \(selectedWindow.displayTitle) data for \(selectedRange.displayTitle)"
        case .tokens:
            return "No token data for \(selectedRange.displayTitle)"
        }
    }

    private var noDataMessage: String {
        switch selectedChartKind {
        case .capacity, .usage:
            return "Choose a different range or limit window to inspect recorded samples."
        case .tokens:
            return "Choose a different range to inspect local captured tokens."
        }
    }

    var hasHistory: Bool {
        switch selectedChartKind {
        case .capacity, .usage:
            return !points.isEmpty
        case .tokens:
            return !tokenComponentBucketPoints.isEmpty
        }
    }

    @discardableResult
    func reload() async -> Bool {
        reloadTask?.cancel()
        reloadTask = nil
        return await performReload()
    }

    @discardableResult
    private func performReload() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }

        syncCurrentPeriodIfNeeded()
        let generation = nextReloadGeneration()
        isLoadingHistory = true
        let queryPeriod = periodForQuery()
        let request = UsageHistoryLoadRequest(
            chartKind: selectedChartKind,
            range: selectedRange,
            window: selectedWindow,
            periodStart: queryPeriod.start,
            periodEnd: queryPeriod.end,
            now: now(),
            calendar: calendar
        )
        let instrumentationSpan = performanceInstrumentationStore?.begin(
            .historyReload,
            metadata: [
                "surface": "history",
                "range": selectedRange.rawValue,
                "chartKind": selectedChartKind.rawValue,
                "window": selectedWindow.rawValue,
            ]
        )

        do {
            let result = try await database.usageHistorySnapshot(for: request)
            guard generation == reloadGeneration, !Task.isCancelled else {
                return false
            }

            points = result.points
            tokenPoints = result.tokenPoints
            tokenComponentPoints = result.tokenComponentPoints
            tokenComponentBucketPoints = result.tokenComponentBucketPoints
            series = result.series
            hasAnyRecordedHistory = result.hasAnyHistory
            isLoadingHistory = false
            historyBounds = result.historyBounds
            reconcileSelectedSeries()
            rebuildChartCaches()
            clearHoverSelectionAndCancelPendingWork()
            errorMessage = nil
            performanceInstrumentationStore?.finish(
                instrumentationSpan,
                status: hasHistory ? .success : .noData,
                metadata: [
                    "rowCount": "\(points.count + tokenComponentBucketPoints.count)",
                    "seriesCount": "\(series.count)",
                ]
            )
            return true
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else {
                return false
            }

            points = []
            tokenPoints = []
            tokenComponentPoints = []
            tokenComponentBucketPoints = []
            series = []
            selectedSeriesIDs = []
            hasAnyRecordedHistory = false
            isLoadingHistory = false
            historyBounds = nil
            rebuildChartCaches()
            clearHoverSelectionAndCancelPendingWork()
            errorMessage = "History could not be loaded."
            performanceInstrumentationStore?.finish(instrumentationSpan, status: .failed)
            return false
        }
    }

    func scheduleReload() {
        isLoadingHistory = true
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.performReload()
        }
    }

    private func nextReloadGeneration() -> Int {
        reloadGeneration += 1
        return reloadGeneration
    }

    func activateCurrentPeriod() {
        followsCurrentPeriod = true
        if !syncCurrentPeriodIfNeeded() {
            scheduleReload()
        }
    }

    func binding(for series: UsageHistorySeries) -> Binding<Bool> {
        Binding(
            get: { self.selectedSeriesIDs.contains(series.id) },
            set: { isSelected in
                self.setSeries(series.id, isSelected: isSelected)
            }
        )
    }

    func setSeries(_ seriesID: String, isSelected: Bool) {
        guard let targetSeries = series.first(where: { $0.id == seriesID }) else {
            return
        }

        if !isSelected, isPinnedSeries(targetSeries) {
            selectedSeriesIDs.insert(targetSeries.id)
            return
        }

        userEditedSeriesSelection = true
        if isSelected {
            selectedSeriesIDs.insert(targetSeries.id)
        } else {
            selectedSeriesIDs.remove(targetSeries.id)
        }
        rebuildChartCaches()
        clearHoverSelectionAndCancelPendingWork()
    }

    func isPinnedSeries(_ series: UsageHistorySeries) -> Bool {
        series.kind == .aggregate
    }

    func isDefaultHiddenSeries(_ series: UsageHistorySeries) -> Bool {
        Self.isHiddenByDefault(series)
    }

    func selectAllSeries() {
        selectedSeriesIDs = Set(series.map(\.id))
        userEditedSeriesSelection = true
        rebuildChartCaches()
        clearHoverSelectionAndCancelPendingWork()
    }

    func clearModelSeries() {
        selectedSeriesIDs = Set(series.filter { $0.kind == .aggregate }.map(\.id))
        userEditedSeriesSelection = true
        rebuildChartCaches()
        clearHoverSelectionAndCancelPendingWork()
    }

    func updateHoverSelection(nearestTo timestamp: Date, xPosition: CGFloat) {
        guard let selection = hoverIndex.selection(nearestTo: timestamp, xPosition: xPosition) else {
            clearHoverSelection()
            return
        }

        hoverSelection = selection
    }

    func clearHoverSelection() {
        hoverSelection = nil
    }

    func scheduleHoverSelection(nearestTo timestamp: Date, xPosition: CGFloat) {
        hoverSelectionWorkItem?.cancel()
        let cacheVersion = hoverCacheVersion
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.hoverCacheVersion == cacheVersion else {
                return
            }
            self.updateHoverSelection(nearestTo: timestamp, xPosition: xPosition)
        }
        hoverSelectionWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func scheduleClearHoverSelection() {
        hoverSelectionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearHoverSelection()
        }
        hoverSelectionWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func goToPreviousPeriod() {
        guard canGoToPreviousPeriod else {
            return
        }

        followsCurrentPeriod = false
        selectedPeriodStart = periodOffset(from: selectedPeriodStart, value: -1)
        clearHoverSelectionAndCancelPendingWork()
    }

    func goToNextPeriod() {
        guard canGoToNextPeriod else {
            return
        }

        let nextPeriodStart = min(periodOffset(from: selectedPeriodStart, value: 1), currentPeriodStart())
        selectedPeriodStart = nextPeriodStart
        followsCurrentPeriod = nextPeriodStart == currentPeriodStart()
        clearHoverSelectionAndCancelPendingWork()
    }

    func jumpToCurrentPeriod() {
        guard canJumpToCurrentPeriod else {
            return
        }

        followsCurrentPeriod = true
        selectedPeriodStart = currentPeriodStart()
        clearHoverSelectionAndCancelPendingWork()
    }

    func chartXAxisLabel(for date: Date) -> String {
        Self.chartXAxisLabel(for: date, range: selectedRange, calendar: calendar)
    }

    func chartXPosition(for point: UsageHistoryChartPoint) -> Date {
        guard chartSemantics == .independentSignals else {
            return chartXPosition(forBucketStart: point.bucketStart)
        }

        let visibleSeriesIDs = sortedSeries
            .filter { selectedSeriesIDs.contains($0.id) }
            .map(\.id)
        guard
            let index = visibleSeriesIDs.firstIndex(of: point.bucketID),
            !visibleSeriesIDs.isEmpty
        else {
            return chartXPosition(forBucketStart: point.bucketStart)
        }

        let bucketEnd = fullBucketEnd(for: point.bucketStart)
        let bucketDuration = max(bucketEnd.timeIntervalSince(point.bucketStart), 1)
        let slotDuration = bucketDuration / Double(visibleSeriesIDs.count)
        let offset = slotDuration * (Double(index) + 0.5)
        return point.bucketStart.addingTimeInterval(offset)
    }

    func chartXPosition(for selection: UsageHistoryHoverSelection) -> Date {
        chartXPosition(forBucketStart: selection.bucketStart)
    }

    func chartValue(for point: UsageHistoryChartPoint) -> Double {
        switch selectedChartKind {
        case .capacity, .usage:
            return point.value(for: selectedMetric)
        case .tokens:
            return Double(point.tokenCount ?? 0)
        }
    }

    func formattedChartValue(for point: UsageHistoryChartPoint) -> String {
        switch selectedChartKind {
        case .capacity, .usage:
            return "\(Int(chartValue(for: point).rounded()))%"
        case .tokens:
            return Self.compactTokenText(point.tokenCount ?? 0)
        }
    }

    func formattedCompactTokenValue(_ tokenCount: Int64) -> String {
        Self.compactTokenAxisText(Double(tokenCount))
    }

    func chartPointLabel(for point: UsageHistoryChartPoint) -> String {
        guard selectedChartKind == .tokens else {
            return point.bucketName
        }

        return "\(point.bucketName) \(tokenComponentTitle(for: point))"
    }

    func compactSeriesTitle(for seriesName: String) -> String {
        if seriesName.localizedCaseInsensitiveCompare("All tokens") == .orderedSame {
            return "Total"
        }

        let lowercased = seriesName.lowercased()
        if lowercased.contains("spark") {
            return "Spark"
        }

        if let range = seriesName.range(
            of: #"(?i)^gpt-([0-9]+(?:\.[0-9]+)*)(?:[-_ ](.+))?$"#,
            options: .regularExpression
        ) {
            let matched = String(seriesName[range])
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

        return seriesName
    }

    func tokenComponentTitle(for point: UsageHistoryChartPoint) -> String {
        point.tokenComponent?.displayTitle ?? "Tokens"
    }

    func formattedYAxisValue(_ value: Double) -> String {
        switch selectedChartKind {
        case .capacity, .usage:
            return "\(Int(value.rounded()))"
        case .tokens:
            return Self.compactTokenAxisText(value)
        }
    }

    func clearHistory() {
        Task {
            await clearHistoryAsync()
        }
    }

    func clearHistoryAsync() async {
        do {
            try await database.clearHistory()
            userEditedSeriesSelection = false
            seriesSearchText = ""
            await reload()
        } catch {
            errorMessage = "History could not be cleared."
        }
    }

    func exportCSV() {
        do {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = exportFilename

            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            try Data(chartCSV().utf8).write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "History could not be exported."
        }
    }

    func chartCSV() -> String {
        if selectedChartKind == .tokens {
            return tokenChartCSV()
        }

        var rows = ["range,limit,metric,bucket_start,bucket_end,bucket_id,bucket_name,bucket_kind,percent_value"]
        let formatter = ISO8601DateFormatter()

        rows += visibleChartPoints.map { point in
            [
                selectedRange.rawValue,
                selectedWindow.rawValue,
                selectedMetric.rawValue,
                formatter.string(from: point.bucketStart),
                formatter.string(from: point.bucketEnd),
                Self.csvEscaped(point.bucketID),
                Self.csvEscaped(point.bucketName),
                point.bucketKind.rawValue,
                String(format: "%.3f", point.value(for: selectedMetric)),
            ].joined(separator: ",")
        }

        return rows.joined(separator: "\n") + "\n"
    }

    private func tokenChartCSV() -> String {
        var rows = ["range,bucket_start,bucket_end,series_id,series_name,series_kind,token_component,token_count"]
        let formatter = ISO8601DateFormatter()

        rows += visibleChartPoints.map { point in
            [
                selectedRange.rawValue,
                formatter.string(from: point.bucketStart),
                formatter.string(from: point.bucketEnd),
                Self.csvEscaped(point.bucketID),
                Self.csvEscaped(point.bucketName),
                point.bucketKind.rawValue,
                point.tokenComponent?.rawValue ?? "unknown",
                "\(point.tokenCount ?? 0)",
            ].joined(separator: ",")
        }

        return rows.joined(separator: "\n") + "\n"
    }

    func formattedBucketInterval(_ selection: UsageHistoryHoverSelection) -> String {
        switch selectedRange.chartBucketComponent {
        case .hour:
            let date = selection.bucketStart.formatted(date: .abbreviated, time: .omitted)
            let start = selection.bucketStart.formatted(date: .omitted, time: .shortened)
            let end = selection.bucketEnd.formatted(date: .omitted, time: .shortened)
            return "\(date), \(start)-\(end)"
        case .day:
            return selection.bucketStart.formatted(date: .abbreviated, time: .omitted)
        case .month:
            return selection.bucketStart.formatted(.dateTime.month(.abbreviated).year())
        default:
            return selection.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private func rebuildChartCaches() {
        let rebuiltChartPoints = uncachedChartPoints()
        let rebuiltVisibleChartPoints = rebuiltChartPoints.filter { selectedSeriesIDs.contains($0.bucketID) }
        let rebuiltTokenDetailPoints = selectedChartKind == .tokens
            ? rebuiltVisibleChartPoints.filter { $0.bucketKind == .aggregate }
            : []
        let rebuiltVisibleContributorPoints = chartSemantics == .comparableContributors
            ? rebuiltVisibleChartPoints.filter { $0.bucketKind == .model }
            : []
        let rebuiltVisibleAggregateReferencePoints = rebuiltVisibleChartPoints.filter { $0.bucketKind == .aggregate }

        let rebuiltVisibleBarPoints: [UsageHistoryChartPoint]
        if selectedChartKind == .tokens {
            rebuiltVisibleBarPoints = Self.combinedTokenBarPoints(from: rebuiltTokenDetailPoints)
        } else {
            switch chartSemantics {
            case .independentSignals:
                rebuiltVisibleBarPoints = rebuiltVisibleChartPoints
            case .comparableContributors:
                rebuiltVisibleBarPoints = rebuiltVisibleContributorPoints
            }
        }

        cachedChartPoints = rebuiltChartPoints
        cachedVisibleChartPoints = rebuiltVisibleChartPoints
        cachedVisibleBarPoints = rebuiltVisibleBarPoints
        cachedVisibleContributorPoints = rebuiltVisibleContributorPoints
        cachedVisibleAggregateReferencePoints = rebuiltVisibleAggregateReferencePoints
        cachedTokenDetailPoints = rebuiltTokenDetailPoints
        hoverIndex = makeHoverIndex(
            candidatePoints: selectedChartKind == .tokens ? rebuiltVisibleBarPoints : rebuiltVisibleChartPoints,
            detailPoints: selectedChartKind == .tokens ? rebuiltTokenDetailPoints : nil
        )
        hoverCacheVersion += 1
    }

    private func uncachedChartPoints() -> [UsageHistoryChartPoint] {
        switch selectedChartKind {
        case .capacity, .usage:
            return Self.bucketedChartPoints(
                from: points,
                range: selectedRange,
                window: selectedWindow,
                period: selectedPeriod,
                now: now(),
                calendar: calendar
            )
        case .tokens:
            return Self.tokenComponentChartPoints(from: tokenComponentBucketPoints)
        }
    }

    private func makeHoverIndex(
        candidatePoints: [UsageHistoryChartPoint],
        detailPoints: [UsageHistoryChartPoint]? = nil
    ) -> UsageHistoryHoverIndex {
        guard !candidatePoints.isEmpty else {
            return .empty
        }

        let detailPointsByBucket = Dictionary(grouping: detailPoints ?? candidatePoints, by: \.bucketStart)
        let buckets = Set(candidatePoints.map(\.bucketStart))
            .compactMap { bucketStart -> UsageHistoryHoverBucket? in
                let points = detailPointsByBucket[bucketStart]?.sortedByDisplayOrder() ?? []
                guard let bucketEnd = points.first?.bucketEnd else {
                    return nil
                }

                return UsageHistoryHoverBucket(
                    bucketStart: bucketStart,
                    bucketEnd: bucketEnd,
                    xDate: chartXPosition(forBucketStart: bucketStart),
                    points: points
                )
            }
            .sorted { lhs, rhs in
                if lhs.xDate != rhs.xDate {
                    return lhs.xDate < rhs.xDate
                }

                return lhs.bucketStart < rhs.bucketStart
            }

        return UsageHistoryHoverIndex(buckets: buckets)
    }

    private func clearHoverSelectionAndCancelPendingWork() {
        hoverSelectionWorkItem?.cancel()
        hoverSelectionWorkItem = nil
        clearHoverSelection()
    }

    private func refreshChartCachesForPendingReload() {
        rebuildChartCaches()
        clearHoverSelectionAndCancelPendingWork()
    }

    private func reconcileSelectedSeries() {
        let currentIDs = Set(series.map(\.id))

        if selectedChartKind == .tokens {
            selectedSeriesIDs = Self.aggregateSeriesIDs(from: series)
            userEditedSeriesSelection = false
            return
        }

        if !userEditedSeriesSelection {
            selectedSeriesIDs = Self.defaultSelectedSeriesIDs(from: series)
            return
        }

        selectedSeriesIDs.formIntersection(currentIDs)
        selectedSeriesIDs.formUnion(Self.aggregateSeriesIDs(from: series))
        if selectedSeriesIDs.isEmpty {
            selectedSeriesIDs = Self.defaultSelectedSeriesIDs(from: series)
            userEditedSeriesSelection = false
        }
    }

    @discardableResult
    private func syncCurrentPeriodIfNeeded() -> Bool {
        guard followsCurrentPeriod else {
            return false
        }

        let currentPeriodStart = currentPeriodStart()
        guard selectedPeriodStart != currentPeriodStart else {
            return false
        }

        selectedPeriodStart = currentPeriodStart
        clearHoverSelectionAndCancelPendingWork()
        return true
    }

    private static func defaultSelectedSeriesIDs(from series: [UsageHistorySeries]) -> Set<String> {
        Set(series.filter { !isHiddenByDefault($0) }.map(\.id))
    }

    private static func aggregateSeriesIDs(from series: [UsageHistorySeries]) -> Set<String> {
        Set(series.filter { $0.kind == .aggregate }.map(\.id))
    }

    private static func compactModelSuffixTitle(_ value: String) -> String {
        guard let first = value.first else {
            return value
        }

        return first.uppercased() + value.dropFirst().lowercased()
    }

    private static func isHiddenByDefault(_ series: UsageHistorySeries) -> Bool {
        guard series.kind == .model else {
            return false
        }

        let normalizedID = series.id.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedName = series.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalizedID.contains("spark") || normalizedName.contains("spark")
    }

    private static func bucketedChartPoints(
        from points: [UsageHistoryPoint],
        range: UsageHistoryRange,
        window: UsageLimitWindow,
        period: UsageHistoryPeriod,
        now: Date,
        calendar: Calendar
    ) -> [UsageHistoryChartPoint] {
        let bucketComponent = range.chartBucketComponent
        var buckets = [String: [UsageHistoryPoint]]()

        for point in points {
            let bucketStart = UsageHistoryRange.bucketStart(
                for: point.timestamp,
                component: bucketComponent,
                calendar: calendar
            )
            guard bucketStart >= period.start, bucketStart < period.end else {
                continue
            }

            let key = "\(point.bucketID)-\(Int(bucketStart.timeIntervalSince1970))"
            buckets[key, default: []].append(point)
        }

        return buckets.compactMap { _, bucketPoints in
            guard
                let latestPoint = bucketPoints.max(by: { lhs, rhs in
                    if lhs.timestamp == rhs.timestamp {
                        return lhs.bucketName < rhs.bucketName
                    }

                    return lhs.timestamp < rhs.timestamp
                }),
                let firstPoint = bucketPoints.first
            else {
                return nil
            }

            let bucketStart = UsageHistoryRange.bucketStart(
                for: latestPoint.timestamp,
                component: bucketComponent,
                calendar: calendar
            )
            let uncappedBucketEnd = calendar.date(byAdding: bucketComponent, value: 1, to: bucketStart) ?? bucketStart
            let peakUsedPercent = bucketPoints.map(\.peakUsedPercent).max() ?? latestPoint.peakUsedPercent
            let consumedPercent = bucketPoints.reduce(0) { total, point in
                total + point.consumedPercent
            }
            let bucketEnd = min(uncappedBucketEnd, period.end, now)

            return UsageHistoryChartPoint(
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                sampleTimestamp: latestPoint.timestamp,
                bucketID: firstPoint.bucketID,
                bucketName: latestPoint.bucketName,
                bucketKind: latestPoint.bucketKind,
                window: window,
                latestUsedPercent: latestPoint.usedPercent,
                peakUsedPercent: peakUsedPercent,
                consumedPercent: consumedPercent
            )
        }
        .sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }

            if lhs.bucketKind != rhs.bucketKind {
                return lhs.bucketKind == .aggregate
            }

            return lhs.bucketName.localizedStandardCompare(rhs.bucketName) == .orderedAscending
        }
    }

    private static func tokenComponentChartPoints(
        from points: [TokenHistoryComponentBucketPoint]
    ) -> [UsageHistoryChartPoint] {
        points.map { point in
            UsageHistoryChartPoint(
                bucketStart: point.bucketStart,
                bucketEnd: point.bucketEnd,
                sampleTimestamp: point.latestSampleTimestamp,
                bucketID: point.seriesID,
                bucketName: point.seriesName,
                bucketKind: point.seriesKind,
                tokenComponent: point.component,
                tokenCount: point.tokenCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }

            if lhs.bucketKind != rhs.bucketKind {
                return lhs.bucketKind == .aggregate
            }

            if lhs.bucketName != rhs.bucketName {
                return lhs.bucketName.localizedStandardCompare(rhs.bucketName) == .orderedAscending
            }

            return tokenComponentSortIndex(lhs.tokenComponent) < tokenComponentSortIndex(rhs.tokenComponent)
        }
    }

    nonisolated fileprivate static func tokenComponentSortIndex(_ component: TokenHistoryComponent?) -> Int {
        guard
            let component,
            let index = TokenHistoryComponent.allCases.firstIndex(of: component)
        else {
            return TokenHistoryComponent.allCases.count
        }

        return index
    }

    private static func combinedTokenBarPoints(from points: [UsageHistoryChartPoint]) -> [UsageHistoryChartPoint] {
        let groupedPoints = Dictionary(grouping: points) { point in
            "\(Int(point.bucketStart.timeIntervalSince1970))-\(point.tokenComponent?.rawValue ?? "tokens")"
        }

        return groupedPoints.compactMap { _, bucketPoints in
            guard
                let firstPoint = bucketPoints.first,
                let latestPoint = bucketPoints.max(by: { lhs, rhs in
                    lhs.sampleTimestamp < rhs.sampleTimestamp
                })
            else {
                return nil
            }

            let tokenCount = bucketPoints.reduce(Int64(0)) { total, point in
                total + max(point.tokenCount ?? 0, 0)
            }

            return UsageHistoryChartPoint(
                bucketStart: firstPoint.bucketStart,
                bucketEnd: firstPoint.bucketEnd,
                sampleTimestamp: latestPoint.sampleTimestamp,
                bucketID: "tokens_visible_total",
                bucketName: "Visible tokens",
                bucketKind: .aggregate,
                tokenComponent: firstPoint.tokenComponent,
                tokenCount: tokenCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }

            return tokenComponentSortIndex(lhs.tokenComponent) < tokenComponentSortIndex(rhs.tokenComponent)
        }
    }

    private static func maximumTokenStackValue(in points: [UsageHistoryChartPoint]) -> Double {
        let totals = Dictionary(grouping: points) { point in
            "\(Int(point.bucketStart.timeIntervalSince1970))-\(point.bucketID)"
        }
        .mapValues { stackPoints in
            stackPoints.reduce(0) { total, point in
                total + Double(point.tokenCount ?? 0)
            }
        }

        return totals.values.max() ?? 0
    }

    private func periodForQuery() -> UsageHistoryPeriod {
        let period = selectedPeriod
        let cappedEnd = min(period.end, now().addingTimeInterval(1))
        return UsageHistoryPeriod(start: period.start, end: cappedEnd)
    }

    private func period(startingAt start: Date) -> UsageHistoryPeriod {
        let end = calendar.date(byAdding: selectedRange.periodComponent, value: 1, to: start) ?? start
        return UsageHistoryPeriod(start: start, end: end)
    }

    private func currentPeriodStart() -> Date {
        selectedRange.period(containing: now(), calendar: calendar).start
    }

    private func periodOffset(from start: Date, value: Int) -> Date {
        calendar.date(byAdding: selectedRange.periodComponent, value: value, to: start) ?? start
    }

    private var periodDisplayNoun: String {
        selectedRange.displayTitle.lowercased()
    }

    private var periodFilenameToken: String {
        Self.periodFilenameToken(for: selectedRange, periodStart: selectedPeriod.start, calendar: calendar)
    }

    private static func periodTitle(
        for range: UsageHistoryRange,
        period: UsageHistoryPeriod,
        calendar: Calendar
    ) -> String {
        switch range {
        case .day:
            return period.start.formatted(.dateTime.month(.abbreviated).day())
        case .week:
            let endDate = period.end.addingTimeInterval(-1)
            let start = period.start.formatted(.dateTime.month(.abbreviated).day())
            let end = endDate.formatted(.dateTime.month(.abbreviated).day())
            return "\(start)-\(end)"
        case .month:
            return period.start.formatted(.dateTime.month(.abbreviated).year())
        case .year:
            let year = calendar.component(.year, from: period.start)
            return "\(year)"
        }
    }

    private static func compactPeriodTitle(
        for range: UsageHistoryRange,
        period: UsageHistoryPeriod,
        calendar: Calendar
    ) -> String {
        switch range {
        case .day:
            return formattedDate(period.start, template: "MMM d", calendar: calendar)
        case .week:
            let endDate = period.end.addingTimeInterval(-1)
            let sameMonth = calendar.component(.year, from: period.start) == calendar.component(.year, from: endDate)
                && calendar.component(.month, from: period.start) == calendar.component(.month, from: endDate)
            let start = formattedDate(period.start, template: "MMM d", calendar: calendar)
            let end = formattedDate(endDate, template: sameMonth ? "d" : "MMM d", calendar: calendar)
            return "\(start)-\(end)"
        case .month:
            return formattedDate(period.start, template: "MMM y", calendar: calendar)
        case .year:
            return "\(calendar.component(.year, from: period.start))"
        }
    }

    private static func formattedDate(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? Locale.autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func chartXAxisLabel(
        for date: Date,
        range: UsageHistoryRange,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? Locale.autoupdatingCurrent
        formatter.timeZone = calendar.timeZone

        switch range {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("ha")
        case .week:
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("d")
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("MMM")
        }

        return formatter.string(from: date)
    }

    private static func periodFilenameToken(
        for range: UsageHistoryRange,
        periodStart: Date,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone

        switch range {
        case .day, .week:
            formatter.dateFormat = "yyyy-MM-dd"
        case .month:
            formatter.dateFormat = "yyyy-MM"
        case .year:
            formatter.dateFormat = "yyyy"
        }

        return formatter.string(from: periodStart)
    }

    private func chartXAxisLabelBucketStarts() -> [Date] {
        let component = selectedRange.chartBucketComponent
        let step: Int
        switch selectedRange {
        case .day:
            step = 4
        case .week:
            step = 1
        case .month:
            step = 5
        case .year:
            step = 1
        }

        var bucketStarts = [Date]()
        var cursor = selectedPeriod.start

        while cursor < selectedPeriod.end {
            bucketStarts.append(cursor)
            guard
                let next = calendar.date(byAdding: component, value: step, to: cursor),
                next > cursor
            else {
                break
            }

            cursor = next
        }

        return bucketStarts
    }

    private static func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        return value
    }

    private static func tokenAxisUpperBound(for value: Double) -> Double {
        guard value > 0 else {
            return 1
        }

        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let multiplier: Double
        if normalized <= 1 {
            multiplier = 1
        } else if normalized <= 2 {
            multiplier = 2
        } else if normalized <= 5 {
            multiplier = 5
        } else {
            multiplier = 10
        }

        return multiplier * magnitude
    }

    private static func compactTokenText(_ tokenCount: Int64) -> String {
        "\(compactTokenNumber(Double(max(tokenCount, 0)))) tok"
    }

    private static func compactTokenAxisText(_ value: Double) -> String {
        compactTokenNumber(max(value, 0))
    }

    private static func compactTokenNumber(_ value: Double) -> String {
        if value < 1_000 {
            return "\(Int(value.rounded()))"
        }

        if value < 10_000 {
            return String(format: "%.1fk", roundedSingleDecimal(value / 1_000))
        }

        if value < 1_000_000 {
            return "\(Int((value / 1_000).rounded()))k"
        }

        if value < 10_000_000 {
            return String(format: "%.1fM", roundedSingleDecimal(value / 1_000_000))
        }

        return "\(Int((value / 1_000_000).rounded()))M"
    }

    private static func roundedSingleDecimal(_ value: Double) -> Double {
        (value * 10).rounded(.toNearestOrAwayFromZero) / 10
    }

    private func chartXPosition(forBucketStart bucketStart: Date) -> Date {
        let bucketEnd = fullBucketEnd(for: bucketStart)
        let midpointOffset = max(bucketEnd.timeIntervalSince(bucketStart), 1) / 2
        return bucketStart.addingTimeInterval(midpointOffset)
    }

    private var chartDomainBucketPadding: TimeInterval {
        let firstBucketEnd = fullBucketEnd(for: selectedPeriod.start)
        return max(firstBucketEnd.timeIntervalSince(selectedPeriod.start), 1) / 2
    }

    private func fullBucketEnd(for bucketStart: Date) -> Date {
        calendar.date(byAdding: selectedRange.chartBucketComponent, value: 1, to: bucketStart) ?? bucketStart
    }
}

private extension Array where Element == UsageHistorySeries {
    func sortedByDisplayOrder() -> [UsageHistorySeries] {
        sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .aggregate
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

private extension Array where Element == UsageHistoryPoint {
    func sortedByDisplayOrder() -> [UsageHistoryPoint] {
        sorted { lhs, rhs in
            if lhs.bucketKind != rhs.bucketKind {
                return lhs.bucketKind == .aggregate
            }

            return lhs.bucketName.localizedStandardCompare(rhs.bucketName) == .orderedAscending
        }
    }
}

private extension Array where Element == UsageHistoryChartPoint {
    func sortedByDisplayOrder() -> [UsageHistoryChartPoint] {
        sorted { lhs, rhs in
            if lhs.bucketKind != rhs.bucketKind {
                return lhs.bucketKind == .aggregate
            }

            if lhs.bucketName != rhs.bucketName {
                return lhs.bucketName.localizedStandardCompare(rhs.bucketName) == .orderedAscending
            }

            return UsageHistoryViewModel.tokenComponentSortIndex(lhs.tokenComponent) <
                UsageHistoryViewModel.tokenComponentSortIndex(rhs.tokenComponent)
        }
    }
}
