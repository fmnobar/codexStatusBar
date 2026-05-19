@preconcurrency import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum TokenDashboardSeriesKind: String, Equatable {
    case aggregate
    case model
    case effort
    case project
    case dimension
    case unattributed
}

enum TokenDashboardBreakdownDimension: String, CaseIterable, Identifiable, Equatable {
    case model
    case effort
    case project
    case originator
    case sourceKind = "source_kind"
    case threadSource = "thread_source"
    case cliVersion = "cli_version"
    case modelProvider = "model_provider"
    case memoryMode = "memory_mode"
    case approvalPolicy = "approval_policy"
    case sandboxType = "sandbox_type"
    case permissionProfile = "permission_profile"
    case realtimeActive = "realtime_active"
    case truncationPolicy = "truncation_policy"
    case isSubagent = "is_subagent"
    case subagentParentThreadID = "subagent_parent_thread_id"
    case subagentDepth = "subagent_depth"
    case agentRole = "agent_role"
    case agentNickname = "agent_nickname"
    case usageMode = "usage_mode"

    var id: String {
        rawValue
    }

    var displayTitle: String {
        if let dimensionKey {
            return dimensionKey.dashboardDisplayTitle
        }

        switch self {
        case .model:
            return "Model"
        case .effort:
            return "Effort"
        case .project:
            return "Project"
        case .originator,
             .sourceKind,
             .threadSource,
             .cliVersion,
             .modelProvider,
             .memoryMode,
             .approvalPolicy,
             .sandboxType,
             .permissionProfile,
             .realtimeActive,
             .truncationPolicy,
             .isSubagent,
             .subagentParentThreadID,
             .subagentDepth,
             .agentRole,
             .agentNickname,
             .usageMode:
            return rawValue
        }
    }

    var dimensionKey: TokenUsageDimensionKey? {
        TokenUsageDimensionKey(rawValue: rawValue)
    }
}

struct TokenDashboardSeries: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let kind: TokenDashboardSeriesKind
    let contextID: String
    let projectPath: String?
    let dimensionKey: TokenUsageDimensionKey?

    init(
        id: String,
        name: String,
        kind: TokenDashboardSeriesKind,
        contextID: String? = nil,
        projectPath: String? = nil,
        dimensionKey: TokenUsageDimensionKey? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.contextID = contextID ?? id
        self.projectPath = projectPath
        self.dimensionKey = dimensionKey
    }

    static let aggregateID = "tokens_all"
    static let unattributedID = "tokens_unattributed"
}

struct TokenDashboardComponentPoint: Identifiable, Equatable {
    let id: String
    let bucketStart: Date
    let bucketEnd: Date
    let seriesID: String
    let seriesName: String
    let seriesKind: TokenDashboardSeriesKind
    let component: TokenHistoryComponent
    let tokenCount: Int64

    init(
        bucketStart: Date,
        bucketEnd: Date,
        seriesID: String,
        seriesName: String,
        seriesKind: TokenDashboardSeriesKind,
        component: TokenHistoryComponent,
        tokenCount: Int64
    ) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.seriesID = seriesID
        self.seriesName = seriesName
        self.seriesKind = seriesKind
        self.component = component
        self.tokenCount = tokenCount
        id = "\(Int(bucketStart.timeIntervalSince1970))-\(seriesID)-\(component.rawValue)"
    }
}

struct TokenDashboardSummaryTile: Identifiable, Equatable {
    let id: String
    let title: String
    let tokenCount: Int64
    let component: TokenHistoryComponent?
}

struct TokenDashboardBreakdownRow: Identifiable, Equatable {
    let series: TokenDashboardSeries
    let totalsByComponent: [TokenHistoryComponent: Int64]

    var id: String {
        series.id
    }

    var totalTokens: Int64 {
        TokenHistoryComponent.allCases.reduce(Int64(0)) { total, component in
            total + (totalsByComponent[component] ?? 0)
        }
    }
}

struct TokenDashboardEmptyState: Equatable {
    let title: String
    let message: String
    let systemImage: String
}

