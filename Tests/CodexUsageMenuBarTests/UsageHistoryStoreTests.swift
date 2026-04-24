import XCTest

final class UsageHistoryStoreTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    func testRecordsAggregateAndModelSamples() throws {
        let store = try makeStore()
        let now = date("2026-04-14T20:00:10Z")

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: now)

        let points = try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(points.map(\.bucketName), ["All models", "GPT-5.5"])
        XCTAssertEqual(points.map(\.usedPercent), [20, 7])
        XCTAssertEqual(points.map(\.timestamp), [date("2026-04-14T20:00:00Z"), date("2026-04-14T20:00:00Z")])
    }

    func testUpsertsDuplicateMinuteSamples() throws {
        let store = try makeStore()
        let first = date("2026-04-14T20:00:10Z")
        let second = date("2026-04-14T20:00:50Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: first)
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: second)

        let points = try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.usedPercent, 25)
        XCTAssertEqual(points.first?.timestamp, date("2026-04-14T20:00:00Z"))
    }

    func testWeekMonthAndYearQueriesUseRollups() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T20:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T20:40:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 45)), at: date("2026-04-15T08:00:00Z"))

        let weekPoints = try store.points(range: .week, window: .sevenDay, now: date("2026-04-15T09:00:00Z"), calendar: calendar)
        let monthPoints = try store.points(range: .month, window: .sevenDay, now: date("2026-04-15T09:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: date("2026-04-15T09:00:00Z"), calendar: calendar)

        XCTAssertEqual(weekPoints.map(\.usedPercent), [30, 45])
        XCTAssertEqual(monthPoints.map(\.usedPercent), [30, 45])
        XCTAssertEqual(yearPoints.map(\.usedPercent), [30, 45])
    }

    func testRawSamplesCompactButRollupsRemain() throws {
        let store = try makeStore()
        let oldDate = date("2026-01-10T12:00:00Z")
        let currentDate = date("2026-04-14T20:00:00Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: oldDate)
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: currentDate)

        let oldRawPoints = try store.points(range: .day, window: .sevenDay, now: date("2026-01-10T13:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: currentDate, calendar: calendar)

        XCTAssertTrue(oldRawPoints.isEmpty)
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 12 })
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 40 })
    }

    func testClearHistoryDeletesSamplesAndRollups() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        try store.clearHistory()

        XCTAssertTrue(try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar).isEmpty)
        XCTAssertTrue(try store.points(range: .year, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar).isEmpty)
    }

    func testExportsCSVRows() throws {
        let store = try makeStore()

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))

        let csv = try store.csv(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertTrue(csv.contains("timestamp,bucket_id,bucket_name,bucket_kind,window,used_percent"))
        XCTAssertTrue(csv.contains("2026-04-14T20:00:00Z,codex,All models,aggregate,sevenDay,20.000"))
        XCTAssertTrue(csv.contains("2026-04-14T20:00:00Z,codex_gpt55,GPT-5.5,model,sevenDay,7.000"))
    }

    func testHasAnyHistoryReflectsSamplesAndClear() throws {
        let store = try makeStore()

        XCTAssertFalse(try store.hasAnyHistory())

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        XCTAssertTrue(try store.hasAnyHistory())

        try store.clearHistory()
        XCTAssertFalse(try store.hasAnyHistory())
    }

    @MainActor
    func testHistoryPresentationDefaultsToIndependentSignals() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.reload()

        XCTAssertEqual(viewModel.chartSemantics, .independentSignals)
        XCTAssertEqual(viewModel.chartSubtitle, "Sampled rate-limit usage signals by bucket")
        XCTAssertEqual(viewModel.visibleLinePoints.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertTrue(viewModel.visibleContributorPoints.isEmpty)
    }

    @MainActor
    func testComparableHistoryPresentationUsesContributorsAndAggregateReference() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            chartSemantics: .comparableContributors,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.reload()

        XCTAssertEqual(viewModel.chartSubtitle, "Sampled model usage contributors with aggregate reference")
        XCTAssertEqual(viewModel.visibleContributorPoints.map(\.bucketID), ["codex_gpt55"])
        XCTAssertEqual(viewModel.visibleAggregateReferencePoints.map(\.bucketID), ["codex"])
        XCTAssertEqual(viewModel.visibleLinePoints.map(\.bucketID), ["codex"])
    }

    @MainActor
    func testHoverSelectionChoosesNearestTimestampAndGroupsVisiblePoints() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 25, modelSevenDay: 9), at: date("2026-04-14T20:10:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()

        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:07:00Z"), xPosition: 180)

        XCTAssertEqual(viewModel.hoverSelection?.timestamp, date("2026-04-14T20:10:00Z"))
        XCTAssertEqual(viewModel.hoverSelection?.points.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(viewModel.hoverSelection?.xPosition, 180)
    }

    @MainActor
    func testHoverSelectionClearsWhenVisibleSeriesChanges() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()
        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:00:00Z"), xPosition: 80)

        viewModel.setSeries("codex_gpt55", isSelected: false)

        XCTAssertNil(viewModel.hoverSelection)
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])
    }

    @MainActor
    func testSeriesSelectorKeepsAggregateSelectedAndFiltersModels() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7, extraModelSevenDay: 4), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()

        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertTrue(viewModel.selectedSeriesIDs.contains("codex"))

        viewModel.setSeries("codex", isSelected: false)
        XCTAssertTrue(viewModel.selectedSeriesIDs.contains("codex"))

        viewModel.seriesSearchText = "5.5"
        XCTAssertEqual(viewModel.filteredSeries.map(\.id), ["codex", "codex_gpt55"])
    }

    @MainActor
    func testSeriesSelectorSelectAllAndClearModels() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7, extraModelSevenDay: 4), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()

        viewModel.clearModelSeries()
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])
        XCTAssertFalse(viewModel.hasSelectedModels)

        viewModel.selectAllSeries()
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertEqual(viewModel.seriesSelectionSummary, "3 of 3 selected")
    }

    @MainActor
    func testEmptyStateDistinguishesNoHistoryAndNoDataForSelection() throws {
        let emptyStore = try makeStore()
        let emptyViewModel = UsageHistoryViewModel(
            store: emptyStore,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        emptyViewModel.reload()

        XCTAssertEqual(emptyViewModel.emptyStatePresentation.kind, .noHistory)

        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-16T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()

        XCTAssertTrue(viewModel.hasAnyRecordedHistory)
        XCTAssertEqual(viewModel.emptyStatePresentation.kind, .noDataForSelection)
    }

    @MainActor
    func testHiddenSeriesStateWhenVisiblePointsAreEmpty() throws {
        let store = try makeStore()
        try store.record(snapshot: modelOnlyUsageSnapshot(modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()

        viewModel.clearModelSeries()

        XCTAssertTrue(viewModel.hasHistory)
        XCTAssertTrue(viewModel.visiblePoints.isEmpty)
        XCTAssertEqual(viewModel.emptyStatePresentation.kind, .hiddenSeries)
    }

    private func makeStore() throws -> UsageHistoryStore {
        try UsageHistoryStore.inMemory(notificationCenter: NotificationCenter(), calendar: calendar)
    }

    private func usageSnapshot(
        aggregateSevenDay: Int,
        modelSevenDay: Int,
        extraModelSevenDay: Int? = nil
    ) -> CodexUsageSnapshot {
        let aggregateSnapshot = rateLimitSnapshot(sevenDayUsedPercent: aggregateSevenDay)
        let modelSnapshot = rateLimitSnapshot(sevenDayUsedPercent: modelSevenDay)
        var buckets = [
            CodexUsageBucket(id: "codex", name: "All models", kind: .aggregate, snapshot: aggregateSnapshot),
            CodexUsageBucket(id: "codex_gpt55", name: "GPT-5.5", kind: .model, snapshot: modelSnapshot),
        ]

        if let extraModelSevenDay {
            buckets.append(
                CodexUsageBucket(
                    id: "codex_gpt54",
                    name: "GPT-5.4",
                    kind: .model,
                    snapshot: rateLimitSnapshot(sevenDayUsedPercent: extraModelSevenDay)
                )
            )
        }

        return CodexUsageSnapshot(
            displaySnapshot: aggregateSnapshot,
            buckets: buckets
        )
    }

    private func modelOnlyUsageSnapshot(modelSevenDay: Int) -> CodexUsageSnapshot {
        let snapshot = rateLimitSnapshot(sevenDayUsedPercent: modelSevenDay)
        return CodexUsageSnapshot(
            displaySnapshot: CodexRateLimitSnapshot(
                primary: snapshot.primary,
                secondary: nil
            ),
            buckets: [
                CodexUsageBucket(id: "codex_gpt55", name: "GPT-5.5", kind: .model, snapshot: snapshot),
            ]
        )
    }

    private func rateLimitSnapshot(sevenDayUsedPercent: Int) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 5, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: sevenDayUsedPercent, windowDurationMinutes: 10080, resetsAt: nil)
        )
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
