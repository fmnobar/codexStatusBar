import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    @MainActor
    func testHistoryPresentationDefaultsToIndependentSignals() async throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        await viewModel.reload()

        XCTAssertEqual(viewModel.chartSemantics, .independentSignals)
        XCTAssertEqual(viewModel.selectedRange, .month)
        XCTAssertEqual(viewModel.selectedChartKind, .capacity)
        XCTAssertEqual(viewModel.selectedMetric, .capacityLeft)
        XCTAssertEqual(viewModel.chartSubtitle, "Capacity left by day")
        XCTAssertEqual(viewModel.chartYAxisTitle, "Left %")
        XCTAssertEqual(viewModel.chartYDomain, 0...100)
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(viewModel.visibleBarPoints.map { $0.value(for: viewModel.selectedMetric) }, [80, 93])
        XCTAssertTrue(viewModel.visibleContributorPoints.isEmpty)

        viewModel.selectedMetric = .usage

        XCTAssertEqual(viewModel.selectedChartKind, .usage)
        XCTAssertEqual(viewModel.chartSubtitle, "Usage consumed by day")
        XCTAssertEqual(viewModel.chartYAxisTitle, "Consumed %")
        XCTAssertEqual(viewModel.chartYDomain, 0...50)
        XCTAssertEqual(viewModel.visibleBarPoints.map { $0.value(for: viewModel.selectedMetric) }, [0, 0])
    }

    @MainActor
    func testTokenChartPresentationUsesStackedComponentsInsteadOfLimitWindow() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 120,
                lastCached: 50,
                lastOutput: 25,
                lastReasoning: 5,
                lastTotal: 200,
                totalInput: 120,
                totalCached: 50,
                totalOutput: 25,
                totalReasoning: 5,
                totalTotal: 200
            ),
            at: date("2026-04-14T20:10:00Z")
        )
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedChartKind = .tokens
        viewModel.selectedWindow = .fiveHour
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedChartKind, .tokens)
        XCTAssertEqual(viewModel.chartSubtitle, "Tokens by hour")
        XCTAssertEqual(viewModel.chartYAxisTitle, "Tokens")
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketID), ["tokens_all", "tokens_all", "tokens_all", "tokens_all"])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenComponent), [.input, .cached, .output, .reasoning])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [120, 50, 25, 5])
        XCTAssertEqual(viewModel.visibleChartPoints.map { viewModel.chartValue(for: $0) }, [120, 50, 25, 5])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.bucketID), [
            "tokens_visible_total",
            "tokens_visible_total",
            "tokens_visible_total",
            "tokens_visible_total",
        ])
        XCTAssertEqual(viewModel.chartYDomain, 0...200)
        XCTAssertEqual(viewModel.compactSeriesTitle(for: "All tokens"), "Total")
        XCTAssertEqual(viewModel.compactSeriesTitle(for: "gpt-5.5"), "5.5")
        XCTAssertEqual(viewModel.compactSeriesTitle(for: "gpt-5.4-mini"), "5.4 Mini")
        XCTAssertEqual(viewModel.compactSeriesTitle(for: "GPT-5.3-Codex-Spark"), "Spark")
    }

    @MainActor
    func testTokenCompactSeriesTitlesKeepModelVariantsDistinct() async throws {
        let store = try makeStore()
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        XCTAssertEqual(viewModel.compactSeriesTitle(for: "gpt-5.4"), "5.4")
        XCTAssertEqual(viewModel.compactSeriesTitle(for: "gpt-5.4-mini"), "5.4 Mini")
        XCTAssertEqual(viewModel.compactSeriesTitle(for: "gpt-5.4-codex-mini"), "5.4 Mini")
        XCTAssertEqual(viewModel.compactSeriesTitle(for: "o-series-next"), "o-series-next")
    }

    @MainActor
    func testTokenHistoryUsesAggregateOnlySeriesWhenModelsExist() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 120,
                lastCached: 50,
                lastOutput: 25,
                lastReasoning: 5,
                lastTotal: 200,
                totalInput: 120,
                totalCached: 50,
                totalOutput: 25,
                totalReasoning: 5,
                totalTotal: 200
            ),
            at: date("2026-04-14T20:10:00Z")
        )
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedChartKind = .tokens
        await viewModel.reload()

        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["tokens_all"])
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertTrue(viewModel.tokenComponentPoints.isEmpty)
        XCTAssertEqual(viewModel.tokenComponentBucketPoints.map(\.seriesID), [
            "tokens_all",
            "tokens_all",
            "tokens_all",
            "tokens_all",
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketID), [
            "tokens_all",
            "tokens_all",
            "tokens_all",
            "tokens_all",
        ])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.bucketID), [
            "tokens_visible_total",
            "tokens_visible_total",
            "tokens_visible_total",
            "tokens_visible_total",
        ])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.tokenCount), [120, 50, 25, 5])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.tokenComponent), [.input, .cached, .output, .reasoning])

        viewModel.setSeries("tokens_all", isSelected: false)

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketID), [
            "tokens_all",
            "tokens_all",
            "tokens_all",
            "tokens_all",
        ])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.bucketID), [
            "tokens_visible_total",
            "tokens_visible_total",
            "tokens_visible_total",
            "tokens_visible_total",
        ])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.tokenCount), [120, 50, 25, 5])
    }

    @MainActor
    func testHistoryPeriodDefaultsUseCalendarBoundaries() async throws {
        var mondayCalendar = calendar!
        mondayCalendar.firstWeekday = 2
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-15T14:45:00Z") },
            calendar: mondayCalendar
        )

        viewModel.selectedRange = .day

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-15T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedPeriod.end, date("2026-04-16T00:00:00Z"))

        viewModel.selectedRange = .week

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-13T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedPeriod.end, date("2026-04-20T00:00:00Z"))

        viewModel.selectedRange = .month

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-01T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedPeriod.end, date("2026-05-01T00:00:00Z"))

        viewModel.selectedRange = .year

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-01-01T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedPeriod.end, date("2027-01-01T00:00:00Z"))
    }

    @MainActor
    func testHistoryCompactPeriodTitlesUseInlineFormats() async throws {
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-05-06T12:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        XCTAssertEqual(viewModel.compactPeriodTitle, "May 6")

        viewModel.selectedRange = .week
        XCTAssertEqual(viewModel.compactPeriodTitle, "May 3-9")

        viewModel.selectedRange = .month
        XCTAssertEqual(viewModel.compactPeriodTitle, "May 2026")

        viewModel.selectedRange = .year
        XCTAssertEqual(viewModel.compactPeriodTitle, "2026")
    }

    @MainActor
    func testHistoryCompactWeekPeriodTitleIncludesBothMonthsWhenNeeded() async throws {
        var mondayCalendar = calendar!
        mondayCalendar.firstWeekday = 2
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-29T12:00:00Z") },
            calendar: mondayCalendar
        )

        viewModel.selectedRange = .week

        XCTAssertEqual(viewModel.compactPeriodTitle, "Apr 27-May 3")
    }

    @MainActor
    func testHistoryPeriodNavigationRespectsBoundsAndCurrentPeriod() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-12T09:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-14T00:00:00Z"))
        XCTAssertFalse(viewModel.canGoToNextPeriod)
        XCTAssertTrue(viewModel.canGoToPreviousPeriod)

        viewModel.goToPreviousPeriod()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-13T00:00:00Z"))
        XCTAssertTrue(viewModel.canGoToNextPeriod)
        XCTAssertTrue(viewModel.canGoToPreviousPeriod)

        viewModel.goToPreviousPeriod()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-12T00:00:00Z"))
        XCTAssertFalse(viewModel.canGoToPreviousPeriod)

        viewModel.selectedRange = .month

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-01T00:00:00Z"))
    }

    @MainActor
    func testHistoryFollowsCurrentPeriodAcrossDayBoundary() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-28T09:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-29T08:00:00Z"))
        var currentDate = date("2026-04-28T15:00:00Z")
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { currentDate },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-28T00:00:00Z"))

        currentDate = date("2026-04-29T08:00:00Z")
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-29T00:00:00Z"))
        XCTAssertFalse(viewModel.canGoToNextPeriod)

        viewModel.goToPreviousPeriod()
        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-28T00:00:00Z"))

        currentDate = date("2026-04-30T08:00:00Z")
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-28T00:00:00Z"))

        viewModel.activateCurrentPeriod()
        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-30T00:00:00Z"))
    }

    @MainActor
    func testHistoryPeriodJumpToCurrentAndNavigationHints() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2025-12-31T09:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-28T10:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-28T15:00:00Z") },
            calendar: calendar
        )

        for range in UsageHistoryRange.allCases {
            viewModel.selectedRange = range
            await viewModel.reload()

            let periodName = range.displayTitle.lowercased()
            XCTAssertTrue(viewModel.isCurrentPeriod)
            XCTAssertFalse(viewModel.canJumpToCurrentPeriod)
            XCTAssertFalse(viewModel.canGoToNextPeriod)
            XCTAssertEqual(viewModel.currentPeriodHelpText, "Already showing the current \(periodName)")
            XCTAssertEqual(viewModel.currentPeriodAccessibilityLabel, "Already showing the current \(periodName)")
            XCTAssertEqual(viewModel.nextPeriodHelpText, "Already showing the current \(periodName)")
            XCTAssertEqual(viewModel.nextPeriodAccessibilityLabel, "Already showing the current \(periodName)")

            XCTAssertTrue(viewModel.canGoToPreviousPeriod)
            XCTAssertEqual(viewModel.previousPeriodHelpText, "Show previous \(periodName)")
            XCTAssertEqual(viewModel.previousPeriodAccessibilityLabel, "Previous \(range.displayTitle)")

            viewModel.goToPreviousPeriod()

            XCTAssertFalse(viewModel.isCurrentPeriod)
            XCTAssertTrue(viewModel.canJumpToCurrentPeriod)
            XCTAssertTrue(viewModel.canGoToNextPeriod)
            XCTAssertEqual(viewModel.currentPeriodHelpText, "Jump to current \(periodName)")
            XCTAssertEqual(viewModel.currentPeriodAccessibilityLabel, "Jump to current \(periodName)")
            XCTAssertEqual(viewModel.nextPeriodHelpText, "Show next \(periodName)")
            XCTAssertEqual(viewModel.nextPeriodAccessibilityLabel, "Next \(range.displayTitle)")

            viewModel.jumpToCurrentPeriod()

            XCTAssertTrue(viewModel.isCurrentPeriod)
            XCTAssertEqual(viewModel.selectedPeriodStart, range.period(containing: date("2026-04-28T15:00:00Z"), calendar: calendar).start)
        }
    }

    @MainActor
    func testHistoryPeriodPreviousHintExplainsNoEarlierHistory() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-28T10:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-28T15:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        await viewModel.reload()

        XCTAssertFalse(viewModel.canGoToPreviousPeriod)
        XCTAssertEqual(viewModel.previousPeriodHelpText, "No earlier history for this limit")
        XCTAssertEqual(viewModel.previousPeriodAccessibilityLabel, "No earlier history for this limit")
    }

    @MainActor
    func testHistoryExportFilenameUsesSelectedPeriodWindowAndMetric() async throws {
        var sundayCalendar = calendar!
        sundayCalendar.firstWeekday = 1
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-28T15:00:00Z") },
            calendar: sundayCalendar
        )

        let periodExpectations: [(UsageHistoryRange, String)] = [
            (.day, "2026-04-28"),
            (.week, "2026-04-26"),
            (.month, "2026-04"),
            (.year, "2026"),
        ]
        let windowExpectations: [(UsageLimitWindow, String)] = [
            (.fiveHour, "5h"),
            (.sevenDay, "7d"),
        ]
        let metricExpectations: [(UsageHistoryMetric, String)] = [
            (.capacityLeft, "capacity-left"),
            (.usage, "usage"),
        ]

        for (range, periodToken) in periodExpectations {
            viewModel.selectedRange = range
            for (window, windowToken) in windowExpectations {
                viewModel.selectedWindow = window
                for (metric, metricToken) in metricExpectations {
                    viewModel.selectedMetric = metric

                    XCTAssertEqual(
                        viewModel.exportFilename,
                        "codex-usage-\(range.rawValue)-\(periodToken)-\(windowToken)-\(metricToken).csv"
                    )
                }
            }
        }
    }

    @MainActor
    func testHistoryXAxisLabelsUseSelectedRangeFormats() async throws {
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-14T17:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        let dayLabel = viewModel.chartXAxisLabel(for: date("2026-04-14T17:00:00Z"))

        XCTAssertTrue(dayLabel.contains("PM"))
        XCTAssertFalse(dayLabel.contains("Apr"))
        XCTAssertFalse(dayLabel.contains("14"))

        viewModel.selectedRange = .week
        XCTAssertEqual(viewModel.chartXAxisLabel(for: date("2026-04-14T00:00:00Z")), "Tue")

        viewModel.selectedRange = .month
        XCTAssertEqual(viewModel.chartXAxisLabel(for: date("2026-04-14T00:00:00Z")), "14")

        viewModel.selectedRange = .year
        XCTAssertEqual(viewModel.chartXAxisLabel(for: date("2026-04-01T00:00:00Z")), "Apr")
    }

    @MainActor
    func testHistoryXAxisLabelValuesAreCenteredInBucketsForAllRanges() async throws {
        var sundayCalendar = calendar!
        sundayCalendar.firstWeekday = 1
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-14T17:00:00Z") },
            calendar: sundayCalendar
        )

        viewModel.selectedRange = .day
        XCTAssertEqual(
            viewModel.chartXAxisLabelValues,
            [
                date("2026-04-14T00:30:00Z"),
                date("2026-04-14T04:30:00Z"),
                date("2026-04-14T08:30:00Z"),
                date("2026-04-14T12:30:00Z"),
                date("2026-04-14T16:30:00Z"),
                date("2026-04-14T20:30:00Z"),
            ]
        )

        viewModel.selectedRange = .week
        XCTAssertEqual(
            viewModel.chartXAxisLabelValues,
            [
                date("2026-04-12T12:00:00Z"),
                date("2026-04-13T12:00:00Z"),
                date("2026-04-14T12:00:00Z"),
                date("2026-04-15T12:00:00Z"),
                date("2026-04-16T12:00:00Z"),
                date("2026-04-17T12:00:00Z"),
                date("2026-04-18T12:00:00Z"),
            ]
        )

        viewModel.selectedRange = .month
        XCTAssertEqual(
            viewModel.chartXAxisLabelValues,
            [
                date("2026-04-01T12:00:00Z"),
                date("2026-04-06T12:00:00Z"),
                date("2026-04-11T12:00:00Z"),
                date("2026-04-16T12:00:00Z"),
                date("2026-04-21T12:00:00Z"),
                date("2026-04-26T12:00:00Z"),
            ]
        )

        viewModel.selectedRange = .year
        let monthStarts = (1...12).compactMap { month in
            sundayCalendar.date(from: DateComponents(
                calendar: sundayCalendar,
                timeZone: sundayCalendar.timeZone,
                year: 2026,
                month: month,
                day: 1
            ))
        }
        let expectedYearLabelValues = monthStarts.map { monthStart in
            let monthEnd = sundayCalendar.date(byAdding: .month, value: 1, to: monthStart)!
            return monthStart.addingTimeInterval(monthEnd.timeIntervalSince(monthStart) / 2)
        }
        XCTAssertEqual(viewModel.chartXAxisLabelValues, expectedYearLabelValues)
    }

    @MainActor
    func testHistoryChartDomainAddsHalfBucketPaddingForEdgeLabels() async throws {
        var sundayCalendar = calendar!
        sundayCalendar.firstWeekday = 1
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-14T17:00:00Z") },
            calendar: sundayCalendar
        )

        viewModel.selectedRange = .day
        XCTAssertEqual(viewModel.chartDomainStart, date("2026-04-13T23:30:00Z"))
        XCTAssertEqual(viewModel.chartDomainEnd, date("2026-04-15T00:30:00Z"))

        viewModel.selectedRange = .week
        XCTAssertEqual(viewModel.chartDomainStart, date("2026-04-11T12:00:00Z"))
        XCTAssertEqual(viewModel.chartDomainEnd, date("2026-04-19T12:00:00Z"))

        viewModel.selectedRange = .month
        XCTAssertEqual(viewModel.chartDomainStart, date("2026-03-31T12:00:00Z"))
        XCTAssertEqual(viewModel.chartDomainEnd, date("2026-05-01T12:00:00Z"))

        viewModel.selectedRange = .year
        XCTAssertEqual(viewModel.chartDomainStart, date("2025-12-16T12:00:00Z"))
        XCTAssertEqual(viewModel.chartDomainEnd, date("2027-01-16T12:00:00Z"))
    }

    @MainActor
    func testComparableHistoryPresentationUsesContributorsAndAggregateReference() async throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            chartSemantics: .comparableContributors,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedMetric = .usage
        await viewModel.reload()

        XCTAssertEqual(viewModel.chartSubtitle, "Usage consumed by hour")
        XCTAssertEqual(viewModel.visibleContributorPoints.map(\.bucketID), ["codex_gpt55"])
        XCTAssertEqual(viewModel.visibleAggregateReferencePoints.map(\.bucketID), ["codex"])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.bucketID), ["codex_gpt55"])
    }

    @MainActor
    func testDayChartGroupsHourlyRollupsIntoHourlyBuckets() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 5)), at: date("2026-04-14T17:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 9)), at: date("2026-04-14T17:55:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-14T18:10:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T20:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        await viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T17:00:00Z"),
            date("2026-04-14T18:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [9, 12])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .capacityLeft) }, [91, 88])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .usage) }, [4, 3])
    }

    @MainActor
    func testWeekChartGroupsHourlyRollupsIntoDailyBucketsAndShowsResetCapacity() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 90)), at: date("2026-04-12T17:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 70)), at: date("2026-04-13T18:10:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-16T09:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-17T20:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .week
        await viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-12T00:00:00Z"),
            date("2026-04-13T00:00:00Z"),
            date("2026-04-16T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .capacityLeft) }, [10, 30, 90])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .usage) }, [0, 0, 0])
    }

    @MainActor
    func testMonthAndYearChartBucketGranularity() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 15)), at: date("2026-01-10T12:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 50)), at: date("2026-04-14T12:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 60)), at: date("2026-04-15T12:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-30T20:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .month
        await viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])

        viewModel.selectedRange = .year
        await viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-01-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [15, 60])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.peakUsedPercent), [15, 60])
    }

    @MainActor
    func testTokenChartsBucketBySelectedPeriod() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastInput: 100, lastTotal: 100, totalInput: 100, totalTotal: 100),
            at: date("2026-01-10T12:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-b", turnID: "turn-a", lastInput: 200, lastTotal: 200, totalInput: 200, totalTotal: 200),
            at: date("2026-04-14T12:10:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-c", turnID: "turn-a", lastInput: 300, lastTotal: 300, totalInput: 300, totalTotal: 300),
            at: date("2026-04-14T12:40:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-d", turnID: "turn-a", lastInput: 400, lastTotal: 400, totalInput: 400, totalTotal: 400),
            at: date("2026-04-15T09:00:00Z")
        )
        var currentDate = date("2026-04-14T21:00:00Z")
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { currentDate },
            calendar: calendar
        )
        viewModel.selectedChartKind = .tokens

        viewModel.selectedRange = .day
        await viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [date("2026-04-14T12:00:00Z")])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [500])

        currentDate = date("2026-04-17T20:00:00Z")
        viewModel.selectedRange = .week
        await viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [500, 400])

        currentDate = date("2026-04-30T20:00:00Z")
        viewModel.selectedRange = .month
        await viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])

        viewModel.selectedRange = .year
        await viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-01-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [100, 900])
    }

    @MainActor
    func testUsageMetricUsesObservedConsumptionWithinBucket() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T19:55:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-14T20:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 42)), at: date("2026-04-14T20:45:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedMetric = .usage
        await viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [30, 42])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.peakUsedPercent), [30, 42])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: viewModel.selectedMetric) }, [0, 12])
    }

    @MainActor
    func testChartCSVUsesVisibleBucketedDatasetAndSelectedMetric() async throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-14T19:30:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedMetric = .usage
        await viewModel.reload()
        let csv = viewModel.chartCSV()

        XCTAssertTrue(csv.contains("range,limit,metric,bucket_start,bucket_end,bucket_id,bucket_name,bucket_kind,percent_value"))
        XCTAssertTrue(csv.contains("day,sevenDay,usage,2026-04-14T20:00:00Z,2026-04-14T21:00:00Z,codex,All models,aggregate,8.000"))
    }

    @MainActor
    func testTokenChartCSVUsesVisibleBucketedDatasetAndCategory() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 120,
                lastCached: 80,
                lastTotal: 200,
                totalInput: 120,
                totalCached: 80,
                totalTotal: 200
            ),
            at: date("2026-04-14T20:10:00Z")
        )
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedChartKind = .tokens
        await viewModel.reload()

        XCTAssertEqual(viewModel.exportFilename, "codex-usage-tokens-day-2026-04-14.csv")

        let csv = viewModel.chartCSV()

        XCTAssertTrue(csv.contains("range,bucket_start,bucket_end,series_id,series_name,series_kind,token_component,token_count"))
        XCTAssertTrue(csv.contains("day,2026-04-14T20:00:00Z,2026-04-14T21:00:00Z,tokens_all,All tokens,aggregate,input,120"))
        XCTAssertTrue(csv.contains("day,2026-04-14T20:00:00Z,2026-04-14T21:00:00Z,tokens_all,All tokens,aggregate,cached,80"))
    }

    @MainActor
    func testHoverSelectionChoosesNearestTimestampAndGroupsVisiblePoints() async throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 25, modelSevenDay: 9), at: date("2026-04-14T20:10:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        await viewModel.reload()

        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:07:00Z"), xPosition: 180)

        XCTAssertEqual(viewModel.hoverSelection?.bucketStart, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(viewModel.hoverSelection?.points.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(viewModel.hoverSelection?.xPosition, 180)
    }

    func testHoverIndexChoosesNearestBucketWithoutScanningVisiblePoints() async throws {
        let firstPoint = UsageHistoryChartPoint(
            bucketStart: date("2026-04-14T00:00:00Z"),
            bucketEnd: date("2026-04-14T01:00:00Z"),
            sampleTimestamp: date("2026-04-14T00:30:00Z"),
            bucketID: "codex",
            bucketName: "All models",
            bucketKind: .aggregate,
            window: .sevenDay,
            latestUsedPercent: 20,
            peakUsedPercent: 20,
            consumedPercent: 4
        )
        let secondPoint = UsageHistoryChartPoint(
            bucketStart: date("2026-04-14T01:00:00Z"),
            bucketEnd: date("2026-04-14T02:00:00Z"),
            sampleTimestamp: date("2026-04-14T01:30:00Z"),
            bucketID: "codex",
            bucketName: "All models",
            bucketKind: .aggregate,
            window: .sevenDay,
            latestUsedPercent: 30,
            peakUsedPercent: 30,
            consumedPercent: 5
        )
        let index = UsageHistoryHoverIndex(buckets: [
            UsageHistoryHoverBucket(
                bucketStart: firstPoint.bucketStart,
                bucketEnd: firstPoint.bucketEnd,
                xDate: date("2026-04-14T00:30:00Z"),
                points: [firstPoint]
            ),
            UsageHistoryHoverBucket(
                bucketStart: secondPoint.bucketStart,
                bucketEnd: secondPoint.bucketEnd,
                xDate: date("2026-04-14T01:30:00Z"),
                points: [secondPoint]
            ),
        ])

        let firstSelection = index.selection(nearestTo: date("2026-04-14T00:55:00Z"), xPosition: 64)
        let secondSelection = index.selection(nearestTo: date("2026-04-14T01:15:00Z"), xPosition: 96)

        XCTAssertEqual(firstSelection?.bucketStart, firstPoint.bucketStart)
        XCTAssertEqual(firstSelection?.points, [firstPoint])
        XCTAssertEqual(firstSelection?.xPosition, 64)
        XCTAssertEqual(secondSelection?.bucketStart, secondPoint.bucketStart)
        XCTAssertEqual(secondSelection?.points, [secondPoint])
        XCTAssertEqual(secondSelection?.xPosition, 96)
    }

    @MainActor
    func testTokenHoverSelectionGroupsVisibleSeriesInBucket() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 120,
                lastCached: 80,
                lastTotal: 200,
                totalInput: 120,
                totalCached: 80,
                totalTotal: 200
            ),
            at: date("2026-04-14T20:10:00Z")
        )
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        viewModel.selectedChartKind = .tokens
        await viewModel.reload()

        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:15:00Z"), xPosition: 120)

        XCTAssertEqual(viewModel.hoverSelection?.bucketStart, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(viewModel.hoverSelection?.points.map(\.bucketID), [
            "tokens_all",
            "tokens_all",
        ])
        XCTAssertEqual(viewModel.hoverSelection?.points.map(\.tokenComponent), [.input, .cached])
        XCTAssertEqual(viewModel.hoverSelection?.points.map(\.tokenCount), [120, 80])
        XCTAssertEqual(viewModel.hoverSelection?.points.map { viewModel.formattedChartValue(for: $0) }, ["120 tok", "80 tok"])
    }

    @MainActor
    func testHoverSelectionUsesRebuiltCacheAfterSeriesSelectionChanges() async throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        await viewModel.reload()

        viewModel.setSeries("codex_gpt55", isSelected: false)
        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:00:00Z"), xPosition: 80)

        XCTAssertEqual(viewModel.hoverSelection?.points.map(\.bucketID), ["codex"])
    }

    @MainActor
    func testScheduledHoverSelectionIgnoresStaleWorkAfterSeriesChanges() async throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        await viewModel.reload()

        viewModel.scheduleHoverSelection(nearestTo: date("2026-04-14T20:00:00Z"), xPosition: 80)
        viewModel.setSeries("codex_gpt55", isSelected: false)
        await Task.yield()

        XCTAssertNil(viewModel.hoverSelection)
    }

    @MainActor
    func testHoverSelectionClearsWhenNoVisibleBucketsExist() async throws {
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:00:00Z"), xPosition: 80)

        XCTAssertNil(viewModel.hoverSelection)
    }

    @MainActor
    func testHoverSelectionClearsWhenVisibleSeriesChanges() async throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        await viewModel.reload()
        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:00:00Z"), xPosition: 80)

        viewModel.setSeries("codex_gpt55", isSelected: false)

        XCTAssertNil(viewModel.hoverSelection)
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])
    }

    @MainActor
    func testSeriesSelectorKeepsAggregateSelectedAndFiltersModels() async throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7, extraModelSevenDay: 4), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertTrue(viewModel.selectedSeriesIDs.contains("codex"))

        viewModel.setSeries("codex", isSelected: false)
        XCTAssertTrue(viewModel.selectedSeriesIDs.contains("codex"))

        viewModel.seriesSearchText = "5.5"
        XCTAssertEqual(viewModel.filteredSeries.map(\.id), ["codex", "codex_gpt55"])
    }

    @MainActor
    func testSparkModelIsHiddenByDefault() async throws {
        let store = try makeStore()
        try store.record(
            snapshot: sparkUsageSnapshot(aggregateSevenDay: 20, sparkSevenDay: 2),
            at: date("2026-04-14T20:00:00Z")
        )
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        await viewModel.reload()

        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["codex", "codex_gpt53_spark"])
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])

        viewModel.selectAllSeries()

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex", "codex_gpt53_spark"])
    }

    @MainActor
    func testSparkModelRemainsAvailableButHiddenWhenSelectedPeriodHasNoBars() async throws {
        let store = try makeStore()
        try store.record(
            snapshot: sparkUsageSnapshot(aggregateSevenDay: 20, sparkSevenDay: 2),
            at: date("2026-04-13T20:00:00Z")
        )
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        await viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints, [])
        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["codex", "codex_gpt53_spark"])
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])

        viewModel.selectAllSeries()

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex", "codex_gpt53_spark"])

        viewModel.clearModelSeries()

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])
    }

    func testAvailableRateLimitSeriesDoesNotExposeTokenOnlyModels() async throws {
        let store = try makeStore()
        try store.record(
            snapshot: sparkUsageSnapshot(aggregateSevenDay: 20, sparkSevenDay: 2),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-54",
                turnID: "turn-54",
                model: "gpt-5.4",
                lastInput: 100,
                lastCached: 10,
                lastOutput: 8,
                lastReasoning: 2,
                lastTotal: 110,
                totalInput: 100,
                totalCached: 10,
                totalOutput: 8,
                totalReasoning: 2,
                totalTotal: 110
            ),
            at: date("2026-04-14T20:10:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-54-mini",
                turnID: "turn-54-mini",
                model: "gpt-5.4-mini",
                lastInput: 50,
                lastCached: 5,
                lastOutput: 4,
                lastReasoning: 1,
                lastTotal: 55,
                totalInput: 50,
                totalCached: 5,
                totalOutput: 4,
                totalReasoning: 1,
                totalTotal: 55
            ),
            at: date("2026-04-14T20:12:00Z")
        )

        let availableSeries = try store.availableSeries(window: .sevenDay)

        XCTAssertEqual(
            availableSeries.map(\.id),
            ["codex", "codex_gpt53_spark"]
        )
        XCTAssertEqual(
            availableSeries.map(\.name),
            ["All models", "GPT-5.3-Codex-Spark"]
        )
    }

    @MainActor
    func testSeriesSelectorSelectAllAndClearModels() async throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7, extraModelSevenDay: 4), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        viewModel.clearModelSeries()
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])
        XCTAssertFalse(viewModel.hasSelectedModels)

        viewModel.selectAllSeries()
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertEqual(viewModel.seriesSelectionSummary, "3 of 3 selected")
    }

    @MainActor
    func testEmptyStateDistinguishesNoHistoryAndNoDataForSelection() async throws {
        let emptyStore = try makeStore()
        let emptyViewModel = UsageHistoryViewModel(
            store: emptyStore,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        await emptyViewModel.reload()

        XCTAssertEqual(emptyViewModel.emptyStatePresentation.kind, .noHistory)

        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-16T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        await viewModel.reload()

        XCTAssertTrue(viewModel.hasAnyRecordedHistory)
        XCTAssertEqual(viewModel.emptyStatePresentation.kind, .noDataForSelection)
    }

    @MainActor
    func testUsageAxisDefaultsToFiftyAndExpandsForHighConsumption() async throws {
        let lowUsageStore = try makeStore()
        try lowUsageStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T19:55:00Z"))
        try lowUsageStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: date("2026-04-14T20:05:00Z"))
        let lowUsageViewModel = UsageHistoryViewModel(
            store: lowUsageStore,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        lowUsageViewModel.selectedRange = .day
        lowUsageViewModel.selectedMetric = .usage
        await lowUsageViewModel.reload()

        XCTAssertEqual(lowUsageViewModel.chartYDomain, 0...50)

        let highUsageStore = try makeStore()
        try highUsageStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T19:55:00Z"))
        try highUsageStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 70)), at: date("2026-04-14T20:05:00Z"))
        let highUsageViewModel = UsageHistoryViewModel(
            store: highUsageStore,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        highUsageViewModel.selectedRange = .day
        highUsageViewModel.selectedMetric = .usage
        await highUsageViewModel.reload()

        XCTAssertEqual(highUsageViewModel.chartYDomain, 0...100)
    }

    @MainActor
    func testTokenAxisFormatsRawThousandsAndMillions() async throws {
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedChartKind = .tokens

        XCTAssertEqual(viewModel.formattedYAxisValue(999), "999")
        XCTAssertEqual(viewModel.formattedYAxisValue(1_250), "1.3k")
        XCTAssertEqual(viewModel.formattedYAxisValue(118_400), "118k")
        XCTAssertEqual(viewModel.formattedYAxisValue(1_250_000), "1.3M")
    }

    @MainActor
    func testHiddenSeriesStateWhenVisiblePointsAreEmpty() async throws {
        let store = try makeStore()
        try store.record(snapshot: modelOnlyUsageSnapshot(modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        viewModel.clearModelSeries()

        XCTAssertTrue(viewModel.hasHistory)
        XCTAssertTrue(viewModel.visiblePoints.isEmpty)
        XCTAssertEqual(viewModel.emptyStatePresentation.kind, .hiddenSeries)
    }

}
