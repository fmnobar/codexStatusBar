@preconcurrency import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct NeutralCheckboxMark: View {
    let isSelected: Bool
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: size, height: size, alignment: .center)
    }
}

struct NeutralCheckboxToggleStyle: ToggleStyle {
    var size: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                NeutralCheckboxMark(isSelected: configuration.isOn, size: size)
                configuration.label
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

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

enum UsageHistoryEmptyStateKind: Equatable {
    case noHistory
    case noDataForSelection
    case hiddenSeries
}

struct UsageHistoryEmptyStatePresentation: Equatable {
    let kind: UsageHistoryEmptyStateKind
    let systemImage: String
    let title: String
    let message: String
}

@MainActor
final class UsageHistoryViewModel: ObservableObject {
    typealias RecentTokenHistoryImporter = (UsageHistoryStore, Date, Calendar) -> Void

    static let liveRecentTokenHistoryImporter: RecentTokenHistoryImporter = { store, date, calendar in
        store.importRecentTokenHistoryIfAvailable(containing: date, calendar: calendar)
    }

    @Published var selectedRange: UsageHistoryRange = .month {
        didSet {
            followsCurrentPeriod = true
            selectedPeriodStart = currentPeriodStart()
            scheduleReload()
        }
    }
    @Published var selectedWindow: UsageLimitWindow = .sevenDay {
        didSet { scheduleReload() }
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
            scheduleReload()
            scheduleClearHoverSelection()
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
    @Published private(set) var series: [UsageHistorySeries] = []
    @Published private(set) var selectedSeriesIDs = Set<String>()
    @Published private(set) var errorMessage: String?
    @Published private(set) var hoverSelection: UsageHistoryHoverSelection?
    @Published private(set) var hasAnyRecordedHistory = false
    @Published private(set) var selectedPeriodStart = Date(timeIntervalSince1970: 0) {
        didSet { scheduleReload() }
    }
    let chartSemantics: UsageHistoryChartSemantics

    private let store: UsageHistoryStore
    private let now: () -> Date
    private let calendar: Calendar
    private let recentTokenHistoryImporter: RecentTokenHistoryImporter
    private var historyBounds: UsageHistoryBounds?
    private var userEditedSeriesSelection = false
    private var followsCurrentPeriod = true
    private var historyObserver: NSObjectProtocol?
    private var reloadWorkItem: DispatchWorkItem?
    private var hoverSelectionWorkItem: DispatchWorkItem?

    init(
        store: UsageHistoryStore,
        chartSemantics: UsageHistoryChartSemantics = .independentSignals,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        recentTokenHistoryImporter: @escaping RecentTokenHistoryImporter = { _, _, _ in }
    ) {
        self.store = store
        self.chartSemantics = chartSemantics
        self.now = now
        self.calendar = calendar
        self.recentTokenHistoryImporter = recentTokenHistoryImporter
        selectedPeriodStart = selectedRange.period(containing: now(), calendar: calendar).start
        historyObserver = NotificationCenter.default.addObserver(
            forName: UsageHistoryStore.didChangeNotification,
            object: store,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
    }

    deinit {
        reloadWorkItem?.cancel()
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
            return Self.bucketedTokenComponentChartPoints(
                from: tokenComponentPoints,
                range: selectedRange,
                period: selectedPeriod,
                now: now(),
                calendar: calendar
            )
        }
    }

    var visibleChartPoints: [UsageHistoryChartPoint] {
        chartPoints.filter { selectedSeriesIDs.contains($0.bucketID) }
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
        if selectedChartKind == .tokens {
            return tokenBarPoints
        }

        switch chartSemantics {
        case .independentSignals:
            return visibleChartPoints
        case .comparableContributors:
            return visibleContributorPoints
        }
    }

    var visibleContributorPoints: [UsageHistoryChartPoint] {
        guard chartSemantics == .comparableContributors else {
            return []
        }

        return visibleChartPoints.filter { $0.bucketKind == .model }
    }

    var visibleAggregateReferencePoints: [UsageHistoryChartPoint] {
        visibleChartPoints.filter { $0.bucketKind == .aggregate }
    }

    var tokenDetailPoints: [UsageHistoryChartPoint] {
        guard selectedChartKind == .tokens else {
            return []
        }

        return visibleChartPoints
    }

    private var tokenBarPoints: [UsageHistoryChartPoint] {
        guard selectedChartKind == .tokens else {
            return []
        }

        let selectedPoints = visibleChartPoints
        let barSourcePoints: [UsageHistoryChartPoint]
        if selectedPoints.contains(where: { $0.bucketKind == .aggregate }) {
            barSourcePoints = selectedPoints.filter { $0.bucketKind == .aggregate }
        } else {
            barSourcePoints = selectedPoints
        }

        return Self.combinedTokenBarPoints(from: barSourcePoints)
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
            return "Choose a different range to inspect captured tokens."
        }
    }

