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
    @Published var selectedRange: UsageHistoryRange = .month {
        didSet {
            selectedPeriodStart = currentPeriodStart()
            scheduleReload()
        }
    }
    @Published var selectedWindow: UsageLimitWindow = .sevenDay {
        didSet { scheduleReload() }
    }
    @Published var selectedMetric: UsageHistoryMetric = .capacityLeft {
        didSet { scheduleClearHoverSelection() }
    }
    @Published var seriesSearchText = ""
    @Published private(set) var points: [UsageHistoryPoint] = []
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
    private var historyBounds: UsageHistoryBounds?
    private var userEditedSeriesSelection = false
    private var historyObserver: NSObjectProtocol?
    private var reloadWorkItem: DispatchWorkItem?
    private var hoverSelectionWorkItem: DispatchWorkItem?

    init(
        store: UsageHistoryStore,
        chartSemantics: UsageHistoryChartSemantics = .independentSignals,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
        self.chartSemantics = chartSemantics
        self.now = now
        self.calendar = calendar
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

    var chartPoints: [UsageHistoryChartPoint] {
        Self.bucketedChartPoints(
            from: points,
            range: selectedRange,
            window: selectedWindow,
            period: selectedPeriod,
            now: now(),
            calendar: calendar
        )
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
        selectedMetric.subtitle(for: selectedRange)
    }

    var chartYAxisTitle: String {
        selectedMetric.axisTitle
    }

    var chartYDomain: ClosedRange<Double> {
        switch selectedMetric {
        case .capacityLeft:
            return 0...100
        case .usage:
            let hasHighUsage = visibleChartPoints.contains { point in
                point.value(for: .usage) > 50
            }
            return hasHighUsage ? 0...100 : 0...50
        }
    }

    var chartValueLabel: String {
        selectedMetric.displayTitle
    }

    var selectedPeriod: UsageHistoryPeriod {
        period(startingAt: selectedPeriodStart)
    }

    var periodTitle: String {
        Self.periodTitle(for: selectedRange, period: selectedPeriod, calendar: calendar)
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
        "\(visibleChartPoints.count) bars"
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
            title: "No \(selectedWindow.displayTitle) data for \(selectedRange.displayTitle)",
            message: "Choose a different range or limit window to inspect recorded samples."
        )
    }

    var hasHistory: Bool {
        !points.isEmpty
    }

    func reload() {
        do {
            let queryPeriod = periodForQuery()
            let loadedPoints = try store.points(
                range: selectedRange,
                window: selectedWindow,
                periodStart: queryPeriod.start,
                periodEnd: queryPeriod.end
            )
            let loadedSeries = try store.series(
                range: selectedRange,
                window: selectedWindow,
                periodStart: queryPeriod.start,
                periodEnd: queryPeriod.end
            )
            let loadedHasAnyHistory = try store.hasAnyHistory()
            let loadedHistoryBounds = try store.historyBounds(
                window: selectedWindow,
                granularity: selectedRange.storageGranularity
            )

            points = loadedPoints
            series = loadedSeries
            hasAnyRecordedHistory = loadedHasAnyHistory
            historyBounds = loadedHistoryBounds
            reconcileSelectedSeries()
            clearHoverSelection()
            errorMessage = nil
        } catch {
            points = []
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

        if !isSelected, targetSeries.kind == .aggregate {
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
        let candidates = visibleChartPoints
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

        let selectedPoints = candidates
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

        selectedPeriodStart = periodOffset(from: selectedPeriodStart, value: -1)
        clearHoverSelection()
    }

    func goToNextPeriod() {
        guard canGoToNextPeriod else {
            return
        }

        selectedPeriodStart = min(periodOffset(from: selectedPeriodStart, value: 1), currentPeriodStart())
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
            panel.nameFieldStringValue = "codex-usage-\(selectedRange.rawValue)-\(selectedWindow.rawValue)-\(selectedMetric.rawValue).csv"

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
        selectedSeriesIDs.formUnion(series.filter { $0.kind == .aggregate }.map(\.id))
        if selectedSeriesIDs.isEmpty {
            selectedSeriesIDs = Self.defaultSelectedSeriesIDs(from: series)
            userEditedSeriesSelection = false
        }
    }

    private static func defaultSelectedSeriesIDs(from series: [UsageHistorySeries]) -> Set<String> {
        Set(series.filter { !isHiddenByDefault($0) }.map(\.id))
    }

    private static func isHiddenByDefault(_ series: UsageHistorySeries) -> Bool {
        series.kind == .model && series.name.compare(
            "GPT-5.3-Codex-Spark",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
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
            .help("Previous \(viewModel.selectedRange.displayTitle.lowercased())")
            .accessibilityLabel("Previous \(viewModel.selectedRange.displayTitle)")

            Text(viewModel.periodTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 72, alignment: .center)

            Button {
                viewModel.goToNextPeriod()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToNextPeriod)
            .help("Next \(viewModel.selectedRange.displayTitle.lowercased())")
            .accessibilityLabel("Next \(viewModel.selectedRange.displayTitle)")
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
            chartSemantics: chartSemantics
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
            viewModel.scheduleReload()
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
                limitPicker
                metricPicker
                Spacer()
                chartPointCount
                historyActions
            }

            HStack(spacing: 10) {
                rangePicker
                limitPicker
                metricPicker
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

    private var metricPicker: some View {
        Picker("Metric", selection: $viewModel.selectedMetric) {
            ForEach(UsageHistoryMetric.allCases) { metric in
                Text(metric.displayTitle).tag(metric)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 216)
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
                if viewModel.chartSemantics == .comparableContributors {
                    ForEach(viewModel.visibleContributorPoints) { point in
                        BarMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, point.value(for: viewModel.selectedMetric)),
                            stacking: .standard
                        )
                        .foregroundStyle(by: .value("Bucket", point.bucketName))
                        .opacity(0.72)
                    }

                    ForEach(viewModel.visibleAggregateReferencePoints) { point in
                        LineMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, point.value(for: viewModel.selectedMetric)),
                            series: .value("Bucket", point.bucketName)
                        )
                        .foregroundStyle(by: .value("Bucket", point.bucketName))
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                } else {
                    ForEach(viewModel.visibleBarPoints) { point in
                        BarMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, point.value(for: viewModel.selectedMetric)),
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
                            y: .value(viewModel.chartYAxisTitle, point.value(for: viewModel.selectedMetric))
                        )
                        .foregroundStyle(by: .value("Bucket", point.bucketName))
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
                        .disabled(series.kind == .aggregate)
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
                    Text(point.bucketName)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(point.value(for: viewModel.selectedMetric), specifier: "%.0f")%")
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

            return lhs.bucketName.localizedStandardCompare(rhs.bucketName) == .orderedAscending
        }
    }
}
