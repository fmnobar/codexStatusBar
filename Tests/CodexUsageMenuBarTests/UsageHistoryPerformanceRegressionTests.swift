import Foundation
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testPerformanceFixtureBackfillsCatalogsThroughStoreMigration() throws {
        let fixture = try makePerformanceFixture()

        XCTAssertGreaterThan(try fixture.store.availableSeries(window: .sevenDay).count, 1)
        XCTAssertEqual(
            try fixture.store.availableTokenComponentSeries().map(\.id),
            ["tokens_all", "model:gpt-5.4", "model:gpt-5.4-mini", "model:gpt-5.5"]
        )
        XCTAssertEqual(
            try fixture.store.tokenDashboardSeries().map(\.id),
            ["tokens_all", "model:gpt-5.4", "model:gpt-5.4-mini", "model:gpt-5.5", "tokens_unattributed"]
        )
    }

    func testHistoryHotQueriesUseBoundedIndexes() throws {
        let fixture = try makePerformanceFixture()
        let month = UsageHistoryRange.month.period(containing: fixture.now, calendar: calendar)
        let rawStart = month.start.timeIntervalSince1970Int
        let rawEnd = month.end.timeIntervalSince1970Int
        let year = UsageHistoryRange.year.period(containing: fixture.now, calendar: calendar)
        let yearStart = year.start.timeIntervalSince1970Int
        let yearEnd = year.end.timeIntervalSince1970Int

        let rawPlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            SELECT bucket_id, bucket_name, bucket_kind, timestamp, used_percent,
                used_percent, consumed_percent
            FROM usage_samples
            WHERE window = 'sevenDay' AND timestamp >= \(rawStart) AND timestamp < \(rawEnd)
            ORDER BY timestamp ASC, bucket_kind ASC, bucket_name ASC
            """
        )
        XCTAssertPlanUsesSearch(rawPlan, table: "usage_samples")
        XCTAssertPlanMentions(rawPlan, "idx_usage_samples_window_timestamp")

        let rollupPlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            SELECT bucket_id, bucket_name, bucket_kind, sample_timestamp,
                used_percent, IFNULL(peak_used_percent, used_percent), consumed_percent
            FROM usage_rollups
            WHERE granularity = 'day' AND window = 'sevenDay'
                AND sample_timestamp >= \(yearStart) AND sample_timestamp < \(yearEnd)
            ORDER BY sample_timestamp ASC, bucket_kind ASC, bucket_name ASC
            """
        )
        XCTAssertPlanUsesSearch(rollupPlan, table: "usage_rollups")
        XCTAssertPlanMentions(rollupPlan, "idx_usage_rollups_window_sample_timestamp")
    }

    func testTokenHistoryAndDashboardHotQueriesUseBoundedIndexes() throws {
        let fixture = try makePerformanceFixture()
        let month = UsageHistoryRange.month.period(containing: fixture.now, calendar: calendar)
        let start = month.start.timeIntervalSince1970Int
        let end = month.end.timeIntervalSince1970Int
        let bucketEnd = calendar.date(byAdding: .day, value: 1, to: month.start)!.timeIntervalSince1970Int

        let compactTokenPlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            WITH buckets(bucket_start, bucket_end, display_end) AS (
                VALUES (\(start), \(bucketEnd), \(bucketEnd))
            ),
            components(component, sort_order) AS (
                VALUES ('input', 0), ('cached', 1), ('output', 2), ('reasoning', 3)
            )
            SELECT b.bucket_start, c.component, SUM(
                CASE c.component
                    WHEN 'input' THEN IFNULL(s.observed_input_tokens, 0)
                    WHEN 'cached' THEN IFNULL(s.observed_cached_input_tokens, 0)
                    WHEN 'output' THEN IFNULL(s.observed_output_tokens, 0)
                    WHEN 'reasoning' THEN IFNULL(s.observed_reasoning_output_tokens, 0)
                    ELSE 0
                END
            )
            FROM buckets b
            JOIN token_usage_samples s
                ON s.received_at >= b.bucket_start
                AND s.received_at < b.bucket_end
            CROSS JOIN components c
            WHERE s.received_at >= \(start)
                AND s.received_at < \(end)
                AND (
                    s.observed_input_tokens > 0
                    OR s.observed_cached_input_tokens > 0
                    OR s.observed_output_tokens > 0
                    OR s.observed_reasoning_output_tokens > 0
                )
            GROUP BY b.bucket_start, c.component
            """
        )
        XCTAssertPlanUsesSearch(compactTokenPlan, tableOrAlias: "s", fullScanTable: "token_usage_samples")
        XCTAssertPlanMentions(compactTokenPlan, "idx_token_usage_samples_observed_components_received_at")

        let dashboardPlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            SELECT received_at, model, observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens
            FROM token_usage_samples
            WHERE received_at >= \(start) AND received_at < \(end)
                AND (
                    observed_input_tokens > 0
                    OR observed_cached_input_tokens > 0
                    OR observed_output_tokens > 0
                    OR observed_reasoning_output_tokens > 0
                )
            ORDER BY received_at ASC
            """
        )
        XCTAssertPlanUsesSearch(dashboardPlan, table: "token_usage_samples")
        XCTAssertPlanMentions(dashboardPlan, "idx_token_usage_samples_observed_components_received_at")
    }

    func testAvailableSeriesQueriesUseCatalogTables() throws {
        let fixture = try makePerformanceFixture()

        let usagePlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            SELECT bucket_id, bucket_name, bucket_kind, seen_at
            FROM usage_series_catalog
            WHERE window = 'sevenDay'
            ORDER BY seen_at DESC, bucket_kind ASC, bucket_name ASC
            """
        )
        XCTAssertPlanMentions(usagePlan, "usage_series_catalog")
        XCTAssertPlanDoesNotMention(usagePlan, "usage_samples")
        XCTAssertPlanDoesNotMention(usagePlan, "usage_rollups")

        let tokenPlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            SELECT series_id, series_name, series_kind, seen_at
            FROM token_series_catalog
            WHERE has_input = 1
                OR has_cached = 1
                OR has_output = 1
                OR has_reasoning = 1
            ORDER BY seen_at DESC, series_kind ASC, series_name ASC
            """
        )
        XCTAssertPlanMentions(tokenPlan, "token_series_catalog")
        XCTAssertPlanDoesNotMention(tokenPlan, "token_usage_samples")

        let projectPlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            SELECT project_path, project_name, last_seen_at
            FROM token_project_catalog
            ORDER BY last_seen_at DESC, project_name ASC, project_path ASC
            """
        )
        XCTAssertPlanMentions(projectPlan, "token_project_catalog")
        XCTAssertPlanDoesNotMention(projectPlan, "token_usage_samples")

        let effortPlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            SELECT effort, last_seen_at
            FROM token_effort_catalog
            ORDER BY last_seen_at DESC, effort ASC
            """
        )
        XCTAssertPlanMentions(effortPlan, "token_effort_catalog")
        XCTAssertPlanDoesNotMention(effortPlan, "token_usage_samples")

        let dimensionPlan = try queryPlan(
            at: fixture.databaseURL,
            sql: """
            SELECT dimension_key, dimension_value, last_seen_at
            FROM token_dimension_catalog
            WHERE dimension_key = 'usage_mode'
            ORDER BY last_seen_at DESC, dimension_value ASC
            """
        )
        XCTAssertPlanMentions(dimensionPlan, "token_dimension_catalog")
        XCTAssertPlanDoesNotMention(dimensionPlan, "token_usage_samples")
        XCTAssertPlanDoesNotMention(dimensionPlan, "token_usage_dimensions")
    }

    func testHistoryAndDashboardSnapshotsStayWithinConservativeBudgets() async throws {
        let fixture = try makePerformanceFixture()
        let worker = UsageHistoryDatabaseWorker(
            store: fixture.store,
            recentTokenHistoryImporter: { _, _, _, _ in CodexLiveTokenCaptureState(status: .noNewEvents) }
        )
        let month = UsageHistoryRange.month.period(containing: fixture.now, calendar: calendar)

        let capacityRequest = UsageHistoryLoadRequest(
            chartKind: .capacity,
            range: .month,
            window: .sevenDay,
            periodStart: month.start,
            periodEnd: month.end,
            now: fixture.now,
            calendar: calendar
        )
        let usageRequest = UsageHistoryLoadRequest(
            chartKind: .usage,
            range: .month,
            window: .sevenDay,
            periodStart: month.start,
            periodEnd: month.end,
            now: fixture.now,
            calendar: calendar
        )
        let tokenRequest = UsageHistoryLoadRequest(
            chartKind: .tokens,
            range: .month,
            window: .sevenDay,
            periodStart: month.start,
            periodEnd: month.end,
            now: fixture.now,
            calendar: calendar
        )
        let dashboardRequest = TokenDashboardLoadRequest(
            breakdownDimension: .model,
            range: .month,
            periodStart: month.start,
            periodEnd: month.end
        )

        let capacityDuration = try await elapsed {
            let result = try await worker.usageHistorySnapshot(for: capacityRequest)
            XCTAssertFalse(result.points.isEmpty)
            XCTAssertFalse(result.series.isEmpty)
        }
        XCTAssertLessThan(capacityDuration, 2.0)

        let usageDuration = try await elapsed {
            let result = try await worker.usageHistorySnapshot(for: usageRequest)
            XCTAssertFalse(result.points.isEmpty)
            XCTAssertFalse(result.series.isEmpty)
        }
        XCTAssertLessThan(usageDuration, 2.0)

        let tokenDuration = try await elapsed {
            let result = try await worker.usageHistorySnapshot(for: tokenRequest)
            XCTAssertFalse(result.tokenComponentBucketPoints.isEmpty)
            XCTAssertEqual(result.series.map(\.id), ["tokens_all"])
        }
        XCTAssertLessThan(tokenDuration, 2.0)

        let dashboardDuration = try await elapsed {
            let result = try await worker.tokenDashboardSnapshot(for: dashboardRequest)
            XCTAssertFalse(result.points.isEmpty)
            XCTAssertFalse(result.series.isEmpty)
        }
        XCTAssertLessThan(dashboardDuration, 2.0)
    }

    func testHoverIndexLookupStaysBoundedForLargeVisibleDatasets() throws {
        let start = date("2026-01-01T00:00:00Z")
        let buckets = (0..<2_000).map { offset -> UsageHistoryHoverBucket in
            let bucketStart = calendar.date(byAdding: .hour, value: offset, to: start)!
            let bucketEnd = calendar.date(byAdding: .hour, value: 1, to: bucketStart)!
            let point = UsageHistoryChartPoint(
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                sampleTimestamp: bucketStart,
                bucketID: "codex",
                bucketName: "All models",
                bucketKind: .aggregate,
                window: .sevenDay,
                latestUsedPercent: Double(offset % 100),
                peakUsedPercent: Double(offset % 100),
                consumedPercent: Double(offset % 7)
            )
            return UsageHistoryHoverBucket(
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                xDate: bucketStart,
                points: [point]
            )
        }
        let index = UsageHistoryHoverIndex(buckets: buckets)

        let nearTarget = calendar.date(byAdding: .hour, value: 1_234, to: start)!
            .addingTimeInterval(60 * 20)
        let selection = index.selection(nearestTo: nearTarget, xPosition: 42)
        XCTAssertEqual(selection?.bucketStart, calendar.date(byAdding: .hour, value: 1_234, to: start))

        let lookupDuration = elapsed {
            for offset in 0..<20_000 {
                let timestamp = calendar.date(byAdding: .minute, value: offset * 13, to: start)!
                _ = index.selection(nearestTo: timestamp, xPosition: 42)
            }
        }
        XCTAssertLessThan(lookupDuration, 1.0)
    }
}