@MainActor
final class TokenDashboardViewModel: ObservableObject {
    @Published var selectedRange: UsageHistoryRange = .month {
        didSet {
            guard selectedRange != oldValue else {
                return
            }

            selectedPeriodStart = currentPeriod.start
            selectedSeriesIDs = []
            scheduleReload()
        }
    }

    @Published var selectedBreakdownDimension: TokenDashboardBreakdownDimension = .model {
        didSet {
            guard selectedBreakdownDimension != oldValue else {
                return
            }

            selectedSeriesIDs = []
            scheduleReload()
        }
    }

    @Published private(set) var selectedPeriodStart: Date
    @Published private(set) var points: [TokenDashboardComponentPoint] = []
    @Published private(set) var series: [TokenDashboardSeries] = []
    @Published private(set) var selectedSeriesIDs: Set<String> = []
    @Published private(set) var historyBounds: UsageHistoryBounds?
    @Published private(set) var errorMessage: String?

    private let database: UsageHistoryDatabaseWorking
    private let now: () -> Date
    private let calendar: Calendar
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    init(
        database: UsageHistoryDatabaseWorking,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.database = database
        self.now = now
        self.calendar = calendar
        selectedPeriodStart = UsageHistoryRange.month.period(containing: now(), calendar: calendar).start
        scheduleReload()
    }

    convenience init(
        store: UsageHistoryStore,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.init(database: UsageHistoryDatabaseWorker(store: store), now: now, calendar: calendar)
    }

    deinit {
        reloadTask?.cancel()
    }

    var selectedPeriod: UsageHistoryPeriod {
        period(startingAt: selectedPeriodStart)
    }

    var currentPeriod: UsageHistoryPeriod {
        selectedRange.period(containing: now(), calendar: calendar)
    }

    var isCurrentPeriod: Bool {
        selectedPeriod.start == currentPeriod.start
    }

    var canGoToPreviousPeriod: Bool {
        guard let historyBounds else {
            return false
        }

        return historyBounds.earliest < selectedPeriod.start
    }

    var canGoToNextPeriod: Bool {
        !isCurrentPeriod
    }

    var canJumpToCurrentPeriod: Bool {
        !isCurrentPeriod
    }

    var periodTitle: String {
        Self.periodTitle(for: selectedRange, period: selectedPeriod, calendar: calendar)
    }

    var periodDisplayNoun: String {
        selectedRange.displayTitle.lowercased()
    }

    var previousPeriodHelpText: String {
        canGoToPreviousPeriod ? "Show previous \(periodDisplayNoun)" : "No earlier token history"
    }

    var nextPeriodHelpText: String {
        canGoToNextPeriod ? "Show next \(periodDisplayNoun)" : "Already showing the current \(periodDisplayNoun)"
    }

    var currentPeriodHelpText: String {
        canJumpToCurrentPeriod ? "Jump to current \(periodDisplayNoun)" : "Already showing the current \(periodDisplayNoun)"
    }

    var hasTokenData: Bool {
        !series.isEmpty
    }

    var selectedSeries: [TokenDashboardSeries] {
        series.filter { selectedSeriesIDs.contains($0.id) }
    }

    var visibleSourcePoints: [TokenDashboardComponentPoint] {
        if selectedSeriesIDs.contains(TokenDashboardSeries.aggregateID) {
            return points.filter { $0.seriesID == TokenDashboardSeries.aggregateID }
        }

        return points.filter { selectedSeriesIDs.contains($0.seriesID) }
    }

    var chartPoints: [TokenDashboardComponentPoint] {
        var grouped = [String: TokenDashboardComponentPointAccumulator]()

        for point in visibleSourcePoints {
            let key = "\(Int(point.bucketStart.timeIntervalSince1970))-\(point.component.rawValue)"
            var accumulator = grouped[key] ?? TokenDashboardComponentPointAccumulator(
                bucketStart: point.bucketStart,
                bucketEnd: point.bucketEnd,
                component: point.component
            )
            accumulator.tokenCount += point.tokenCount
            grouped[key] = accumulator
        }

        return grouped.values
            .map { accumulator in
                TokenDashboardComponentPoint(
                    bucketStart: accumulator.bucketStart,
                    bucketEnd: accumulator.bucketEnd,
                    seriesID: "visible",
                    seriesName: "Visible",
                    seriesKind: .aggregate,
                    component: accumulator.component,
                    tokenCount: accumulator.tokenCount
                )
            }
            .sortedByDashboardDisplayOrder()
    }

