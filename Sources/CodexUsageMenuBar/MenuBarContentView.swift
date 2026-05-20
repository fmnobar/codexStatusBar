import AppKit
import Charts
import SwiftUI

private enum MenuBarPopoverExpandedSection: Equatable {
    case history
    case settings
}

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel
    @ObservedObject var updateMonitor: AppUpdateMonitor
    let historyDatabase: UsageHistoryDatabaseWorking
    var onOpenTokenDashboard: () -> Void
    var onOpenUpdatesSettings: () -> Void
    var onContentSizeChange: (NSSize) -> Void
    var appVersionInfo: AppVersionInfo
    @StateObject private var freshnessViewModel: AppFreshnessStatusViewModel
    @StateObject private var historyViewModel: UsageHistoryViewModel
    @State private var expandedSection: MenuBarPopoverExpandedSection?

    init(
        viewModel: MenuBarStatusViewModel,
        historyDatabase: UsageHistoryDatabaseWorking,
        updateMonitor: AppUpdateMonitor = AppUpdateMonitor(),
        onOpenTokenDashboard: @escaping () -> Void = {},
        onOpenUpdatesSettings: @escaping () -> Void = {},
        onContentSizeChange: @escaping (NSSize) -> Void = { _ in },
        appVersionInfo: AppVersionInfo = .current(),
        freshnessViewModel: AppFreshnessStatusViewModel = .current()
    ) {
        self.viewModel = viewModel
        self.updateMonitor = updateMonitor
        self.historyDatabase = historyDatabase
        self.onOpenTokenDashboard = onOpenTokenDashboard
        self.onOpenUpdatesSettings = onOpenUpdatesSettings
        self.onContentSizeChange = onContentSizeChange
        self.appVersionInfo = appVersionInfo
        _freshnessViewModel = StateObject(wrappedValue: freshnessViewModel)
        _historyViewModel = StateObject(wrappedValue: UsageHistoryViewModel(database: historyDatabase))
    }

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
                tokenDashboardRow
                Divider()
                settingsSection
                Divider()
                if freshnessViewModel.shouldShowWarning {
                    staleBuildWarningRow
                    Divider()
                }
                if updateMonitor.promptPresentation != nil {
                    updatePromptRow
                    Divider()
                }
                footer
            }
        }
        .padding(10)
        .frame(width: popoverWidth, alignment: .topLeading)
        .background(PopoverMaterialBackground())
        .background(contentSizeReader)
        .onAppear {
            freshnessViewModel.refresh()
            historyViewModel.activateCurrentPeriod()
            Task {
                await updateMonitor.checkIfNeeded()
            }
        }
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
                CompactUsageHistoryPanel(viewModel: historyViewModel)
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

    private var tokenDashboardRow: some View {
        Button {
            onOpenTokenDashboard()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 14))
                    .frame(width: 14)

                Text("Token Dashboard")
                    .font(.system(size: 13))

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open detailed token dashboard")
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
            VStack(alignment: .leading, spacing: 6) {
                menuBarDisplayOptionsRow
                menuBarPreviewRow
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

            inlineCheckboxOption(
                title: "Tokens",
                isSelected: viewModel.menuBarDisplayOptions.showsTokens,
                action: {
                    viewModel.setMenuBarShowsTokens(!viewModel.menuBarDisplayOptions.showsTokens)
                }
            )
        }
        .font(.system(size: 12))
    }

    private var menuBarPreviewRow: some View {
        Text(viewModel.menuBarPercentText)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                refreshButtonIcon
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)
            .help(viewModel.isRefreshing ? "Refreshing…" : "Refresh")
            .accessibilityLabel(viewModel.isRefreshing ? "Refreshing" : "Refresh")
        }
    }

    @ViewBuilder
    private var refreshButtonIcon: some View {
        if viewModel.isRefreshing {
            TimelineView(.animation) { context in
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(refreshRotation(at: context.date))
                    .frame(width: 18, height: 18)
            }
        } else {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
        }
    }

    private var staleBuildWarningRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)

            Text(freshnessViewModel.popoverWarningText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if freshnessViewModel.canRelaunchLatestInstalledApp {
                Button("Relaunch") {
                    freshnessViewModel.relaunchLatestInstalledApp()
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.borderless)
                .help("Relaunch the installed app bundle")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var updatePromptRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.blue)

            Text(updateMonitor.promptPresentation?.titleText ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("Updates") {
                onOpenUpdatesSettings()
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.borderless)
            .help("Open Updates settings")

            Button("Later") {
                updateMonitor.snoozeCurrentPrompt()
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .help("Hide this update prompt for 24 hours")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

private enum CompactHistoryControlMetrics {
    static let controlHeight: CGFloat = 24
    static let groupSpacing: CGFloat = 10
    static let contextHeight: CGFloat = 88
    static let rangeWidth: CGFloat = 154
    static let limitWidth: CGFloat = 58
    static let tokenCategoryWidth: CGFloat = 82
    static let chartKindWidth: CGFloat = 160
    static let periodWidth: CGFloat = 112
    static let periodChevronWidth: CGFloat = 12
    static let periodSpacing: CGFloat = 4
    static let font = Font.system(size: 12)
    static let periodFont = Font.system(size: 11.2)

    static var controlRowWidth: CGFloat {
        rangeWidth + limitWidth + chartKindWidth + periodWidth + groupSpacing * 3
    }

    static var periodTitleWidth: CGFloat {
        periodWidth - periodChevronWidth * 2 - periodSpacing * 2
    }
}

private struct CompactHistorySegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value {
        value
    }
}

private struct CompactHistorySegmentedControl<Value: Hashable>: View {
    let segments: [CompactHistorySegment<Value>]
    @Binding var selection: Value
    let width: CGFloat

    var body: some View {
        HStack(spacing: 1) {
            ForEach(segments) { segment in
                Button {
                    selection = segment.value
                } label: {
                    Text(segment.title)
                        .font(CompactHistoryControlMetrics.font.weight(isSelected(segment) ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .frame(height: CompactHistoryControlMetrics.controlHeight - 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .background {
                    if isSelected(segment) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.18))
                    }
                }
                .accessibilityLabel(segment.title)
                .accessibilityAddTraits(isSelected(segment) ? .isSelected : [])
            }
        }
        .padding(1)
        .frame(width: width, height: CompactHistoryControlMetrics.controlHeight)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func isSelected(_ segment: CompactHistorySegment<Value>) -> Bool {
        selection == segment.value
    }
}

private struct CompactHistoryMenuControl<Value: Hashable>: View {
    let segments: [CompactHistorySegment<Value>]
    @Binding var selection: Value
    let width: CGFloat

    var body: some View {
        Menu {
            ForEach(segments) { segment in
                Button {
                    selection = segment.value
                } label: {
                    if selection == segment.value {
                        Label(segment.title, systemImage: "checkmark")
                    } else {
                        Text(segment.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedTitle)
                    .font(CompactHistoryControlMetrics.font.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: CompactHistoryControlMetrics.controlHeight - 2)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(1)
        .frame(width: width, height: CompactHistoryControlMetrics.controlHeight)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    private var selectedTitle: String {
        segments.first { $0.value == selection }?.title ?? ""
    }
}

private struct CompactUsageHistoryPanel: View {
    @ObservedObject private var viewModel: UsageHistoryViewModel
    private static let seriesColors: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .pink,
        .teal,
    ]

    init(viewModel: UsageHistoryViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls

            compactChartContext

            if viewModel.hasVisiblePoints {
                chart
                    .frame(height: 186)
            } else {
                emptyState
                    .frame(height: 186)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            viewModel.activateCurrentPeriod()
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: CompactHistoryControlMetrics.groupSpacing) {
            CompactHistorySegmentedControl(
                segments: UsageHistoryRange.allCases.map {
                    CompactHistorySegment(value: $0, title: $0.displayTitle)
                },
                selection: $viewModel.selectedRange,
                width: CompactHistoryControlMetrics.rangeWidth
            )

            compactSecondarySelector

            CompactHistorySegmentedControl(
                segments: UsageHistoryChartKind.allCases.map {
                    CompactHistorySegment(value: $0, title: $0.displayTitle)
                },
                selection: $viewModel.selectedChartKind,
                width: CompactHistoryControlMetrics.chartKindWidth
            )

            compactPeriodNavigation
        }
        .frame(width: CompactHistoryControlMetrics.controlRowWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var compactSecondarySelector: some View {
        if viewModel.selectedChartKind != .tokens {
            CompactHistorySegmentedControl(
                segments: UsageLimitWindow.allCases.map {
                    CompactHistorySegment(value: $0, title: $0.displayTitle)
                },
                selection: $viewModel.selectedWindow,
                width: CompactHistoryControlMetrics.limitWidth
            )
        } else {
            Color.clear
                .frame(width: CompactHistoryControlMetrics.limitWidth, height: CompactHistoryControlMetrics.controlHeight)
                .accessibilityHidden(true)
        }
    }

    private var compactPeriodNavigation: some View {
        HStack(alignment: .center, spacing: CompactHistoryControlMetrics.periodSpacing) {
            Button {
                viewModel.goToPreviousPeriod()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: CompactHistoryControlMetrics.periodChevronWidth, height: CompactHistoryControlMetrics.controlHeight)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToPreviousPeriod)
            .help(viewModel.previousPeriodHelpText)
            .accessibilityLabel(viewModel.previousPeriodAccessibilityLabel)

            Text(viewModel.compactPeriodTitle)
                .font(CompactHistoryControlMetrics.periodFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(width: CompactHistoryControlMetrics.periodTitleWidth)

            Button {
                viewModel.goToNextPeriod()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: CompactHistoryControlMetrics.periodChevronWidth, height: CompactHistoryControlMetrics.controlHeight)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToNextPeriod)
            .help(viewModel.nextPeriodHelpText)
            .accessibilityLabel(viewModel.nextPeriodAccessibilityLabel)
        }
        .frame(width: CompactHistoryControlMetrics.periodWidth, height: CompactHistoryControlMetrics.controlHeight)
    }

    private var chart: some View {
        ZStack(alignment: .topLeading) {
            Chart {
                ForEach(viewModel.visibleBarPoints) { point in
                    BarMark(
                        x: .value("Time", viewModel.chartXPosition(for: point)),
                        y: .value(viewModel.chartYAxisTitle, viewModel.chartValue(for: point)),
                        stacking: viewModel.selectedChartKind == .tokens ? .standard : .unstacked
                    )
                    .foregroundStyle(
                        viewModel.selectedChartKind == .tokens
                            ? tokenComponentColor(for: point)
                            : seriesColor(for: point.bucketID)
                    )
                    .opacity(point.bucketKind == .aggregate ? 0.84 : 0.66)
                }

                if let hoverSelection = viewModel.hoverSelection {
                    RuleMark(x: .value("Selected Time", viewModel.chartXPosition(for: hoverSelection)))
                        .foregroundStyle(.secondary.opacity(0.42))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    if viewModel.selectedChartKind != .tokens {
                        ForEach(hoverSelection.points) { point in
                            PointMark(
                                x: .value("Time", viewModel.chartXPosition(for: point)),
                                y: .value(viewModel.chartYAxisTitle, viewModel.chartValue(for: point))
                            )
                            .foregroundStyle(seriesColor(for: point.bucketID))
                            .symbolSize(point.bucketKind == .aggregate ? 48 : 36)
                        }
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
        }
    }

    private var compactChartContext: some View {
        VStack(alignment: .leading, spacing: 5) {
            if viewModel.selectedChartKind == .tokens {
                if let hoverSelection = viewModel.hoverSelection {
                    compactTokenHoverTable(for: hoverSelection)
                } else {
                    compactTokenLegendRows
                }
            } else {
                if let hoverSelection = viewModel.hoverSelection {
                    compactHoverReadout(for: hoverSelection)
                } else {
                    compactSeriesLegend
                }

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CompactHistoryControlMetrics.contextHeight, alignment: .topLeading)
        .padding(.horizontal, 10)
    }

    private var compactSeriesLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(compactLegendSeries) { series in
                    compactSeriesButton(series)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactLegendSeries: [UsageHistorySeries] {
        viewModel.sortedSeries.filter { series in
            if viewModel.selectedChartKind == .tokens {
                return true
            }

            return viewModel.selectedSeriesIDs.contains(series.id)
                || !viewModel.isDefaultHiddenSeries(series)
        }
    }

    private var compactTokenLegendRows: some View {
        compactTokenComponentLegend
    }

    private var compactTokenComponentLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TokenHistoryComponent.allCases) { component in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(tokenComponentColor(for: component))
                            .frame(width: 7, height: 7)

                        Text(component.displayTitle)
                            .font(.system(size: 9.5))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                }
            }
        }
    }

    private func compactHoverReadout(for selection: UsageHistoryHoverSelection) -> some View {
        HStack(spacing: 8) {
            Text(viewModel.formattedBucketInterval(selection))
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(hoverValueSummary(for: selection))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func compactTokenHoverTable(for selection: UsageHistoryHoverSelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.formattedBucketInterval(selection))
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow {
                        Text("")
                            .frame(width: 58, alignment: .leading)

                        ForEach(tokenHoverColumns(for: selection)) { series in
                            Text(viewModel.compactSeriesTitle(for: series.name))
                                .font(.system(size: 8.8, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(minWidth: 36, alignment: .trailing)
                        }
                    }

                    ForEach(TokenHistoryComponent.allCases) { component in
                        GridRow {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(tokenComponentColor(for: component))
                                    .frame(width: 6, height: 6)

                                Text(component.displayTitle)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 8.8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)

                            ForEach(tokenHoverColumns(for: selection)) { series in
                                Text(tokenHoverValue(selection: selection, series: series, component: component))
                                    .font(.system(size: 8.8))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .frame(minWidth: 36, alignment: .trailing)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func compactSeriesButton(_ series: UsageHistorySeries) -> some View {
        let isSelected = viewModel.selectedSeriesIDs.contains(series.id)
        let displayTitle = viewModel.compactSeriesTitle(for: series.name)

        return Button {
            if !viewModel.isPinnedSeries(series) {
                viewModel.setSeries(series.id, isSelected: !isSelected)
            }
        } label: {
            HStack(spacing: 4) {
                if viewModel.selectedChartKind == .tokens {
                    NeutralCheckboxMark(isSelected: isSelected, size: 9)
                        .opacity(series.kind == .aggregate || isSelected ? 1 : 0.56)
                } else {
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
                }

                Text(displayTitle)
                    .font(.system(size: viewModel.selectedChartKind == .tokens ? 9.5 : 9))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .opacity(series.kind == .aggregate || isSelected ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayTitle)
        .accessibilityValue(isSelected ? "Shown" : "Hidden")
        .help(viewModel.isPinnedSeries(series) ? "\(series.name) is always shown" : "Toggle \(series.name)")
    }

    private func hoverValueSummary(for selection: UsageHistoryHoverSelection) -> String {
        selection.points
            .map { point in
                "\(viewModel.chartPointLabel(for: point)) \(viewModel.formattedChartValue(for: point))"
            }
            .joined(separator: "  ")
    }

    private func seriesColor(for seriesID: String) -> Color {
        let orderedSeriesIDs = viewModel.sortedSeries.map(\.id)
        guard let index = orderedSeriesIDs.firstIndex(of: seriesID) else {
            return .secondary
        }

        return Self.seriesColors[index % Self.seriesColors.count]
    }

    private func tokenComponentColor(for point: UsageHistoryChartPoint) -> Color {
        tokenComponentColor(for: point.tokenComponent)
    }

    private func tokenComponentColor(for component: TokenHistoryComponent?) -> Color {
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

    private func tokenHoverColumns(for selection: UsageHistoryHoverSelection) -> [UsageHistorySeries] {
        let ids = Set(selection.points.map(\.bucketID))
        return viewModel.sortedSeries.filter { ids.contains($0.id) }
    }

    private func tokenHoverValue(
        selection: UsageHistoryHoverSelection,
        series: UsageHistorySeries,
        component: TokenHistoryComponent
    ) -> String {
        let tokenCount = selection.points
            .filter { $0.bucketID == series.id && $0.tokenComponent == component }
            .reduce(Int64(0)) { total, point in
                total + max(point.tokenCount ?? 0, 0)
            }

        guard tokenCount > 0 else {
            return "-"
        }

        return viewModel.formattedCompactTokenValue(tokenCount)
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
