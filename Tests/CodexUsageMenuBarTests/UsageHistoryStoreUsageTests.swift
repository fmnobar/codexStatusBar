import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testRecordsAggregateAndModelSamples() async throws {
        let store = try makeStore()
        let now = date("2026-04-14T20:00:10Z")

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: now)

        let points = try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(points.map(\.bucketName), ["All models", "GPT-5.5"])
        XCTAssertEqual(points.map(\.usedPercent), [20, 7])
        XCTAssertEqual(points.map(\.timestamp), [date("2026-04-14T20:00:00Z"), date("2026-04-14T20:00:00Z")])
    }

    func testRecordsDisplaySnapshotForAggregateWhenBucketAggregateDiffers() async throws {
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

    func testAvailableSeriesIncludesTrackedModelsOutsideSelectedPeriod() async throws {
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

    func testAvailableSeriesReadsFromCatalog() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        try executeSQLite(
            at: databaseURL,
            sql: """
            INSERT INTO usage_series_catalog (
                window, bucket_id, bucket_name, bucket_kind, seen_at
            ) VALUES
                ('sevenDay', 'codex', 'All models', 'aggregate', \(Int64(date("2026-04-14T20:00:00Z").timeIntervalSince1970))),
                ('sevenDay', 'codex_gpt55', 'GPT-5.5', 'model', \(Int64(date("2026-04-14T20:01:00Z").timeIntervalSince1970))),
                ('fiveHour', 'codex', 'All models', 'aggregate', \(Int64(date("2026-04-14T20:02:00Z").timeIntervalSince1970)));
            """
        )

        let availableSeries = try store.availableSeries(window: .sevenDay)
        let rawPoints = try store.points(
            range: .day,
            window: .sevenDay,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )

        XCTAssertEqual(rawPoints, [])
        XCTAssertEqual(availableSeries.map(\.id), ["codex", "codex_gpt55"])
        XCTAssertEqual(availableSeries.map(\.name), ["All models", "GPT-5.5"])
    }

    func testUpsertsDuplicateMinuteSamples() async throws {
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

    func testLatestUsageSnapshotReadsCachedAggregateWindows() async throws {
        let store = try makeStore()
        let first = date("2026-04-14T20:00:10Z")
        let second = date("2026-04-14T20:01:10Z")
        let resetAt = date("2026-04-20T13:25:00Z")

        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(
                    sevenDayUsedPercent: 20,
                    sevenDayResetAt: resetAt
                )
            ),
            at: first
        )
        try store.record(
            snapshot: CodexUsageSnapshot.aggregateOnly(
                displaySnapshot: rateLimitSnapshot(
                    sevenDayUsedPercent: 29,
                    sevenDayResetAt: resetAt,
                    fiveHourUsedPercent: 8
                )
            ),
            at: second
        )

        let cached = try XCTUnwrap(store.latestUsageSnapshot())

        XCTAssertEqual(cached.recordedAt, date("2026-04-14T20:01:00Z"))
        XCTAssertEqual(cached.snapshot.displaySnapshot.primary?.usedPercent, 8)
        XCTAssertEqual(cached.snapshot.displaySnapshot.secondary?.usedPercent, 29)
        XCTAssertEqual(cached.snapshot.displaySnapshot.secondary?.resetsAt, resetAt)
    }

    func testWeekMonthAndYearQueriesUseRollups() async throws {
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

    func testMigratesExistingRollupsWithoutPeakColumn() async throws {
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
        XCTAssertEqual(try store.availableSeries(window: .sevenDay).map(\.id), ["codex"])
    }

    func testRollupsTrackLatestAndPeakUsedPercent() async throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T20:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T20:40:00Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [10])
        XCTAssertEqual(points.map(\.peakUsedPercent), [30])
    }

    func testDuplicateMinuteRollupsPreservePeakWhileUpdatingLatest() async throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T20:00:10Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: date("2026-04-14T20:00:50Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [25])
        XCTAssertEqual(points.map(\.peakUsedPercent), [30])
    }

    func testDuplicateMinuteConsumptionAdjustsRollupsWithoutDoubleCounting() async throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T19:50:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:10Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: date("2026-04-14T20:00:50Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [10, 25])
        XCTAssertEqual(points.map(\.consumedPercent), [0, 15])
    }

    func testUsageConsumptionIgnoresTransientZeroFromDifferentResetCohort() async throws {
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

    func testMigrationRecomputesInflatedUsageConsumption() async throws {
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

    func testMigrationRecreatesMissingRollupsFromRawSamples() async throws {
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

    func testRawSamplesCompactButRollupsRemain() async throws {
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

    func testClearHistoryDeletesSamplesAndRollups() async throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        try store.clearHistory()

        XCTAssertTrue(try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar).isEmpty)
        XCTAssertTrue(try store.points(range: .year, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar).isEmpty)
    }

}
