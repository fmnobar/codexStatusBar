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
        XCTAssertTrue(tables.contains("codex_turn_performance_dimensions"))
        XCTAssertTrue(tables.contains("codex_turn_performance_dimension_catalog"))
        XCTAssertTrue(tables.contains("codex_thread_catalog"))
        XCTAssertTrue(tables.contains("codex_thread_spawn_edges"))
        XCTAssertTrue(tables.contains("codex_thread_dynamic_tools"))
        XCTAssertTrue(tables.contains("codex_thread_catalog_capture_state"))
        XCTAssertTrue(tables.contains("codex_model_capabilities"))
        XCTAssertTrue(tables.contains("codex_model_capability_reasoning_levels"))
        XCTAssertTrue(tables.contains("codex_model_capability_service_tiers"))
        XCTAssertTrue(tables.contains("codex_model_capability_speed_tiers"))
        XCTAssertTrue(tables.contains("codex_model_capability_input_modalities"))
        XCTAssertTrue(tables.contains("codex_model_capability_tools"))
        XCTAssertTrue(tables.contains("codex_model_capabilities_capture_state"))
        XCTAssertTrue(
            try sqliteStrings(at: databaseURL, sql: "SELECT name FROM pragma_table_info('token_project_catalog')")
                .contains("display_name")
        )
        XCTAssertTrue(indexes.contains("idx_usage_samples_window_bucket_timestamp"))
        XCTAssertTrue(indexes.contains("idx_usage_samples_timestamp"))
        XCTAssertTrue(indexes.contains("idx_usage_rollups_window_bucket_sample_timestamp"))
        XCTAssertTrue(indexes.contains("idx_token_usage_samples_model_received_at"))
        XCTAssertTrue(indexes.contains("idx_token_usage_samples_project_received_at"))
        XCTAssertTrue(indexes.contains("idx_token_usage_samples_effort_received_at"))
        XCTAssertTrue(indexes.contains("idx_token_usage_samples_observed_components_received_at"))
        XCTAssertTrue(indexes.contains("idx_token_usage_dimensions_sample"))
        XCTAssertTrue(indexes.contains("idx_token_usage_dimensions_key_value_seen"))
        XCTAssertTrue(indexes.contains("idx_token_dimension_catalog_key_seen"))
        XCTAssertTrue(indexes.contains("idx_codex_turn_performance_dimensions_event"))
        XCTAssertTrue(indexes.contains("idx_codex_turn_performance_dimensions_key_value_seen"))
        XCTAssertTrue(indexes.contains("idx_codex_turn_performance_dimension_catalog_key_seen"))
        XCTAssertTrue(
            try sqliteQueryPlanDetails(
                at: databaseURL,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT dimension_value
                FROM codex_turn_performance_dimension_catalog INDEXED BY idx_codex_turn_performance_dimension_catalog_key_seen
                WHERE dimension_key = 'auth_mode'
                ORDER BY last_seen_at DESC
                """
            )
            .joined(separator: "\n")
            .contains("idx_codex_turn_performance_dimension_catalog_key_seen")
        )
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_started_at"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_completed_at"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_event_timestamp"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_project_started"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_effort_started"))
        XCTAssertTrue(indexes.contains("idx_codex_session_task_timing_duration"))
        XCTAssertTrue(indexes.contains("idx_codex_thread_catalog_updated"))
        XCTAssertTrue(indexes.contains("idx_codex_thread_catalog_project_updated"))
        XCTAssertTrue(indexes.contains("idx_codex_thread_spawn_edges_parent"))
        XCTAssertTrue(indexes.contains("idx_codex_thread_dynamic_tools_namespace_name"))
        XCTAssertTrue(indexes.contains("idx_codex_model_capabilities_priority"))
        XCTAssertTrue(indexes.contains("idx_codex_model_capabilities_visibility"))
        XCTAssertTrue(indexes.contains("idx_codex_model_capability_reasoning_effort"))
        XCTAssertTrue(indexes.contains("idx_codex_model_capability_tool_kind_value"))
    }

    func testSessionTaskTimingEventTimestampMigrationBackfillsExistingRows() async throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createLegacyHistoryDatabase(at: databaseURL)
        let started = date("2026-05-17T10:00:00Z").timeIntervalSince1970Int
        let completed = date("2026-05-17T10:00:05Z").timeIntervalSince1970Int
        let recorded = date("2026-05-17T10:00:10Z").timeIntervalSince1970Int

        try executeSQLite(
            at: databaseURL,
            sql: """
            CREATE TABLE codex_session_task_timing_events (
                session_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                source_path TEXT,
                started_at INTEGER,
                completed_at INTEGER,
                duration_ms INTEGER,
                time_to_first_token_ms INTEGER,
                model_context_window INTEGER,
                collaboration_mode_kind TEXT,
                model TEXT,
                project_path TEXT,
                project_name TEXT,
                effort TEXT,
                source TEXT,
                dimensions_json TEXT,
                recorded_at INTEGER NOT NULL,
                PRIMARY KEY (session_id, turn_id)
            );
            INSERT INTO codex_session_task_timing_events (
                session_id, turn_id, started_at, completed_at, recorded_at
            ) VALUES
                ('session-a', 'turn-a', \(started), \(completed), \(recorded)),
                ('session-b', 'turn-b', NULL, \(completed), \(recorded)),
                ('session-c', 'turn-c', NULL, NULL, \(recorded));
            """
        )

        _ = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )

        let rows = try sqliteStrings(
            at: databaseURL,
            sql: """
            SELECT session_id || ':' || event_timestamp
            FROM codex_session_task_timing_events
            ORDER BY session_id
            """
        )

        XCTAssertEqual(
            rows,
            [
                "session-a:\(started)",
                "session-b:\(completed)",
                "session-c:\(recorded)",
            ]
        )
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
        XCTAssertEqual(try store.availableTokenSeries(category: .total).map(\.id), [])
        XCTAssertEqual(try store.availableTokenComponentSeries(), [])
        XCTAssertNil(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar))
        XCTAssertNil(try store.tokenCategoryTotalsForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar))
    }

    private func sqliteQueryPlanDetails(at databaseURL: URL, sql: String) throws -> [String] {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let database else {
            XCTFail("Expected database to open")
            return []
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else {
            XCTFail("Expected statement to prepare")
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(String(cString: sqlite3_column_text(statement, 3)))
            case SQLITE_DONE:
                return rows
            default:
                XCTFail("Unexpected SQLite result \(sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown error")")
                return rows
            }
        }
    }

}
