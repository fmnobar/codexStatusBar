import CoreGraphics
import SQLite3
import XCTest
@testable import CodexUsageCore

extension UsageHistoryStoreTests {
    func testBusyTimeoutLetsWriterResumeAfterShortExternalLock() async throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        var lockingDatabase: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &lockingDatabase, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil),
            SQLITE_OK
        )
        let database = try XCTUnwrap(lockingDatabase)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let notification = tokenNotification(
            threadID: "locked-thread",
            turnID: "locked-turn",
            lastTotal: 100,
            totalTotal: 100
        )
        let timestamp = date("2026-05-17T12:00:00Z")

        let write = Task.detached {
            try store.record(tokenUsage: notification, at: timestamp)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sqlite3_exec(database, "COMMIT", nil, nil, nil), SQLITE_OK)
        try await write.value

        XCTAssertEqual(try store.tokenUsageSamples().count, 1)
    }

    func testGitOriginMigrationSanitizesPreviouslyPersistedSecretsAndLocalPaths() async throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        let conflictOversizedValues = Array(1_000..<1_300)
        let conflictOversizedCSV = conflictOversizedValues.map(String.init).joined(separator: ",") + ","
        let conflictOversizedTotal = conflictOversizedValues.reduce(0, +)
        let noConflictOversizedValues = Array(2_000..<2_300)
        let noConflictOversizedCSV = noConflictOversizedValues.map(String.init).joined(separator: ",") + ","
        let noConflictOversizedTotal = noConflictOversizedValues.reduce(0, +)
        do {
            let store = try UsageHistoryStore(
                databaseURL: databaseURL,
                notificationCenter: NotificationCenter(),
                calendar: calendar
            )
            XCTAssertEqual(store.databaseURL, databaseURL)
        }
        try executeSQLite(
            at: databaseURL,
            sql: """
            INSERT INTO codex_thread_catalog (
                thread_id, git_origin_url, cli_version, agent_role, recorded_at
            )
            VALUES
                (
                    'secret-remote',
                    'https://user:github_pat_secret@github.com/example/app.git?token=secret#fragment',
                    'private_cli@example.com', 'acct_agent_role_789', 1
                ),
                ('local-remote', 'file:///Users/example/private/app.git', '0.78.0', 'explorer', 1);
            INSERT INTO token_usage_dimensions (
                thread_id, turn_id, total_total_tokens, dimension_key, dimension_value, seen_at
            ) VALUES
                ('secret-remote', 'turn', 1, 'cli_version', 'private_cli@example.com', 1),
                ('secret-remote', 'turn', 1, 'agent_role', 'acct_agent_role_789', 1);
            INSERT INTO token_dimension_catalog (
                dimension_key, dimension_value, first_seen_at, last_seen_at
            ) VALUES
                ('cli_version', 'private_cli@example.com', 1, 1),
                ('agent_role', 'acct_agent_role_789', 1, 1);
            INSERT INTO token_usage_samples (
                thread_id, turn_id, session_id, effort, source, received_at,
                last_input_tokens, last_cached_input_tokens, last_output_tokens,
                last_reasoning_output_tokens, last_total_tokens, total_input_tokens,
                total_cached_input_tokens, total_output_tokens, total_reasoning_output_tokens,
                total_total_tokens, observed_total_tokens
            ) VALUES (
                'secret-context', 'turn', 'acct_session_context_123',
                'private_effort@example.com', 'acct_source_context_456', 1,
                1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1
            );
            INSERT INTO token_effort_catalog (effort, first_seen_at, last_seen_at)
            VALUES ('private_effort@example.com', 1, 1);
            INSERT INTO token_source_catalog (source, first_seen_at, last_seen_at)
            VALUES ('acct_source_context_456', 1, 1);
            INSERT INTO token_usage_hourly_rollups (
                period_start, effort, source, observed_total_tokens, sample_count
            ) VALUES
                (1, '', '', 10, 1),
                (1, 'private_effort@example.com', 'acct_source_context_456', 20, 2);
            INSERT INTO token_dimension_hourly_rollups (
                period_start, dimension_key, dimension_value, observed_total_tokens, sample_count
            ) VALUES
                (1, 'agent_role', '', 30, 3),
                (1, 'agent_role', 'acct_agent_role_789', 40, 4);
            INSERT INTO telemetry_hourly_rollups (
                metric, period_start, effort, source, transport, wire_api,
                sample_count, success_count, failure_count, duration_sample_count,
                duration_total_ms, first_token_sample_count, first_token_total_ms,
                completed_count, incomplete_count, duration_values, first_token_values
            ) VALUES
                ('session_timing', 1, '', '', '', '', 2, 1, 0, 0, 0, 1, 5, 2, 0, NULL, '5,'),
                ('session_timing', 1, 'private_effort@example.com', 'acct_source_context_456',
                    'acct_transport_1234', 'private_wire@example.com',
                    3, 0, 2, 300, \(conflictOversizedTotal), 1, 15, 0, 3,
                    '\(conflictOversizedCSV)', '15,'),
                ('turn_performance', 2, 'private_effort@example.com', 'acct_source_context_456',
                    'acct_transport_1234', 'private_wire@example.com',
                    300, 300, 0, 300, \(noConflictOversizedTotal), 0, 0, 0, 0,
                    '\(noConflictOversizedCSV)', NULL);
            INSERT INTO telemetry_error_hourly_rollups (
                period_start, effort, source, transport, wire_api, error_summary, event_count
            ) VALUES
                (1, '', '', '', '', '', 2),
                (1, 'private_effort@example.com', 'acct_source_context_456',
                    'acct_transport_1234', 'private_wire@example.com', 'acct_error_1234', 3);
            PRAGMA user_version = 1;
            """
        )

        let migratedStore = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let threads = try migratedStore.codexThreadCatalogThreads()

        XCTAssertEqual(
            threads.first { $0.threadID == "secret-remote" }?.gitOriginURL,
            "https://github.com/example/app.git"
        )
        XCTAssertNil(threads.first { $0.threadID == "local-remote" }?.gitOriginURL)
        XCTAssertNil(threads.first { $0.threadID == "secret-remote" }?.cliVersion)
        XCTAssertNil(threads.first { $0.threadID == "secret-remote" }?.agentRole)
        XCTAssertEqual(threads.first { $0.threadID == "local-remote" }?.cliVersion, "0.78.0")
        XCTAssertEqual(threads.first { $0.threadID == "local-remote" }?.agentRole, "explorer")
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "SELECT COUNT(*) FROM token_usage_dimensions"),
            ["0"]
        )
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "SELECT COUNT(*) FROM token_dimension_catalog"),
            ["0"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: """
                SELECT COUNT(*) FROM token_usage_samples
                WHERE session_id IS NOT NULL OR effort IS NOT NULL OR source IS NOT NULL
                """
            ),
            ["0"]
        )
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "SELECT COUNT(*) FROM token_effort_catalog"),
            ["0"]
        )
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "SELECT COUNT(*) FROM token_source_catalog"),
            ["0"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT effort || '|' || source || '|' || observed_total_tokens || '|' || sample_count FROM token_usage_hourly_rollups"
            ),
            ["||30|3"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT dimension_value || '|' || observed_total_tokens || '|' || sample_count FROM token_dimension_hourly_rollups"
            ),
            ["|70|7"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: """
                SELECT effort || '|' || source || '|' || transport || '|' || wire_api || '|' ||
                    sample_count || '|' || success_count || '|' || failure_count || '|' ||
                    duration_sample_count || '|' || duration_total_ms || '|' ||
                    first_token_sample_count || '|' || first_token_total_ms || '|' ||
                    completed_count || '|' || incomplete_count || '|' || first_token_values
                FROM telemetry_hourly_rollups
                WHERE metric = 'session_timing'
                """
            ),
            ["||||5|1|2|300|\(conflictOversizedTotal)|2|20|2|3|5,15,"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: """
                SELECT CAST((LENGTH(duration_values) - LENGTH(REPLACE(duration_values, ',', ''))) <= 192 AS TEXT) || '|' ||
                    CAST(LENGTH(CAST(duration_values AS BLOB)) <= 4096 AS TEXT) || '|' ||
                    CAST(duration_values LIKE '1000,%' AS TEXT) || '|' ||
                    CAST(duration_values LIKE '%1299,' AS TEXT)
                FROM telemetry_hourly_rollups WHERE metric = 'session_timing'
                """
            ),
            ["1|1|1|1"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: """
                SELECT effort || '|' || source || '|' || transport || '|' || wire_api || '|' ||
                    sample_count || '|' || duration_sample_count || '|' || duration_total_ms
                FROM telemetry_hourly_rollups WHERE metric = 'turn_performance'
                """
            ),
            ["||||300|300|\(noConflictOversizedTotal)"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: """
                SELECT CAST((LENGTH(duration_values) - LENGTH(REPLACE(duration_values, ',', ''))) <= 192 AS TEXT) || '|' ||
                    CAST(LENGTH(CAST(duration_values AS BLOB)) <= 4096 AS TEXT) || '|' ||
                    CAST(duration_values LIKE '2000,%' AS TEXT) || '|' ||
                    CAST(duration_values LIKE '%2299,' AS TEXT)
                FROM telemetry_hourly_rollups WHERE metric = 'turn_performance'
                """
            ),
            ["1|1|1|1"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT effort || '|' || source || '|' || transport || '|' || wire_api || '|' || error_summary || '|' || event_count FROM telemetry_error_hourly_rollups"
            ),
            ["|||||5"]
        )
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "PRAGMA user_version"),
            [String(UsageHistoryStore.currentSchemaVersion)]
        )
    }

    func testNumberedMigrationRollsBackAndRecoversAfterInterruption() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let databaseURL = directoryURL.appendingPathComponent("usage-history.sqlite3")
        do {
            let seedStore = try UsageHistoryStore(
                databaseURL: databaseURL,
                notificationCenter: NotificationCenter(),
                calendar: calendar
            )
            XCTAssertEqual(seedStore.databaseURL, databaseURL)
        }
        try executeSQLite(
            at: databaseURL,
            sql: """
            DROP VIEW IF EXISTS token_usage_query_samples;
            DROP VIEW IF EXISTS token_usage_dimension_query_values;
            DROP VIEW IF EXISTS token_dimension_query_rollups;
            DROP VIEW IF EXISTS telemetry_query_rollups;
            DROP VIEW IF EXISTS telemetry_error_query_rollups;
            DROP INDEX IF EXISTS idx_token_usage_samples_dimension_set;
            DROP TABLE IF EXISTS token_dimension_set_members;
            DROP TABLE IF EXISTS token_dimension_sets;
            DROP TABLE IF EXISTS token_dimension_values;
            DROP TABLE IF EXISTS token_usage_daily_rollups;
            DROP TABLE IF EXISTS token_dimension_daily_rollups;
            DROP TABLE IF EXISTS telemetry_daily_rollups;
            DROP TABLE IF EXISTS telemetry_error_daily_rollups;
            DROP TABLE IF EXISTS storage_maintenance_journal;
            DROP TABLE IF EXISTS token_expired_baselines;
            DROP TABLE token_dimension_hourly_rollups;
            DROP TABLE token_usage_hourly_rollups;
            DROP TABLE telemetry_error_hourly_rollups;
            DROP TABLE telemetry_hourly_rollups;
            ALTER TABLE token_usage_samples DROP COLUMN is_retention_baseline;
            ALTER TABLE codex_session_token_imports DROP COLUMN tail_state_json;
            ALTER TABLE codex_session_token_imports DROP COLUMN file_prefix_hash;
            ALTER TABLE codex_session_token_imports DROP COLUMN next_line_number;
            ALTER TABLE codex_session_token_imports DROP COLUMN byte_offset;
            ALTER TABLE codex_session_task_timing_import_files DROP COLUMN tail_state_json;
            ALTER TABLE codex_session_task_timing_import_files DROP COLUMN file_prefix_hash;
            ALTER TABLE codex_session_task_timing_import_files DROP COLUMN next_line_number;
            ALTER TABLE codex_session_task_timing_import_files DROP COLUMN byte_offset;
            PRAGMA user_version = 1;
            CREATE VIEW token_dimension_hourly_rollups AS SELECT 1 AS value;
            """
        )

        XCTAssertThrowsError(
            try UsageHistoryStore(
                databaseURL: databaseURL,
                notificationCenter: NotificationCenter(),
                calendar: calendar
            )
        )
        XCTAssertEqual(try sqliteStrings(at: databaseURL, sql: "PRAGMA user_version"), ["1"])
        XCTAssertFalse(
            try sqliteStrings(at: databaseURL, sql: "SELECT name FROM pragma_table_info('token_usage_samples')")
                .contains("is_retention_baseline")
        )
        XCTAssertFalse(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT name FROM pragma_table_info('codex_session_task_timing_import_files')"
            )
            .contains("byte_offset")
        )

        try executeSQLite(at: databaseURL, sql: "DROP VIEW token_dimension_hourly_rollups;")
        let recoveredStore = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )

        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "PRAGMA user_version"),
            [String(UsageHistoryStore.currentSchemaVersion)]
        )
        XCTAssertEqual(try recoveredStore.busyTimeoutMilliseconds(), UsageHistoryStore.defaultBusyTimeoutMilliseconds)
        XCTAssertTrue(
            try sqliteStrings(at: databaseURL, sql: "SELECT name FROM pragma_table_info('token_usage_samples')")
                .contains("is_retention_baseline")
        )
        XCTAssertEqual(
            Set(try sqliteStrings(
                at: databaseURL,
                sql: "SELECT name FROM pragma_table_info('codex_session_task_timing_import_files')"
            )).intersection(["byte_offset", "next_line_number", "file_prefix_hash", "tail_state_json"]),
            Set(["byte_offset", "next_line_number", "file_prefix_hash", "tail_state_json"])
        )
    }

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
        let (store, databaseURL) = try makeTemporaryStore()

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
        XCTAssertTrue(tables.contains("token_usage_hourly_rollups"))
        XCTAssertTrue(tables.contains("token_dimension_hourly_rollups"))
        XCTAssertTrue(tables.contains("telemetry_hourly_rollups"))
        XCTAssertTrue(tables.contains("telemetry_error_hourly_rollups"))
        XCTAssertTrue(tables.contains("token_dimension_values"))
        XCTAssertTrue(tables.contains("token_dimension_sets"))
        XCTAssertTrue(tables.contains("token_dimension_set_members"))
        XCTAssertTrue(tables.contains("token_usage_daily_rollups"))
        XCTAssertTrue(tables.contains("token_dimension_daily_rollups"))
        XCTAssertTrue(tables.contains("telemetry_daily_rollups"))
        XCTAssertTrue(tables.contains("telemetry_error_daily_rollups"))
        XCTAssertTrue(tables.contains("storage_maintenance_journal"))
        XCTAssertEqual(
            Set(try sqliteStrings(
                at: databaseURL,
                sql: "SELECT name FROM pragma_table_info('codex_session_task_timing_import_files')"
            )).intersection(["byte_offset", "next_line_number", "file_prefix_hash", "tail_state_json"]),
            Set(["byte_offset", "next_line_number", "file_prefix_hash", "tail_state_json"])
        )
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
        XCTAssertFalse(indexes.contains("idx_token_usage_dimensions_sample"))
        XCTAssertTrue(indexes.contains("idx_token_usage_dimensions_key_value_seen"))
        XCTAssertTrue(indexes.contains("idx_token_dimension_catalog_key_seen"))
        XCTAssertFalse(indexes.contains("idx_codex_turn_performance_dimensions_event"))
        XCTAssertFalse(indexes.contains("idx_token_usage_hourly_rollups_period"))
        XCTAssertFalse(indexes.contains("idx_telemetry_hourly_rollups_metric_period"))
        XCTAssertFalse(indexes.contains("idx_telemetry_error_hourly_rollups_period"))
        XCTAssertTrue(indexes.contains("idx_token_dimension_hourly_rollups_key_period"))
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
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "PRAGMA user_version"),
            [String(UsageHistoryStore.currentSchemaVersion)]
        )
        XCTAssertEqual(try store.busyTimeoutMilliseconds(), UsageHistoryStore.defaultBusyTimeoutMilliseconds)
        XCTAssertTrue(
            try sqliteQueryPlanDetails(
                at: databaseURL,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT observed_total_tokens
                FROM token_usage_hourly_rollups
                WHERE period_start >= 1 AND period_start < 2
                """
            )
            .joined(separator: "\n")
            .contains("sqlite_autoindex_token_usage_hourly_rollups_1")
        )
        XCTAssertTrue(
            try sqliteQueryPlanDetails(
                at: databaseURL,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT sample_count
                FROM telemetry_hourly_rollups
                WHERE metric = 'session_timing' AND period_start >= 1 AND period_start < 2
                """
            )
            .joined(separator: "\n")
            .contains("sqlite_autoindex_telemetry_hourly_rollups_1")
        )
        XCTAssertTrue(
            try sqliteQueryPlanDetails(
                at: databaseURL,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT dimension_value
                FROM token_usage_dimensions
                WHERE thread_id = 'thread' AND turn_id = 'turn' AND total_total_tokens = 1
                """
            )
            .joined(separator: "\n")
            .contains("sqlite_autoindex_token_usage_dimensions_1")
        )
        XCTAssertTrue(
            try sqliteQueryPlanDetails(
                at: databaseURL,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT dimension_value
                FROM codex_turn_performance_dimensions
                WHERE source_key = 'source' AND source_row_id = 1
                """
            )
            .joined(separator: "\n")
            .contains("sqlite_autoindex_codex_turn_performance_dimensions_1")
        )
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
        do {
            let seedStore = try UsageHistoryStore(
                databaseURL: databaseURL,
                notificationCenter: NotificationCenter(),
                calendar: calendar
            )
            XCTAssertEqual(seedStore.databaseURL, databaseURL)
        }
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