private struct UsageHistoryPerformanceFixture {
    let store: UsageHistoryStore
    let databaseURL: URL
    let now: Date
}

private extension UsageHistoryStoreTests {
    func makePerformanceFixture() throws -> UsageHistoryPerformanceFixture {
        let directoryURL = try makeTemporaryDirectory()
        let databaseURL = directoryURL.appendingPathComponent("performance-usage-history.sqlite3")
        let now = date("2026-05-17T12:00:00Z")

        do {
            _ = try UsageHistoryStore(
                databaseURL: databaseURL,
                notificationCenter: NotificationCenter(),
                calendar: calendar
            )
        }

        try seedPerformanceFixture(at: databaseURL, now: now)

        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        return UsageHistoryPerformanceFixture(store: store, databaseURL: databaseURL, now: now)
    }

    func seedPerformanceFixture(at databaseURL: URL, now: Date) throws {
        let database = try SQLitePerformanceFixtureDatabase(url: databaseURL)
        defer { database.close() }

        try database.transaction {
            try seedUsageSamples(into: database, now: now)
            try seedUsageRollups(into: database, now: now)
            try seedTokenUsageSamples(into: database, now: now)
            try database.execute("DELETE FROM usage_history_metadata WHERE key = 'series_catalog_version'")
        }
    }

