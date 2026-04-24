@preconcurrency import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class UsageHistoryViewModel: ObservableObject {
    @Published var selectedRange: UsageHistoryRange = .day {
        didSet { reload() }
    }
    @Published var selectedWindow: UsageLimitWindow = .sevenDay {
        didSet { reload() }
    }
    @Published private(set) var points: [UsageHistoryPoint] = []
    @Published private(set) var series: [UsageHistorySeries] = []
    @Published private(set) var selectedSeriesIDs = Set<String>()
    @Published private(set) var errorMessage: String?

    private let store: UsageHistoryStore
    private let now: () -> Date
    private let calendar: Calendar
    private var userEditedSeriesSelection = false
    private var historyObserver: NSObjectProtocol?

    init(
        store: UsageHistoryStore,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
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

            points = loadedPoints
            series = loadedSeries
            reconcileSelectedSeries()
            errorMessage = nil
        } catch {
            points = []
            series = []
            selectedSeriesIDs = []
            errorMessage = "History could not be loaded."
        }
    }

    func binding(for series: UsageHistorySeries) -> Binding<Bool> {
        Binding(
            get: { self.selectedSeriesIDs.contains(series.id) },
            set: { isSelected in
                self.userEditedSeriesSelection = true
                if isSelected {
                    self.selectedSeriesIDs.insert(series.id)
                } else {
                    self.selectedSeriesIDs.remove(series.id)
                }
            }
        )
    }

    func clearHistory() {
        do {
            try store.clearHistory()
            userEditedSeriesSelection = false
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
        if selectedSeriesIDs.isEmpty {
            selectedSeriesIDs = currentIDs
            userEditedSeriesSelection = false
        }
    }
}

struct UsageHistoryView: View {
    @StateObject private var viewModel: UsageHistoryViewModel
    @State private var isConfirmingClear = false

    init(store: UsageHistoryStore) {
        _viewModel = StateObject(wrappedValue: UsageHistoryViewModel(store: store))
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

            if viewModel.hasHistory {
                chart
                seriesToggles
            } else {
                emptyState
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
                Text("Sampled rate-limit usage by model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.exportCSV()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(!viewModel.hasHistory)

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
        Chart(viewModel.visiblePoints) { point in
            LineMark(
                x: .value("Time", point.timestamp),
                y: .value("Used", point.usedPercent),
                series: .value("Model", point.bucketName)
            )
            .foregroundStyle(by: .value("Model", point.bucketName))
            .lineStyle(StrokeStyle(lineWidth: point.bucketKind == .aggregate ? 2.5 : 1.8))
        }
        .chartYScale(domain: 0...100)
        .chartYAxisLabel("Used %")
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(minHeight: 280)
    }

    private var seriesToggles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(viewModel.series) { series in
                    Toggle(isOn: viewModel.binding(for: series)) {
                        Text(series.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .fixedSize()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No history for this range")
                .font(.headline)
            Text("Usage samples are recorded when Codex Status Bar refreshes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
