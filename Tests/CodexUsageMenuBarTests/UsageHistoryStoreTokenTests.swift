import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testRecordsAllTokenUsageFields() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 120,
                lastCached: 80,
                lastOutput: 40,
                lastReasoning: 12,
                lastTotal: 160,
                totalInput: 1_200,
                totalCached: 800,
                totalOutput: 400,
                totalReasoning: 120,
                totalTotal: 1_600,
                contextWindow: 258_400
            ),
            at: date("2026-04-14T20:00:00Z")
        )

        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.threadID, "thread-a")
        XCTAssertEqual(samples.first?.turnID, "turn-a")
        XCTAssertEqual(samples.first?.model, "gpt-5.5")
        XCTAssertEqual(samples.first?.modelContextWindow, 258_400)
        XCTAssertEqual(samples.first?.last.inputTokens, 120)
        XCTAssertEqual(samples.first?.last.cachedInputTokens, 80)
        XCTAssertEqual(samples.first?.last.outputTokens, 40)
        XCTAssertEqual(samples.first?.last.reasoningOutputTokens, 12)
        XCTAssertEqual(samples.first?.last.totalTokens, 160)
        XCTAssertEqual(samples.first?.total.inputTokens, 1_200)
        XCTAssertEqual(samples.first?.total.cachedInputTokens, 800)
        XCTAssertEqual(samples.first?.total.outputTokens, 400)
        XCTAssertEqual(samples.first?.total.reasoningOutputTokens, 120)
        XCTAssertEqual(samples.first?.total.totalTokens, 1_600)
        XCTAssertEqual(samples.first?.observedInputTokens, 120)
        XCTAssertEqual(samples.first?.observedCachedInputTokens, 80)
        XCTAssertEqual(samples.first?.observedOutputTokens, 40)
        XCTAssertEqual(samples.first?.observedReasoningOutputTokens, 12)
        XCTAssertEqual(samples.first?.observedTotalTokens, 160)
    }

    func testTokenUsageComputesObservedCategoryDeltas() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 100,
                lastCached: 20,
                lastOutput: 30,
                lastReasoning: 5,
                lastTotal: 155,
                totalInput: 1_000,
                totalCached: 200,
                totalOutput: 300,
                totalReasoning: 50,
                totalTotal: 1_550
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-b",
                lastInput: 90,
                lastCached: 30,
                lastOutput: 60,
                lastReasoning: 25,
                lastTotal: 205,
                totalInput: 1_100,
                totalCached: 230,
                totalOutput: 360,
                totalReasoning: 65,
                totalTotal: 1_755
            ),
            at: date("2026-04-14T20:10:00Z")
        )

        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(samples.map(\.observedInputTokens), [100, 100])
        XCTAssertEqual(samples.map(\.observedCachedInputTokens), [20, 30])
        XCTAssertEqual(samples.map(\.observedOutputTokens), [30, 60])
        XCTAssertEqual(samples.map(\.observedReasoningOutputTokens), [5, 15])
        XCTAssertEqual(samples.map(\.observedTotalTokens), [155, 205])
    }

    func testTokenUsageDeduplicatesRepeatedThreadTurnAndCumulativeTotal() async throws {
        let store = try makeStore()
        let notification = tokenNotification(
            threadID: "thread-a",
            turnID: "turn-a",
            lastTotal: 250,
            totalTotal: 2_000
        )

        try store.record(tokenUsage: notification, at: date("2026-04-14T20:00:00Z"))
        try store.record(tokenUsage: notification, at: date("2026-04-14T20:00:05Z"))

        XCTAssertEqual(try store.tokenUsageSamples().count, 1)
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 250)
    }

    func testTokenUsageReimportFillsMissingModelWithoutInflatingTotals() async throws {
        let store = try makeStore()
        let receivedAt = date("2026-04-14T20:00:00Z")
        let firstImport = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: nil,
                    lastTotal: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])
        let repairImport = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: " gpt-future-1 ",
                    lastTotal: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(firstImport, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(repairImport, TokenUsageImportResult(insertedCount: 0, duplicateCount: 1, repairedModelCount: 1))
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.model, "gpt-future-1")
        XCTAssertEqual(samples.first?.observedTotalTokens, 125)
        XCTAssertEqual(try store.availableTokenSeries(category: .total).map(\.id), ["tokens_all", "model:gpt-future-1"])
        XCTAssertEqual(try store.tokenTotalForDay(containing: receivedAt, calendar: calendar), 125)
    }

    func testTokenUsageReimportDoesNotClearExistingModel() async throws {
        let store = try makeStore()
        let receivedAt = date("2026-04-14T20:00:00Z")

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: "codex-stable-model",
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-b",
                    turnID: "turn-a",
                    model: " \tgpt-5.6\n ",
                    lastInput: 80,
                    lastTotal: 80,
                    totalInput: 80,
                    totalTotal: 80
                ),
                receivedAt: date("2026-04-14T20:05:00Z")
            ),
        ])
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: nil,
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])

        let samples = try store.tokenUsageSamples()
        let availableSeries = try store.availableTokenComponentSeries()

        XCTAssertEqual(samples.map(\.model), ["codex-stable-model", "gpt-5.6"])
        XCTAssertEqual(availableSeries.map(\.id), [
            "tokens_all",
            "model:codex-stable-model",
            "model:gpt-5.6",
        ])
    }

    func testTokenUsageReimportRepairsMalformedExistingModelWithoutInflatingTotals() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let receivedAt = date("2026-04-14T20:00:00Z")

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: nil,
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])
        try executeSQLite(
            at: databaseURL,
            sql: """
            UPDATE token_usage_samples
            SET model = 'gpt-5.5
            Tests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:'
            WHERE thread_id = 'thread-a';
            """
        )

        let repairImport = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])

        XCTAssertEqual(repairImport, TokenUsageImportResult(insertedCount: 0, duplicateCount: 1, repairedModelCount: 1))
        XCTAssertEqual(try store.tokenUsageSamples().map(\.model), ["gpt-5.5"])
        XCTAssertEqual(try store.tokenTotalForDay(containing: receivedAt, calendar: calendar), 125)
        XCTAssertEqual(try store.availableTokenSeries(category: .total).map(\.id), ["tokens_all", "model:gpt-5.5"])
    }

    func testTokenUsageComputesSameThreadCumulativeDeltas() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 250, totalTotal: 2_000),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-b", lastTotal: 400, totalTotal: 2_500),
            at: date("2026-04-14T20:10:00Z")
        )

        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(samples.map(\.observedTotalTokens), [250, 500])
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 750)
    }

    func testTokenUsageFirstObservedSampleUsesLastTotalInsteadOfCumulativeTotal() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-late", lastTotal: 600, totalTotal: 12_000),
            at: date("2026-04-14T20:00:00Z")
        )

        XCTAssertEqual(try store.tokenUsageSamples().first?.observedTotalTokens, 600)
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 600)
    }

    func testTokenHistoryPointsIncludeAggregateAndModelSeries() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastTotal: 120,
                totalTotal: 120
            ),
            at: date("2026-04-14T20:00:00Z")
        )

        let points = try store.tokenPoints(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let series = try store.tokenSeries(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )

        XCTAssertEqual(points.map(\.seriesID), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(points.map(\.seriesName), ["All tokens", "gpt-5.5"])
        XCTAssertEqual(points.map(\.seriesKind), [.aggregate, .model])
        XCTAssertEqual(points.map(\.tokenCount), [120, 120])
        XCTAssertEqual(series.map(\.id), ["tokens_all", "model:gpt-5.5"])
    }

    func testAvailableTokenSeriesIncludesTrackedModelsOutsideSelectedPeriod() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastTotal: 120,
                totalTotal: 120
            ),
            at: date("2026-04-13T20:00:00Z")
        )

        let emptyCurrentDayPoints = try store.tokenPoints(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let availableSeries = try store.availableTokenSeries(category: .total)

        XCTAssertEqual(emptyCurrentDayPoints, [])
        XCTAssertEqual(availableSeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(availableSeries.map(\.name), ["All tokens", "gpt-5.5"])
    }

    func testTokenModelSeriesTrimWhitespaceAndDeduplicate() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5\n",
                lastInput: 80,
                lastCached: 20,
                lastOutput: 10,
                lastReasoning: 2,
                lastTotal: 112,
                totalInput: 80,
                totalCached: 20,
                totalOutput: 10,
                totalReasoning: 2,
                totalTotal: 112
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                model: " gpt-5.5 ",
                lastInput: 120,
                lastCached: 40,
                lastOutput: 20,
                lastReasoning: 4,
                lastTotal: 184,
                totalInput: 120,
                totalCached: 40,
                totalOutput: 20,
                totalReasoning: 4,
                totalTotal: 184
            ),
            at: date("2026-04-14T20:05:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-c",
                turnID: "turn-a",
                model: "gpt-5.5\nTests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:",
                lastInput: 60,
                lastCached: 10,
                lastOutput: 8,
                lastReasoning: 2,
                lastTotal: 80,
                totalInput: 60,
                totalCached: 10,
                totalOutput: 8,
                totalReasoning: 2,
                totalTotal: 80
            ),
            at: date("2026-04-14T20:10:00Z")
        )

        let points = try store.tokenPoints(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let componentPoints = try store.tokenComponentPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let availableSeries = try store.availableTokenSeries(category: .total)
        let availableComponentSeries = try store.availableTokenComponentSeries()

        XCTAssertFalse(points.contains { $0.seriesName.contains("\n") })
        XCTAssertFalse(componentPoints.contains { $0.seriesName.contains("\n") })
        XCTAssertEqual(Set(points.map(\.seriesID)), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(Set(componentPoints.map(\.seriesID)), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(availableSeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(availableSeries.map(\.name), ["All tokens", "gpt-5.5"])
        XCTAssertEqual(availableComponentSeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(availableComponentSeries.map(\.name), ["All tokens", "gpt-5.5"])
    }

    func testTokenComponentPointsIncludeAggregateAndModelSeries() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 120,
                lastCached: 80,
                lastOutput: 30,
                lastReasoning: 10,
                lastTotal: 240,
                totalInput: 120,
                totalCached: 80,
                totalOutput: 30,
                totalReasoning: 10,
                totalTotal: 240
            ),
            at: date("2026-04-14T20:00:00Z")
        )

        let points = try store.tokenComponentPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let availableSeries = try store.availableTokenComponentSeries()
        let bounds = try store.tokenComponentHistoryBounds()

        XCTAssertEqual(points.map(\.seriesID), [
            "tokens_all",
            "tokens_all",
            "tokens_all",
            "tokens_all",
            "model:gpt-5.5",
            "model:gpt-5.5",
            "model:gpt-5.5",
            "model:gpt-5.5",
        ])
        XCTAssertEqual(points.map(\.component), [
            .input,
            .cached,
            .output,
            .reasoning,
            .input,
            .cached,
            .output,
            .reasoning,
        ])
        XCTAssertEqual(points.map(\.tokenCount), [120, 80, 30, 10, 120, 80, 30, 10])
        XCTAssertEqual(availableSeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(bounds?.earliest, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(bounds?.latest, date("2026-04-14T20:00:00Z"))
    }

    func testTokenComponentBucketPointsAggregateSamplesInSQLite() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastCached: 40,
                lastOutput: 20,
                lastReasoning: 5,
                lastTotal: 165,
                totalInput: 100,
                totalCached: 40,
                totalOutput: 20,
                totalReasoning: 5,
                totalTotal: 165
            ),
            at: date("2026-04-14T20:10:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                model: "gpt-5.4",
                lastInput: 50,
                lastCached: 10,
                lastOutput: 30,
                lastReasoning: 2,
                lastTotal: 92,
                totalInput: 50,
                totalCached: 10,
                totalOutput: 30,
                totalReasoning: 2,
                totalTotal: 92
            ),
            at: date("2026-04-14T20:25:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-c",
                turnID: "turn-a",
                lastInput: 25,
                lastTotal: 25,
                totalInput: 25,
                totalTotal: 25
            ),
            at: date("2026-04-14T21:05:00Z")
        )

        let points = try store.tokenComponentBucketPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z"),
            now: date("2026-04-14T22:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(Set(points.map(\.seriesID)), ["tokens_all"])
        XCTAssertEqual(points.map(\.bucketStart), [
            date("2026-04-14T20:00:00Z"),
            date("2026-04-14T20:00:00Z"),
            date("2026-04-14T20:00:00Z"),
            date("2026-04-14T20:00:00Z"),
            date("2026-04-14T21:00:00Z"),
        ])
        XCTAssertEqual(points.map(\.component), [.input, .cached, .output, .reasoning, .input])
        XCTAssertEqual(points.map(\.tokenCount), [150, 50, 50, 7, 25])
        XCTAssertEqual(
            points.filter { $0.bucketStart == date("2026-04-14T20:00:00Z") }.map(\.latestSampleTimestamp),
            Array(repeating: date("2026-04-14T20:25:00Z"), count: 4)
        )
    }

    func testTokenComponentBucketPointsUseCalendarBucketsForAllRanges() async throws {
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
            at: date("2026-04-15T09:00:00Z")
        )

        let dayPoints = try store.tokenComponentBucketPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z"),
            now: date("2026-04-14T21:00:00Z"),
            calendar: calendar
        )
        let weekPoints = try store.tokenComponentBucketPoints(
            range: .week,
            periodStart: date("2026-04-12T00:00:00Z"),
            periodEnd: date("2026-04-19T00:00:00Z"),
            now: date("2026-04-17T21:00:00Z"),
            calendar: calendar
        )
        let monthPoints = try store.tokenComponentBucketPoints(
            range: .month,
            periodStart: date("2026-04-01T00:00:00Z"),
            periodEnd: date("2026-05-01T00:00:00Z"),
            now: date("2026-04-30T21:00:00Z"),
            calendar: calendar
        )
        let yearPoints = try store.tokenComponentBucketPoints(
            range: .year,
            periodStart: date("2026-01-01T00:00:00Z"),
            periodEnd: date("2027-01-01T00:00:00Z"),
            now: date("2026-12-31T21:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(dayPoints.map(\.bucketStart), [date("2026-04-14T12:00:00Z")])
        XCTAssertEqual(dayPoints.map(\.tokenCount), [200])
        XCTAssertEqual(weekPoints.map(\.bucketStart), [date("2026-04-14T00:00:00Z"), date("2026-04-15T00:00:00Z")])
        XCTAssertEqual(weekPoints.map(\.tokenCount), [200, 300])
        XCTAssertEqual(monthPoints.map(\.bucketStart), [date("2026-04-14T00:00:00Z"), date("2026-04-15T00:00:00Z")])
        XCTAssertEqual(monthPoints.map(\.tokenCount), [200, 300])
        XCTAssertEqual(yearPoints.map(\.bucketStart), [date("2026-01-01T00:00:00Z"), date("2026-04-01T00:00:00Z")])
        XCTAssertEqual(yearPoints.map(\.tokenCount), [100, 500])
    }

    func testTokenComponentBucketPointsReturnEmptyRowsForEmptyPeriods() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastInput: 100, lastTotal: 100, totalInput: 100, totalTotal: 100),
            at: date("2026-04-14T20:00:00Z")
        )

        let points = try store.tokenComponentBucketPoints(
            range: .day,
            periodStart: date("2026-04-15T00:00:00Z"),
            periodEnd: date("2026-04-16T00:00:00Z"),
            now: date("2026-04-16T00:00:00Z"),
            calendar: calendar
        )

        XCTAssertTrue(points.isEmpty)
    }

    func testTokenDashboardPointsAggregateComponentsModelsAndUnattributedRows() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastCached: 40,
                lastOutput: 20,
                lastReasoning: 5,
                lastTotal: 165,
                totalInput: 100,
                totalCached: 40,
                totalOutput: 20,
                totalReasoning: 5,
                totalTotal: 165
            ),
            at: date("2026-05-02T10:15:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                lastInput: 50,
                lastCached: 10,
                lastOutput: 30,
                lastReasoning: 2,
                lastTotal: 92,
                totalInput: 50,
                totalCached: 10,
                totalOutput: 30,
                totalReasoning: 2,
                totalTotal: 92
            ),
            at: date("2026-05-02T11:15:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-c",
                turnID: "turn-a",
                model: "future-model",
                lastInput: 200,
                lastCached: 80,
                lastOutput: 25,
                lastReasoning: 7,
                lastTotal: 312,
                totalInput: 200,
                totalCached: 80,
                totalOutput: 25,
                totalReasoning: 7,
                totalTotal: 312
            ),
            at: date("2026-05-03T09:15:00Z")
        )

        let points = try store.tokenDashboardPoints(
            range: .month,
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z")
        )
        let series = try store.tokenDashboardSeries()

        XCTAssertEqual(series.map(\.id), [
            "tokens_all",
            "model:future-model",
            "model:gpt-5.5",
            "tokens_unattributed",
        ])
        XCTAssertEqual(series.map(\.name), ["All captured", "future-model", "gpt-5.5", "Unattributed"])
        XCTAssertEqual(
            dashboardTokenCount(points, seriesID: "tokens_all", component: .input, bucketStart: date("2026-05-02T00:00:00Z")),
            150
        )
        XCTAssertEqual(
            dashboardTokenCount(points, seriesID: "model:gpt-5.5", component: .cached, bucketStart: date("2026-05-02T00:00:00Z")),
            40
        )
        XCTAssertEqual(
            dashboardTokenCount(points, seriesID: "tokens_unattributed", component: .output, bucketStart: date("2026-05-02T00:00:00Z")),
            30
        )
        XCTAssertEqual(
            dashboardTokenCount(points, seriesID: "model:future-model", component: .reasoning, bucketStart: date("2026-05-03T00:00:00Z")),
            7
        )
    }

    func testTokenSeriesDiscoveryReadsFromCatalog() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        try executeSQLite(
            at: databaseURL,
            sql: """
            INSERT INTO token_series_catalog (
                series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            ) VALUES
                ('tokens_all', 'All tokens', 'aggregate', \(Int64(date("2026-05-03T09:00:00Z").timeIntervalSince1970)), 1, 1, 1, 0, 0),
                ('model:gpt-5.5', 'gpt-5.5', 'model', \(Int64(date("2026-05-03T09:01:00Z").timeIntervalSince1970)), 1, 1, 0, 0, 0),
                ('tokens_unattributed', 'Unattributed', 'unattributed', \(Int64(date("2026-05-03T09:02:00Z").timeIntervalSince1970)), 0, 1, 0, 0, 0);
            """
        )

        let dashboardSeries = try store.tokenDashboardSeries()
        let historySeries = try store.availableTokenComponentSeries()
        let rawSamples = try store.tokenUsageSamples()

        XCTAssertEqual(rawSamples, [])
        XCTAssertEqual(dashboardSeries.map(\.id), ["tokens_all", "model:gpt-5.5", "tokens_unattributed"])
        XCTAssertEqual(dashboardSeries.map(\.name), ["All captured", "gpt-5.5", "Unattributed"])
        XCTAssertEqual(historySeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
    }

    @MainActor
    func testTokenDashboardViewModelDefaultsFiltersAndExportsVisibleRows() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastCached: 40,
                lastOutput: 20,
                lastReasoning: 5,
                lastTotal: 165,
                totalInput: 100,
                totalCached: 40,
                totalOutput: 20,
                totalReasoning: 5,
                totalTotal: 165
            ),
            at: date("2026-05-02T10:15:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                model: "gpt-5.4",
                lastInput: 30,
                lastCached: 10,
                lastOutput: 8,
                lastReasoning: 2,
                lastTotal: 50,
                totalInput: 30,
                totalCached: 10,
                totalOutput: 8,
                totalReasoning: 2,
                totalTotal: 50
            ),
            at: date("2026-05-03T10:15:00Z")
        )

        let viewModel = TokenDashboardViewModel(
            store: store,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedRange, .month)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 215)
        XCTAssertEqual(viewModel.exportFilename, "codex-token-dashboard-month-2026-05.csv")
        XCTAssertEqual(viewModel.compactSeriesTitle("gpt-5.4-mini"), "5.4 Mini")
        XCTAssertEqual(viewModel.compactSeriesTitle("Unattributed"), "Unattributed")
        XCTAssertEqual(viewModel.formattedTokenValue(6_495_500_000), "6.5B")
        XCTAssertEqual(viewModel.formattedTokenValue(3_318_500_000), "3.3B")
        XCTAssertEqual(viewModel.formattedTokenValue(42_800), "42.8k")
        XCTAssertEqual(viewModel.formattedTokenValue(900), "900")
        XCTAssertFalse(viewModel.formattedTokenValue(6_495_500_000).contains("tok"))
        XCTAssertEqual(viewModel.formattedYAxisValue(10_000), "10,000")
        XCTAssertEqual(viewModel.formattedYAxisValue(1_200_000_000), "1.2B")
        XCTAssertTrue(viewModel.csvText.contains("month,2026-05-01T00:00:00Z,2026-06-01T00:00:00Z,2026-05-02T00:00:00Z,2026-05-03T00:00:00Z,tokens_all,All captured,aggregate,input,100"))

        viewModel.selectSeries("model:gpt-5.5")

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["model:gpt-5.5"])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 165)
        XCTAssertFalse(viewModel.csvText.contains("model:gpt-5.4"))
        XCTAssertTrue(viewModel.csvText.contains("model:gpt-5.5,gpt-5.5,model,input,100"))
    }

    @MainActor
    func testTokenDashboardNavigationBoundsAndEmptyStates() async throws {
        let emptyViewModel = TokenDashboardViewModel(
            store: try makeStore(),
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await emptyViewModel.reload()

        XCTAssertEqual(emptyViewModel.emptyState.title, "No token data yet")
        XCTAssertFalse(emptyViewModel.canGoToPreviousPeriod)

        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastTotal: 100,
                totalInput: 100,
                totalTotal: 100
            ),
            at: date("2026-04-14T10:00:00Z")
        )
        let viewModel = TokenDashboardViewModel(
            store: store,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        XCTAssertTrue(viewModel.canGoToPreviousPeriod)
        XCTAssertFalse(viewModel.canGoToNextPeriod)

        viewModel.goToPreviousPeriod()
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-01T00:00:00Z"))
        XCTAssertTrue(viewModel.hasVisiblePoints)
        XCTAssertTrue(viewModel.canGoToNextPeriod)

        viewModel.goToNextPeriod()
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(viewModel.emptyState.title, "No tokens for this selection")
    }

    func testTokenTotalForDayUsesLocalCalendarDay() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 100, totalTotal: 100),
            at: date("2026-04-13T23:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-b", turnID: "turn-a", lastTotal: 200, totalTotal: 200),
            at: date("2026-04-14T20:00:00Z")
        )

        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 200)
        XCTAssertNil(try store.tokenTotalForDay(containing: date("2026-04-15T21:00:00Z"), calendar: calendar))
    }

    func testTokenCategoryTotalsForDaySumsObservedCategories() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 100,
                lastCached: 25,
                lastOutput: 40,
                lastReasoning: 5,
                lastTotal: 145,
                totalInput: 1_000,
                totalCached: 250,
                totalOutput: 400,
                totalReasoning: 50,
                totalTotal: 1_450
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-b",
                lastInput: 80,
                lastCached: 30,
                lastOutput: 50,
                lastReasoning: 15,
                lastTotal: 175,
                totalInput: 1_150,
                totalCached: 280,
                totalOutput: 450,
                totalReasoning: 65,
                totalTotal: 1_625
            ),
            at: date("2026-04-14T21:00:00Z")
        )

        let totals = try store.tokenCategoryTotalsForDay(
            containing: date("2026-04-14T22:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 250,
                cachedInputTokens: 55,
                outputTokens: 90,
                reasoningOutputTokens: 20,
                totalTokens: 320
            )
        )
    }

    func testTokenCategoryTotalsForDayReturnsNilWithoutSamples() async throws {
        let store = try makeStore()

        XCTAssertNil(
            try store.tokenCategoryTotalsForDay(
                containing: date("2026-04-14T22:00:00Z"),
                calendar: calendar
            )
        )
    }

    func testTokenCategoryTotalsForDayDeduplicatesRepeatedNotifications() async throws {
        let store = try makeStore()
        let notification = tokenNotification(
            threadID: "thread-a",
            turnID: "turn-a",
            lastInput: 100,
            lastCached: 20,
            lastOutput: 30,
            lastReasoning: 5,
            lastTotal: 155,
            totalInput: 100,
            totalCached: 20,
            totalOutput: 30,
            totalReasoning: 5,
            totalTotal: 155
        )

        try store.record(tokenUsage: notification, at: date("2026-04-14T20:00:00Z"))
        try store.record(tokenUsage: notification, at: date("2026-04-14T20:00:05Z"))

        XCTAssertEqual(
            try store.tokenCategoryTotalsForDay(containing: date("2026-04-14T22:00:00Z"), calendar: calendar),
            TokenCategoryTotals(
                inputTokens: 100,
                cachedInputTokens: 20,
                outputTokens: 30,
                reasoningOutputTokens: 5,
                totalTokens: 155
            )
        )
    }

    func testCodexLogTokenImporterImportsTodayResponseCompletedCategories() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let body = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=146059 output_token_count=37 cached_token_count=145280 reasoning_token_count=0 tool_token_count=146096 event.timestamp=2026-05-17T12:48:13.035Z conversation.id=019dd6bb-c26b-72c2-bb51-0fff5324362a model=gpt-5.5 slug=gpt-5.5
        """
        let duplicateBody = body + " user.email=\"private@example.com\""
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (timestamp, body),
                (timestamp, duplicateBody),
                (date("2026-05-16T12:00:00Z"), body.replacingOccurrences(of: "2026-05-17T12:48:13.035Z", with: "2026-05-16T12:00:00.000Z")),
            ]
        )
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTokenHistory(
            into: store,
            containing: timestamp,
            calendar: calendar
        )
        let totals = try store.tokenCategoryTotalsForDay(containing: timestamp, calendar: calendar)
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 146_059,
                cachedInputTokens: 145_280,
                outputTokens: 37,
                reasoningOutputTokens: 0,
                totalTokens: 146_096
            )
        )
        XCTAssertEqual(samples.map(\.model), ["gpt-5.5"])
        XCTAssertFalse(samples.contains { $0.threadID.contains("private") || $0.turnID.contains("private") })
    }

    func testRecentTokenHistoryImportUsesCodexDesktopLogs() async throws {
        let store = try makeStore()
        let tempDirectory = try makeTemporaryDirectory()
        let databaseURL = tempDirectory.appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (
                    timestamp,
                    """
                    event.name="codex.sse_event" event.kind=response.completed input_token_count=1000 output_token_count=20 cached_token_count=800 reasoning_token_count=5 tool_token_count=1020 event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation model=gpt-5.5 slug=gpt-5.5
                    """
                ),
            ]
        )

        let result = store.importRecentTokenHistoryIfAvailable(
            containing: timestamp,
            calendar: calendar,
            logsDatabaseURL: databaseURL
        )
        let totals = try store.tokenCategoryTotalsForDay(containing: timestamp, calendar: calendar)

        XCTAssertEqual(result, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 1_000,
                cachedInputTokens: 800,
                outputTokens: 20,
                reasoningOutputTokens: 5,
                totalTokens: 1_020
            )
        )
    }

    @MainActor
    func testTokenHistoryReloadCanImportRecentCodexDesktopLogs() async throws {
        let store = try makeStore()
        let tempDirectory = try makeTemporaryDirectory()
        let databaseURL = tempDirectory.appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (
                    timestamp,
                    """
                    event.name="codex.sse_event" event.kind=response.completed input_token_count=1200 output_token_count=30 cached_token_count=900 reasoning_token_count=7 tool_token_count=1230 event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation model=gpt-5.5 slug=gpt-5.5
                    """
                ),
            ]
        )
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { timestamp },
            calendar: calendar,
            recentTokenHistoryImporter: { store, date, calendar in
                store.importRecentTokenHistoryIfAvailable(
                    containing: date,
                    calendar: calendar,
                    logsDatabaseURL: databaseURL
                )
            }
        )

        viewModel.selectedRange = .day
        viewModel.selectedChartKind = .tokens
        await viewModel.reload()

        XCTAssertEqual(try store.availableTokenComponentSeries().map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["tokens_all"])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketName), [
            "All tokens",
            "All tokens",
            "All tokens",
            "All tokens",
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenComponent), [
            .input,
            .cached,
            .output,
            .reasoning,
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [
            1_200,
            900,
            30,
            7,
        ])
    }

}
