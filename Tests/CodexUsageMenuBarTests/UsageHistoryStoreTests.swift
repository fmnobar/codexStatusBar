import CoreGraphics
import SQLite3
import XCTest

final class UsageHistoryStoreTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
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

    func testRecordsDisplaySnapshotForAggregateWhenBucketAggregateDiffers() throws {
        let store = try makeStore()
        let now = date("2026-04-14T20:00:10Z")
        let displaySnapshot = rateLimitSnapshot(
            sevenDayUsedPercent: 20,
            sevenDayResetAt: date("2026-04-20T13:25:00Z")
        )
        let bucketAggregateSnapshot = rateLimitSnapshot(
            sevenDayUsedPercent: 0,
            sevenDayResetAt: date("2026-04-23T21:19:00Z")
        )
        let modelSnapshot = rateLimitSnapshot(sevenDayUsedPercent: 7)
        let snapshot = CodexUsageSnapshot(
            displaySnapshot: displaySnapshot,
            buckets: [
                CodexUsageBucket(id: "codex", name: "All models", kind: .aggregate, snapshot: bucketAggregateSnapshot),
                CodexUsageBucket(id: "codex_gpt55", name: "GPT-5.5", kind: .model, snapshot: modelSnapshot),
            ]
        )

        try store.record(snapshot: snapshot, at: now)

        let points = try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(points.map(\.usedPercent), [20, 7])
    }

    func testAvailableSeriesIncludesTrackedModelsOutsideSelectedPeriod() throws {
        let store = try makeStore()

        try store.record(
            snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7, extraModelSevenDay: 4),
            at: date("2026-04-13T20:00:10Z")
        )

        let emptyCurrentDayPoints = try store.points(
            range: .day,
            window: .sevenDay,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let availableSeries = try store.availableSeries(window: .sevenDay)

        XCTAssertEqual(emptyCurrentDayPoints, [])
        XCTAssertEqual(availableSeries.map(\.id), ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertEqual(availableSeries.map(\.kind), [.aggregate, .model, .model])
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

    func testMigratesExistingRollupsWithoutPeakColumn() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createLegacyHistoryDatabase(at: databaseURL)

        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [42])
        XCTAssertEqual(points.map(\.peakUsedPercent), [42])
    }

    func testRollupsTrackLatestAndPeakUsedPercent() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T20:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T20:40:00Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [10])
        XCTAssertEqual(points.map(\.peakUsedPercent), [30])
    }

    func testDuplicateMinuteRollupsPreservePeakWhileUpdatingLatest() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T20:00:10Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: date("2026-04-14T20:00:50Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [25])
        XCTAssertEqual(points.map(\.peakUsedPercent), [30])
    }

    func testDuplicateMinuteConsumptionAdjustsRollupsWithoutDoubleCounting() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T19:50:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:10Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: date("2026-04-14T20:00:50Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [10, 25])
        XCTAssertEqual(points.map(\.consumedPercent), [0, 15])
    }

    func testUsageConsumptionIgnoresTransientZeroFromDifferentResetCohort() throws {
        let store = try makeStore()
        let stableReset = date("2026-05-20T13:25:36Z")
        let transientReset = date("2026-05-23T19:05:55Z")

        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 27, sevenDayResetAt: stableReset)
            ),
            at: date("2026-05-16T19:00:00Z")
        )
        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 28, sevenDayResetAt: stableReset)
            ),
            at: date("2026-05-16T19:04:00Z")
        )
        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 0, sevenDayResetAt: transientReset)
            ),
            at: date("2026-05-16T19:05:00Z")
        )
        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 28, sevenDayResetAt: stableReset)
            ),
            at: date("2026-05-16T19:09:00Z")
        )
        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30, sevenDayResetAt: stableReset)
            ),
            at: date("2026-05-16T19:50:00Z")
        )
        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 0, sevenDayResetAt: transientReset.addingTimeInterval(52 * 60))
            ),
            at: date("2026-05-16T19:57:00Z")
        )
        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 33, sevenDayResetAt: stableReset)
            ),
            at: date("2026-05-16T20:28:00Z")
        )

        let points = try store.points(range: .month, window: .sevenDay, now: date("2026-05-17T00:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [33])
        XCTAssertEqual(points.map(\.peakUsedPercent), [33])
        XCTAssertEqual(points.map(\.consumedPercent), [6])
    }

    func testMigrationRecomputesInflatedUsageConsumption() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createInflatedConsumptionHistoryDatabase(at: databaseURL)

        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let points = try store.points(range: .month, window: .sevenDay, now: date("2026-05-17T00:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [33])
        XCTAssertEqual(points.map(\.peakUsedPercent), [33])
        XCTAssertEqual(points.map(\.consumedPercent), [6])
    }

    func testMigrationRecreatesMissingRollupsFromRawSamples() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createInflatedConsumptionHistoryDatabase(at: databaseURL, includeLegacyRollup: false)

        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let points = try store.points(range: .month, window: .sevenDay, now: date("2026-05-17T00:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [33])
        XCTAssertEqual(points.map(\.peakUsedPercent), [33])
        XCTAssertEqual(points.map(\.consumedPercent), [6])
    }

    func testRawSamplesCompactButRollupsRemain() throws {
        let store = try makeStore()
        let oldDate = date("2026-01-10T12:00:00Z")
        let currentDate = date("2026-04-14T20:00:00Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: oldDate)
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: currentDate)

        let oldDayPoints = try store.points(range: .day, window: .sevenDay, now: date("2026-01-10T13:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: currentDate, calendar: calendar)

        XCTAssertEqual(oldDayPoints.map(\.usedPercent), [12])
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

    func testRecordsAllTokenUsageFields() throws {
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

    func testTokenUsageComputesObservedCategoryDeltas() throws {
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

    func testTokenUsageDeduplicatesRepeatedThreadTurnAndCumulativeTotal() throws {
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

    func testTokenUsageReimportFillsMissingModelWithoutInflatingTotals() throws {
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
        XCTAssertEqual(try store.tokenTotalForDay(containing: receivedAt, calendar: calendar), 125)
    }

    func testTokenUsageReimportDoesNotClearExistingModel() throws {
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

    func testTokenUsageComputesSameThreadCumulativeDeltas() throws {
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

    func testTokenUsageFirstObservedSampleUsesLastTotalInsteadOfCumulativeTotal() throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-late", lastTotal: 600, totalTotal: 12_000),
            at: date("2026-04-14T20:00:00Z")
        )

        XCTAssertEqual(try store.tokenUsageSamples().first?.observedTotalTokens, 600)
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 600)
    }

    func testTokenHistoryPointsIncludeAggregateAndModelSeries() throws {
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

    func testAvailableTokenSeriesIncludesTrackedModelsOutsideSelectedPeriod() throws {
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

    func testTokenModelSeriesTrimWhitespaceAndDeduplicate() throws {
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

    func testTokenComponentPointsIncludeAggregateAndModelSeries() throws {
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

    func testTokenDashboardPointsAggregateComponentsModelsAndUnattributedRows() throws {
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

    @MainActor
    func testTokenDashboardViewModelDefaultsFiltersAndExportsVisibleRows() throws {
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

        XCTAssertEqual(viewModel.selectedRange, .month)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 215)
        XCTAssertEqual(viewModel.exportFilename, "codex-token-dashboard-month-2026-05.csv")
        XCTAssertEqual(viewModel.compactSeriesTitle("gpt-5.4-mini"), "5.4 Mini")
        XCTAssertTrue(viewModel.csvText.contains("month,2026-05-01T00:00:00Z,2026-06-01T00:00:00Z,2026-05-02T00:00:00Z,2026-05-03T00:00:00Z,tokens_all,All captured,aggregate,input,100"))

        viewModel.selectSeries("model:gpt-5.5")

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["model:gpt-5.5"])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 165)
        XCTAssertFalse(viewModel.csvText.contains("model:gpt-5.4"))
        XCTAssertTrue(viewModel.csvText.contains("model:gpt-5.5,gpt-5.5,model,input,100"))
    }

    @MainActor
    func testTokenDashboardNavigationBoundsAndEmptyStates() throws {
        let emptyViewModel = TokenDashboardViewModel(
            store: try makeStore(),
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )

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

        XCTAssertTrue(viewModel.canGoToPreviousPeriod)
        XCTAssertFalse(viewModel.canGoToNextPeriod)

        viewModel.goToPreviousPeriod()

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-01T00:00:00Z"))
        XCTAssertTrue(viewModel.hasVisiblePoints)
        XCTAssertTrue(viewModel.canGoToNextPeriod)

        viewModel.goToNextPeriod()

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(viewModel.emptyState.title, "No tokens for this selection")
    }

    func testTokenTotalForDayUsesLocalCalendarDay() throws {
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

    func testTokenCategoryTotalsForDaySumsObservedCategories() throws {
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

    func testTokenCategoryTotalsForDayReturnsNilWithoutSamples() throws {
        let store = try makeStore()

        XCTAssertNil(
            try store.tokenCategoryTotalsForDay(
                containing: date("2026-04-14T22:00:00Z"),
                calendar: calendar
            )
        )
    }

    func testTokenCategoryTotalsForDayDeduplicatesRepeatedNotifications() throws {
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

    func testCodexLogTokenImporterImportsTodayResponseCompletedCategories() throws {
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

    func testRecentTokenHistoryImportUsesCodexDesktopLogs() throws {
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
    func testTokenHistoryReloadCanImportRecentCodexDesktopLogs() throws {
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
        viewModel.reload()

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

    func testMigratesExistingDatabaseForTokenUsageSamples() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createLegacyHistoryDatabase(at: databaseURL)
        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 120, totalTotal: 120),
            at: date("2026-04-14T20:00:00Z")
        )

        XCTAssertEqual(try store.tokenUsageSamples().count, 1)
    }

    func testMigratesLegacyTokenTableWithoutObservedCategoryColumns() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createLegacyTokenHistoryDatabase(at: databaseURL)
        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )

        let samples = try store.tokenUsageSamples()
        let inputPoints = try store.tokenPoints(
            category: .input,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )

        XCTAssertEqual(samples.first?.observedInputTokens, nil)
        XCTAssertEqual(inputPoints.map(\.tokenCount), [120])
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 200)
        XCTAssertNil(try store.tokenCategoryTotalsForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar))
    }

    func testSessionTokenBackfillImportsMetadataOnlyTokenEvents() throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-04-14T13-00-00-abc.jsonl")
        try writeSessionLines(
            [
                """
                {"timestamp":"2026-04-14T20:00:00.000Z","type":"response_item","payload":{"item":{"type":"message","content":[{"text":"secret prompt text"}]}}}
                """,
                """
                {"timestamp":"2026-04-14T20:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{}}}
                """,
                "{not valid json \"token_count\"",
                tokenCountLine(
                    timestamp: "2026-04-14T20:00:02.123Z",
                    lastInput: 10,
                    lastCached: 2,
                    lastOutput: 3,
                    lastReasoning: 1,
                    lastTotal: 16,
                    totalInput: 10,
                    totalCached: 2,
                    totalOutput: 3,
                    totalReasoning: 1,
                    totalTotal: 16,
                    contextWindow: 258_400
                ),
                tokenCountLine(
                    timestamp: "2026-04-14T20:05:00Z",
                    lastInput: 15,
                    lastCached: 3,
                    lastOutput: 4,
                    lastReasoning: 2,
                    lastTotal: 24,
                    totalInput: 25,
                    totalCached: 5,
                    totalOutput: 7,
                    totalReasoning: 3,
                    totalTotal: 40,
                    contextWindow: 258_400
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let summary = try importer.importTokenHistory(into: store)
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.tokenEventsImported, 2)
        XCTAssertEqual(summary.duplicateEventsSkipped, 0)
        XCTAssertEqual(summary.failedLinesSkipped, 1)
        XCTAssertEqual(samples.map(\.threadID), [
            "session:rollout-2026-04-14T13-00-00-abc",
            "session:rollout-2026-04-14T13-00-00-abc",
        ])
        XCTAssertEqual(samples.map(\.turnID), ["line:4", "line:5"])
        XCTAssertEqual(samples.map(\.model), [nil, nil])
        XCTAssertEqual(samples.map(\.modelContextWindow), [258_400, 258_400])
        XCTAssertEqual(samples.map(\.observedInputTokens), [10, 15])
        XCTAssertEqual(samples.map(\.observedCachedInputTokens), [2, 3])
        XCTAssertEqual(samples.map(\.observedOutputTokens), [3, 4])
        XCTAssertEqual(samples.map(\.observedReasoningOutputTokens), [1, 2])
        XCTAssertEqual(samples.map(\.observedTotalTokens), [16, 24])
        XCTAssertFalse(samples.contains { sample in
            sample.threadID.contains("secret") || sample.turnID.contains("secret") || (sample.model?.contains("secret") ?? false)
        })
    }

    func testSessionTokenBackfillUsesLatestModelMetadataForTokenEvents() throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-models.jsonl")
        try writeSessionLines(
            [
                turnContextLine(timestamp: "2026-05-17T15:00:00Z", model: " gpt-5.4 "),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 125,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 125
                ),
                turnContextLine(timestamp: "2026-05-17T15:05:00Z", model: "codex-future-7"),
                tokenCountLine(
                    timestamp: "2026-05-17T15:05:10Z",
                    lastInput: 200,
                    lastCached: 100,
                    lastOutput: 30,
                    lastReasoning: 10,
                    lastTotal: 240,
                    totalInput: 300,
                    totalCached: 140,
                    totalOutput: 50,
                    totalReasoning: 15,
                    totalTotal: 365
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let summary = try importer.importTokenHistory(into: store)
        let samples = try store.tokenUsageSamples()
        let availableSeries = try store.availableTokenComponentSeries()

        XCTAssertEqual(summary.tokenEventsImported, 2)
        XCTAssertEqual(samples.map(\.model), ["gpt-5.4", "codex-future-7"])
        XCTAssertEqual(availableSeries.map(\.id), [
            "tokens_all",
            "model:codex-future-7",
            "model:gpt-5.4",
        ])
    }

    func testSessionTokenBackfillUsesTokenCountInfoModelWhenPresent() throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-info-model.jsonl")
        try writeSessionLines(
            [
                turnContextLine(timestamp: "2026-05-17T15:00:00Z", model: "gpt-5.4"),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 125,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 125,
                    model: "o-series-next"
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        _ = try importer.importTokenHistory(into: store)

        XCTAssertEqual(try store.tokenUsageSamples().map(\.model), ["o-series-next"])
    }

    func testSessionTokenBackfillIsIdempotent() throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-04-14T20:00:00Z",
                    lastInput: 100,
                    lastCached: 0,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 125,
                    totalInput: 100,
                    totalCached: 0,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 125
                ),
                tokenCountLine(
                    timestamp: "2026-04-14T20:10:00Z",
                    lastInput: 50,
                    lastCached: 5,
                    lastOutput: 30,
                    lastReasoning: 10,
                    lastTotal: 95,
                    totalInput: 150,
                    totalCached: 5,
                    totalOutput: 50,
                    totalReasoning: 15,
                    totalTotal: 220
                ),
            ],
            to: sessionsURL.appendingPathComponent("rollout-2026-04-14T13-00-00-idempotent.jsonl")
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let firstSummary = try importer.importTokenHistory(into: store)
        let secondSummary = try importer.importTokenHistory(into: store)
        let forcedSummary = try importer.importTokenHistory(into: store, request: .allHistory(forceRescan: true))

        XCTAssertEqual(firstSummary.tokenEventsImported, 2)
        XCTAssertEqual(firstSummary.duplicateEventsSkipped, 0)
        XCTAssertEqual(secondSummary.tokenEventsImported, 0)
        XCTAssertEqual(secondSummary.duplicateEventsSkipped, 0)
        XCTAssertEqual(secondSummary.filesScanned, 0)
        XCTAssertEqual(secondSummary.filesSkippedUnchanged, 1)
        XCTAssertEqual(forcedSummary.tokenEventsImported, 0)
        XCTAssertEqual(forcedSummary.duplicateEventsSkipped, 2)
        XCTAssertEqual(try store.tokenUsageSamples().map(\.observedTotalTokens), [125, 95])
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 220)
    }

    func testSessionTokenBackfillRecentRequestUsesBounds() throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        let archivedURL = sessionsURL.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedURL, withIntermediateDirectories: true)
        let oldURL = sessionsURL.appendingPathComponent("rollout-2026-03-01T10-00-00-old.jsonl")
        let recentURL = sessionsURL.appendingPathComponent("rollout-2026-05-10T10-00-00-recent.jsonl")
        let archivedRecentURL = archivedURL.appendingPathComponent("rollout-2026-05-12T10-00-00-archived.jsonl")
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-03-01T18:00:00Z",
                    lastInput: 10,
                    lastCached: 0,
                    lastOutput: 2,
                    lastReasoning: 0,
                    lastTotal: 12,
                    totalInput: 10,
                    totalCached: 0,
                    totalOutput: 2,
                    totalReasoning: 0,
                    totalTotal: 12
                ),
            ],
            to: oldURL
        )
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-05-10T18:00:00Z",
                    lastInput: 20,
                    lastCached: 5,
                    lastOutput: 3,
                    lastReasoning: 1,
                    lastTotal: 29,
                    totalInput: 20,
                    totalCached: 5,
                    totalOutput: 3,
                    totalReasoning: 1,
                    totalTotal: 29
                ),
            ],
            to: recentURL
        )
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-05-12T18:00:00Z",
                    lastInput: 30,
                    lastCached: 5,
                    lastOutput: 4,
                    lastReasoning: 1,
                    lastTotal: 40,
                    totalInput: 30,
                    totalCached: 5,
                    totalOutput: 4,
                    totalReasoning: 1,
                    totalTotal: 40
                ),
            ],
            to: archivedRecentURL
        )
        try setModificationDate(date("2026-05-17T18:10:00Z"), for: oldURL)
        try setModificationDate(date("2026-05-10T18:10:00Z"), for: recentURL)
        try setModificationDate(date("2026-05-12T18:10:00Z"), for: archivedRecentURL)
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL, archivedURL])

        let summary = try importer.importTokenHistory(
            into: store,
            request: .recent(now: date("2026-05-17T12:00:00Z"), days: 30)
        )

        XCTAssertEqual(summary.filesDiscovered, 3)
        XCTAssertEqual(summary.filesSkippedByBounds, 2)
        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.tokenEventsImported, 1)
        XCTAssertEqual(try store.tokenUsageSamples().map(\.receivedAt), [date("2026-05-10T18:00:00Z")])
    }

    func testSessionTokenBackfillReimportsChangedFilesAndRepairsModel() throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-repair.jsonl")
        let tokenLineWithoutModel = tokenCountLine(
            timestamp: "2026-05-17T15:00:00Z",
            lastInput: 100,
            lastCached: 10,
            lastOutput: 15,
            lastReasoning: 0,
            lastTotal: 125,
            totalInput: 100,
            totalCached: 10,
            totalOutput: 15,
            totalReasoning: 0,
            totalTotal: 125
        )
        try writeSessionLines([tokenLineWithoutModel], to: sessionURL)
        try setModificationDate(date("2026-05-17T15:01:00Z"), for: sessionURL)
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let firstSummary = try importer.importTokenHistory(into: store)

        let tokenLineWithModel = tokenCountLine(
            timestamp: "2026-05-17T15:00:00Z",
            lastInput: 100,
            lastCached: 10,
            lastOutput: 15,
            lastReasoning: 0,
            lastTotal: 125,
            totalInput: 100,
            totalCached: 10,
            totalOutput: 15,
            totalReasoning: 0,
            totalTotal: 125,
            model: " gpt-future-2 "
        )
        try writeSessionLines([tokenLineWithModel], to: sessionURL)
        try setModificationDate(date("2026-05-17T15:05:00Z"), for: sessionURL)

        let repairSummary = try importer.importTokenHistory(into: store)
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(firstSummary.tokenEventsImported, 1)
        XCTAssertEqual(repairSummary.filesScanned, 1)
        XCTAssertEqual(repairSummary.tokenEventsImported, 0)
        XCTAssertEqual(repairSummary.duplicateEventsSkipped, 1)
        XCTAssertEqual(repairSummary.modelEventsRepaired, 1)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.model, "gpt-future-2")
        XCTAssertEqual(samples.first?.observedTotalTokens, 125)
    }

    @MainActor
    func testSessionTokenBackfillScansSessionsAndArchivedAndFeedsTokenCharts() throws {
        let store = try makeStore()
        let rootURL = try makeTemporaryDirectory()
        let sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        let archivedURL = rootURL.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedURL, withIntermediateDirectories: true)
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-01-10T12:00:00Z",
                    lastInput: 80,
                    lastCached: 0,
                    lastOutput: 20,
                    lastReasoning: 0,
                    lastTotal: 100,
                    totalInput: 80,
                    totalCached: 0,
                    totalOutput: 20,
                    totalReasoning: 0,
                    totalTotal: 100
                ),
            ],
            to: archivedURL.appendingPathComponent("rollout-2026-01-10T04-00-00-archived.jsonl")
        )
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-04-14T12:10:00Z",
                    lastInput: 120,
                    lastCached: 30,
                    lastOutput: 40,
                    lastReasoning: 10,
                    lastTotal: 200,
                    totalInput: 120,
                    totalCached: 30,
                    totalOutput: 40,
                    totalReasoning: 10,
                    totalTotal: 200
                ),
                tokenCountLine(
                    timestamp: "2026-04-15T09:00:00Z",
                    lastInput: 250,
                    lastCached: 60,
                    lastOutput: 70,
                    lastReasoning: 20,
                    lastTotal: 400,
                    totalInput: 370,
                    totalCached: 90,
                    totalOutput: 110,
                    totalReasoning: 30,
                    totalTotal: 600
                ),
            ],
            to: sessionsURL.appendingPathComponent("rollout-2026-04-14T05-00-00-live.jsonl")
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL, archivedURL])

        let summary = try importer.importTokenHistory(into: store)

        XCTAssertEqual(summary.filesScanned, 2)
        XCTAssertEqual(summary.tokenEventsImported, 3)

        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-15T12:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedChartKind = .tokens

        viewModel.selectedRange = .day
        viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-15T09:00:00Z"),
            date("2026-04-15T09:00:00Z"),
            date("2026-04-15T09:00:00Z"),
            date("2026-04-15T09:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenComponent), [.input, .cached, .output, .reasoning])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [250, 60, 70, 20])

        viewModel.selectedRange = .week
        viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-14T00:00:00Z"),
            date("2026-04-14T00:00:00Z"),
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [120, 30, 40, 10, 250, 60, 70, 20])

        viewModel.selectedRange = .month
        viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [120, 30, 40, 10, 250, 60, 70, 20])

        viewModel.selectedRange = .year
        viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-01-01T00:00:00Z"),
            date("2026-01-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [80, 20, 370, 90, 110, 30])
    }

    func testSessionTokenBackfillMissingDirectoriesReturnsEmptySummary() throws {
        let store = try makeStore()
        let missingURL = try makeTemporaryDirectory().appendingPathComponent("missing", isDirectory: true)
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [missingURL])

        let summary = try importer.importTokenHistory(into: store)

        XCTAssertEqual(summary.filesScanned, 0)
        XCTAssertEqual(summary.tokenEventsImported, 0)
        XCTAssertEqual(summary.duplicateEventsSkipped, 0)
        XCTAssertEqual(summary.failedLinesSkipped, 0)
        XCTAssertEqual(summary.statusMessage, "No Codex session files found.")
        XCTAssertTrue(try store.tokenUsageSamples().isEmpty)
    }

    func testSessionTokenImportMetadataMigratesFromExistingDatabase() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createLegacyTokenHistoryDatabase(at: databaseURL)
        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let metadata = CodexSessionTokenImportFileMetadata(path: "/tmp/session.jsonl", fileSize: 123, modifiedAt: 456)

        try store.recordCodexSessionTokenImportFile(metadata, importedAt: 789, status: .imported)

        XCTAssertEqual(
            try store.codexSessionTokenImportFileRecord(path: "/tmp/session.jsonl"),
            CodexSessionTokenImportFileRecord(metadata: metadata, importedAt: 789, status: .imported)
        )
    }

    func testClearHistoryDeletesTokenUsageSamples() throws {
        let store = try makeStore()
        let metadata = CodexSessionTokenImportFileMetadata(path: "/tmp/session.jsonl", fileSize: 123, modifiedAt: 456)

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 120, totalTotal: 120),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.recordCodexSessionTokenImportFile(metadata, importedAt: 789, status: .imported)
        XCTAssertTrue(try store.hasAnyHistory())
        XCTAssertEqual(try store.codexSessionTokenImportFileRecords().count, 1)

        try store.clearHistory()

        XCTAssertTrue(try store.tokenUsageSamples().isEmpty)
        XCTAssertTrue(try store.codexSessionTokenImportFileRecords().isEmpty)
        XCTAssertFalse(try store.hasAnyHistory())
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

    func testDatabaseInfoReportsURLAndByteSize() throws {
        let (store, databaseURL) = try makeTemporaryStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))

        let info = try store.databaseInfo()

        XCTAssertEqual(info.databaseURL, databaseURL)
        XCTAssertGreaterThan(info.totalByteSize, 0)
    }

    func testRawRetentionDefaultsAndPersists() throws {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .fourteenDays)

        UsageHistoryRawRetentionStore.save(.ninetyDays, to: defaults)

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .ninetyDays)
    }

    func testRecordUsesUpdatedRawRetentionProvider() throws {
        var retention = UsageHistoryRawRetention.thirtyDays.timeInterval
        let store = try UsageHistoryStore.inMemory(
            notificationCenter: NotificationCenter(),
            calendar: calendar,
            rawRetentionProvider: { retention }
        )
        let oldDate = date("2026-04-01T12:00:00Z")
        let currentDate = date("2026-04-14T20:00:00Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: oldDate)
        retention = UsageHistoryRawRetention.sevenDays.timeInterval
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: currentDate)

        let oldDayPoints = try store.points(range: .day, window: .sevenDay, now: date("2026-04-01T13:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: currentDate, calendar: calendar)

        XCTAssertEqual(oldDayPoints.map(\.usedPercent), [12])
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 12 })
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 40 })
    }

    func testHistoryBoundsUseRequestedRollupGranularity() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-01T12:30:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-14T20:00:00Z"))

        let hourlyBounds = try store.historyBounds(window: .sevenDay, granularity: .hour)
        let dailyBounds = try store.historyBounds(window: .sevenDay, granularity: .day)

        XCTAssertEqual(hourlyBounds?.earliest, date("2026-04-01T12:30:00Z"))
        XCTAssertEqual(hourlyBounds?.latest, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(dailyBounds?.earliest, date("2026-04-01T12:30:00Z"))
        XCTAssertEqual(dailyBounds?.latest, date("2026-04-14T20:00:00Z"))
    }

    func testBackupExportProducesImportableDatabase() throws {
        let (sourceStore, _) = try makeTemporaryStore()
        try sourceStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        try sourceStore.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 120, totalTotal: 120),
            at: date("2026-04-14T20:10:00Z")
        )
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")

        try sourceStore.exportBackup(to: backupURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let (destinationStore, _) = try makeTemporaryStore()
        try destinationStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 80)), at: date("2026-04-14T20:00:00Z"))

        try destinationStore.importBackup(from: backupURL)
        let points = try destinationStore.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [20])
        XCTAssertEqual(try destinationStore.tokenUsageSamples().map(\.observedTotalTokens), [120])
    }

    func testImportBackupReplacesHistoryAndNotifies() throws {
        let (sourceStore, _) = try makeTemporaryStore()
        try sourceStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")
        try sourceStore.exportBackup(to: backupURL)
        let notificationCenter = NotificationCenter()
        let (destinationStore, _) = try makeTemporaryStore(notificationCenter: notificationCenter)
        try destinationStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 80)), at: date("2026-04-14T20:00:00Z"))
        let expectation = expectation(description: "Import posts history change notification")
        let observer = notificationCenter.addObserver(
            forName: UsageHistoryStore.didChangeNotification,
            object: destinationStore,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        try destinationStore.importBackup(from: backupURL)
        wait(for: [expectation], timeout: 1)
        let points = try destinationStore.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [20])
    }

    func testInvalidBackupImportThrowsUserFacingFailure() throws {
        let (store, _) = try makeTemporaryStore()
        let invalidURL = try makeTemporaryDirectory().appendingPathComponent("invalid.sqlite3")
        try Data("not a sqlite backup".utf8).write(to: invalidURL)

        XCTAssertThrowsError(try store.importBackup(from: invalidURL)) { error in
            XCTAssertEqual(error.localizedDescription, UsageHistoryStoreError.invalidBackup.localizedDescription)
        }
    }

    @MainActor
    func testSettingsViewModelFormatsDatabaseInfoAndPersistsRetention() throws {
        let defaults = makeIsolatedDefaults()
        let (store, databaseURL) = try makeTemporaryStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))

        let viewModel = DataManagementSettingsViewModel(store: store, defaults: defaults)

        XCTAssertEqual(viewModel.databasePathText, databaseURL.path)
        XCTAssertNotEqual(viewModel.databaseSizeText, "--")

        viewModel.selectedRetention = .ninetyDays

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .ninetyDays)
        XCTAssertEqual(viewModel.statusMessage, "Raw sample retention updated.")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testSettingsViewModelExportImportClearAndFailureMessages() throws {
        let (store, _) = try makeTemporaryStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let viewModel = DataManagementSettingsViewModel(store: store, defaults: makeIsolatedDefaults())
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")

        viewModel.exportBackup(to: backupURL)

        XCTAssertEqual(viewModel.statusMessage, "Backup exported.")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        viewModel.clearHistory()

        XCTAssertEqual(viewModel.statusMessage, "History cleared.")
        XCTAssertFalse(try store.hasAnyHistory())

        viewModel.importBackup(from: backupURL)

        XCTAssertEqual(viewModel.statusMessage, "Backup imported.")
        XCTAssertTrue(try store.hasAnyHistory())

        let invalidURL = try makeTemporaryDirectory().appendingPathComponent("invalid.sqlite3")
        try Data("not a sqlite backup".utf8).write(to: invalidURL)
        viewModel.importBackup(from: invalidURL)

        XCTAssertEqual(viewModel.errorMessage, "Backup could not be imported.")
        XCTAssertNil(viewModel.statusMessage)
    }

    @MainActor
    func testSettingsViewModelImportsTokenHistoryAndReportsFailure() throws {
        let store = try makeStore()
        let releaseSuccessfulImport = DispatchSemaphore(value: 0)
        let successfulImportStarted = expectation(description: "Successful import started")
        let successImporter = StubTokenBackfillImporter { _, _ in
            successfulImportStarted.fulfill()
            releaseSuccessfulImport.wait()
            return CodexSessionTokenBackfillSummary(
                request: .recent(now: self.date("2026-05-17T12:00:00Z")),
                filesDiscovered: 7,
                filesScanned: 3,
                filesSkippedByBounds: 2,
                filesSkippedUnchanged: 2,
                tokenEventsImported: 12,
                duplicateEventsSkipped: 4,
                modelEventsRepaired: 1,
                failedLinesSkipped: 1,
                elapsedTime: 0.1
            )
        }
        let successViewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            tokenBackfillImporter: successImporter
        )

        successViewModel.importRecentTokenHistoryFromCodexSessions(now: date("2026-05-17T12:00:00Z"))
        wait(for: [successfulImportStarted], timeout: 1)

        XCTAssertTrue(successViewModel.isImportingTokenHistory)
        XCTAssertEqual(successImporter.receivedRequests.map(\.mode), [.recent])
        releaseSuccessfulImport.signal()
        waitForImportToFinish(successViewModel)

        XCTAssertFalse(successViewModel.isImportingTokenHistory)
        XCTAssertEqual(
            successViewModel.tokenImportSummaryText,
            "Recent sessions: scanned 3 of 7 files. Imported 12 token events. 2 outside this import scope. 2 unchanged files skipped. 4 duplicates skipped. 1 model labels repaired. 1 unreadable lines skipped. 0.1s elapsed."
        )
        XCTAssertNil(successViewModel.statusMessage)
        XCTAssertNil(successViewModel.errorMessage)

        let allHistoryImporter = StubTokenBackfillImporter { _, _ in
            CodexSessionTokenBackfillSummary(filesScanned: 1, tokenEventsImported: 0, duplicateEventsSkipped: 0, failedLinesSkipped: 0)
        }
        let allHistoryViewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            tokenBackfillImporter: allHistoryImporter
        )

        allHistoryViewModel.importAllTokenHistoryFromCodexSessions()
        waitForImportToFinish(allHistoryViewModel)

        XCTAssertEqual(allHistoryImporter.receivedRequests.map(\.mode), [.allHistory])

        let failingViewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            tokenBackfillImporter: StubTokenBackfillImporter { _, _ in
                throw UsageHistoryStoreError.databaseUnavailable
            }
        )

        failingViewModel.importTokenHistoryFromCodexSessions()
        waitForImportToFinish(failingViewModel)

        XCTAssertFalse(failingViewModel.isImportingTokenHistory)
        XCTAssertNil(failingViewModel.tokenImportSummaryText)
        XCTAssertEqual(failingViewModel.errorMessage, "Token history could not be imported.")
        XCTAssertNil(failingViewModel.statusMessage)
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
    func testTokenChartPresentationUsesStackedComponentsInsteadOfLimitWindow() throws {
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
        viewModel.reload()

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
    func testTokenCompactSeriesTitlesKeepModelVariantsDistinct() throws {
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
    func testTokenHistoryUsesAggregateOnlySeriesWhenModelsExist() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["tokens_all"])
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
    func testHistoryPeriodDefaultsUseCalendarBoundaries() throws {
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
    func testHistoryCompactPeriodTitlesUseInlineFormats() throws {
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
    func testHistoryCompactWeekPeriodTitleIncludesBothMonthsWhenNeeded() throws {
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
    func testHistoryPeriodNavigationRespectsBoundsAndCurrentPeriod() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-12T09:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.reload()

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
    func testHistoryFollowsCurrentPeriodAcrossDayBoundary() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-28T00:00:00Z"))

        currentDate = date("2026-04-29T08:00:00Z")
        viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-29T00:00:00Z"))
        XCTAssertFalse(viewModel.canGoToNextPeriod)

        viewModel.goToPreviousPeriod()
        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-28T00:00:00Z"))

        currentDate = date("2026-04-30T08:00:00Z")
        viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-28T00:00:00Z"))

        viewModel.activateCurrentPeriod()
        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-30T00:00:00Z"))
    }

    @MainActor
    func testHistoryPeriodJumpToCurrentAndNavigationHints() throws {
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
            viewModel.reload()

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
    func testHistoryPeriodPreviousHintExplainsNoEarlierHistory() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-28T10:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-28T15:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.reload()

        XCTAssertFalse(viewModel.canGoToPreviousPeriod)
        XCTAssertEqual(viewModel.previousPeriodHelpText, "No earlier history for this limit")
        XCTAssertEqual(viewModel.previousPeriodAccessibilityLabel, "No earlier history for this limit")
    }

    @MainActor
    func testHistoryExportFilenameUsesSelectedPeriodWindowAndMetric() throws {
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
    func testHistoryXAxisLabelsUseSelectedRangeFormats() throws {
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
    func testHistoryXAxisLabelValuesAreCenteredInBucketsForAllRanges() throws {
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
    func testHistoryChartDomainAddsHalfBucketPaddingForEdgeLabels() throws {
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
    func testComparableHistoryPresentationUsesContributorsAndAggregateReference() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.chartSubtitle, "Usage consumed by hour")
        XCTAssertEqual(viewModel.visibleContributorPoints.map(\.bucketID), ["codex_gpt55"])
        XCTAssertEqual(viewModel.visibleAggregateReferencePoints.map(\.bucketID), ["codex"])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.bucketID), ["codex_gpt55"])
    }

    @MainActor
    func testDayChartGroupsHourlyRollupsIntoHourlyBuckets() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T17:00:00Z"),
            date("2026-04-14T18:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [9, 12])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .capacityLeft) }, [91, 88])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .usage) }, [4, 3])
    }

    @MainActor
    func testWeekChartGroupsHourlyRollupsIntoDailyBucketsAndShowsResetCapacity() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-12T00:00:00Z"),
            date("2026-04-13T00:00:00Z"),
            date("2026-04-16T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .capacityLeft) }, [10, 30, 90])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .usage) }, [0, 0, 0])
    }

    @MainActor
    func testMonthAndYearChartBucketGranularity() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])

        viewModel.selectedRange = .year
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-01-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [15, 60])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.peakUsedPercent), [15, 60])
    }

    @MainActor
    func testTokenChartsBucketBySelectedPeriod() throws {
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
        viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [date("2026-04-14T12:00:00Z")])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [500])

        currentDate = date("2026-04-17T20:00:00Z")
        viewModel.selectedRange = .week
        viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [500, 400])

        currentDate = date("2026-04-30T20:00:00Z")
        viewModel.selectedRange = .month
        viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])

        viewModel.selectedRange = .year
        viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-01-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [100, 900])
    }

    @MainActor
    func testUsageMetricUsesObservedConsumptionWithinBucket() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [30, 42])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.peakUsedPercent), [30, 42])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: viewModel.selectedMetric) }, [0, 12])
    }

    @MainActor
    func testChartCSVUsesVisibleBucketedDatasetAndSelectedMetric() throws {
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
        viewModel.reload()
        let csv = viewModel.chartCSV()

        XCTAssertTrue(csv.contains("range,limit,metric,bucket_start,bucket_end,bucket_id,bucket_name,bucket_kind,percent_value"))
        XCTAssertTrue(csv.contains("day,sevenDay,usage,2026-04-14T20:00:00Z,2026-04-14T21:00:00Z,codex,All models,aggregate,8.000"))
    }

    @MainActor
    func testTokenChartCSVUsesVisibleBucketedDatasetAndCategory() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.exportFilename, "codex-usage-tokens-day-2026-04-14.csv")

        let csv = viewModel.chartCSV()

        XCTAssertTrue(csv.contains("range,bucket_start,bucket_end,series_id,series_name,series_kind,token_component,token_count"))
        XCTAssertTrue(csv.contains("day,2026-04-14T20:00:00Z,2026-04-14T21:00:00Z,tokens_all,All tokens,aggregate,input,120"))
        XCTAssertTrue(csv.contains("day,2026-04-14T20:00:00Z,2026-04-14T21:00:00Z,tokens_all,All tokens,aggregate,cached,80"))
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
        viewModel.selectedRange = .day
        viewModel.reload()

        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:07:00Z"), xPosition: 180)

        XCTAssertEqual(viewModel.hoverSelection?.bucketStart, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(viewModel.hoverSelection?.points.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(viewModel.hoverSelection?.xPosition, 180)
    }

    @MainActor
    func testTokenHoverSelectionGroupsVisibleSeriesInBucket() throws {
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
        viewModel.reload()

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
    func testHoverSelectionClearsWhenVisibleSeriesChanges() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
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
    func testSparkModelIsHiddenByDefault() throws {
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

        viewModel.reload()

        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["codex", "codex_gpt53_spark"])
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])

        viewModel.selectAllSeries()

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex", "codex_gpt53_spark"])
    }

    @MainActor
    func testSparkModelRemainsAvailableButHiddenWhenSelectedPeriodHasNoBars() throws {
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
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints, [])
        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["codex", "codex_gpt53_spark"])
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])

        viewModel.selectAllSeries()

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex", "codex_gpt53_spark"])

        viewModel.clearModelSeries()

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])
    }

    func testAvailableRateLimitSeriesDoesNotExposeTokenOnlyModels() throws {
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
        viewModel.selectedRange = .day
        viewModel.reload()

        XCTAssertTrue(viewModel.hasAnyRecordedHistory)
        XCTAssertEqual(viewModel.emptyStatePresentation.kind, .noDataForSelection)
    }

    @MainActor
    func testUsageAxisDefaultsToFiftyAndExpandsForHighConsumption() throws {
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
        lowUsageViewModel.reload()

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
        highUsageViewModel.reload()

        XCTAssertEqual(highUsageViewModel.chartYDomain, 0...100)
    }

    @MainActor
    func testTokenAxisFormatsRawThousandsAndMillions() throws {
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

    func testHistoryWindowFrameClampsOffscreenSavedFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let restoredFrame = CGRect(x: -320, y: -80, width: 880, height: 640)

        let frame = UsageHistoryWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 700, height: 520),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 880, height: 640))
    }

    func testHistoryWindowFrameFitsVisibleScreenBeforeMinimumSize() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 640, height: 480)
        let restoredFrame = CGRect(x: 80, y: 20, width: 500, height: 300)

        let frame = UsageHistoryWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 700, height: 520),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
    }

    func testTokenDashboardWindowFrameClampsLikeHistoryWindow() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 900, height: 620)
        let restoredFrame = CGRect(x: 20, y: -40, width: 1040, height: 700)

        let frame = TokenDashboardWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 780, height: 560),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
    }

    private func makeStore() throws -> UsageHistoryStore {
        try UsageHistoryStore.inMemory(notificationCenter: NotificationCenter(), calendar: calendar)
    }

    private func makeTemporaryStore(
        notificationCenter: NotificationCenter = NotificationCenter()
    ) throws -> (store: UsageHistoryStore, databaseURL: URL) {
        let directoryURL = try makeTemporaryDirectory()
        let databaseURL = directoryURL.appendingPathComponent("usage-history.sqlite3")
        return (
            try UsageHistoryStore(
                databaseURL: databaseURL,
                notificationCenter: notificationCenter,
                calendar: calendar
            ),
            databaseURL
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL
    }

    private func createLegacyHistoryDatabase(at databaseURL: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let database else {
            XCTFail("Expected legacy database to open")
            return
        }
        defer { sqlite3_close(database) }

        let legacyTimestamp = Int64(date("2026-04-14T20:30:00Z").timeIntervalSince1970)
        let legacyPeriodStart = Int64(date("2026-04-14T20:00:00Z").timeIntervalSince1970)
        let sql = """
        CREATE TABLE usage_samples (
            bucket_id TEXT NOT NULL,
            bucket_name TEXT NOT NULL,
            bucket_kind TEXT NOT NULL,
            window TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            used_percent INTEGER NOT NULL,
            reset_at INTEGER,
            PRIMARY KEY (bucket_id, window, timestamp)
        );
        CREATE TABLE usage_rollups (
            granularity TEXT NOT NULL,
            bucket_id TEXT NOT NULL,
            bucket_name TEXT NOT NULL,
            bucket_kind TEXT NOT NULL,
            window TEXT NOT NULL,
            period_start INTEGER NOT NULL,
            sample_timestamp INTEGER NOT NULL,
            used_percent INTEGER NOT NULL,
            reset_at INTEGER,
            PRIMARY KEY (granularity, bucket_id, window, period_start)
        );
        INSERT INTO usage_rollups (
            granularity, bucket_id, bucket_name, bucket_kind, window,
            period_start, sample_timestamp, used_percent, reset_at
        ) VALUES (
            'hour', 'codex', 'All models', 'aggregate', 'sevenDay',
            \(legacyPeriodStart), \(legacyTimestamp), 42, NULL
        );
        """

        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            XCTFail(message)
        }
    }

    private func createInflatedConsumptionHistoryDatabase(
        at databaseURL: URL,
        includeLegacyRollup: Bool = true
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let database else {
            XCTFail("Expected history database to open")
            return
        }
        defer { sqlite3_close(database) }

        let stableReset = Int64(date("2026-05-20T13:25:36Z").timeIntervalSince1970)
        let transientReset = Int64(date("2026-05-23T19:05:55Z").timeIntervalSince1970)
        let sampleRows: [(String, Int, Double, Int64)] = [
            ("2026-05-16T19:00:00Z", 27, 0, stableReset),
            ("2026-05-16T19:04:00Z", 28, 1, stableReset),
            ("2026-05-16T19:05:00Z", 0, 0, transientReset),
            ("2026-05-16T19:09:00Z", 28, 28, stableReset),
            ("2026-05-16T19:50:00Z", 30, 2, stableReset),
            ("2026-05-16T19:57:00Z", 0, 0, transientReset + 52 * 60),
            ("2026-05-16T20:28:00Z", 33, 33, stableReset),
            ("2026-05-16T21:33:00Z", 1, 1, transientReset + 2 * 60 * 60),
            ("2026-05-16T21:45:00Z", 2, 1, transientReset + 2 * 60 * 60),
            ("2026-05-16T21:56:00Z", 3, 1, transientReset + 2 * 60 * 60),
            ("2026-05-16T22:12:00Z", 4, 1, transientReset + 2 * 60 * 60),
            ("2026-05-16T22:38:00Z", 5, 1, transientReset + 2 * 60 * 60),
            ("2026-05-16T23:22:00Z", 6, 1, transientReset + 2 * 60 * 60),
        ]
        let insertedSamples = sampleRows.map { timestamp, usedPercent, consumedPercent, resetAt in
            """
            ('codex', 'All models', 'aggregate', 'sevenDay', \(Int64(date(timestamp).timeIntervalSince1970)),
                \(usedPercent), \(consumedPercent), \(resetAt))
            """
        }.joined(separator: ",\n")
        let dayStart = Int64(date("2026-05-16T00:00:00Z").timeIntervalSince1970)
        let lastSampleTimestamp = Int64(date("2026-05-16T23:22:00Z").timeIntervalSince1970)
        let legacyRollupSQL = includeLegacyRollup ? """
        INSERT INTO usage_rollups (
            granularity, bucket_id, bucket_name, bucket_kind, window,
            period_start, sample_timestamp, used_percent, peak_used_percent, consumed_percent, reset_at
        ) VALUES (
            'day', 'codex', 'All models', 'aggregate', 'sevenDay',
            \(dayStart), \(lastSampleTimestamp), 6, 33, 120, \(transientReset + 2 * 60 * 60)
        );
        """ : ""

        let sql = """
        CREATE TABLE usage_samples (
            bucket_id TEXT NOT NULL,
            bucket_name TEXT NOT NULL,
            bucket_kind TEXT NOT NULL,
            window TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            used_percent INTEGER NOT NULL,
            consumed_percent REAL,
            reset_at INTEGER,
            PRIMARY KEY (bucket_id, window, timestamp)
        );
        CREATE TABLE usage_rollups (
            granularity TEXT NOT NULL,
            bucket_id TEXT NOT NULL,
            bucket_name TEXT NOT NULL,
            bucket_kind TEXT NOT NULL,
            window TEXT NOT NULL,
            period_start INTEGER NOT NULL,
            sample_timestamp INTEGER NOT NULL,
            used_percent INTEGER NOT NULL,
            peak_used_percent INTEGER,
            consumed_percent REAL,
            reset_at INTEGER,
            PRIMARY KEY (granularity, bucket_id, window, period_start)
        );
        INSERT INTO usage_samples (
            bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent, consumed_percent, reset_at
        ) VALUES
        \(insertedSamples);
        \(legacyRollupSQL)
        """

        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            XCTFail(message)
        }
    }

    private func createLegacyTokenHistoryDatabase(at databaseURL: URL) throws {
        try createLegacyHistoryDatabase(at: databaseURL)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let database else {
            XCTFail("Expected legacy token database to open")
            return
        }
        defer { sqlite3_close(database) }

        let receivedAt = Int64(date("2026-04-14T20:30:00Z").timeIntervalSince1970)
        let sql = """
        CREATE TABLE token_usage_samples (
            thread_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            model TEXT,
            received_at INTEGER NOT NULL,
            model_context_window INTEGER,
            last_input_tokens INTEGER NOT NULL,
            last_cached_input_tokens INTEGER NOT NULL,
            last_output_tokens INTEGER NOT NULL,
            last_reasoning_output_tokens INTEGER NOT NULL,
            last_total_tokens INTEGER NOT NULL,
            total_input_tokens INTEGER NOT NULL,
            total_cached_input_tokens INTEGER NOT NULL,
            total_output_tokens INTEGER NOT NULL,
            total_reasoning_output_tokens INTEGER NOT NULL,
            total_total_tokens INTEGER NOT NULL,
            observed_total_tokens INTEGER NOT NULL,
            PRIMARY KEY (thread_id, turn_id, total_total_tokens)
        );
        INSERT INTO token_usage_samples (
            thread_id, turn_id, model, received_at, model_context_window,
            last_input_tokens, last_cached_input_tokens, last_output_tokens,
            last_reasoning_output_tokens, last_total_tokens,
            total_input_tokens, total_cached_input_tokens, total_output_tokens,
            total_reasoning_output_tokens, total_total_tokens, observed_total_tokens
        ) VALUES (
            'thread-a', 'turn-a', NULL, \(receivedAt), NULL,
            120, 30, 40, 10, 200,
            120, 30, 40, 10, 200, 200
        );
        """

        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            XCTFail(message)
        }
    }

    private func createCodexLogsDatabase(at databaseURL: URL, rows: [(Date, String)]) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let database else {
            XCTFail("Expected Codex logs database to open")
            return
        }
        defer { sqlite3_close(database) }

        var errorMessage: UnsafeMutablePointer<Int8>?
        let createResult = sqlite3_exec(
            database,
            """
            CREATE TABLE logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                feedback_log_body TEXT
            );
            """,
            nil,
            nil,
            &errorMessage
        )
        if createResult != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            XCTFail(message)
            return
        }

        for (timestamp, body) in rows {
            let escapedBody = body.replacingOccurrences(of: "'", with: "''")
            let sql = """
            INSERT INTO logs (ts, feedback_log_body)
            VALUES (\(Int64(timestamp.timeIntervalSince1970)), '\(escapedBody)');
            """
            let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
            if result != SQLITE_OK {
                let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
                sqlite3_free(errorMessage)
                XCTFail(message)
                return
            }
        }
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "CodexUsageMenuBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
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

    private func sparkUsageSnapshot(aggregateSevenDay: Int, sparkSevenDay: Int) -> CodexUsageSnapshot {
        let aggregateSnapshot = rateLimitSnapshot(sevenDayUsedPercent: aggregateSevenDay)
        let sparkSnapshot = rateLimitSnapshot(sevenDayUsedPercent: sparkSevenDay)
        return CodexUsageSnapshot(
            displaySnapshot: aggregateSnapshot,
            buckets: [
                CodexUsageBucket(id: "codex", name: "All models", kind: .aggregate, snapshot: aggregateSnapshot),
                CodexUsageBucket(
                    id: "codex_gpt53_spark",
                    name: "GPT-5.3-Codex-Spark",
                    kind: .model,
                    snapshot: sparkSnapshot
                ),
            ]
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

    private func rateLimitSnapshot(
        sevenDayUsedPercent: Int,
        sevenDayResetAt: Date? = nil,
        fiveHourUsedPercent: Int = 5,
        fiveHourResetAt: Date? = nil
    ) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(
                usedPercent: fiveHourUsedPercent,
                windowDurationMinutes: 300,
                resetsAt: fiveHourResetAt
            ),
            secondary: CodexRateLimitWindow(
                usedPercent: sevenDayUsedPercent,
                windowDurationMinutes: 10080,
                resetsAt: sevenDayResetAt
            )
        )
    }

    private func tokenNotification(
        threadID: String,
        turnID: String,
        model: String? = nil,
        lastInput: Int64 = 0,
        lastCached: Int64 = 0,
        lastOutput: Int64 = 0,
        lastReasoning: Int64 = 0,
        lastTotal: Int64,
        totalInput: Int64 = 0,
        totalCached: Int64 = 0,
        totalOutput: Int64 = 0,
        totalReasoning: Int64 = 0,
        totalTotal: Int64,
        contextWindow: Int64? = nil
    ) -> CodexTokenUsageNotification {
        CodexTokenUsageNotification(
            threadID: threadID,
            turnID: turnID,
            model: model,
            tokenUsage: CodexThreadTokenUsage(
                last: CodexTokenUsageBreakdown(
                    inputTokens: lastInput,
                    cachedInputTokens: lastCached,
                    outputTokens: lastOutput,
                    reasoningOutputTokens: lastReasoning,
                    totalTokens: lastTotal
                ),
                total: CodexTokenUsageBreakdown(
                    inputTokens: totalInput,
                    cachedInputTokens: totalCached,
                    outputTokens: totalOutput,
                    reasoningOutputTokens: totalReasoning,
                    totalTokens: totalTotal
                ),
                modelContextWindow: contextWindow
            )
        )
    }

    private func writeSessionLines(_ lines: [String], to url: URL) throws {
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func dashboardTokenCount(
        _ points: [TokenDashboardComponentPoint],
        seriesID: String,
        component: TokenHistoryComponent,
        bucketStart: Date
    ) -> Int64? {
        points.first {
            $0.seriesID == seriesID
                && $0.component == component
                && $0.bucketStart == bucketStart
        }?.tokenCount
    }

    @MainActor
    private func waitForImportToFinish(_ viewModel: DataManagementSettingsViewModel, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isImportingTokenHistory && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func tokenCountLine(
        timestamp: String,
        lastInput: Int64,
        lastCached: Int64,
        lastOutput: Int64,
        lastReasoning: Int64,
        lastTotal: Int64,
        totalInput: Int64,
        totalCached: Int64,
        totalOutput: Int64,
        totalReasoning: Int64,
        totalTotal: Int64,
        contextWindow: Int64? = nil,
        model: String? = nil
    ) -> String {
        let contextWindowValue = contextWindow.map(String.init) ?? "null"
        let modelFragment = model.map { #","model":"\#($0)""# } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(lastInput),"cached_input_tokens":\(lastCached),"output_tokens":\(lastOutput),"reasoning_output_tokens":\(lastReasoning),"total_tokens":\(lastTotal)},"total_token_usage":{"input_tokens":\(totalInput),"cached_input_tokens":\(totalCached),"output_tokens":\(totalOutput),"reasoning_output_tokens":\(totalReasoning),"total_tokens":\(totalTotal)},"model_context_window":\(contextWindowValue)\(modelFragment)}}}
        """
    }

    private func turnContextLine(timestamp: String, model: String) -> String {
        """
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"\(model)","sandbox_policy":{"type":"danger-full-access"}}}
        """
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}

private final class StubTokenBackfillImporter: CodexSessionTokenBackfillImporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var receivedRequests: [CodexSessionTokenBackfillRequest] = []
    private let result: (UsageHistoryStore, CodexSessionTokenBackfillRequest) throws -> CodexSessionTokenBackfillSummary

    init(result: @escaping (UsageHistoryStore, CodexSessionTokenBackfillRequest) throws -> CodexSessionTokenBackfillSummary) {
        self.result = result
    }

    func importTokenHistory(
        into store: UsageHistoryStore,
        request: CodexSessionTokenBackfillRequest
    ) throws -> CodexSessionTokenBackfillSummary {
        lock.lock()
        receivedRequests.append(request)
        lock.unlock()
        return try result(store, request)
    }
}
