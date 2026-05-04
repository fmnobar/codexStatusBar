import AppKit
import Charts
import SwiftUI

private enum MenuBarPopoverExpandedSection: Equatable {
    case history
    case settings
}

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel
    let historyStore: UsageHistoryStore
    var onContentSizeChange: (NSSize) -> Void = { _ in }
    var appVersionInfo: AppVersionInfo = .current()
    @State private var expandedSection: MenuBarPopoverExpandedSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isLoading && !viewModel.hasSnapshot {
                Text("Loading…")
                    .font(.system(size: 13))
            } else if let errorMessage = viewModel.errorMessage, !viewModel.hasSnapshot {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Retry") {
                    Task {
                        await viewModel.manualRefresh()
                    }
                }
            } else {
                limitSelectionRow
                Divider()
                historySection
                Divider()
                settingsSection
                Divider()
                footer
            }
        }
        .padding(10)
        .frame(width: popoverWidth, alignment: .topLeading)
        .background(PopoverMaterialBackground())
        .background(contentSizeReader)
    }

    private var popoverWidth: CGFloat {
        560
    }

    private var contentSizeReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PopoverContentSizePreferenceKey.self, value: proxy.size)
        }
        .onPreferenceChange(PopoverContentSizePreferenceKey.self) { size in
            guard size.width > 0, size.height > 0 else {
                return
            }

            onContentSizeChange(NSSize(width: ceil(size.width), height: ceil(size.height)))
        }
    }

    @ViewBuilder
    private var limitSelectionRow: some View {
        HStack(alignment: .top, spacing: 8) {
            compactSelectableRow(viewModel.fiveHourRow)
            compactSelectableRow(viewModel.sevenDayRow)
            compactSelectableRow(viewModel.tightestRow)
        }
    }

    private func compactSelectableRow(_ row: MenuBarLimitRowPresentation) -> some View {
        Button {
            viewModel.selectMenuBarDisplayWindow(row.displayWindow)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                checkboxImage(isSelected: row.isSelected, size: 12)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(row.title.replacingOccurrences(of: " limit", with: ""))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        if !row.remainingPercentText.isEmpty {
                            Text(row.remainingPercentText.replacingOccurrences(of: " left", with: ""))
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }

                    if !row.detailText.isEmpty {
                        Text(row.detailText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            expandableHeader(title: "History", systemImage: "chart.xyaxis.line", section: .history)

            if expandedSection == .history {
                CompactUsageHistoryPanel(store: historyStore)
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            expandableHeader(title: "Settings", systemImage: "gearshape", section: .settings)

            if expandedSection == .settings {
                inlineSettings
            }
        }
    }

    private func expandableHeader(
        title: String,
        systemImage: String,
        section: MenuBarPopoverExpandedSection
    ) -> some View {
        Button {
            expandedSection = expandedSection == section ? nil : section
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 13))

                Spacer(minLength: 0)

                Image(systemName: expandedSection == section ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var inlineSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Menu Bar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                menuBarDisplayOptionsRow
            }

            Divider()

            Button {
                viewModel.setLaunchAtLoginEnabled(!viewModel.launchAtLoginEnabled)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    checkboxImage(isSelected: viewModel.launchAtLoginEnabled)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(.system(size: 13))

                        if let launchAtLoginError = viewModel.launchAtLoginError {
                            Text(launchAtLoginError)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var menuBarDisplayOptionsRow: some View {
        HStack(alignment: .center, spacing: 14) {
            inlineCheckboxOption(
                title: "7d/5h",
                isSelected: viewModel.menuBarDisplayOptions.showsLimitLabel,
                action: {
                    viewModel.setMenuBarShowsLimitLabel(!viewModel.menuBarDisplayOptions.showsLimitLabel)
                }
            )

            inlineCheckboxOption(
                title: "Reset date",
                isSelected: viewModel.menuBarDisplayOptions.showsResetDate,
                action: {
                    viewModel.setMenuBarShowsResetDate(!viewModel.menuBarDisplayOptions.showsResetDate)
                }
            )

            inlineCheckboxOption(
                title: "Reset time",
                isSelected: viewModel.menuBarDisplayOptions.showsResetTime,
                action: {
                    viewModel.setMenuBarShowsResetTime(!viewModel.menuBarDisplayOptions.showsResetTime)
                }
            )

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("Preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(viewModel.menuBarPercentText)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
    }

    private func inlineCheckboxOption(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                checkboxImage(isSelected: isSelected)

                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "On" : "Off")
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            if let footerStatusText = viewModel.footerStatusText {
                Text(footerStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(viewModel.isStaleSnapshot ? .orange : .secondary)
                    .lineLimit(1)

                Text("•")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Text(appVersionInfo.versionBuildText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                Task {
                    await viewModel.manualRefresh()
                }
            } label: {
                TimelineView(.animation) { context in
                    let rotation = refreshRotation(at: context.date)

                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .rotationEffect(rotation)
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)
            .help(viewModel.isRefreshing ? "Refreshing…" : "Refresh")
            .accessibilityLabel(viewModel.isRefreshing ? "Refreshing" : "Refresh")
        }
    }

    private func refreshRotation(at date: Date) -> Angle {
        guard viewModel.isRefreshing else {
            return .degrees(0)
        }

        let cycleDuration = 0.9
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration

        return .degrees(progress * 360)
    }

    private func checkboxImage(isSelected: Bool) -> some View {
        checkboxImage(isSelected: isSelected, size: 12)
    }

    private func checkboxImage(isSelected: Bool, size: CGFloat) -> some View {
        NeutralCheckboxMark(isSelected: isSelected, size: size)
    }
}

private struct CompactUsageHistoryPanel: View {
    @StateObject private var viewModel: UsageHistoryViewModel
    private static let seriesColors: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .pink,
        .teal,
    ]

    init(store: UsageHistoryStore) {
        _viewModel = StateObject(wrappedValue: UsageHistoryViewModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls

            if viewModel.hasVisiblePoints {
                chart
                    .frame(height: 206)
            } else {
                emptyState
                    .frame(height: 206)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            viewModel.activateCurrentPeriod()
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 9) {
            Picker("Range", selection: $viewModel.selectedRange) {
                ForEach(UsageHistoryRange.allCases) { range in
                    Text(range.displayTitle).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 156)

            Picker("Limit", selection: $viewModel.selectedWindow) {
                ForEach(UsageLimitWindow.allCases) { window in
                    Text(window.displayTitle).tag(window)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 70)

            Picker("Metric", selection: $viewModel.selectedMetric) {
                ForEach(UsageHistoryMetric.allCases) { metric in
                    Text(compactMetricTitle(metric)).tag(metric)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 130)

            compactPeriodNavigation
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private var compactPeriodNavigation: some View {
        HStack(alignment: .center, spacing: 3) {
            Button {
                viewModel.goToPreviousPeriod()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToPreviousPeriod)
            .help(viewModel.previousPeriodHelpText)
            .accessibilityLabel(viewModel.previousPeriodAccessibilityLabel)

            Text(viewModel.periodTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                viewModel.goToNextPeriod()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToNextPeriod)
            .help(viewModel.nextPeriodHelpText)
            .accessibilityLabel(viewModel.nextPeriodAccessibilityLabel)
        }
        .frame(width: 120, alignment: .center)
    }

    private var chart: some View {
        ZStack(alignment: .topLeading) {
            Chart {
                ForEach(viewModel.visibleBarPoints) { point in
                    BarMark(
                        x: .value("Time", viewModel.chartXPosition(for: point)),
                        y: .value(viewModel.chartYAxisTitle, point.value(for: viewModel.selectedMetric)),
                        stacking: .unstacked
                    )
                    .foregroundStyle(seriesColor(for: point.bucketID))
                    .opacity(point.bucketKind == .aggregate ? 0.84 : 0.66)
                }

                if let hoverSelection = viewModel.hoverSelection {
                    RuleMark(x: .value("Selected Time", viewModel.chartXPosition(for: hoverSelection)))
                        .foregroundStyle(.secondary.opacity(0.42))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    ForEach(hoverSelection.points) { point in
                        PointMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value(viewModel.chartYAxisTitle, point.value(for: viewModel.selectedMetric))
                        )
                        .foregroundStyle(seriesColor(for: point.bucketID))
                        .symbolSize(point.bucketKind == .aggregate ? 48 : 36)
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
            .chartLegend(.hidden)
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

            chartTopOverlay
        }
    }

    private var chartTopOverlay: some View {
        HStack(alignment: .top, spacing: 8) {
            compactSeriesLegend

            Spacer(minLength: 0)

            if let hoverSelection = viewModel.hoverSelection {
                hoverSummary(for: hoverSelection)
                    .allowsHitTesting(false)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 6)
    }

    private var compactSeriesLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.sortedSeries) { series in
                    compactSeriesButton(series)
                }
            }
        }
        .frame(maxWidth: 310, alignment: .leading)
    }

    private func compactSeriesButton(_ series: UsageHistorySeries) -> some View {
        let isSelected = viewModel.selectedSeriesIDs.contains(series.id)

        return Button {
            if series.kind != .aggregate {
                viewModel.setSeries(series.id, isSelected: !isSelected)
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(seriesColor(for: series.id))
                    .frame(width: 7, height: 7)
                    .opacity(isSelected ? 1 : 0.28)
                    .overlay {
                        if !isSelected {
                            Circle()
                                .stroke(seriesColor(for: series.id).opacity(0.7), lineWidth: 1)
                        }
                    }

                Text(series.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .opacity(series.kind == .aggregate || isSelected ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(series.name)
        .accessibilityValue(isSelected ? "Shown" : "Hidden")
        .help(series.kind == .aggregate ? "\(series.name) is always shown" : "Toggle \(series.name)")
    }

    private func hoverSummary(for selection: UsageHistoryHoverSelection) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(viewModel.formattedBucketInterval(selection))
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(hoverValueSummary(for: selection))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func hoverValueSummary(for selection: UsageHistoryHoverSelection) -> String {
        selection.points
            .map { point in
                "\(point.bucketName) \(Int(point.value(for: viewModel.selectedMetric).rounded()))%"
            }
            .joined(separator: "  ")
    }

    private func compactMetricTitle(_ metric: UsageHistoryMetric) -> String {
        switch metric {
        case .capacityLeft:
            return "Capacity"
        case .usage:
            return metric.displayTitle
        }
    }

    private func seriesColor(for seriesID: String) -> Color {
        let orderedSeriesIDs = viewModel.sortedSeries.map(\.id)
        guard let index = orderedSeriesIDs.firstIndex(of: seriesID) else {
            return .secondary
        }

        return Self.seriesColors[index % Self.seriesColors.count]
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

            viewModel.scheduleHoverSelection(nearestTo: timestamp, xPosition: xPosition)
        case .ended:
            viewModel.scheduleClearHoverSelection()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: viewModel.emptyStatePresentation.systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            Text(viewModel.emptyStatePresentation.title)
                .font(.system(size: 12, weight: .semibold))

            Text(viewModel.emptyStatePresentation.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }
}

private struct PopoverContentSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let nextValue = nextValue()
        guard nextValue != .zero else {
            return
        }

        value = nextValue
    }
}

private struct PopoverMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
    }
}
