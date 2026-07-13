@preconcurrency import AppKit
import Charts
import SwiftUI

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

struct UsageHistoryView: View {
    @StateObject private var viewModel: UsageHistoryViewModel
    @State private var isConfirmingClear = false

    init(
        database: UsageHistoryDatabaseWorking,
        chartSemantics: UsageHistoryChartSemantics = .independentSignals
    ) {
        _viewModel = StateObject(wrappedValue: UsageHistoryViewModel(
            database: database,
            chartSemantics: chartSemantics
        ))
    }

    var body: some View {
        GeometryReader { geometry in
            let showsSeriesSelector = viewModel.hasHistory && viewModel.selectedChartKind != .tokens
            let layout = UsageHistoryLayoutMetrics(
                availableSize: geometry.size,
                hasHistory: showsSeriesSelector
            )

            content(layout: layout, showsSeriesSelector: showsSeriesSelector)
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

    private func content(
        layout: UsageHistoryLayoutMetrics,
        showsSeriesSelector: Bool
    ) -> some View {
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

            if showsSeriesSelector {
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
            .help(AppAccessibilitySemantics.exportCSVLabel)
            .accessibilityLabel(AppAccessibilitySemantics.exportCSVLabel)

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
