@preconcurrency import AppKit
import Charts
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
    @Published var selectedRange: UsageHistoryRange = .day {
        didSet { reload() }
    }
    @Published var selectedWindow: UsageLimitWindow = .sevenDay {
        didSet { reload() }
    }
    @Published var selectedMetric: UsageHistoryMetric = .capacityLeft {
        didSet { clearHoverSelection() }
    }
    @Published var seriesSearchText = ""
    @Published private(set) var points: [UsageHistoryPoint] = []
    @Published private(set) var series: [UsageHistorySeries] = []
    @Published private(set) var selectedSeriesIDs = Set<String>()
    @Published private(set) var errorMessage: String?
    @Published private(set) var hoverSelection: UsageHistoryHoverSelection?
    @Published private(set) var hasAnyRecordedHistory = false
    let chartSemantics: UsageHistoryChartSemantics

    private let store: UsageHistoryStore
    private let now: () -> Date
    private let calendar: Calendar
    private var userEditedSeriesSelection = false
    private var historyObserver: NSObjectProtocol?

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

    var chartValueLabel: String {
        selectedMetric.displayTitle
    }

    var chartDomainStart: Date {
        Self.bucketWindow(for: selectedRange, now: now(), calendar: calendar).start
    }

    var chartDomainEnd: Date {
        Self.bucketWindow(for: selectedRange, now: now(), calendar: calendar).end
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
            let loadedPoints = try store.points(
                range: selectedRange,
                window: selectedWindow,
                now: now(),
                calendar: calendar
            )
            let loadedSeries = try store.series(
                range: selectedRange,
                window: selectedWindow,
                now: now(),
                calendar: calendar
            )
            let loadedHasAnyHistory = try store.hasAnyHistory()

            points = loadedPoints
            series = loadedSeries
            hasAnyRecordedHistory = loadedHasAnyHistory
            reconcileSelectedSeries()
            clearHoverSelection()
            errorMessage = nil
        } catch {
            points = []
            series = []
            selectedSeriesIDs = []
            hasAnyRecordedHistory = false
            clearHoverSelection()
            errorMessage = "History could not be loaded."
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
            selectedSeriesIDs = currentIDs
            return
        }

        selectedSeriesIDs.formIntersection(currentIDs)
        selectedSeriesIDs.formUnion(series.filter { $0.kind == .aggregate }.map(\.id))
        if selectedSeriesIDs.isEmpty {
            selectedSeriesIDs = currentIDs
            userEditedSeriesSelection = false
        }
    }

    private static func bucketedChartPoints(
        from points: [UsageHistoryPoint],
        range: UsageHistoryRange,
        window: UsageLimitWindow,
        now: Date,
        calendar: Calendar
    ) -> [UsageHistoryChartPoint] {
        let bucketComponent = range.chartBucketComponent
        let bucketWindow = bucketWindow(for: range, now: now, calendar: calendar)
        var buckets = [String: [UsageHistoryPoint]]()

        for point in points {
            let bucketStart = bucketStart(for: point.timestamp, component: bucketComponent, calendar: calendar)
            guard bucketStart >= bucketWindow.start, bucketStart < bucketWindow.end else {
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

            let bucketStart = bucketStart(for: latestPoint.timestamp, component: bucketComponent, calendar: calendar)
            let uncappedBucketEnd = calendar.date(byAdding: bucketComponent, value: 1, to: bucketStart) ?? bucketStart
            let peakUsedPercent = bucketPoints.map(\.peakUsedPercent).max() ?? latestPoint.peakUsedPercent

            return UsageHistoryChartPoint(
                bucketStart: bucketStart,
                bucketEnd: min(uncappedBucketEnd, now),
                sampleTimestamp: latestPoint.timestamp,
                bucketID: firstPoint.bucketID,
                bucketName: latestPoint.bucketName,
                bucketKind: latestPoint.bucketKind,
                window: window,
                latestUsedPercent: latestPoint.usedPercent,
                peakUsedPercent: peakUsedPercent
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

    private static func bucketWindow(
        for range: UsageHistoryRange,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        let component = range.chartBucketComponent
        let currentBucketStart = bucketStart(for: now, component: component, calendar: calendar)

        let bucketCountBack: Int
        switch range {
        case .day:
            bucketCountBack = 23
        case .week:
            bucketCountBack = 6
        case .month:
            let monthStart = range.startDate(before: now, calendar: calendar)
            let start = bucketStart(for: monthStart, component: component, calendar: calendar)
            let end = calendar.date(byAdding: component, value: 1, to: currentBucketStart) ?? now
            return (start, end)
        case .year:
            bucketCountBack = 11
        }

        let start = calendar.date(byAdding: component, value: -bucketCountBack, to: currentBucketStart) ?? currentBucketStart
        let end = calendar.date(byAdding: component, value: 1, to: currentBucketStart) ?? now
        return (start, end)
    }

    private static func bucketStart(
        for date: Date,
        component: Calendar.Component,
        calendar: Calendar
    ) -> Date {
        let components: Set<Calendar.Component>
        switch component {
        case .hour:
            components = [.year, .month, .day, .hour]
        case .day:
            components = [.year, .month, .day]
        case .month:
            components = [.year, .month]
        default:
            components = [.year, .month, .day]
        }

        return calendar.date(from: calendar.dateComponents(components, from: date)) ?? date
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

    private func fullBucketEnd(for bucketStart: Date) -> Date {
        calendar.date(byAdding: selectedRange.chartBucketComponent, value: 1, to: bucketStart) ?? bucketStart
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
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            Text(viewModel.chartSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if viewModel.hasVisiblePoints {
                chart
            } else {
                emptyState
            }

            if viewModel.hasHistory {
                seriesSelector
            }
        }
        .padding(.top, 34)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            viewModel.reload()
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Spacer()

            Button {
                viewModel.exportCSV()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(!viewModel.canExport)

            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(!viewModel.hasHistory)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("Range", selection: $viewModel.selectedRange) {
                    ForEach(UsageHistoryRange.allCases) { range in
                        Text(range.displayTitle).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Picker("Limit", selection: $viewModel.selectedWindow) {
                    ForEach(UsageLimitWindow.allCases) { window in
                        Text(window.displayTitle).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                Spacer()

                Text(viewModel.chartPointCountSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            HStack(spacing: 16) {
                Picker("Metric", selection: $viewModel.selectedMetric) {
                    ForEach(UsageHistoryMetric.allCases) { metric in
                        Text(metric.displayTitle).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)

                Spacer()
            }
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
            .chartYScale(domain: 0...100)
            .chartXScale(domain: viewModel.chartDomainStart...viewModel.chartDomainEnd)
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
        .frame(minHeight: 280)
    }

    private var seriesSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search models", text: $viewModel.seriesSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Button("Select All") {
                    viewModel.selectAllSeries()
                }
                .disabled(viewModel.selectedSeriesCount == viewModel.series.count)

                Button("Clear Models") {
                    viewModel.clearModelSeries()
                }
                .disabled(!viewModel.hasSelectedModels)

                Spacer()

                Text(viewModel.seriesSelectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

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
                        .toggleStyle(.checkbox)
                        .disabled(series.kind == .aggregate)
                    }
                }
            }
            .frame(maxHeight: 112)
        }
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
            viewModel.updateHoverSelection(nearestTo: timestamp, xPosition: clampedX)
        case .ended:
            viewModel.clearHoverSelection()
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