    var hasHistory: Bool {
        switch selectedChartKind {
        case .capacity, .usage:
            return !points.isEmpty
        case .tokens:
            return !tokenComponentPoints.isEmpty
        }
    }

    func reload() {
        syncCurrentPeriodIfNeeded()

        do {
            let queryPeriod = periodForQuery()
            let loadedPoints: [UsageHistoryPoint]
            let loadedTokenPoints: [TokenHistoryPoint]
            let loadedTokenComponentPoints: [TokenHistoryComponentPoint]
            let loadedSeries: [UsageHistorySeries]
            let loadedHistoryBounds: UsageHistoryBounds?

            switch selectedChartKind {
            case .capacity, .usage:
                loadedPoints = try store.points(
                    range: selectedRange,
                    window: selectedWindow,
                    periodStart: queryPeriod.start,
                    periodEnd: queryPeriod.end
                )
                loadedTokenPoints = []
                loadedTokenComponentPoints = []
                loadedSeries = try store.availableSeries(window: selectedWindow)
                loadedHistoryBounds = try store.historyBounds(
                    window: selectedWindow,
                    granularity: selectedRange.storageGranularity
                )
            case .tokens:
                loadedPoints = []
                recentTokenHistoryImporter(store, now(), calendar)
                loadedTokenPoints = []
                loadedTokenComponentPoints = try store.tokenComponentPoints(
                    range: selectedRange,
                    periodStart: queryPeriod.start,
                    periodEnd: queryPeriod.end
                )
                loadedSeries = try store.availableTokenComponentSeries()
                loadedHistoryBounds = try store.tokenComponentHistoryBounds()
            }
            let loadedHasAnyHistory = try store.hasAnyHistory()

            points = loadedPoints
            tokenPoints = loadedTokenPoints
            tokenComponentPoints = loadedTokenComponentPoints
            series = loadedSeries
            hasAnyRecordedHistory = loadedHasAnyHistory
            historyBounds = loadedHistoryBounds
            reconcileSelectedSeries()
            clearHoverSelection()
            errorMessage = nil
        } catch {
            points = []
            tokenPoints = []
            tokenComponentPoints = []
            series = []
            selectedSeriesIDs = []
            hasAnyRecordedHistory = false
            historyBounds = nil
            clearHoverSelection()
            errorMessage = "History could not be loaded."
        }
    }

    func scheduleReload() {
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        reloadWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
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
        clearHoverSelection()
    }

    func isPinnedSeries(_ series: UsageHistorySeries) -> Bool {
        selectedChartKind != .tokens && series.kind == .aggregate
    }

    func selectAllSeries() {
        selectedSeriesIDs = Set(series.map(\.id))
        userEditedSeriesSelection = true
        clearHoverSelection()
    }

    func clearModelSeries() {
        selectedSeriesIDs = Set(series.filter { $0.kind == .aggregate }.map(\.id))
        userEditedSeriesSelection = true
        clearHoverSelection()
    }

