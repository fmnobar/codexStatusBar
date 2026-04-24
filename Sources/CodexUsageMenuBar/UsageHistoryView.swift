@preconcurrency import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum UsageHistoryChartSemantics: Equatable {
    case independentSignals
    case comparableContributors

    var subtitle: String {
        switch self {
        case .independentSignals:
            return "Sampled rate-limit usage signals by bucket"
        case .comparableContributors:
            return "Sampled model usage contributors with aggregate reference"
        }
    }
}

struct UsageHistoryHoverSelection: Equatable {
    let timestamp: Date
    let points: [UsageHistoryPoint]
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

    var hasVisiblePoints: Bool {
        !visiblePoints.isEmpty
    }

    var canExport: Bool {
        hasVisiblePoints
    }

    var chartSubtitle: String {
        chartSemantics.subtitle
    }

    var visibleLinePoints: [UsageHistoryPoint] {
        switch chartSemantics {
        case .independentSignals:
            return visiblePoints
        case .comparableContributors:
            return visibleAggregateReferencePoints
        }
    }

    var visibleContributorPoints: [UsageHistoryPoint] {
        guard chartSemantics == .comparableContributors else {
            return []
        }

        return visiblePoints.filter { $0.bucketKind == .model }
    }

    var visibleAggregateReferencePoints: [UsageHistoryPoint] {
        visiblePoints.filter { $0.bucketKind == .aggregate }
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
        let candidates = visiblePoints
        guard !candidates.isEmpty else {
            clearHoverSelection()
            return
        }

        let timestamps = Array(Set(candidates.map(\.timestamp))).sorted()
        guard let nearestTimestamp = timestamps.min(by: { lhs, rhs in
            let lhsDistance = abs(lhs.timeIntervalSince(timestamp))
            let rhsDistance = abs(rhs.timeIntervalSince(timestamp))
            if lhsDistance == rhsDistance {
                return lhs < rhs
            }

            return lhsDistance < rhsDistance
        }) else {
            clearHoverSelection()
            return
        }

        hoverSelection = UsageHistoryHoverSelection(
            timestamp: nearestTimestamp,
            points: candidates
                .filter { $0.timestamp == nearestTimestamp }
                .sortedByDisplayOrder(),
            xPosition: xPosition
        )
    }

    func clearHoverSelection() {
        hoverSelection = nil
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
            let csv = try store.csv(
                range: selectedRange,
                window: selectedWindow,
                now: now(),
                calendar: calendar
            )
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "codex-usage-\(selectedRange.rawValue)-\(selectedWindow.rawValue).csv"

            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            try Data(csv.utf8).write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "History could not be exported."
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
        .padding(20)
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
            VStack(alignment: .leading, spacing: 3) {
                Text("Usage History")
                    .font(.title2.weight(.semibold))
                Text(viewModel.chartSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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

            Text("\(viewModel.visiblePoints.count) points")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var chart: some View {
        ZStack(alignment: .topLeading) {
            Chart {
                if viewModel.chartSemantics == .comparableContributors {
                    ForEach(viewModel.visibleContributorPoints) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Used", point.usedPercent),
                            stacking: .standard
                        )
                        .foregroundStyle(by: .value("Bucket", point.bucketName))
                        .opacity(0.65)
                    }
                }

                ForEach(viewModel.visibleLinePoints) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used", point.usedPercent),
                        series: .value("Bucket", point.bucketName)
                    )
                    .foregroundStyle(by: .value("Bucket", point.bucketName))
                    .lineStyle(StrokeStyle(lineWidth: point.bucketKind == .aggregate ? 2.5 : 1.8))
                }

                if let hoverSelection = viewModel.hoverSelection {
                    RuleMark(x: .value("Selected Time", hoverSelection.timestamp))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    ForEach(hoverSelection.points) { point in
                        PointMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Used", point.usedPercent)
                        )
                        .foregroundStyle(by: .value("Bucket", point.bucketName))
                        .symbolSize(point.bucketKind == .aggregate ? 58 : 42)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxisLabel("Used %")
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
            Text(selection.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold))

            ForEach(selection.points) { point in
                HStack(spacing: 8) {
                    Text(point.bucketName)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(point.usedPercent, specifier: "%.0f")%")
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
