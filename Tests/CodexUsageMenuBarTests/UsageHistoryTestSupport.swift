import Foundation
import SQLite3
import XCTest
@testable import CodexUsageCore

extension UsageHistoryStoreTests {
    func makeStore() throws -> UsageHistoryStore {
        try UsageHistoryStore.inMemory(notificationCenter: NotificationCenter(), calendar: calendar)
    }

    func makeTemporaryStore(
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

    func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL
    }

    func executeSQLite(at databaseURL: URL, sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let database else {
            XCTFail("Expected database to open")
            return
        }
        defer { sqlite3_close(database) }

        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            XCTFail(message)
        }
    }

    func sqliteStrings(at databaseURL: URL, sql: String) throws -> [String] {
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
                guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                      let text = sqlite3_column_text(statement, 0)
                else {
                    XCTFail("Expected the first SQLite result column to be non-NULL")
                    rows.append("<null>")
                    continue
                }
                rows.append(String(cString: text))
            case SQLITE_DONE:
                return rows
            default:
                XCTFail("Unexpected SQLite result \(sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown error")")
                return rows
            }
        }
    }

    func insertMalformedTokenModelRows(into databaseURL: URL) throws {
        let baseTimestamp = Int64(date("2026-04-14T20:00:00Z").timeIntervalSince1970)
        try executeSQLite(
            at: databaseURL,
            sql: """
            INSERT INTO token_usage_samples (
                thread_id, turn_id, model, received_at, model_context_window,
                last_input_tokens, last_cached_input_tokens, last_output_tokens,
                last_reasoning_output_tokens, last_total_tokens,
                total_input_tokens, total_cached_input_tokens, total_output_tokens,
                total_reasoning_output_tokens, total_total_tokens,
                observed_input_tokens, observed_cached_input_tokens, observed_output_tokens,
                observed_reasoning_output_tokens, observed_total_tokens
            ) VALUES
                (
                    'thread-clean', 'turn-a', 'gpt-5.5', \(baseTimestamp), NULL,
                    100, 0, 0, 0, 100,
                    100, 0, 0, 0, 100,
                    100, 0, 0, 0, 100
                ),
                (
                    'thread-malformed', 'turn-a', 'gpt-5.5
            Tests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:', \(baseTimestamp + 10), NULL,
                    20, 0, 0, 0, 20,
                    20, 0, 0, 0, 20,
                    20, 0, 0, 0, 20
                ),
                (
                    'thread-path', 'turn-a', '/Users/example/.codex/sessions/session.jsonl', \(baseTimestamp + 20), NULL,
                    5, 0, 0, 0, 5,
                    5, 0, 0, 0, 5,
                    5, 0, 0, 0, 5
                );

            INSERT OR REPLACE INTO token_series_catalog (
                series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            ) VALUES
                ('model:gpt-5.5
            Tests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:', 'gpt-5.5
            Tests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:', 'model', \(baseTimestamp + 10), 1, 1, 0, 0, 0);
            """
        )
    }

    func createLegacyHistoryDatabase(at databaseURL: URL) throws {
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

    func createInflatedConsumptionHistoryDatabase(
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

    func createLegacyTokenHistoryDatabase(at databaseURL: URL) throws {
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

    func createCodexLogsDatabase(at databaseURL: URL, rows: [(Date, String)]) throws {
        try createCodexLogsDatabase(
            at: databaseURL,
            rowsWithTargets: rows.map { ($0.0, "codex_otel.trace_safe", $0.1) }
        )
    }

    func createCodexLogsDatabase(at databaseURL: URL, rowsWithTargets rows: [(Date, String, String)]) throws {
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
                target TEXT NOT NULL,
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

        for (timestamp, target, body) in rows {
            let escapedTarget = target.replacingOccurrences(of: "'", with: "''")
            let escapedBody = body.replacingOccurrences(of: "'", with: "''")
            let sql = """
            INSERT INTO logs (ts, target, feedback_log_body)
            VALUES (\(Int64(timestamp.timeIntervalSince1970)), '\(escapedTarget)', '\(escapedBody)');
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

    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "CodexUsageMenuBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func usageSnapshot(
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

    func sparkUsageSnapshot(aggregateSevenDay: Int, sparkSevenDay: Int) -> CodexUsageSnapshot {
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

    func modelOnlyUsageSnapshot(modelSevenDay: Int) -> CodexUsageSnapshot {
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

    func rateLimitSnapshot(
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

    func tokenNotification(
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
        contextWindow: Int64? = nil,
        dimensions: [TokenUsageDimension] = []
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
            ),
            dimensions: dimensions
        )
    }

    func writeSessionLines(_ lines: [String], to url: URL) throws {
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func dashboardTokenCount(
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
    func waitForImportToFinish(_ viewModel: DataManagementSettingsViewModel, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isImportingTokenHistory && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func tokenCountLine(
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
        model: String? = nil,
        extraInfo: String = ""
    ) -> String {
        let contextWindowValue = contextWindow.map(String.init) ?? "null"
        let modelFragment = model.map { #","model":"\#($0)""# } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(lastInput),"cached_input_tokens":\(lastCached),"output_tokens":\(lastOutput),"reasoning_output_tokens":\(lastReasoning),"total_tokens":\(lastTotal)},"total_token_usage":{"input_tokens":\(totalInput),"cached_input_tokens":\(totalCached),"output_tokens":\(totalOutput),"reasoning_output_tokens":\(totalReasoning),"total_tokens":\(totalTotal)},"model_context_window":\(contextWindowValue)\(modelFragment)\(extraInfo)}}}
        """
    }

    func sessionMetaLine(
        timestamp: String,
        sessionID: String? = nil,
        cwd: String? = nil,
        source: String? = nil,
        extraPayload: String = ""
    ) -> String {
        let sessionIDFragment = sessionID.map { #","id":"\#($0)""# } ?? ""
        let cwdFragment = cwd.map { #","cwd":"\#($0)""# } ?? ""
        let sourceFragment = source.map { #","source":"\#($0)""# } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"session_meta","payload":{\(String([sessionIDFragment, cwdFragment, sourceFragment, extraPayload].joined().dropFirst()))}}
        """
    }

    func turnContextLine(
        timestamp: String,
        model: String,
        cwd: String? = nil,
        effort: String? = nil,
        source: String? = nil,
        extraPayload: String = ""
    ) -> String {
        let cwdFragment = cwd.map { #","cwd":"\#($0)""# } ?? ""
        let effortFragment = effort.map { #","effort":"\#($0)""# } ?? ""
        let sourceFragment = source.map { #","source":"\#($0)""# } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"\(model)"\(cwdFragment)\(effortFragment)\(sourceFragment),"sandbox_policy":{"type":"danger-full-access"}\(extraPayload)}}
        """
    }

    func taskStartedLine(
        timestamp: String,
        turnID: String,
        startedAt: String,
        modelContextWindow: Int64? = nil,
        collaborationModeKind: String? = nil,
        model: String? = nil,
        extraPayload: String = ""
    ) -> String {
        let contextWindowFragment = modelContextWindow.map { #","model_context_window":\#($0)"# } ?? ""
        let collaborationModeKindFragment = collaborationModeKind.map { #","collaboration_mode_kind":"\#($0)""# } ?? ""
        let modelFragment = model.map { #","model":"\#($0)""# } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"\(turnID)","started_at":\(Int64(date(startedAt).timeIntervalSince1970))\(contextWindowFragment)\(collaborationModeKindFragment)\(modelFragment)\(extraPayload)}}
        """
    }

    func taskCompleteLine(
        timestamp: String,
        turnID: String,
        completedAt: String,
        durationMilliseconds: Int64? = nil,
        timeToFirstTokenMilliseconds: Int64? = nil,
        extraPayload: String = ""
    ) -> String {
        let durationFragment = durationMilliseconds.map { #","duration_ms":\#($0)"# } ?? ""
        let firstTokenFragment = timeToFirstTokenMilliseconds.map { #","time_to_first_token_ms":\#($0)"# } ?? ""
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turnID)","completed_at":\(Int64(date(completedAt).timeIntervalSince1970))\(durationFragment)\(firstTokenFragment)\(extraPayload)}}
        """
    }

    func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}

final class StubTokenBackfillImporter: CodexSessionTokenBackfillImporting, @unchecked Sendable {
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