    func seedUsageSamples(into database: SQLitePerformanceFixtureDatabase, now: Date) throws {
        let insert = try database.prepare(
            """
            INSERT INTO usage_samples (
                bucket_id, bucket_name, bucket_kind, window, timestamp,
                used_percent, consumed_percent, reset_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(insert) }

        let buckets: [(id: String, name: String, kind: String, offset: Int)] = [
            ("codex", "All models", "aggregate", 0),
            ("codex_gpt54", "GPT-5.4", "model", 7),
            ("codex_gpt55", "GPT-5.5", "model", 13),
        ]
        let windows: [(value: UsageLimitWindow, resetOffset: TimeInterval, offset: Int)] = [
            (.fiveHour, 5 * 60 * 60, 3),
            (.sevenDay, 7 * 24 * 60 * 60, 11),
        ]
        let rawStart = calendar.date(byAdding: .day, value: -13, to: UsageHistoryRange.bucketStart(for: now, component: .day, calendar: calendar))!
        let sampleCount = 14 * 24 * 4

        for sampleIndex in 0..<sampleCount {
            let timestamp = rawStart.addingTimeInterval(TimeInterval(sampleIndex * 15 * 60))
            for window in windows {
                for bucket in buckets {
                    let usedPercent = (sampleIndex + bucket.offset + window.offset) % 100
                    try database.bindText(bucket.id, to: 1, in: insert)
                    try database.bindText(bucket.name, to: 2, in: insert)
                    try database.bindText(bucket.kind, to: 3, in: insert)
                    try database.bindText(window.value.rawValue, to: 4, in: insert)
                    sqlite3_bind_int64(insert, 5, timestamp.timeIntervalSince1970Int)
                    sqlite3_bind_int64(insert, 6, Int64(usedPercent))
                    sqlite3_bind_double(insert, 7, sampleIndex == 0 ? 0 : 1.25)
                    sqlite3_bind_int64(insert, 8, timestamp.addingTimeInterval(window.resetOffset).timeIntervalSince1970Int)
                    try database.stepDoneAndReset(insert)
                }
            }
        }
    }

    func seedUsageRollups(into database: SQLitePerformanceFixtureDatabase, now: Date) throws {
        let insert = try database.prepare(
            """
            INSERT INTO usage_rollups (
                granularity, bucket_id, bucket_name, bucket_kind, window,
                period_start, sample_timestamp, used_percent, peak_used_percent,
                consumed_percent, reset_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(insert) }

        let buckets: [(id: String, name: String, kind: String, offset: Int)] = [
            ("codex", "All models", "aggregate", 0),
            ("codex_gpt54", "GPT-5.4", "model", 7),
            ("codex_gpt55", "GPT-5.5", "model", 13),
        ]
        let windows: [(value: UsageLimitWindow, resetOffset: TimeInterval, offset: Int)] = [
            (.fiveHour, 5 * 60 * 60, 3),
            (.sevenDay, 7 * 24 * 60 * 60, 11),
        ]

        let hourlyStart = calendar.date(
            byAdding: .day,
            value: -119,
            to: UsageHistoryRange.bucketStart(for: now, component: .day, calendar: calendar)
        )!
        for hourIndex in 0..<(120 * 24) {
            let timestamp = hourlyStart.addingTimeInterval(TimeInterval(hourIndex * 60 * 60))
            for window in windows {
                for bucket in buckets {
                    let usedPercent = (hourIndex + bucket.offset + window.offset) % 100
                    try bindRollupRow(
                        insert,
                        database: database,
                        granularity: .hour,
                        bucket: bucket,
                        window: window.value,
                        timestamp: timestamp,
                        usedPercent: usedPercent,
                        consumedPercent: hourIndex == 0 ? 0 : 2.0,
                        resetAt: timestamp.addingTimeInterval(window.resetOffset)
                    )
                }
            }
        }

        let monthStart = calendar.dateInterval(of: .month, for: now)!.start
        let dailyStart = calendar.date(byAdding: .month, value: -17, to: monthStart)!
        var dayIndex = 0
        var timestamp = dailyStart
        while timestamp <= now {
            for window in windows {
                for bucket in buckets {
                    let usedPercent = (dayIndex + bucket.offset + window.offset) % 100
                    try bindRollupRow(
                        insert,
                        database: database,
                        granularity: .day,
                        bucket: bucket,
                        window: window.value,
                        timestamp: timestamp,
                        usedPercent: usedPercent,
                        consumedPercent: dayIndex == 0 ? 0 : 4.0,
                        resetAt: timestamp.addingTimeInterval(window.resetOffset)
                    )
                }
            }

            timestamp = calendar.date(byAdding: .day, value: 1, to: timestamp)!
            dayIndex += 1
        }
    }

    func bindRollupRow(
        _ statement: OpaquePointer,
        database: SQLitePerformanceFixtureDatabase,
        granularity: UsageHistoryGranularity,
        bucket: (id: String, name: String, kind: String, offset: Int),
        window: UsageLimitWindow,
        timestamp: Date,
        usedPercent: Int,
        consumedPercent: Double,
        resetAt: Date
    ) throws {
        try database.bindText(granularity.rawValue, to: 1, in: statement)
        try database.bindText(bucket.id, to: 2, in: statement)
        try database.bindText(bucket.name, to: 3, in: statement)
        try database.bindText(bucket.kind, to: 4, in: statement)
        try database.bindText(window.rawValue, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, timestamp.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 7, timestamp.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 8, Int64(usedPercent))
        sqlite3_bind_int64(statement, 9, Int64(min(100, usedPercent + 3)))
        sqlite3_bind_double(statement, 10, consumedPercent)
        sqlite3_bind_int64(statement, 11, resetAt.timeIntervalSince1970Int)
        try database.stepDoneAndReset(statement)
    }

    func seedTokenUsageSamples(into database: SQLitePerformanceFixtureDatabase, now: Date) throws {
        let insert = try database.prepare(
            """
            INSERT INTO token_usage_samples (
                thread_id, turn_id, model, received_at, model_context_window,
                last_input_tokens, last_cached_input_tokens, last_output_tokens,
                last_reasoning_output_tokens, last_total_tokens,
                total_input_tokens, total_cached_input_tokens, total_output_tokens,
                total_reasoning_output_tokens, total_total_tokens,
                observed_input_tokens, observed_cached_input_tokens, observed_output_tokens,
                observed_reasoning_output_tokens, observed_total_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(insert) }

        let tokenStart = calendar.date(
            byAdding: .day,
            value: -119,
            to: UsageHistoryRange.bucketStart(for: now, component: .day, calendar: calendar)
        )!
        let models: [String?] = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.5", nil]

        for dayIndex in 0..<120 {
            for slotIndex in 0..<6 {
                for (modelIndex, model) in models.enumerated() {
                    let timestamp = tokenStart
                        .addingTimeInterval(TimeInterval(dayIndex * 24 * 60 * 60))
                        .addingTimeInterval(TimeInterval(slotIndex * 4 * 60 * 60))
                        .addingTimeInterval(TimeInterval(modelIndex * 60))
                    let input = Int64(1_000 + dayIndex * 10 + slotIndex * 30 + modelIndex * 100)
                    let cached = Int64(800 + dayIndex * 7 + slotIndex * 20 + modelIndex * 70)
                    let output = Int64(100 + slotIndex * 5 + modelIndex * 10)
                    let reasoning = Int64(50 + slotIndex * 3 + modelIndex * 5)
                    let total = input + cached + output + reasoning
                    let modelKey = model ?? "unattributed"

                    try database.bindText("thread-\(modelKey)-\(dayIndex)-\(slotIndex)", to: 1, in: insert)
                    try database.bindText("turn-\(dayIndex)-\(slotIndex)-\(modelIndex)", to: 2, in: insert)
                    if let model {
                        try database.bindText(model, to: 3, in: insert)
                    } else {
                        sqlite3_bind_null(insert, 3)
                    }
                    sqlite3_bind_int64(insert, 4, timestamp.timeIntervalSince1970Int)
                    sqlite3_bind_int64(insert, 5, 200_000)
                    sqlite3_bind_int64(insert, 6, input)
                    sqlite3_bind_int64(insert, 7, cached)
                    sqlite3_bind_int64(insert, 8, output)
                    sqlite3_bind_int64(insert, 9, reasoning)
                    sqlite3_bind_int64(insert, 10, total)
                    sqlite3_bind_int64(insert, 11, input)
                    sqlite3_bind_int64(insert, 12, cached)
                    sqlite3_bind_int64(insert, 13, output)
                    sqlite3_bind_int64(insert, 14, reasoning)
                    sqlite3_bind_int64(insert, 15, total)
                    sqlite3_bind_int64(insert, 16, input)
                    sqlite3_bind_int64(insert, 17, cached)
                    sqlite3_bind_int64(insert, 18, output)
                    sqlite3_bind_int64(insert, 19, reasoning)
                    sqlite3_bind_int64(insert, 20, total)
                    try database.stepDoneAndReset(insert)
                }
            }
        }
    }

    func queryPlan(at databaseURL: URL, sql: String) throws -> [String] {
        let database = try SQLitePerformanceFixtureDatabase(url: databaseURL, readOnly: true)
        defer { database.close() }
        let statement = try database.prepare("EXPLAIN QUERY PLAN \(sql)")
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(String(cString: sqlite3_column_text(statement, 3)))
            case SQLITE_DONE:
                return rows
            default:
                throw SQLitePerformanceFixtureError.operationFailed(database.lastErrorMessage)
            }
        }
    }

    func XCTAssertPlanUsesSearch(
        _ plan: [String],
        table: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertPlanUsesSearch(plan, tableOrAlias: table, fullScanTable: table, file: file, line: line)
    }

    func XCTAssertPlanUsesSearch(
        _ plan: [String],
        tableOrAlias: String,
        fullScanTable: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let combined = plan.joined(separator: "\n")
        XCTAssertTrue(
            plan.contains { $0.contains("SEARCH \(tableOrAlias)") },
            "Expected indexed SEARCH of \(tableOrAlias), got:\n\(combined)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            plan.contains { $0.contains("SCAN \(fullScanTable)") },
            "Expected no full SCAN of \(fullScanTable), got:\n\(combined)",
            file: file,
            line: line
        )
    }

    func XCTAssertPlanMentions(
        _ plan: [String],
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            plan.contains { $0.contains(text) },
            "Expected query plan to mention \(text), got:\n\(plan.joined(separator: "\n"))",
            file: file,
            line: line
        )
    }

    func XCTAssertPlanDoesNotMention(
        _ plan: [String],
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            plan.contains { $0.contains(text) },
            "Expected query plan not to mention \(text), got:\n\(plan.joined(separator: "\n"))",
            file: file,
            line: line
        )
    }

    func elapsed(_ work: () throws -> Void) rethrows -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        try work()
        return CFAbsoluteTimeGetCurrent() - start
    }

    func elapsed(_ work: () async throws -> Void) async rethrows -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        try await work()
        return CFAbsoluteTimeGetCurrent() - start
    }
}

private final class SQLitePerformanceFixtureDatabase {
    private var database: OpaquePointer?

    var lastErrorMessage: String {
        database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
    }

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, database != nil else {
            throw SQLitePerformanceFixtureError.openFailed(lastErrorMessage)
        }
    }

    func close() {
        if let database {
            sqlite3_close(database)
        }
        database = nil
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLitePerformanceFixtureError.operationFailed(lastErrorMessage)
        }
        return statement
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLitePerformanceFixtureError.operationFailed(message)
        }
    }

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func bindText(_ text: String, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw SQLitePerformanceFixtureError.operationFailed(lastErrorMessage)
        }
    }

    func stepDoneAndReset(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLitePerformanceFixtureError.operationFailed(lastErrorMessage)
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }
}

private enum SQLitePerformanceFixtureError: Error {
    case openFailed(String)
    case operationFailed(String)
}
