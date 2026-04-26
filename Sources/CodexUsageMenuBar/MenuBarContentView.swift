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
            Toggle(
                "7d/5h",
                isOn: Binding(
                    get: { viewModel.menuBarDisplayOptions.showsLimitLabel },
                    set: { viewModel.setMenuBarShowsLimitLabel($0) }
                )
            )
            .toggleStyle(.checkbox)

            Toggle(
                "Reset date",
                isOn: Binding(
                    get: { viewModel.menuBarDisplayOptions.showsResetDate },
                    set: { viewModel.setMenuBarShowsResetDate($0) }
                )
            )
            .toggleStyle(.checkbox)

            Toggle(
                "Reset time",
                isOn: Binding(
                    get: { viewModel.menuBarDisplayOptions.showsResetTime },
                    set: { viewModel.setMenuBarShowsResetTime($0) }
                )
            )
            .toggleStyle(.checkbox)

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
        checkboxImage(isSelected: isSelected, size: 14)
    }

    private func checkboxImage(isSelected: Bool, size: CGFloat) -> some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.system(size: size))
            .frame(width: size, alignment: .top)
    }
}

private struct CompactUsageHistoryPanel: View {
    @StateObject private var viewModel: UsageHistoryViewModel

    init(store: UsageHistoryStore) {
        _viewModel = StateObject(wrappedValue: UsageHistoryViewModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls

            hoverSummary

            if viewModel.hasVisiblePoints {
                chart
                    .frame(height: 190)
            } else {
                emptyState
                    .frame(height: 190)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            viewModel.scheduleReload()
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 8) {
            Picker("Range", selection: $viewModel.selectedRange) {
                ForEach(UsageHistoryRange.allCases) { range in
                    Text(range.displayTitle).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)

            Picker("Limit", selection: $viewModel.selectedWindow) {
                ForEach(UsageLimitWindow.allCases) { window in
                    Text(window.displayTitle).tag(window)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 82)

            Picker("Metric", selection: $viewModel.selectedMetric) {
                ForEach(UsageHistoryMetric.allCases) { metric in
                    Text(metric.displayTitle).tag(metric)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        .controlSize(.small)
    }

    private var chart: some View {
        Chart {
            ForEach(viewModel.visibleBarPoints) { point in
                BarMark(
                    x: .value("Time", viewModel.chartXPosition(for: point)),
                    y: .value(viewModel.chartYAxisTitle, point.value(for: viewModel.selectedMetric)),
                    stacking: .unstacked
                )
                .foregroundStyle(by: .value("Bucket", point.bucketName))
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
                    .foregroundStyle(by: .value("Bucket", point.bucketName))
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
                    AxisValueLabel(viewModel.chartXAxisLabel(for: date))
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
    }

    private var hoverSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let hoverSelection = viewModel.hoverSelection {
                Text(viewModel.formattedBucketInterval(hoverSelection))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)

                Text(hoverValueSummary(for: hoverSelection))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(viewModel.chartSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                UsageHistoryPeriodNavigationView(viewModel: viewModel)

                Spacer(minLength: 0)

                Text(viewModel.chartPointCountSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(height: 16)
    }

    private func hoverValueSummary(for selection: UsageHistoryHoverSelection) -> String {
        selection.points
            .map { point in
                "\(point.bucketName) \(Int(point.value(for: viewModel.selectedMetric).rounded()))%"
            }
            .joined(separator: "  ")
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