    func updateHoverSelection(nearestTo timestamp: Date, xPosition: CGFloat) {
        let candidates = selectedChartKind == .tokens ? visibleBarPoints : visibleChartPoints
        guard !candidates.isEmpty else {
            clearHoverSelection()
            return
        }

        let bucketStarts = Array(Set(candidates.map(\.bucketStart))).sorted()
        guard let nearestBucketStart = bucketStarts.min(by: { lhs, rhs in
            let lhsDistance = abs(chartXPosition(forBucketStart: lhs).timeIntervalSince(timestamp))
            let rhsDistance = abs(chartXPosition(forBucketStart: rhs).timeIntervalSince(timestamp))
            if lhsDistance == rhsDistance {
                return lhs < rhs
            }

            return lhsDistance < rhsDistance
        }) else {
            clearHoverSelection()
            return
        }

        let selectedPoints = (selectedChartKind == .tokens ? tokenDetailPoints : candidates)
            .filter { $0.bucketStart == nearestBucketStart }
            .sortedByDisplayOrder()
        guard let bucketEnd = selectedPoints.first?.bucketEnd else {
            clearHoverSelection()
            return
        }

        hoverSelection = UsageHistoryHoverSelection(
            bucketStart: nearestBucketStart,
            bucketEnd: bucketEnd,
            points: selectedPoints,
            xPosition: xPosition
        )
    }

    func clearHoverSelection() {
        hoverSelection = nil
    }

    func scheduleHoverSelection(nearestTo timestamp: Date, xPosition: CGFloat) {
        hoverSelectionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateHoverSelection(nearestTo: timestamp, xPosition: xPosition)
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
        clearHoverSelection()
    }

    func goToNextPeriod() {
        guard canGoToNextPeriod else {
            return
        }

        let nextPeriodStart = min(periodOffset(from: selectedPeriodStart, value: 1), currentPeriodStart())
        selectedPeriodStart = nextPeriodStart
        followsCurrentPeriod = nextPeriodStart == currentPeriodStart()
        clearHoverSelection()
    }

