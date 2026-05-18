import Foundation
import SQLite3

extension UsageHistoryStore {
    func csv(
        range: UsageHistoryRange,
        window: UsageLimitWindow,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> String {
        let points = try points(range: range, window: window, now: now, calendar: calendar)
        let formatter = ISO8601DateFormatter()
        var rows = ["timestamp,bucket_id,bucket_name,bucket_kind,window,used_percent"]

        rows += points.map { point in
            [
                formatter.string(from: point.timestamp),
                Self.csvEscaped(point.bucketID),
                Self.csvEscaped(point.bucketName),
                point.bucketKind.rawValue,
                point.window.rawValue,
                String(format: "%.3f", point.usedPercent),
            ].joined(separator: ",")
        }

        return rows.joined(separator: "\n") + "\n"
    }

    func clearHistory() throws {
        try transaction {
            try execute("DELETE FROM usage_samples")
            try execute("DELETE FROM usage_rollups")
            try execute("DELETE FROM token_usage_samples")
            try execute("DELETE FROM codex_session_token_imports")
            try execute("DELETE FROM usage_series_catalog")
            try execute("DELETE FROM token_series_catalog")
        }

        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    func hasAnyHistory() throws -> Bool {
        let statement = try prepare(
            """
            SELECT EXISTS(SELECT 1 FROM usage_samples LIMIT 1)
                OR EXISTS(SELECT 1 FROM usage_rollups LIMIT 1)
                OR EXISTS(SELECT 1 FROM token_usage_samples LIMIT 1)
            """
        )
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) != 0
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func databaseInfo(fileManager: FileManager = .default) throws -> UsageHistoryDatabaseInfo {
        guard let databaseURL else {
            throw UsageHistoryStoreError.databaseUnavailable
        }

        return UsageHistoryDatabaseInfo(
            databaseURL: databaseURL,
            totalByteSize: Self.totalByteSize(for: databaseURL, fileManager: fileManager)
        )
    }

    func exportBackup(to destinationURL: URL, fileManager: FileManager = .default) throws {
        guard let databaseURL else {
            throw UsageHistoryStoreError.databaseUnavailable
        }

        guard databaseURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw UsageHistoryStoreError.fileOperationFailed("Backup destination cannot be the active database.")
        }

        try checkpointWriteAheadLog()

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: databaseURL, to: destinationURL)
            try Self.normalizeBackupJournalMode(at: destinationURL)
        } catch {
            throw UsageHistoryStoreError.fileOperationFailed(error.localizedDescription)
        }
    }

    func importBackup(from sourceURL: URL) throws {
        guard let databaseURL else {
            throw UsageHistoryStoreError.databaseUnavailable
        }

        guard databaseURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            throw UsageHistoryStoreError.invalidBackup
        }

        try Self.validateBackup(at: sourceURL)
        try attachBackupDatabase(at: sourceURL)
        defer {
            try? detachBackupDatabase()
        }

        let importedPeakExpression = try tableHasColumn(
            table: "usage_rollups",
            column: "peak_used_percent",
            schema: "imported_usage_history"
        ) ? "IFNULL(peak_used_percent, used_percent)" : "used_percent"
        let importedSampleConsumedExpression = try tableHasColumn(
            table: "usage_samples",
            column: "consumed_percent",
            schema: "imported_usage_history"
        ) ? "consumed_percent" : "NULL"
        let importedRollupConsumedExpression = try tableHasColumn(
            table: "usage_rollups",
            column: "consumed_percent",
            schema: "imported_usage_history"
        ) ? "consumed_percent" : "NULL"
        let importedHasTokenUsageSamples = try tableExists(
            table: "token_usage_samples",
            schema: "imported_usage_history"
        )
        let importedObservedInputExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "observed_input_tokens",
            schema: "imported_usage_history"
        ) ? "observed_input_tokens" : "NULL"
        let importedObservedCachedExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "observed_cached_input_tokens",
            schema: "imported_usage_history"
        ) ? "observed_cached_input_tokens" : "NULL"
        let importedObservedOutputExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "observed_output_tokens",
            schema: "imported_usage_history"
        ) ? "observed_output_tokens" : "NULL"
        let importedObservedReasoningExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "observed_reasoning_output_tokens",
            schema: "imported_usage_history"
        ) ? "observed_reasoning_output_tokens" : "NULL"
        let importedHasSessionTokenImports = try tableExists(
            table: "codex_session_token_imports",
            schema: "imported_usage_history"
        )

        try transaction {
            try execute("DELETE FROM usage_samples")
            try execute("DELETE FROM usage_rollups")
            try execute("DELETE FROM token_usage_samples")
            try execute("DELETE FROM codex_session_token_imports")
            try execute("DELETE FROM usage_series_catalog")
            try execute("DELETE FROM token_series_catalog")
            try execute(
                """
                INSERT INTO usage_samples (
                    bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent,
                    consumed_percent, reset_at
                )
                SELECT bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent,
                    \(importedSampleConsumedExpression), reset_at
                FROM imported_usage_history.usage_samples
                """
            )
            try execute(
                """
                INSERT INTO usage_rollups (
                    granularity, bucket_id, bucket_name, bucket_kind, window, period_start,
                    sample_timestamp, used_percent, peak_used_percent, consumed_percent, reset_at
                )
                SELECT granularity, bucket_id, bucket_name, bucket_kind, window, period_start,
                    sample_timestamp, used_percent, \(importedPeakExpression),
                    \(importedRollupConsumedExpression), reset_at
                FROM imported_usage_history.usage_rollups
                """
            )
            if importedHasTokenUsageSamples {
                try execute(
                    """
                    INSERT INTO token_usage_samples (
                        thread_id, turn_id, model, received_at, model_context_window,
                        last_input_tokens, last_cached_input_tokens, last_output_tokens,
                        last_reasoning_output_tokens, last_total_tokens,
                        total_input_tokens, total_cached_input_tokens, total_output_tokens,
                        total_reasoning_output_tokens, total_total_tokens,
                        observed_input_tokens, observed_cached_input_tokens, observed_output_tokens,
                        observed_reasoning_output_tokens, observed_total_tokens
                    )
                    SELECT thread_id, turn_id, model, received_at, model_context_window,
                        last_input_tokens, last_cached_input_tokens, last_output_tokens,
                        last_reasoning_output_tokens, last_total_tokens,
                        total_input_tokens, total_cached_input_tokens, total_output_tokens,
                        total_reasoning_output_tokens, total_total_tokens,
                        \(importedObservedInputExpression), \(importedObservedCachedExpression),
                        \(importedObservedOutputExpression), \(importedObservedReasoningExpression),
                        observed_total_tokens
                    FROM imported_usage_history.token_usage_samples
                    """
                )
            }
            if importedHasSessionTokenImports {
                try execute(
                    """
                    INSERT INTO codex_session_token_imports (
                        file_path, file_size, modified_at, imported_at, status
                    )
                    SELECT file_path, file_size, modified_at, imported_at, status
                    FROM imported_usage_history.codex_session_token_imports
                    """
                )
            }
        }

        _ = try cleanupTokenModelLabels()
        try recomputeStoredUsageConsumption()
        try rebuildSeriesCatalogs()
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    static func applicationSupportDirectoryURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL.appendingPathComponent("CodexStatusBar", isDirectory: true)
    }

    func checkpointWriteAheadLog() throws {
        let result = sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard result == SQLITE_OK else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func attachBackupDatabase(at sourceURL: URL) throws {
        let statement = try prepare("ATTACH DATABASE ? AS imported_usage_history")
        defer { sqlite3_finalize(statement) }

        bindText(sourceURL.path, to: 1, in: statement)
        try step(statement)
    }

    func detachBackupDatabase() throws {
        try execute("DETACH DATABASE imported_usage_history")
    }


    static func totalByteSize(for databaseURL: URL, fileManager: FileManager) -> Int64 {
        databaseFileURLs(for: databaseURL).reduce(Int64(0)) { total, url in
            guard
                fileManager.fileExists(atPath: url.path),
                let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                let fileSize = attributes[.size] as? NSNumber
            else {
                return total
            }

            return total + fileSize.int64Value
        }
    }

    static func databaseFileURLs(for databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    static func validateBackup(at sourceURL: URL) throws {
        var backupDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(sourceURL.path, &backupDatabase, flags, nil) == SQLITE_OK, let backupDatabase else {
            if let backupDatabase {
                sqlite3_close(backupDatabase)
            }
            throw UsageHistoryStoreError.invalidBackup
        }
        defer { sqlite3_close(backupDatabase) }

        try validateBackupQuery(
            """
            SELECT bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent, reset_at
            FROM usage_samples
            LIMIT 1
            """,
            database: backupDatabase
        )
        try validateBackupQuery(
            """
            SELECT granularity, bucket_id, bucket_name, bucket_kind, window, period_start,
                sample_timestamp, used_percent, reset_at
            FROM usage_rollups
            LIMIT 1
            """,
            database: backupDatabase
        )

        if try backupTableExists("token_usage_samples", database: backupDatabase) {
            try validateBackupQuery(
                """
                SELECT thread_id, turn_id, model, received_at, model_context_window,
                    last_input_tokens, last_cached_input_tokens, last_output_tokens,
                    last_reasoning_output_tokens, last_total_tokens,
                    total_input_tokens, total_cached_input_tokens, total_output_tokens,
                    total_reasoning_output_tokens, total_total_tokens, observed_total_tokens
                FROM token_usage_samples
                LIMIT 1
                """,
                database: backupDatabase
            )
        }
    }

    static func backupTableExists(_ table: String, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.invalidBackup
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) != 0
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.invalidBackup
        }
    }

    static func validateBackupQuery(_ sql: String, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.invalidBackup
        }
        sqlite3_finalize(statement)
    }

    static func normalizeBackupJournalMode(at backupURL: URL) throws {
        var backupDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(backupURL.path, &backupDatabase, flags, nil) == SQLITE_OK, let backupDatabase else {
            if let backupDatabase {
                sqlite3_close(backupDatabase)
            }
            throw UsageHistoryStoreError.fileOperationFailed("Backup database could not be prepared.")
        }
        defer { sqlite3_close(backupDatabase) }

        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(backupDatabase, "PRAGMA journal_mode=DELETE", nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw UsageHistoryStoreError.fileOperationFailed(message)
        }
    }

    static func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        return value
    }
}
