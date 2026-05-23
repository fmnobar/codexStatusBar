import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testMigratesExistingDatabaseForTokenUsageSamples() async throws {
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

    func testMigrationCreatesSeriesCatalogsAndTargetedIndexes() async throws {
        let (_, databaseURL) = try makeTemporaryStore()

        let tables = try sqliteStrings(
            at: databaseURL,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        )
        let indexes = try sqliteStrings(
            at: databaseURL,
            sql: "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name"
        )

        XCTAssertTrue(tables.contains("usage_series_catalog"))
        XCTAssertTrue(tables.contains("token_series_catalog"))
        XCTAssertTrue(tables.contains("token_project_catalog"))
        XCTAssertTrue(tables.contains("token_effort_catalog"))
        XCTAssertTrue(tables.contains("token_source_catalog"))
        XCTAssertTrue(tables.contains("token_usage_dimensions"))
        XCTAssertTrue(tables.contains("token_dimension_catalog"))
        XCTAssertTrue(tables.contains("codex_session_task_timing_events"))
        XCTAssertTrue(tables.contains("codex_session_task_timing_import_files"))
        XCTAssertTrue(tables.contains("codex_session_task_timing_capture_state"))
        XCTAssertTrue(
            try sqliteStrings(at: databaseURL, sql: "SELECT name FROM pragma_table_info('token_project_catalog')")
                .contains("display_name")
        )
        XCTAssertTrue(indexes.contains("idx_usage_samples_window_bucket_timestamp"))
        XCTAssertTrue(indexes.contains("idx_usage_rollups_window_bucket_sample_timestamp"))
        XCTAssertTrue(indexes.contains("idx_token_usage_samples_model_received_at"))
        XCTAssertTrue(indexes.contains("idx_token_usage_samples_project_received_at"))
        XCTAssertTrue(indexes.contains("idx_token_usage_samples_effort_received_at"))
        XCTAssertTrue(indexes.contains("idx_token_usage_samples_observed_components_received_at"))
        XCTAssertTrue(indexes.contains("idx_token_usage_dimensions_sample"))
        XCTAssertTrue(indexes.contains("idx_token_usage_dimensions_key_value_seen"))
        XCTAssertTrue(indexes.contains("idx_token_dimension_catalog_key_seen"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_started_at"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_completed_at"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_project_started"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_effort_started"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_duration"))
    }

    func testTokenModelCleanupMigrationRepairsStoredRowsAndCatalogs() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let databaseURL = directoryURL.appendingPathComponent("usage-history.sqlite3")
        var seedStore: UsageHistoryStore? = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        seedStore = nil
        try insertMalformedTokenModelRows(into: databaseURL)
        try executeSQLite(
            at: databaseURL,
            sql: "DELETE FROM usage_history_metadata WHERE key = 'token_model_cleanup_version';"
        )

        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let samples = try store.tokenUsageSamples()
        let dashboardSeries = try store.tokenDashboardSeries()

        XCTAssertEqual(samples.map(\.model), ["gpt-5.5", "gpt-5.5", nil])
        XCTAssertEqual(samples.map(\.observedTotalTokens), [100, 20, 5])
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 125)
        XCTAssertEqual(dashboardSeries.map(\.id), ["tokens_all", "model:gpt-5.5", "tokens_unattributed"])
        XCTAssertEqual(dashboardSeries.map(\.name), ["All captured", "gpt-5.5", "Unattributed"])
    }

    func testTokenContextCleanupMigrationDropsTraceSuffixedProjectPaths() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let receivedAt = date("2026-04-14T20:00:00Z")

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-context-cleanup",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 100,
                    lastTotal: 100,
                    totalInput: 100,
                    totalTotal: 100
                ),
                receivedAt: receivedAt,
                context: TokenUsageContext(
                    projectPath: "/Users/example/Projects/context-cleanup",
                    effort: "xhigh",
                    source: "desktop"
                )
            ),
        ])
        try executeSQLite(
            at: databaseURL,
            sql: """
            UPDATE token_usage_samples
            SET project_path = '/Users/example/Projects/context-cleanup}:try_run_sampling_request{turn_id=abc}',
                project_name = 'context-cleanup}:try_run_sampling_request{turn_id=abc}'
            WHERE thread_id = 'thread-context-cleanup';
            DELETE FROM usage_history_metadata WHERE key = 'token_context_cleanup_version';
            """
        )

        let reopenedStore = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let sample = try XCTUnwrap(try reopenedStore.tokenUsageSamples().first)

        XCTAssertNil(sample.projectPath)
        XCTAssertNil(sample.projectName)
        XCTAssertEqual(sample.effort, "xhigh")
        XCTAssertEqual(sample.source, "desktop")
        XCTAssertEqual(try reopenedStore.tokenTotalForDay(containing: receivedAt, calendar: calendar), 100)
    }

    func testMigratesLegacyTokenTableWithoutObservedCategoryColumns() async throws {
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
        let componentBucketPoints = try store.tokenComponentBucketPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z"),
            now: date("2026-04-14T21:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(samples.first?.observedInputTokens, nil)
        XCTAssertNil(samples.first?.sessionID)
        XCTAssertNil(samples.first?.projectPath)
        XCTAssertNil(samples.first?.effort)
        XCTAssertEqual(inputPoints.map(\.tokenCount), [120])
        XCTAssertTrue(componentBucketPoints.isEmpty)
        XCTAssertEqual(try store.availableTokenSeries(category: .total).map(\.id), ["tokens_all"])
        XCTAssertEqual(try store.availableTokenComponentSeries(), [])
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 200)
        XCTAssertNil(try store.tokenCategoryTotalsForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar))
    }

}