    func jumpToCurrentPeriod() {
        guard canJumpToCurrentPeriod else {
            return
        }

        followsCurrentPeriod = true
        selectedPeriodStart = currentPeriodStart()
        clearHoverSelection()
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

        if let range = seriesName.range(of: #"(?i)gpt-([0-9]+(?:\.[0-9]+)*)"#, options: .regularExpression) {
            let matched = String(seriesName[range])
            return matched.replacingOccurrences(of: #"(?i)^gpt-"#, with: "", options: .regularExpression)
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
        do {
            try store.clearHistory()
            userEditedSeriesSelection = false
            seriesSearchText = ""
            reload()
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

    private func reconcileSelectedSeries() {
        let currentIDs = Set(series.map(\.id))

        if !userEditedSeriesSelection {
            selectedSeriesIDs = Self.defaultSelectedSeriesIDs(from: series)
            return
        }

        selectedSeriesIDs.formIntersection(currentIDs)
        if selectedChartKind != .tokens {
            selectedSeriesIDs.formUnion(series.filter { $0.kind == .aggregate }.map(\.id))
        }
        if selectedSeriesIDs.isEmpty && selectedChartKind != .tokens {
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
        clearHoverSelection()
        return true
    }

    private static func defaultSelectedSeriesIDs(from series: [UsageHistorySeries]) -> Set<String> {
        Set(series.filter { !isHiddenByDefault($0) }.map(\.id))
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

    private static func bucketedTokenComponentChartPoints(
        from points: [TokenHistoryComponentPoint],
        range: UsageHistoryRange,
        period: UsageHistoryPeriod,
        now: Date,
        calendar: Calendar
    ) -> [UsageHistoryChartPoint] {
        let bucketComponent = range.chartBucketComponent
        var buckets = [String: [TokenHistoryComponentPoint]]()

        for point in points {
            let bucketStart = UsageHistoryRange.bucketStart(
                for: point.timestamp,
                component: bucketComponent,
                calendar: calendar
            )
            guard bucketStart >= period.start, bucketStart < period.end else {
                continue
            }

            let key = "\(point.seriesID)-\(point.component.rawValue)-\(Int(bucketStart.timeIntervalSince1970))"
            buckets[key, default: []].append(point)
        }

        return buckets.compactMap { _, bucketPoints in
            guard
                let latestPoint = bucketPoints.max(by: { lhs, rhs in
                    if lhs.timestamp == rhs.timestamp {
                        return lhs.seriesName < rhs.seriesName
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
            let bucketEnd = min(uncappedBucketEnd, period.end, now)
            let tokenCount = bucketPoints.reduce(Int64(0)) { total, point in
                total + max(point.tokenCount, 0)
            }

            return UsageHistoryChartPoint(
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                sampleTimestamp: latestPoint.timestamp,
                bucketID: firstPoint.seriesID,
                bucketName: latestPoint.seriesName,
                bucketKind: latestPoint.seriesKind,
                tokenComponent: latestPoint.component,
                tokenCount: tokenCount
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

private struct UsageHistoryLayoutMetrics {
    let availableSize: CGSize
    let hasHistory: Bool

    private var isCompactHeight: Bool {
        availableSize.height < 580
    }

    var topPadding: CGFloat {
        isCompactHeight ? 12 : 16
    }

    var horizontalPadding: CGFloat {
        availableSize.width < 760 ? 14 : 20
    }

    var bottomPadding: CGFloat {
        isCompactHeight ? 12 : 20
    }

    var verticalSpacing: CGFloat {
        isCompactHeight ? 8 : 12
    }

    var seriesSelectorHeight: CGFloat {
        guard hasHistory else {
            return 0
        }

        if availableSize.height < 540 {
            return 60
        }

        if availableSize.height < 620 {
            return 84
        }

        return 112
    }

    var chartHeight: CGFloat {
        let fixedRowsHeight: CGFloat = 36 + 22
        let spacingCount: CGFloat = hasHistory ? 3 : 2
        let selectorHeight = hasHistory ? seriesSelectorHeight : 0
        let reservedHeight = topPadding
            + bottomPadding
            + fixedRowsHeight
            + selectorHeight
            + (verticalSpacing * spacingCount)
        let availableChartHeight = availableSize.height - reservedHeight
        let maximumHeight: CGFloat = isCompactHeight ? 240 : 330

        return min(max(availableChartHeight, 160), maximumHeight)
    }
}

struct UsageHistoryPeriodNavigationView: View {
    @ObservedObject var viewModel: UsageHistoryViewModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.goToPreviousPeriod()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToPreviousPeriod)
            .help(viewModel.previousPeriodHelpText)
            .accessibilityLabel(viewModel.previousPeriodAccessibilityLabel)

            Text(viewModel.periodTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 72, alignment: .center)

            Button {
                viewModel.jumpToCurrentPeriod()
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canJumpToCurrentPeriod)
            .help(viewModel.currentPeriodHelpText)
            .accessibilityLabel(viewModel.currentPeriodAccessibilityLabel)

            Button {
                viewModel.goToNextPeriod()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToNextPeriod)
            .help(viewModel.nextPeriodHelpText)
            .accessibilityLabel(viewModel.nextPeriodAccessibilityLabel)
        }
    }
}

struct UsageHistoryView: View {
    @StateObject private var viewModel: UsageHistoryViewModel
    @State private var isConfirmingClear = false

    init(
        store: UsageHistoryStore,
        chartSemantics: UsageHistoryChartSemantics = .independentSignals
    ) {
        _viewModel = StateObject(wrappedValue: UsageHistoryViewModel(
            store: store,
            chartSemantics: chartSemantics,
            recentTokenHistoryImporter: UsageHistoryViewModel.liveRecentTokenHistoryImporter
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = UsageHistoryLayoutMetrics(
                availableSize: geometry.size,
                hasHistory: viewModel.hasHistory
            )

            content(layout: layout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.activateCurrentPeriod()
        }
        .confirmationDialog(
            "Clear all local usage history?",
            isPresented: $isConfirmingClear
        ) {
            Button("Clear History", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func content(layout: UsageHistoryLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: layout.verticalSpacing) {
            controls
            chartHeader

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if viewModel.hasVisiblePoints {
                chart
                    .frame(height: layout.chartHeight)
            } else {
                emptyState
                    .frame(height: layout.chartHeight)
            }

            if viewModel.hasHistory {
                seriesSelector(maxHeight: layout.seriesSelectorHeight)
            }
        }
        .padding(.top, layout.topPadding)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, layout.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                rangePicker
                secondaryHistorySelector
                chartKindPicker
                Spacer()
                chartPointCount
                historyActions
            }

            HStack(spacing: 10) {
                rangePicker
                secondaryHistorySelector
                chartKindPicker
                Spacer(minLength: 0)
                historyActions
            }
        }
    }

    private var chartHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(viewModel.chartSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            UsageHistoryPeriodNavigationView(viewModel: viewModel)
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $viewModel.selectedRange) {
            ForEach(UsageHistoryRange.allCases) { range in
                Text(range.displayTitle).tag(range)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 218)
    }

    private var limitPicker: some View {
        Picker("Limit", selection: $viewModel.selectedWindow) {
            ForEach(UsageLimitWindow.allCases) { window in
                Text(window.displayTitle).tag(window)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 86)
    }

    @ViewBuilder
    private var secondaryHistorySelector: some View {
        if viewModel.selectedChartKind != .tokens {
            limitPicker
        }
    }

    private var tokenCategoryPicker: some View {
        Picker("Token Category", selection: $viewModel.selectedTokenCategory) {
            ForEach(TokenHistoryCategory.allCases) { category in
                Text(category.displayTitle).tag(category)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 128)
    }

    private var chartKindPicker: some View {
        Picker("Chart", selection: $viewModel.selectedChartKind) {
            ForEach(UsageHistoryChartKind.allCases) { kind in
                Text(kind.displayTitle).tag(kind)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 240)
    }

    private var chartPointCount: some View {
        Text(viewModel.chartPointCountSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var historyActions: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.exportCSV()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canExport)
            .help("Export CSV")
            .accessibilityLabel("Export CSV")

            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.hasHistory)
            .help("Clear History")
            .accessibilityLabel("Clear History")
        }
    }

    private var chart: some View {
        ZStack(alignment: .topLeading) {
            Chart {
                if viewModel.selectedChartKind == .tokens {
                    ForEach(viewModel.visibleBarPoints) { point in
                        BarMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, viewModel.chartValue(for: point)),
                            stacking: .standard
                        )
                        .foregroundStyle(by: .value("Token", viewModel.tokenComponentTitle(for: point)))
                        .opacity(point.bucketKind == .aggregate ? 0.86 : 0.72)
                    }
                } else if viewModel.chartSemantics == .comparableContributors {
                    ForEach(viewModel.visibleContributorPoints) { point in
                        BarMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, viewModel.chartValue(for: point)),
                            stacking: .standard
                        )
                        .foregroundStyle(by: .value("Bucket", point.bucketName))
                        .opacity(0.72)
                    }

                    ForEach(viewModel.visibleAggregateReferencePoints) { point in
                        LineMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, viewModel.chartValue(for: point)),
                            series: .value("Bucket", point.bucketName)
                        )
                        .foregroundStyle(by: .value("Bucket", point.bucketName))
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                } else {
                    ForEach(viewModel.visibleBarPoints) { point in
                        BarMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, viewModel.chartValue(for: point)),
                            stacking: .unstacked
                        )
                        .foregroundStyle(by: .value("Bucket", point.bucketName))
                        .opacity(point.bucketKind == .aggregate ? 0.82 : 0.66)
                    }
                }

                if let hoverSelection = viewModel.hoverSelection {
                    RuleMark(x: .value("Selected Time", viewModel.chartXPosition(for: hoverSelection)))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    ForEach(hoverSelection.points) { point in
                        PointMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, viewModel.chartValue(for: point))
                        )
                        .foregroundStyle(
                            by: .value(
                                viewModel.selectedChartKind == .tokens ? "Token" : "Bucket",
                                viewModel.selectedChartKind == .tokens ? viewModel.tokenComponentTitle(for: point) : point.bucketName
                            )
                        )
                        .symbolSize(point.bucketKind == .aggregate ? 58 : 42)
                    }
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
            .chartYAxisLabel(viewModel.chartYAxisTitle)
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
            .chartLegend(position: .bottom, alignment: .leading)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            handleChartHover(phase, proxy: proxy, geometry: geometry)
                        }
                }
            }

            if let hoverSelection = viewModel.hoverSelection {
                hoverCallout(hoverSelection)
                    .frame(width: 230, alignment: .leading)
                    .position(x: hoverSelection.xPosition, y: 54)
                    .allowsHitTesting(false)
            }
        }
    }

    private func seriesSelector(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            seriesActions

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.filteredSeries) { series in
                        Toggle(isOn: viewModel.binding(for: series)) {
                            HStack(spacing: 8) {
                                Text(series.name)
                                    .font(.caption)
                                    .lineLimit(1)

                                if series.kind == .aggregate {
                                    Text("Aggregate")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(NeutralCheckboxToggleStyle())
                        .disabled(viewModel.isPinnedSeries(series))
                    }
                }
            }
            .frame(maxHeight: maxHeight)
        }
    }

    private var seriesActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchModelsField
                selectAllButton
                clearModelsButton
                Spacer()
                seriesSelectionCount
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    searchModelsField
                    Spacer()
                    seriesSelectionCount
                }

                HStack(spacing: 10) {
                    selectAllButton
                    clearModelsButton
                    Spacer()
                }
            }
        }
    }

    private var searchModelsField: some View {
        TextField("Search models", text: $viewModel.seriesSearchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
    }

    private var selectAllButton: some View {
        Button("Select All") {
            viewModel.selectAllSeries()
        }
        .disabled(viewModel.selectedSeriesCount == viewModel.series.count)
    }

    private var clearModelsButton: some View {
        Button("Clear Models") {
            viewModel.clearModelSeries()
        }
        .disabled(!viewModel.hasSelectedModels)
    }

    private var seriesSelectionCount: some View {
        Text(viewModel.seriesSelectionSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var emptyState: some View {
        emptyState(viewModel.emptyStatePresentation)
    }

    private func emptyState(_ state: UsageHistoryEmptyStatePresentation) -> some View {
        VStack(spacing: 8) {
            Image(systemName: state.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(state.title)
                .font(.headline)
            Text(state.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hoverCallout(_ selection: UsageHistoryHoverSelection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.formattedBucketInterval(selection))
                .font(.caption.weight(.semibold))

            ForEach(selection.points) { point in
                HStack(spacing: 8) {
                    Text(viewModel.chartPointLabel(for: point))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(viewModel.formattedChartValue(for: point))
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.secondary.opacity(0.25))
        )
        .shadow(radius: 8, y: 3)
    }

    private func handleChartHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        switch phase {
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else {
                viewModel.clearHoverSelection()
                return
            }

            let plotRect = geometry[plotFrame]
            guard plotRect.contains(location) else {
                viewModel.clearHoverSelection()
                return
            }

            let xPosition = location.x - plotRect.origin.x
            guard let timestamp: Date = proxy.value(atX: xPosition) else {
                viewModel.clearHoverSelection()
                return
            }

            let calloutHalfWidth: CGFloat = 115
            let clampedX = min(
                max(location.x, calloutHalfWidth),
                max(calloutHalfWidth, geometry.size.width - calloutHalfWidth)
            )
            viewModel.scheduleHoverSelection(nearestTo: timestamp, xPosition: clampedX)
        case .ended:
            viewModel.scheduleClearHoverSelection()
        }
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