    var hasVisiblePoints: Bool {
        !chartPoints.isEmpty
    }

    var summaryTiles: [TokenDashboardSummaryTile] {
        let totals = componentTotals(from: chartPoints)
        let total = TokenHistoryComponent.allCases.reduce(Int64(0)) { partial, component in
            partial + (totals[component] ?? 0)
        }

        return [
            TokenDashboardSummaryTile(id: "total", title: "Total", tokenCount: total, component: nil),
            TokenDashboardSummaryTile(id: TokenHistoryComponent.input.rawValue, title: "Input", tokenCount: totals[.input] ?? 0, component: .input),
            TokenDashboardSummaryTile(id: TokenHistoryComponent.cached.rawValue, title: "Cache", tokenCount: totals[.cached] ?? 0, component: .cached),
            TokenDashboardSummaryTile(id: TokenHistoryComponent.output.rawValue, title: "Output", tokenCount: totals[.output] ?? 0, component: .output),
            TokenDashboardSummaryTile(id: TokenHistoryComponent.reasoning.rawValue, title: "Reasoning", tokenCount: totals[.reasoning] ?? 0, component: .reasoning),
        ]
    }

    var breakdownRows: [TokenDashboardBreakdownRow] {
        let grouped = Dictionary(grouping: points, by: \.seriesID)
        return series.compactMap { series in
            let totals = componentTotals(from: grouped[series.id] ?? [])
            let row = TokenDashboardBreakdownRow(series: series, totalsByComponent: totals)
            return row.totalTokens > 0 ? row : nil
        }
    }

    var emptyState: TokenDashboardEmptyState {
        if !hasTokenData {
            return TokenDashboardEmptyState(
                title: "No token data yet",
                message: "Import recent sessions or use Codex to start capturing token history.",
                systemImage: "chart.bar.doc.horizontal"
            )
        }

        return TokenDashboardEmptyState(
            title: "No tokens for this selection",
            message: "Choose a different period or breakdown row.",
            systemImage: "line.3.horizontal.decrease.circle"
        )
    }

    var chartYDomain: ClosedRange<Double> {
        let maximum = chartPoints
            .reduce(into: [Date: Double]()) { partial, point in
                partial[point.bucketStart, default: 0] += Double(point.tokenCount)
            }
            .values
            .max() ?? 0

        return 0...Self.tokenAxisUpperBound(for: maximum)
    }

    var chartDomainStart: Date {
        selectedPeriod.start.addingTimeInterval(-chartDomainBucketPadding)
    }

    var chartDomainEnd: Date {
        selectedPeriod.end.addingTimeInterval(chartDomainBucketPadding)
    }

    var chartXAxisLabelValues: [Date] {
        chartXAxisLabelBucketStarts().map(chartXPosition(forBucketStart:))
    }

    var exportFilename: String {
        [
            "codex-token-dashboard",
            selectedRange.rawValue,
            periodFilenameToken,
        ].joined(separator: "-") + ".csv"
    }

    var csvText: String {
        var rows = ["breakdown_dimension,range,period_start,period_end,bucket_start,bucket_end,series_id,series_name,series_kind,context_id,context_name,project_path,component,token_count,dimension_key"]
        let formatter = ISO8601DateFormatter()
        let seriesByID = Dictionary(uniqueKeysWithValues: series.map { ($0.id, $0) })

        rows += visibleSourcePoints.sortedByDashboardDisplayOrder().map { point in
            let pointSeries = seriesByID[point.seriesID]
            let contextID = pointSeries?.contextID ?? point.seriesID
            let contextName = pointSeries?.name ?? point.seriesName
            let projectPath = pointSeries?.projectPath ?? ""
            let dimensionKey = pointSeries?.dimensionKey?.rawValue ?? selectedBreakdownDimension.dimensionKey?.rawValue ?? ""
            return [
                selectedBreakdownDimension.rawValue,
                selectedRange.rawValue,
                formatter.string(from: selectedPeriod.start),
                formatter.string(from: selectedPeriod.end),
                formatter.string(from: point.bucketStart),
                formatter.string(from: point.bucketEnd),
                Self.csvEscaped(point.seriesID),
                Self.csvEscaped(contextName),
                point.seriesKind.rawValue,
                Self.csvEscaped(contextID),
                Self.csvEscaped(contextName),
                Self.csvEscaped(projectPath),
                point.component.rawValue,
                "\(point.tokenCount)",
                dimensionKey,
            ].joined(separator: ",")
        }

        return rows.joined(separator: "\n") + "\n"
    }

    private var periodFilenameToken: String {
        Self.periodFilenameToken(for: selectedRange, periodStart: selectedPeriod.start, calendar: calendar)
    }

    private var chartDomainBucketPadding: TimeInterval {
        let reference = selectedPeriod.start
        let next = calendar.date(byAdding: selectedRange.chartBucketComponent, value: 1, to: reference)
            ?? reference.addingTimeInterval(3600)
        return max(next.timeIntervalSince(reference) / 2, 1)
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

        let generation = nextReloadGeneration()
        let queryPeriod = periodForQuery()
        let request = TokenDashboardLoadRequest(
            breakdownDimension: selectedBreakdownDimension,
            range: selectedRange,
            periodStart: queryPeriod.start,
            periodEnd: queryPeriod.end
        )

        do {
            let result = try await database.tokenDashboardSnapshot(for: request)
            guard generation == reloadGeneration, !Task.isCancelled else {
                return false
            }

            points = result.points
            series = result.series
            historyBounds = result.historyBounds
            reconcileSelection()
            errorMessage = nil
            return true
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else {
                return false
            }

            points = []
            series = []
            historyBounds = nil
            selectedSeriesIDs = []
            errorMessage = "Token dashboard could not be loaded."
            return false
        }
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.performReload()
        }
    }

    private func nextReloadGeneration() -> Int {
        reloadGeneration += 1
        return reloadGeneration
    }

    func goToPreviousPeriod() {
        guard canGoToPreviousPeriod,
              let previous = calendar.date(byAdding: selectedRange.periodComponent, value: -1, to: selectedPeriod.start)
        else {
            return
        }

        selectedPeriodStart = previous
        scheduleReload()
    }

    func goToNextPeriod() {
        guard canGoToNextPeriod,
              let next = calendar.date(byAdding: selectedRange.periodComponent, value: 1, to: selectedPeriod.start)
        else {
            return
        }

        selectedPeriodStart = min(next, currentPeriod.start)
        scheduleReload()
    }

    func jumpToCurrentPeriod() {
        guard canJumpToCurrentPeriod else {
            return
        }

        selectedPeriodStart = currentPeriod.start
        scheduleReload()
    }

    func selectSeries(_ id: String) {
        guard series.contains(where: { $0.id == id }) else {
            return
        }

        if id == TokenDashboardSeries.aggregateID {
            selectedSeriesIDs = [TokenDashboardSeries.aggregateID]
            return
        }

        var updated = selectedSeriesIDs
        updated.remove(TokenDashboardSeries.aggregateID)

        if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }

        selectedSeriesIDs = updated.isEmpty ? [TokenDashboardSeries.aggregateID] : updated
    }

    func isSelected(_ series: TokenDashboardSeries) -> Bool {
        selectedSeriesIDs.contains(series.id)
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = exportFilename

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try csvText.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "Token dashboard could not be exported."
        }
    }

    func chartXPosition(for point: TokenDashboardComponentPoint) -> Date {
        chartXPosition(forBucketStart: point.bucketStart)
    }

    func chartXAxisLabel(for date: Date) -> String {
        let bucketStart = UsageHistoryRange.bucketStart(
            for: date.addingTimeInterval(-chartDomainBucketPadding / 2),
            component: selectedRange.chartBucketComponent,
            calendar: calendar
        )
        return Self.chartXAxisLabel(for: bucketStart, range: selectedRange, calendar: calendar)
    }

    func formattedTokenValue(_ tokenCount: Int64) -> String {
        Self.compactTokenNumber(Double(tokenCount))
    }

    func formattedYAxisValue(_ value: Double) -> String {
        Self.compactTokenAxisText(value)
    }

    func color(for component: TokenHistoryComponent?) -> Color {
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

    func compactSeriesTitle(_ name: String) -> String {
        if name == "All captured" {
            return "All"
        }

        let lowercased = name.lowercased()
        if lowercased.contains("spark") {
            return "Spark"
        }

        if let range = name.range(
            of: #"(?i)^gpt-([0-9]+(?:\.[0-9]+)*)(?:[-_ ](.+))?$"#,
            options: .regularExpression
        ) {
            let matched = String(name[range])
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

        return name
    }

    var breakdownColumnTitle: String {
        selectedBreakdownDimension.displayTitle
    }

    private func reconcileSelection() {
        let availableIDs = Set(series.map(\.id))
        let retained = selectedSeriesIDs.intersection(availableIDs)

        if retained.isEmpty, availableIDs.contains(TokenDashboardSeries.aggregateID) {
            selectedSeriesIDs = [TokenDashboardSeries.aggregateID]
        } else {
            selectedSeriesIDs = retained
        }
    }

    private func periodForQuery() -> UsageHistoryPeriod {
        let period = selectedPeriod
        let currentDate = now()
        if period.end > currentDate {
            return UsageHistoryPeriod(start: period.start, end: currentDate)
        }

        return period
    }

    private func period(startingAt start: Date) -> UsageHistoryPeriod {
        if let interval = calendar.dateInterval(of: selectedRange.periodComponent, for: start) {
            return UsageHistoryPeriod(start: interval.start, end: interval.end)
        }

        let end = calendar.date(byAdding: selectedRange.periodComponent, value: 1, to: start) ?? start
        return UsageHistoryPeriod(start: start, end: end)
    }

    private func chartXPosition(forBucketStart bucketStart: Date) -> Date {
        let bucketEnd = calendar.date(byAdding: selectedRange.chartBucketComponent, value: 1, to: bucketStart)
            ?? bucketStart.addingTimeInterval(chartDomainBucketPadding * 2)
        return bucketStart.addingTimeInterval(bucketEnd.timeIntervalSince(bucketStart) / 2)
    }

    private func chartXAxisLabelBucketStarts() -> [Date] {
        switch selectedRange {
        case .day:
            return bucketStarts(step: 4, component: .hour)
        case .week:
            return bucketStarts(step: 1, component: .day)
        case .month:
            return bucketStarts(step: 5, component: .day)
        case .year:
            return bucketStarts(step: 1, component: .month)
        }
    }

    private func bucketStarts(step: Int, component: Calendar.Component) -> [Date] {
        var values: [Date] = []
        var cursor = selectedPeriod.start

        while cursor < selectedPeriod.end {
            values.append(cursor)
            guard let next = calendar.date(byAdding: component, value: step, to: cursor), next > cursor else {
                break
            }
            cursor = next
        }

        return values
    }

    private func componentTotals(from points: [TokenDashboardComponentPoint]) -> [TokenHistoryComponent: Int64] {
        points.reduce(into: [:]) { partial, point in
            partial[point.component, default: 0] += point.tokenCount
        }
    }

    private static func periodTitle(
        for range: UsageHistoryRange,
        period: UsageHistoryPeriod,
        calendar: Calendar
    ) -> String {
        switch range {
        case .day:
            return formattedDate(period.start, template: "MMM d", calendar: calendar)
        case .week:
            let end = calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.end
            return "\(formattedDate(period.start, template: "MMM d", calendar: calendar))-\(formattedDate(end, template: "MMM d", calendar: calendar))"
        case .month:
            return formattedDate(period.start, template: "MMM yyyy", calendar: calendar)
        case .year:
            return formattedDate(period.start, template: "yyyy", calendar: calendar)
        }
    }

    private static func chartXAxisLabel(
        for date: Date,
        range: UsageHistoryRange,
        calendar: Calendar
    ) -> String {
        switch range {
        case .day:
            return formattedDate(date, template: "ha", calendar: calendar).replacingOccurrences(of: " ", with: "")
        case .week:
            return formattedDate(date, template: "EEE", calendar: calendar)
        case .month:
            return formattedDate(date, template: "d", calendar: calendar)
        case .year:
            return formattedDate(date, template: "MMM", calendar: calendar)
        }
    }

    private static func formattedDate(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private static func periodFilenameToken(
        for range: UsageHistoryRange,
        periodStart: Date,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = {
            switch range {
            case .day, .week:
                return "yyyy-MM-dd"
            case .month:
                return "yyyy-MM"
            case .year:
                return "yyyy"
            }
        }()
        return formatter.string(from: periodStart)
    }

    private static func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        return value
    }

    private static func compactModelSuffixTitle(_ value: String) -> String {
        guard let first = value.first else {
            return value
        }

        return first.uppercased() + value.dropFirst().lowercased()
    }

    private static func compactTokenAxisText(_ value: Double) -> String {
        if abs(value) < 1_000_000 {
            return groupedInteger(value)
        }

        return compactTokenNumber(value)
    }

    private static func compactTokenNumber(_ value: Double) -> String {
        let absolute = abs(value)
        let scaledValue: Double
        let suffix: String

        if absolute >= 1_000_000_000 {
            scaledValue = value / 1_000_000_000
            suffix = "B"
        } else if absolute >= 1_000_000 {
            scaledValue = value / 1_000_000
            suffix = "M"
        } else if absolute >= 1_000 {
            scaledValue = value / 1_000
            suffix = "k"
        } else {
            return groupedInteger(value)
        }

        let rounded = (scaledValue * 10).rounded() / 10
        if rounded == rounded.rounded() || abs(rounded) >= 100 {
            return "\(Int(rounded))\(suffix)"
        }

        return String(format: "%.1f%@", rounded, suffix)
    }

    private static func groupedInteger(_ value: Double) -> String {
        Int64(value.rounded()).formatted(.number.grouping(.automatic))
    }

    private static func tokenAxisUpperBound(for value: Double) -> Double {
        guard value > 0 else {
            return 1
        }

        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let step: Double

        if normalized <= 1 {
            step = 1
        } else if normalized <= 2 {
            step = 2
        } else if normalized <= 5 {
            step = 5
        } else {
            step = 10
        }

        return step * magnitude
    }
}

private struct TokenDashboardComponentPointAccumulator {
    let bucketStart: Date
    let bucketEnd: Date
    let component: TokenHistoryComponent
    var tokenCount: Int64 = 0
}

struct TokenDashboardView: View {
    @StateObject private var viewModel: TokenDashboardViewModel
    private let modelColumnWidth: CGFloat = 118
    private let primaryNumberColumnWidth: CGFloat = 88
    private let numberColumnWidth: CGFloat = 84
    private let outputColumnWidth: CGFloat = 76
    private let reasoningColumnWidth: CGFloat = 88

    init(database: UsageHistoryDatabaseWorking) {
        _viewModel = StateObject(wrappedValue: TokenDashboardViewModel(database: database))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            summaryTiles

            HStack(alignment: .top, spacing: 16) {
                chartPanel
                    .frame(minWidth: 520, maxWidth: .infinity)
                    .layoutPriority(1)

                modelBreakdown
                    .frame(width: 606)
                    .layoutPriority(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: UsageHistoryStore.didChangeNotification)) { _ in
            viewModel.scheduleReload()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $viewModel.selectedRange) {
                ForEach(UsageHistoryRange.allCases) { range in
                    Text(range.displayTitle).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 240)

            Picker("Breakdown", selection: $viewModel.selectedBreakdownDimension) {
                ForEach(TokenDashboardBreakdownDimension.allCases) { dimension in
                    Text(dimension.displayTitle).tag(dimension)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190)

            Spacer(minLength: 16)

            periodNavigation

            Spacer(minLength: 16)

            Button {
                viewModel.exportCSV()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.hasVisiblePoints)
            .help("Export CSV")
            .accessibilityLabel("Export CSV")
        }
    }

    private var periodNavigation: some View {
        HStack(spacing: 5) {
            Button {
                viewModel.goToPreviousPeriod()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToPreviousPeriod)
            .help(viewModel.previousPeriodHelpText)

            Text(viewModel.periodTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 112)

            Button {
                viewModel.goToNextPeriod()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToNextPeriod)
            .help(viewModel.nextPeriodHelpText)
        }
    }

    private var summaryTiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 10), count: 5), spacing: 10) {
            ForEach(viewModel.summaryTiles) { tile in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let component = tile.component {
                            Circle()
                                .fill(viewModel.color(for: component))
                                .frame(width: 8, height: 8)
                        }

                        Text(tile.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(viewModel.formattedTokenValue(tile.tokenCount))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            componentLegend

            if viewModel.hasVisiblePoints {
                Chart {
                    ForEach(viewModel.chartPoints) { point in
                        BarMark(
                            x: .value("Time", viewModel.chartXPosition(for: point)),
                            y: .value("Value", Double(point.tokenCount)),
                            stacking: .standard
                        )
                        .foregroundStyle(viewModel.color(for: point.component))
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
                .frame(minHeight: 320, maxHeight: .infinity)
            } else {
                emptyState
                    .frame(minHeight: 320, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var componentLegend: some View {
        HStack(spacing: 8) {
            ForEach(TokenHistoryComponent.allCases) { component in
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.color(for: component))
                        .frame(width: 7, height: 7)

                    Text(component.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    Text(viewModel.breakdownColumnTitle)
                        .frame(width: modelColumnWidth, alignment: .leading)
                    Text("Total")
                        .frame(width: primaryNumberColumnWidth, alignment: .trailing)
                    Text("In")
                        .frame(width: numberColumnWidth, alignment: .trailing)
                    Text("Cache")
                        .frame(width: numberColumnWidth, alignment: .trailing)
                    Text("Out")
                        .frame(width: outputColumnWidth, alignment: .trailing)
                    Text("Reasoning")
                        .frame(width: reasoningColumnWidth, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellColumns(6)

                ForEach(viewModel.breakdownRows) { row in
                    GridRow {
                        Button {
                            viewModel.selectSeries(row.series.id)
                        } label: {
                            HStack(spacing: 6) {
                                NeutralCheckboxMark(isSelected: viewModel.isSelected(row.series), size: 11)

                                Text(viewModel.compactSeriesTitle(row.series.name))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(width: modelColumnWidth, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(row.series.projectPath ?? row.series.name)

                        Text(viewModel.formattedTokenValue(row.totalTokens))
                            .fontWeight(.semibold)
                            .frame(width: primaryNumberColumnWidth, alignment: .trailing)

                        ForEach(TokenHistoryComponent.allCases) { component in
                            Text(viewModel.formattedTokenValue(row.totalsByComponent[component] ?? 0))
                                .foregroundStyle(.secondary)
                                .frame(width: width(for: component), alignment: .trailing)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func width(for component: TokenHistoryComponent) -> CGFloat {
        switch component {
        case .input, .cached:
            return numberColumnWidth
        case .output:
            return outputColumnWidth
        case .reasoning:
            return reasoningColumnWidth
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.emptyState.systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)

            Text(viewModel.emptyState.title)
                .font(.headline)

            Text(viewModel.emptyState.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Array where Element == TokenDashboardComponentPoint {
    func sortedByDashboardDisplayOrder() -> [TokenDashboardComponentPoint] {
        sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }

            if lhs.seriesKind != rhs.seriesKind {
                return lhs.seriesKind.sortIndex < rhs.seriesKind.sortIndex
            }

            if lhs.seriesName != rhs.seriesName {
                return lhs.seriesName.localizedStandardCompare(rhs.seriesName) == .orderedAscending
            }

            return lhs.component.sortIndex < rhs.component.sortIndex
        }
    }
}

private extension TokenDashboardSeriesKind {
    var sortIndex: Int {
        switch self {
        case .aggregate:
            return 0
        case .model:
            return 1
        case .effort:
            return 1
        case .project:
            return 1
        case .dimension:
            return 1
        case .unattributed:
            return 2
        }
    }
}

private extension TokenHistoryComponent {
    var sortIndex: Int {
        switch self {
        case .input:
            return 0
        case .cached:
            return 1
        case .output:
            return 2
        case .reasoning:
            return 3
        }
    }
}
