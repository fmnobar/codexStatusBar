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
        let hasLegacyTokenDimensions = try tableExists(table: "token_usage_dimensions")
        try transaction {
            try execute("DELETE FROM usage_samples")
            try execute("DELETE FROM usage_rollups")
            try execute("DELETE FROM token_usage_samples")
            try execute("DELETE FROM token_usage_hourly_rollups")
            try execute("DELETE FROM token_usage_daily_rollups")
            try execute("DELETE FROM token_dimension_hourly_rollups")
            try execute("DELETE FROM token_dimension_daily_rollups")
            if hasLegacyTokenDimensions {
                try execute("DELETE FROM token_usage_dimensions")
            }
            try execute("DELETE FROM token_dimension_set_members")
            try execute("DELETE FROM token_dimension_sets")
            try execute("DELETE FROM token_dimension_values")
            try execute("DELETE FROM token_expired_baselines")
            try execute("DELETE FROM codex_session_token_imports")
            try execute("DELETE FROM usage_series_catalog")
            try execute("DELETE FROM token_series_catalog")
            try execute("DELETE FROM token_project_catalog")
            try execute("DELETE FROM token_effort_catalog")
            try execute("DELETE FROM token_source_catalog")
            try execute("DELETE FROM token_dimension_catalog")
            try execute("DELETE FROM codex_live_token_capture_state")
            try execute("DELETE FROM codex_turn_performance_events")
            try execute("DELETE FROM codex_turn_performance_dimensions")
            try execute("DELETE FROM codex_turn_performance_dimension_catalog")
            try execute("DELETE FROM codex_turn_performance_capture_state")
            try execute("DELETE FROM codex_session_task_timing_events")
            try execute("DELETE FROM codex_session_task_timing_import_files")
            try execute("DELETE FROM codex_session_task_timing_capture_state")
            try execute("DELETE FROM telemetry_hourly_rollups")
            try execute("DELETE FROM telemetry_error_hourly_rollups")
            try execute("DELETE FROM telemetry_daily_rollups")
            try execute("DELETE FROM telemetry_error_daily_rollups")
            try execute("DELETE FROM codex_thread_catalog")
            try execute("DELETE FROM codex_thread_spawn_edges")
            try execute("DELETE FROM codex_thread_dynamic_tools")
            try execute("DELETE FROM codex_thread_catalog_capture_state")
            try execute("DELETE FROM codex_model_capability_reasoning_levels")
            try execute("DELETE FROM codex_model_capability_service_tiers")
            try execute("DELETE FROM codex_model_capability_speed_tiers")
            try execute("DELETE FROM codex_model_capability_input_modalities")
            try execute("DELETE FROM codex_model_capability_tools")
            try execute("DELETE FROM codex_model_capabilities")
            try execute("DELETE FROM codex_model_capabilities_capture_state")
        }

        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    /// Removes optional analytics while preserving rate-limit History, lightweight token totals,
    /// cumulative baselines, preferences, capture freshness, and independently managed archives.
    func clearAnalyticsData() throws {
        let hasLegacyTokenDimensions = try tableExists(table: "token_usage_dimensions")
        try transaction {
            try execute(
                """
                UPDATE token_usage_samples
                SET model = NULL,
                    session_id = NULL,
                    project_path = NULL,
                    project_name = NULL,
                    effort = NULL,
                    source = NULL,
                    model_context_window = NULL,
                    dimension_set_id = NULL
                """
            )
            if hasLegacyTokenDimensions {
                try execute("DELETE FROM token_usage_dimensions")
            }
            try execute("DELETE FROM token_dimension_set_members")
            try execute("DELETE FROM token_dimension_sets")
            try execute("DELETE FROM token_dimension_values")
            try collapseTokenRollupsToLightweight(table: "token_usage_hourly_rollups")
            try collapseTokenRollupsToLightweight(table: "token_usage_daily_rollups")
            try execute("DELETE FROM token_dimension_hourly_rollups")
            try execute("DELETE FROM token_dimension_daily_rollups")
            try execute("DELETE FROM token_project_catalog")
            try execute("DELETE FROM token_effort_catalog")
            try execute("DELETE FROM token_source_catalog")
            try execute("DELETE FROM token_dimension_catalog")
            try execute("DELETE FROM codex_turn_performance_dimensions")
            try execute("DELETE FROM codex_turn_performance_events")
            try execute("DELETE FROM codex_turn_performance_dimension_catalog")
            try execute("DELETE FROM codex_turn_performance_capture_state")
            try execute("DELETE FROM codex_session_task_timing_events")
            try execute("DELETE FROM codex_session_task_timing_import_files")
            try execute("DELETE FROM codex_session_task_timing_capture_state")
            try execute("DELETE FROM telemetry_hourly_rollups")
            try execute("DELETE FROM telemetry_error_hourly_rollups")
            try execute("DELETE FROM telemetry_daily_rollups")
            try execute("DELETE FROM telemetry_error_daily_rollups")
            try execute("DELETE FROM codex_thread_spawn_edges")
            try execute("DELETE FROM codex_thread_dynamic_tools")
            try execute("DELETE FROM codex_thread_catalog")
            try execute("DELETE FROM codex_thread_catalog_capture_state")
            try execute("DELETE FROM codex_model_capability_reasoning_levels")
            try execute("DELETE FROM codex_model_capability_service_tiers")
            try execute("DELETE FROM codex_model_capability_speed_tiers")
            try execute("DELETE FROM codex_model_capability_input_modalities")
            try execute("DELETE FROM codex_model_capability_tools")
            try execute("DELETE FROM codex_model_capabilities")
            try execute("DELETE FROM codex_model_capabilities_capture_state")
        }
        try rebuildSeriesCatalogs()
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    private func collapseTokenRollupsToLightweight(table: String) throws {
        try execute(
            """
            INSERT INTO \(table) (
                period_start, model, project_path, project_name, effort, source,
                model_context_window, observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens,
                observed_total_tokens, sample_count
            )
            SELECT period_start, '', '', '', '', '', -1,
                SUM(observed_input_tokens), SUM(observed_cached_input_tokens),
                SUM(observed_output_tokens), SUM(observed_reasoning_output_tokens),
                SUM(observed_total_tokens), SUM(sample_count)
            FROM \(table)
            WHERE model != '' OR project_path != '' OR project_name != ''
                OR effort != '' OR source != '' OR model_context_window != -1
            GROUP BY period_start
            ON CONFLICT(
                period_start, model, project_path, project_name,
                effort, source, model_context_window
            ) DO UPDATE SET
                observed_input_tokens = observed_input_tokens + excluded.observed_input_tokens,
                observed_cached_input_tokens = observed_cached_input_tokens + excluded.observed_cached_input_tokens,
                observed_output_tokens = observed_output_tokens + excluded.observed_output_tokens,
                observed_reasoning_output_tokens = observed_reasoning_output_tokens + excluded.observed_reasoning_output_tokens,
                observed_total_tokens = observed_total_tokens + excluded.observed_total_tokens,
                sample_count = sample_count + excluded.sample_count
            """
        )
        try execute(
            """
            DELETE FROM \(table)
            WHERE model != '' OR project_path != '' OR project_name != ''
                OR effort != '' OR source != '' OR model_context_window != -1
            """
        )
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

    func databaseInfo(
        collectionMode: UsageCollectionMode = .lightweight,
        fileManager: FileManager = .default
    ) throws -> UsageHistoryDatabaseInfo {
        guard let databaseURL else {
            throw UsageHistoryStoreError.databaseUnavailable
        }

        let databaseByteSize = Self.fileByteSize(databaseURL, fileManager: fileManager)
        let walByteSize = Self.fileByteSize(
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            fileManager: fileManager
        )
        let sharedMemoryByteSize = Self.fileByteSize(
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            fileManager: fileManager
        )
        let pageSize = try databasePragmaInt64("page_size")
        let pageCount = try databasePragmaInt64("page_count")
        let freePageCount = try databasePragmaInt64("freelist_count")

        return UsageHistoryDatabaseInfo(
            databaseURL: databaseURL,
            totalByteSize: databaseByteSize + walByteSize + sharedMemoryByteSize,
            databaseByteSize: databaseByteSize,
            walByteSize: walByteSize,
            sharedMemoryByteSize: sharedMemoryByteSize,
            logicalLiveByteSize: max(pageCount - freePageCount, 0) * pageSize,
            reclaimableByteSize: max(freePageCount, 0) * pageSize,
            collectionMode: collectionMode,
            oldestRawBucket: try oldestTimestampDate(
                """
                SELECT MIN(value) FROM (
                    SELECT MIN(timestamp) AS value FROM usage_samples
                    UNION ALL SELECT MIN(received_at) FROM token_usage_samples WHERE is_retention_baseline = 0
                    UNION ALL SELECT MIN(event_timestamp) FROM codex_turn_performance_events
                    UNION ALL SELECT MIN(event_timestamp) FROM codex_session_task_timing_events
                )
                """
            ),
            oldestHourlyBucket: try oldestTimestampDate(
                """
                SELECT MIN(value) FROM (
                    SELECT MIN(period_start) AS value FROM usage_rollups WHERE granularity = 'hourly'
                    UNION ALL SELECT MIN(period_start) FROM token_usage_hourly_rollups
                    UNION ALL SELECT MIN(period_start) FROM token_dimension_hourly_rollups
                    UNION ALL SELECT MIN(period_start) FROM telemetry_hourly_rollups
                    UNION ALL SELECT MIN(period_start) FROM telemetry_error_hourly_rollups
                )
                """
            ),
            oldestDailyBucket: try oldestTimestampDate(
                """
                SELECT MIN(value) FROM (
                    SELECT MIN(period_start) AS value FROM usage_rollups WHERE granularity = 'daily'
                    UNION ALL SELECT MIN(period_start) FROM token_usage_daily_rollups
                    UNION ALL SELECT MIN(period_start) FROM token_dimension_daily_rollups
                    UNION ALL SELECT MIN(period_start) FROM telemetry_daily_rollups
                    UNION ALL SELECT MIN(period_start) FROM telemetry_error_daily_rollups
                )
                """
            ),
            maintenanceState: try storageMaintenanceState()
        )
    }

    func preflightAdvancedIngestion(
        mode: UsageCollectionMode,
        batchKind: AdvancedIngestionBatchKind
    ) throws -> Bool {
        guard mode == .detailedAnalytics else {
            return false
        }
        // In-memory stores are test/preview stores with no persistent physical budget.
        guard databaseURL != nil else {
            return true
        }
        let info = try databaseInfo(collectionMode: mode)
        let policy = StorageBudgetPolicy.policy(for: mode)
        let wasPaused = try metadataValue(for: "advanced_ingestion_paused") == "1"

        if wasPaused {
            guard info.totalByteSize < policy.softTargetByteSize else {
                return false
            }
            try setMetadataValue("0", for: "advanced_ingestion_paused")
        }

        guard policy.allowsAdvancedBatch(
            current: info.totalByteSize,
            conservativeBatchGrowth: batchKind.conservativeGrowthByteSize
        ) else {
            try setMetadataValue("1", for: "advanced_ingestion_paused")
            try setMetadataValue("1", for: "storage_budget_pressure_pending")
            return false
        }

        if policy.isAtMaintenancePressure(info.totalByteSize) {
            try setMetadataValue("1", for: "storage_budget_pressure_pending")
        }
        return true
    }

    /// Applies the frozen pressure sequence after normal time-tier retention has caught up.
    /// Every destructive step is bounded and preserves the low-cardinality status tables and
    /// token cumulative baselines needed by Lightweight mode.
    @discardableResult
    func enforceStorageBudget(mode: UsageCollectionMode) throws -> UsageHistoryDatabaseInfo {
        guard databaseURL != nil else {
            throw UsageHistoryStoreError.databaseUnavailable
        }

        let policy = StorageBudgetPolicy.policy(for: mode)
        try checkpointWriteAheadLog()
        var info = try databaseInfo(collectionMode: mode)
        guard info.totalByteSize > policy.softTargetByteSize else {
            try setMetadataValue("0", for: "storage_budget_pressure_pending")
            try setMetadataValue("0", for: "advanced_ingestion_paused")
            return info
        }

        try pruneStorageBudgetOrphans()
        info = try databaseInfo(collectionMode: mode)

        var madeProgress = true
        while info.logicalLiveByteSize > policy.softTargetByteSize, madeProgress {
            madeProgress = try shedOldestOptionalRawDetail()
            if !madeProgress {
                madeProgress = try foldOldestInTierHourlyBudgetBatch()
            }
            if !madeProgress {
                madeProgress = try shedOldestDailyAnalytics(mode: mode)
            }
            if madeProgress {
                try checkpointWriteAheadLog()
                info = try databaseInfo(collectionMode: mode)
            }
        }

        if mode == .lightweight, info.logicalLiveByteSize > policy.hardMaximumByteSize {
            try retainSevereLightweightCore(referenceDate: Date())
            try checkpointWriteAheadLog()
            info = try databaseInfo(collectionMode: mode)
        }

        // Ordinary lifecycle passes only reclaim a bounded number of pages. A full rebuild is
        // coordinated separately because it requires quiescing and atomic file replacement.
        try execute("PRAGMA incremental_vacuum(512)")
        try checkpointWriteAheadLog()
        info = try databaseInfo(collectionMode: mode)

        let remainsPressured = info.totalByteSize > policy.softTargetByteSize
        try setMetadataValue(remainsPressured ? "1" : "0", for: "storage_budget_pressure_pending")
        try setMetadataValue(remainsPressured ? "1" : "0", for: "advanced_ingestion_paused")
        return info
    }

    /// Last-resort Lightweight pressure policy. Lifecycle and ordinary pressure shedding run
    /// first; this path retains the newest limit/reset sample, current-day token counters, and
    /// cumulative baselines so core status and the next delta remain correct.
    private func retainSevereLightweightCore(referenceDate: Date) throws {
        let dayStart = UsageHistoryRange.bucketStart(
            for: referenceDate,
            component: .day,
            calendar: calendar
        ).timeIntervalSince1970Int
        try transaction {
            try compactTokenTelemetry(olderThan: dayStart)
            try execute(
                """
                DELETE FROM usage_samples
                WHERE timestamp < \(dayStart)
                  AND EXISTS (
                      SELECT 1 FROM usage_samples AS newer
                      WHERE newer.bucket_id = usage_samples.bucket_id
                        AND newer.window = usage_samples.window
                        AND newer.timestamp > usage_samples.timestamp
                  )
                """
            )
            try execute(
                """
                DELETE FROM usage_rollups
                WHERE period_start < \(dayStart)
                  AND EXISTS (
                      SELECT 1 FROM usage_rollups AS newer
                      WHERE newer.granularity = usage_rollups.granularity
                        AND newer.bucket_id = usage_rollups.bucket_id
                        AND newer.window = usage_rollups.window
                        AND newer.period_start > usage_rollups.period_start
                  )
                """
            )
            try execute(
                "DELETE FROM token_usage_samples WHERE is_retention_baseline = 0 AND received_at < \(dayStart)"
            )
            try execute("DELETE FROM token_usage_hourly_rollups WHERE period_start < \(dayStart)")
            try execute("DELETE FROM token_dimension_hourly_rollups WHERE period_start < \(dayStart)")
            try execute("DELETE FROM token_usage_daily_rollups WHERE period_start < \(dayStart)")
            try execute("DELETE FROM token_dimension_daily_rollups WHERE period_start < \(dayStart)")
            try execute("DELETE FROM telemetry_hourly_rollups WHERE period_start < \(dayStart)")
            try execute("DELETE FROM telemetry_error_hourly_rollups WHERE period_start < \(dayStart)")
            try execute("DELETE FROM telemetry_daily_rollups WHERE period_start < \(dayStart)")
            try execute("DELETE FROM telemetry_error_daily_rollups WHERE period_start < \(dayStart)")
            try execute("DELETE FROM codex_turn_performance_dimensions")
            try execute("DELETE FROM codex_turn_performance_events")
            try execute("DELETE FROM codex_session_task_timing_events")
        }
        try pruneStorageBudgetOrphans()
    }

    private func pruneStorageBudgetOrphans() throws {
        try transaction {
            try execute(
                """
                DELETE FROM token_dimension_sets
                WHERE NOT EXISTS (
                    SELECT 1 FROM token_usage_samples
                    WHERE token_usage_samples.dimension_set_id = token_dimension_sets.set_id
                )
                """
            )
            try execute(
                """
                DELETE FROM token_dimension_values
                WHERE NOT EXISTS (
                    SELECT 1 FROM token_dimension_set_members
                    WHERE token_dimension_set_members.value_id = token_dimension_values.value_id
                )
                """
            )
            try execute(
                """
                DELETE FROM token_expired_baselines
                WHERE expired_at < CAST(strftime('%s', 'now', '-30 days') AS INTEGER)
                """
            )
            try execute(
                """
                DELETE FROM codex_turn_performance_dimension_catalog
                WHERE NOT EXISTS (
                    SELECT 1 FROM codex_turn_performance_dimensions
                    WHERE codex_turn_performance_dimensions.dimension_key = codex_turn_performance_dimension_catalog.dimension_key
                      AND codex_turn_performance_dimensions.dimension_value = codex_turn_performance_dimension_catalog.dimension_value
                )
                """
            )
        }
    }

    private func shedOldestOptionalRawDetail() throws -> Bool {
        if try compactOldestRawBudgetBatch() {
            return true
        }
        let beforeChanges = sqlite3_total_changes64(database)
        try transaction {
            // Performance/session rows are optional. Delete at most one oldest 24-hour slice.
            try execute(
                """
                DELETE FROM codex_turn_performance_dimensions
                WHERE EXISTS (
                    SELECT 1 FROM codex_turn_performance_events AS events
                    WHERE events.source_key = codex_turn_performance_dimensions.source_key
                      AND events.source_row_id = codex_turn_performance_dimensions.source_row_id
                      AND events.event_timestamp < (
                          SELECT COALESCE(MIN(event_timestamp), 0) + 86400
                          FROM codex_turn_performance_events
                      )
                )
                """
            )
            try execute(
                """
                DELETE FROM codex_turn_performance_events
                WHERE event_timestamp < (
                    SELECT COALESCE(MIN(event_timestamp), 0) + 86400
                    FROM codex_turn_performance_events
                )
                """
            )
            try execute(
                """
                DELETE FROM codex_session_task_timing_events
                WHERE event_timestamp < (
                    SELECT COALESCE(MIN(event_timestamp), 0) + 86400
                    FROM codex_session_task_timing_events
                )
                """
            )

            // Preserve token totals/delta baselines while dropping only their oldest optional
            // attribution. The row remains a valid Lightweight sample.
            try execute(
                """
                UPDATE token_usage_samples
                SET model = NULL,
                    session_id = NULL,
                    project_path = NULL,
                    project_name = NULL,
                    effort = NULL,
                    source = NULL,
                    model_context_window = NULL,
                    dimension_set_id = NULL
                WHERE rowid IN (
                    SELECT rowid FROM token_usage_samples
                    WHERE is_retention_baseline = 0
                      AND (dimension_set_id IS NOT NULL OR model IS NOT NULL OR project_path IS NOT NULL)
                    ORDER BY received_at, rowid
                    LIMIT 10000
                )
                """
            )
        }
        if sqlite3_total_changes64(database) > beforeChanges {
            try pruneStorageBudgetOrphans()
            return true
        }
        return false
    }

    private func foldOldestInTierHourlyBudgetBatch() throws -> Bool {
        guard let earliest = try oldestTimestampDate(
            """
            SELECT MIN(value) FROM (
                SELECT MIN(period_start) AS value FROM token_usage_hourly_rollups
                UNION ALL SELECT MIN(period_start) FROM token_dimension_hourly_rollups
                UNION ALL SELECT MIN(period_start) FROM telemetry_hourly_rollups
                UNION ALL SELECT MIN(period_start) FROM telemetry_error_hourly_rollups
            )
            """
        ) else {
            return false
        }
        return try foldHourlyBudgetBatch(startingAt: earliest)
    }

    private func shedOldestDailyAnalytics(mode: UsageCollectionMode) throws -> Bool {
        let protectedTokenCutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970Int
        let beforeChanges = sqlite3_total_changes64(database)
        _ = mode // Both modes protect the same core seven-day token trend.
        try transaction {
            try execute(
                """
                DELETE FROM token_dimension_daily_rollups
                WHERE period_start = (SELECT MIN(period_start) FROM token_dimension_daily_rollups)
                """
            )
            try execute(
                """
                DELETE FROM telemetry_daily_rollups
                WHERE period_start = (SELECT MIN(period_start) FROM telemetry_daily_rollups)
                """
            )
            try execute(
                """
                DELETE FROM telemetry_error_daily_rollups
                WHERE period_start = (SELECT MIN(period_start) FROM telemetry_error_daily_rollups)
                """
            )
            try execute(
                """
                DELETE FROM token_usage_daily_rollups
                WHERE period_start = (
                    SELECT MIN(period_start)
                    FROM token_usage_daily_rollups
                    WHERE period_start < \(protectedTokenCutoff)
                )
                """
            )
        }
        return sqlite3_total_changes64(database) > beforeChanges
    }

    private func databasePragmaInt64(_ name: String) throws -> Int64 {
        let statement = try prepare("PRAGMA \(name)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
        return sqlite3_column_int64(statement, 0)
    }

    func oldestTimestampDate(_ sql: String) throws -> Date? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL
        else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
    }

    func localSourceStoredMetrics() throws -> CodexLocalSourceStoredMetrics {
        CodexLocalSourceStoredMetrics(
            tokenSamples: try localSourceStoredMetric(
                table: "token_usage_samples",
                latestTimestampExpression: "received_at",
                rollupTable: "token_usage_hourly_rollups",
                rawWhereClause: "is_retention_baseline = 0"
            ),
            turnPerformanceEvents: try localSourceStoredMetric(
                table: "codex_turn_performance_events",
                latestTimestampExpression: "event_timestamp",
                rollupTable: "telemetry_hourly_rollups",
                rollupMetric: "turn_performance"
            ),
            runtimeDimensions: try localSourceStoredMetric(
                table: "codex_turn_performance_dimensions",
                latestTimestampExpression: "seen_at"
            ),
            sessionTaskTimingEvents: try localSourceStoredMetric(
                table: "codex_session_task_timing_events",
                latestTimestampExpression: "COALESCE(event_timestamp, started_at, completed_at, recorded_at)",
                rollupTable: "telemetry_hourly_rollups",
                rollupMetric: "session_timing"
            ),
            threadCatalog: try localSourceStoredMetric(
                table: "codex_thread_catalog",
                latestTimestampExpression: "COALESCE(updated_at, created_at, recorded_at)"
            ),
            modelCapabilities: try localSourceStoredMetric(
                table: "codex_model_capabilities",
                latestTimestampExpression: "recorded_at"
            )
        )
    }

    private func localSourceStoredMetric(
        table: String,
        latestTimestampExpression: String,
        rollupTable: String? = nil,
        rollupMetric: String? = nil,
        rawWhereClause: String? = nil
    ) throws -> CodexLocalSourceStoredMetric {
        guard try tableExists(table: table) else {
            return .missingSchema
        }

        let rollupCount = rollupTable.map { table in
            "(SELECT IFNULL(SUM(sample_count), 0) FROM \(table)\(rollupMetric.map { " WHERE metric = '\($0)'" } ?? ""))"
        } ?? "0"
        let rollupLatest = rollupTable.map { table in
            "(SELECT MAX(period_start) FROM \(table)\(rollupMetric.map { " WHERE metric = '\($0)'" } ?? ""))"
        } ?? "NULL"
        let rawWhere = rawWhereClause.map { " WHERE \($0)" } ?? ""
        let statement = try prepare(
            """
            SELECT (SELECT COUNT(*) FROM \(table)\(rawWhere)) + \(rollupCount),
                COALESCE(
                    MAX((SELECT MAX(\(latestTimestampExpression)) FROM \(table)\(rawWhere)), \(rollupLatest)),
                    (SELECT MAX(\(latestTimestampExpression)) FROM \(table)\(rawWhere)),
                    \(rollupLatest)
                )
            """
        )
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return CodexLocalSourceStoredMetric(
                schemaRecognized: true,
                rowCount: Int(sqlite3_column_int64(statement, 0)),
                latestStoredEventAt: optionalColumnDate(statement, index: 1)
            )
        case SQLITE_DONE:
            return .empty
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func exportBackup(to destinationURL: URL, fileManager: FileManager = .default) throws {
        guard let databaseURL else {
            throw UsageHistoryStoreError.databaseUnavailable
        }

        guard databaseURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw UsageHistoryStoreError.fileOperationFailed("Backup destination cannot be the active database.")
        }

        // Treat export as another privacy boundary. This also repairs a current-schema database
        // that was modified by an older build or external tooling before any bytes are copied.
        try transaction {
            try sanitizeStoredGitOrigins()
            try sanitizeStoredSensitiveMetadata()
        }
        try checkpointWriteAheadLog()

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try Self.sqliteBackupCopy(
                from: databaseURL,
                to: destinationURL,
                fileManager: fileManager
            )
            try Self.normalizeBackupJournalMode(at: destinationURL)
        } catch {
            throw UsageHistoryStoreError.fileOperationFailed(error.localizedDescription)
        }
    }

    func sanitizeForOfflineRestore() throws {
        try transaction {
            try sanitizeStoredGitOrigins()
            try sanitizeStoredSensitiveMetadata()
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
        let importedHasTokenUsageHourlyRollups = try tableExists(
            table: "token_usage_hourly_rollups",
            schema: "imported_usage_history"
        )
        let importedHasTokenDimensionHourlyRollups = try tableExists(
            table: "token_dimension_hourly_rollups",
            schema: "imported_usage_history"
        )
        let importedHasTelemetryHourlyRollups = try tableExists(
            table: "telemetry_hourly_rollups",
            schema: "imported_usage_history"
        )
        let importedHasTelemetryErrorHourlyRollups = try tableExists(
            table: "telemetry_error_hourly_rollups",
            schema: "imported_usage_history"
        )
        let importedHasTokenUsageDimensions = try tableExists(
            table: "token_usage_dimensions",
            schema: "imported_usage_history"
        )
        let importedHasNormalizedTokenDimensions = try tableExists(
            table: "token_dimension_values",
            schema: "imported_usage_history"
        ) && tableExists(
            table: "token_dimension_sets",
            schema: "imported_usage_history"
        ) && tableExists(
            table: "token_dimension_set_members",
            schema: "imported_usage_history"
        ) && importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "dimension_set_id",
            schema: "imported_usage_history"
        )
        let importedHasTokenUsageDailyRollups = try tableExists(
            table: "token_usage_daily_rollups",
            schema: "imported_usage_history"
        )
        let importedHasTokenDimensionDailyRollups = try tableExists(
            table: "token_dimension_daily_rollups",
            schema: "imported_usage_history"
        )
        let importedHasTelemetryDailyRollups = try tableExists(
            table: "telemetry_daily_rollups",
            schema: "imported_usage_history"
        )
        let importedHasTelemetryErrorDailyRollups = try tableExists(
            table: "telemetry_error_daily_rollups",
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
        let importedSessionIDExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "session_id",
            schema: "imported_usage_history"
        ) ? "session_id" : "NULL"
        let importedProjectPathExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "project_path",
            schema: "imported_usage_history"
        ) ? "project_path" : "NULL"
        let importedProjectNameExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "project_name",
            schema: "imported_usage_history"
        ) ? "project_name" : "NULL"
        let importedEffortExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "effort",
            schema: "imported_usage_history"
        ) ? "effort" : "NULL"
        let importedSourceExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "source",
            schema: "imported_usage_history"
        ) ? "source" : "NULL"
        let importedRetentionBaselineExpression = try importedHasTokenUsageSamples && tableHasColumn(
            table: "token_usage_samples",
            column: "is_retention_baseline",
            schema: "imported_usage_history"
        ) ? "is_retention_baseline" : "0"
        let importedContextVersionExpression = try importedHasSessionTokenImports && tableHasColumn(
            table: "codex_session_token_imports",
            column: "context_version",
            schema: "imported_usage_history"
        ) ? "context_version" : "NULL"
        let importedByteOffsetExpression = try importedHasSessionTokenImports && tableHasColumn(
            table: "codex_session_token_imports",
            column: "byte_offset",
            schema: "imported_usage_history"
        ) ? "byte_offset" : "file_size"
        let importedNextLineNumberExpression = try importedHasSessionTokenImports && tableHasColumn(
            table: "codex_session_token_imports",
            column: "next_line_number",
            schema: "imported_usage_history"
        ) ? "next_line_number" : "NULL"
        let importedFilePrefixHashExpression = try importedHasSessionTokenImports && tableHasColumn(
            table: "codex_session_token_imports",
            column: "file_prefix_hash",
            schema: "imported_usage_history"
        ) ? "file_prefix_hash" : "NULL"
        let importedTailStateExpression = try importedHasSessionTokenImports && tableHasColumn(
            table: "codex_session_token_imports",
            column: "tail_state_json",
            schema: "imported_usage_history"
        ) ? "tail_state_json" : "NULL"
        let importedHasProjectDisplayNames = try tableExists(
            table: "token_project_catalog",
            schema: "imported_usage_history"
        ) && tableHasColumn(
            table: "token_project_catalog",
            column: "display_name",
            schema: "imported_usage_history"
        )
        let importedHasTurnPerformanceEvents = try tableExists(
            table: "codex_turn_performance_events",
            schema: "imported_usage_history"
        )
        let importedHasTurnPerformanceDimensions = try tableExists(
            table: "codex_turn_performance_dimensions",
            schema: "imported_usage_history"
        )
        let importedHasTurnPerformanceDimensionCatalog = try tableExists(
            table: "codex_turn_performance_dimension_catalog",
            schema: "imported_usage_history"
        )
        let importedHasTurnPerformanceCaptureState = try tableExists(
            table: "codex_turn_performance_capture_state",
            schema: "imported_usage_history"
        )
        let importedHasSessionTaskTimingEvents = try tableExists(
            table: "codex_session_task_timing_events",
            schema: "imported_usage_history"
        )
        let importedSessionTaskTimingEventTimestampExpression = try importedHasSessionTaskTimingEvents && tableHasColumn(
            table: "codex_session_task_timing_events",
            column: "event_timestamp",
            schema: "imported_usage_history"
        ) ? "COALESCE(event_timestamp, started_at, completed_at, recorded_at)" : "COALESCE(started_at, completed_at, recorded_at)"
        let importedHasSessionTaskTimingImportFiles = try tableExists(
            table: "codex_session_task_timing_import_files",
            schema: "imported_usage_history"
        )
        let importedTaskTimingByteOffsetExpression = try importedHasSessionTaskTimingImportFiles && tableHasColumn(
            table: "codex_session_task_timing_import_files",
            column: "byte_offset",
            schema: "imported_usage_history"
        ) ? "byte_offset" : "file_size"
        let importedTaskTimingNextLineNumberExpression = try importedHasSessionTaskTimingImportFiles && tableHasColumn(
            table: "codex_session_task_timing_import_files",
            column: "next_line_number",
            schema: "imported_usage_history"
        ) ? "next_line_number" : "NULL"
        let importedTaskTimingFilePrefixHashExpression = try importedHasSessionTaskTimingImportFiles && tableHasColumn(
            table: "codex_session_task_timing_import_files",
            column: "file_prefix_hash",
            schema: "imported_usage_history"
        ) ? "file_prefix_hash" : "NULL"
        let importedTaskTimingTailStateExpression = try importedHasSessionTaskTimingImportFiles && tableHasColumn(
            table: "codex_session_task_timing_import_files",
            column: "tail_state_json",
            schema: "imported_usage_history"
        ) ? "tail_state_json" : "NULL"
        let importedHasSessionTaskTimingCaptureState = try tableExists(
            table: "codex_session_task_timing_capture_state",
            schema: "imported_usage_history"
        )
        let importedHasThreadCatalog = try tableExists(
            table: "codex_thread_catalog",
            schema: "imported_usage_history"
        )
        let importedHasThreadSpawnEdges = try tableExists(
            table: "codex_thread_spawn_edges",
            schema: "imported_usage_history"
        )
        let importedHasThreadDynamicTools = try tableExists(
            table: "codex_thread_dynamic_tools",
            schema: "imported_usage_history"
        )
        let importedHasThreadCatalogCaptureState = try tableExists(
            table: "codex_thread_catalog_capture_state",
            schema: "imported_usage_history"
        )
        let importedHasModelCapabilities = try tableExists(
            table: "codex_model_capabilities",
            schema: "imported_usage_history"
        )
        let importedHasModelCapabilityReasoningLevels = try tableExists(
            table: "codex_model_capability_reasoning_levels",
            schema: "imported_usage_history"
        )
        let importedHasModelCapabilityServiceTiers = try tableExists(
            table: "codex_model_capability_service_tiers",
            schema: "imported_usage_history"
        )
        let importedHasModelCapabilitySpeedTiers = try tableExists(
            table: "codex_model_capability_speed_tiers",
            schema: "imported_usage_history"
        )
        let importedHasModelCapabilityInputModalities = try tableExists(
            table: "codex_model_capability_input_modalities",
            schema: "imported_usage_history"
        )
        let importedHasModelCapabilityTools = try tableExists(
            table: "codex_model_capability_tools",
            schema: "imported_usage_history"
        )
        let importedHasModelCapabilitiesCaptureState = try tableExists(
            table: "codex_model_capabilities_capture_state",
            schema: "imported_usage_history"
        )

        if importedHasTokenUsageDimensions || importedHasNormalizedTokenDimensions {
            try ensureLegacyTokenDimensionTransitionTable()
            try setMetadataValue("0", for: "token_dimension_v3_finalized")
        }

        try transaction {
            try execute("DELETE FROM usage_samples")
            try execute("DELETE FROM usage_rollups")
            try execute("DELETE FROM token_usage_samples")
            try execute("DELETE FROM token_usage_hourly_rollups")
            try execute("DELETE FROM token_dimension_hourly_rollups")
            try execute("DELETE FROM token_usage_daily_rollups")
            try execute("DELETE FROM token_dimension_daily_rollups")
            try execute("DELETE FROM telemetry_daily_rollups")
            try execute("DELETE FROM telemetry_error_daily_rollups")
            if try tableExists(table: "token_usage_dimensions") {
                try execute("DELETE FROM token_usage_dimensions")
            }
            try execute("DELETE FROM token_dimension_set_members")
            try execute("DELETE FROM token_dimension_sets")
            try execute("DELETE FROM token_dimension_values")
            try execute("DELETE FROM codex_session_token_imports")
            try execute("DELETE FROM usage_series_catalog")
            try execute("DELETE FROM token_series_catalog")
            try execute("DELETE FROM token_project_catalog")
            try execute("DELETE FROM token_effort_catalog")
            try execute("DELETE FROM token_source_catalog")
            try execute("DELETE FROM token_dimension_catalog")
            try execute("DELETE FROM codex_live_token_capture_state")
            try execute("DELETE FROM codex_turn_performance_events")
            try execute("DELETE FROM codex_turn_performance_dimensions")
            try execute("DELETE FROM codex_turn_performance_dimension_catalog")
            try execute("DELETE FROM codex_turn_performance_capture_state")
            try execute("DELETE FROM codex_session_task_timing_events")
            try execute("DELETE FROM codex_session_task_timing_import_files")
            try execute("DELETE FROM codex_session_task_timing_capture_state")
            try execute("DELETE FROM telemetry_hourly_rollups")
            try execute("DELETE FROM telemetry_error_hourly_rollups")
            try execute("DELETE FROM codex_thread_catalog")
            try execute("DELETE FROM codex_thread_spawn_edges")
            try execute("DELETE FROM codex_thread_dynamic_tools")
            try execute("DELETE FROM codex_thread_catalog_capture_state")
            try execute("DELETE FROM codex_model_capability_reasoning_levels")
            try execute("DELETE FROM codex_model_capability_service_tiers")
            try execute("DELETE FROM codex_model_capability_speed_tiers")
            try execute("DELETE FROM codex_model_capability_input_modalities")
            try execute("DELETE FROM codex_model_capability_tools")
            try execute("DELETE FROM codex_model_capabilities")
            try execute("DELETE FROM codex_model_capabilities_capture_state")
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
                        thread_id, turn_id, model, session_id, project_path, project_name,
                        effort, source, received_at, model_context_window,
                        last_input_tokens, last_cached_input_tokens, last_output_tokens,
                        last_reasoning_output_tokens, last_total_tokens,
                        total_input_tokens, total_cached_input_tokens, total_output_tokens,
                        total_reasoning_output_tokens, total_total_tokens,
                        observed_input_tokens, observed_cached_input_tokens, observed_output_tokens,
                        observed_reasoning_output_tokens, observed_total_tokens,
                        is_retention_baseline
                    )
                    SELECT thread_id, turn_id, model,
                        \(importedSessionIDExpression), \(importedProjectPathExpression),
                        \(importedProjectNameExpression), \(importedEffortExpression),
                        \(importedSourceExpression), received_at, model_context_window,
                        last_input_tokens, last_cached_input_tokens, last_output_tokens,
                        last_reasoning_output_tokens, last_total_tokens,
                        total_input_tokens, total_cached_input_tokens, total_output_tokens,
                        total_reasoning_output_tokens, total_total_tokens,
                        \(importedObservedInputExpression), \(importedObservedCachedExpression),
                        \(importedObservedOutputExpression), \(importedObservedReasoningExpression),
                        observed_total_tokens, \(importedRetentionBaselineExpression)
                    FROM imported_usage_history.token_usage_samples
                    """
                )
            }
            if importedHasTokenUsageHourlyRollups {
                try execute(
                    """
                    INSERT INTO token_usage_hourly_rollups (
                        period_start, model, project_path, project_name, effort, source,
                        model_context_window, observed_input_tokens, observed_cached_input_tokens,
                        observed_output_tokens, observed_reasoning_output_tokens,
                        observed_total_tokens, sample_count
                    )
                    SELECT period_start, model, project_path, project_name, effort, source,
                        model_context_window, observed_input_tokens, observed_cached_input_tokens,
                        observed_output_tokens, observed_reasoning_output_tokens,
                        observed_total_tokens, sample_count
                    FROM imported_usage_history.token_usage_hourly_rollups
                    """
                )
            }
            if importedHasTokenDimensionHourlyRollups {
                try execute(
                    """
                    INSERT INTO token_dimension_hourly_rollups (
                        period_start, dimension_key, dimension_value,
                        observed_input_tokens, observed_cached_input_tokens,
                        observed_output_tokens, observed_reasoning_output_tokens,
                        observed_total_tokens, sample_count
                    )
                    SELECT period_start, dimension_key, dimension_value,
                        observed_input_tokens, observed_cached_input_tokens,
                        observed_output_tokens, observed_reasoning_output_tokens,
                        observed_total_tokens, sample_count
                    FROM imported_usage_history.token_dimension_hourly_rollups
                    """
                )
            }
            if importedHasTokenUsageDailyRollups {
                try execute(
                    """
                    INSERT INTO token_usage_daily_rollups
                    SELECT * FROM imported_usage_history.token_usage_daily_rollups
                    """
                )
            }
            if importedHasTokenDimensionDailyRollups {
                try execute(
                    """
                    INSERT INTO token_dimension_daily_rollups
                    SELECT * FROM imported_usage_history.token_dimension_daily_rollups
                    """
                )
            }
            if importedHasTelemetryDailyRollups {
                try execute(
                    """
                    INSERT INTO telemetry_daily_rollups
                    SELECT * FROM imported_usage_history.telemetry_daily_rollups
                    """
                )
            }
            if importedHasTelemetryErrorDailyRollups {
                try execute(
                    """
                    INSERT INTO telemetry_error_daily_rollups
                    SELECT * FROM imported_usage_history.telemetry_error_daily_rollups
                    """
                )
            }
            if importedHasTelemetryHourlyRollups {
                try execute(
                    """
                    INSERT INTO telemetry_hourly_rollups (
                        metric, period_start, model, project_path, project_name, effort, source,
                        transport, wire_api, sample_count, success_count, failure_count,
                        duration_sample_count, duration_total_ms,
                        first_token_sample_count, first_token_total_ms,
                        completed_count, incomplete_count, duration_values, first_token_values
                    )
                    SELECT metric, period_start, model, project_path, project_name, effort, source,
                        transport, wire_api, sample_count, success_count, failure_count,
                        duration_sample_count, duration_total_ms,
                        first_token_sample_count, first_token_total_ms,
                        completed_count, incomplete_count, duration_values, first_token_values
                    FROM imported_usage_history.telemetry_hourly_rollups
                    """
                )
            }
            if importedHasTelemetryErrorHourlyRollups {
                try execute(
                    """
                    INSERT INTO telemetry_error_hourly_rollups (
                        period_start, model, project_path, project_name, effort, source,
                        transport, wire_api, error_summary, event_count
                    )
                    SELECT period_start, model, project_path, project_name, effort, source,
                        transport, wire_api, error_summary, event_count
                    FROM imported_usage_history.telemetry_error_hourly_rollups
                    """
                )
            }
            if importedHasTokenUsageDimensions {
                try execute(
                    """
                    INSERT OR IGNORE INTO token_usage_dimensions (
                        thread_id, turn_id, total_total_tokens, dimension_key, dimension_value, seen_at
                    )
                    SELECT dimension_rows.thread_id, dimension_rows.turn_id,
                        dimension_rows.total_total_tokens, dimension_rows.dimension_key,
                        dimension_rows.dimension_value, dimension_rows.seen_at
                    FROM imported_usage_history.token_usage_dimensions dimension_rows
                    INNER JOIN token_usage_samples samples
                        ON samples.thread_id = dimension_rows.thread_id
                        AND samples.turn_id = dimension_rows.turn_id
                        AND samples.total_total_tokens = dimension_rows.total_total_tokens
                    """
                )
            } else if importedHasNormalizedTokenDimensions {
                try execute(
                    """
                    INSERT OR IGNORE INTO token_usage_dimensions (
                        thread_id, turn_id, total_total_tokens, dimension_key, dimension_value, seen_at
                    )
                    SELECT samples.thread_id, samples.turn_id, samples.total_total_tokens,
                        values_table.dimension_key, values_table.dimension_value,
                        MAX(values_table.last_seen_at, samples.received_at)
                    FROM imported_usage_history.token_usage_samples AS samples
                    JOIN imported_usage_history.token_dimension_set_members AS members
                      ON members.set_id = samples.dimension_set_id
                    JOIN imported_usage_history.token_dimension_values AS values_table
                      ON values_table.value_id = members.value_id
                    JOIN token_usage_samples AS local_samples
                      ON local_samples.thread_id = samples.thread_id
                     AND local_samples.turn_id = samples.turn_id
                     AND local_samples.total_total_tokens = samples.total_total_tokens
                    WHERE samples.dimension_set_id IS NOT NULL
                    """
                )
            }
            if importedHasSessionTokenImports {
                try execute(
                    """
                    INSERT INTO codex_session_token_imports (
                        file_path, file_size, modified_at, imported_at, status, context_version,
                        byte_offset, next_line_number, file_prefix_hash, tail_state_json
                    )
                    SELECT file_path, file_size, modified_at, imported_at, status,
                        \(importedContextVersionExpression), \(importedByteOffsetExpression),
                        \(importedNextLineNumberExpression), \(importedFilePrefixHashExpression),
                        \(importedTailStateExpression)
                    FROM imported_usage_history.codex_session_token_imports
                    """
                )
            }
            if importedHasTurnPerformanceEvents {
                try execute(
                    """
                    INSERT OR IGNORE INTO codex_turn_performance_events (
                        source_key, source_row_id, target, event_timestamp, event_name, event_kind,
                        duration_ms, success, error_summary, thread_id, turn_id, model, session_id,
                        project_path, project_name, effort, source, originator, app_version,
                        terminal_type, transport, wire_api, api_path, recorded_at
                    )
                    SELECT source_key, source_row_id, target, event_timestamp, event_name, event_kind,
                        duration_ms, success, error_summary, thread_id, turn_id, model, session_id,
                        project_path, project_name, effort, source, originator, app_version,
                        terminal_type, transport, wire_api, api_path, recorded_at
                    FROM imported_usage_history.codex_turn_performance_events
                    """
                )
            }
            if importedHasTurnPerformanceDimensions {
                try execute(
                    """
                    INSERT OR IGNORE INTO codex_turn_performance_dimensions (
                        source_key, source_row_id, dimension_key, dimension_value, seen_at
                    )
                    SELECT dimensions.source_key, dimensions.source_row_id,
                        dimensions.dimension_key, dimensions.dimension_value, dimensions.seen_at
                    FROM imported_usage_history.codex_turn_performance_dimensions dimensions
                    INNER JOIN codex_turn_performance_events events
                        ON events.source_key = dimensions.source_key
                        AND events.source_row_id = dimensions.source_row_id
                    """
                )
            }
            if importedHasTurnPerformanceDimensionCatalog {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_turn_performance_dimension_catalog (
                        dimension_key, dimension_value, first_seen_at, last_seen_at
                    )
                    SELECT dimension_key, dimension_value, first_seen_at, last_seen_at
                    FROM imported_usage_history.codex_turn_performance_dimension_catalog
                    """
                )
            }
            if importedHasTurnPerformanceCaptureState {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_turn_performance_capture_state (
                        source_key, last_checked_at, last_imported_event_at, last_log_row_id,
                        status, inserted_count, duplicate_count, last_error_text
                    )
                    SELECT source_key, last_checked_at, last_imported_event_at, last_log_row_id,
                        status, inserted_count, duplicate_count, last_error_text
                    FROM imported_usage_history.codex_turn_performance_capture_state
                    """
                )
            }
            if importedHasSessionTaskTimingEvents {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_session_task_timing_events (
                        session_id, turn_id, source_path, started_at, completed_at,
                        duration_ms, time_to_first_token_ms, model_context_window,
                        collaboration_mode_kind, model, project_path, project_name,
                        effort, source, dimensions_json, event_timestamp, recorded_at
                    )
                    SELECT session_id, turn_id, source_path, started_at, completed_at,
                        duration_ms, time_to_first_token_ms, model_context_window,
                        collaboration_mode_kind, model, project_path, project_name,
                        effort, source, dimensions_json,
                        \(importedSessionTaskTimingEventTimestampExpression), recorded_at
                    FROM imported_usage_history.codex_session_task_timing_events
                    """
                )
            }
            if importedHasSessionTaskTimingImportFiles {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_session_task_timing_import_files (
                        file_path, file_size, modified_at, imported_at, status, timing_version,
                        byte_offset, next_line_number, file_prefix_hash, tail_state_json
                    )
                    SELECT file_path, file_size, modified_at, imported_at, status, timing_version,
                        \(importedTaskTimingByteOffsetExpression),
                        \(importedTaskTimingNextLineNumberExpression),
                        \(importedTaskTimingFilePrefixHashExpression),
                        \(importedTaskTimingTailStateExpression)
                    FROM imported_usage_history.codex_session_task_timing_import_files
                    """
                )
            }
            if importedHasSessionTaskTimingCaptureState {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_session_task_timing_capture_state (
                        source_key, last_checked_at, last_imported_event_at, status,
                        files_discovered, files_scanned, files_skipped_unchanged,
                        inserted_count, updated_count, duplicate_count, failed_lines_skipped,
                        last_error_text
                    )
                    SELECT source_key, last_checked_at, last_imported_event_at, status,
                        files_discovered, files_scanned, files_skipped_unchanged,
                        inserted_count, updated_count, duplicate_count, failed_lines_skipped,
                        last_error_text
                    FROM imported_usage_history.codex_session_task_timing_capture_state
                    """
                )
            }
            if importedHasThreadCatalog {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_thread_catalog (
                        thread_id, rollout_path, created_at, updated_at, source,
                        model_provider, project_path, project_name, sandbox_policy,
                        approval_mode, tokens_used, has_user_event, archived,
                        archived_at, git_sha, git_branch, git_origin_url, cli_version,
                        agent_nickname, agent_role, agent_path, memory_mode, model,
                        reasoning_effort, thread_source, recorded_at
                    )
                    SELECT thread_id, rollout_path, created_at, updated_at, source,
                        model_provider, project_path, project_name, sandbox_policy,
                        approval_mode, tokens_used, has_user_event, archived,
                        archived_at, git_sha, git_branch, git_origin_url, cli_version,
                        agent_nickname, agent_role, agent_path, memory_mode, model,
                        reasoning_effort, thread_source, recorded_at
                    FROM imported_usage_history.codex_thread_catalog
                    """
                )
            }
            if importedHasThreadSpawnEdges {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_thread_spawn_edges (
                        parent_thread_id, child_thread_id, status, recorded_at
                    )
                    SELECT parent_thread_id, child_thread_id, status, recorded_at
                    FROM imported_usage_history.codex_thread_spawn_edges
                    """
                )
            }
            if importedHasThreadDynamicTools {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_thread_dynamic_tools (
                        thread_id, position, name, namespace, defer_loading, recorded_at
                    )
                    SELECT thread_id, position, name, namespace, defer_loading, recorded_at
                    FROM imported_usage_history.codex_thread_dynamic_tools
                    """
                )
            }
            if importedHasThreadCatalogCaptureState {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_thread_catalog_capture_state (
                        source_key, last_checked_at, last_imported_thread_updated_at,
                        status, threads_inserted_count, threads_updated_count,
                        spawn_edges_inserted_count, spawn_edges_updated_count,
                        dynamic_tools_inserted_count, dynamic_tools_updated_count,
                        stale_rows_deleted_count, source_path, last_error_text
                    )
                    SELECT source_key, last_checked_at, last_imported_thread_updated_at,
                        status, threads_inserted_count, threads_updated_count,
                        spawn_edges_inserted_count, spawn_edges_updated_count,
                        dynamic_tools_inserted_count, dynamic_tools_updated_count,
                        stale_rows_deleted_count, source_path, last_error_text
                    FROM imported_usage_history.codex_thread_catalog_capture_state
                    """
                )
            }
            if importedHasModelCapabilities {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_model_capabilities (
                        slug, display_name, visibility, supported_in_api, priority,
                        context_window, max_context_window, effective_context_window_percent,
                        default_reasoning_level, supports_reasoning_summaries,
                        default_reasoning_summary, supports_verbosity, default_verbosity,
                        shell_type, apply_patch_tool_type, web_search_tool_type,
                        supports_parallel_tool_calls, supports_image_detail_original,
                        supports_search_tool, truncation_policy_mode, truncation_policy_limit,
                        recorded_at
                    )
                    SELECT slug, display_name, visibility, supported_in_api, priority,
                        context_window, max_context_window, effective_context_window_percent,
                        default_reasoning_level, supports_reasoning_summaries,
                        default_reasoning_summary, supports_verbosity, default_verbosity,
                        shell_type, apply_patch_tool_type, web_search_tool_type,
                        supports_parallel_tool_calls, supports_image_detail_original,
                        supports_search_tool, truncation_policy_mode, truncation_policy_limit,
                        recorded_at
                    FROM imported_usage_history.codex_model_capabilities
                    """
                )
            }
            if importedHasModelCapabilityReasoningLevels {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_model_capability_reasoning_levels (
                        model_slug, position, effort
                    )
                    SELECT model_slug, position, effort
                    FROM imported_usage_history.codex_model_capability_reasoning_levels
                    """
                )
            }
            if importedHasModelCapabilityServiceTiers {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_model_capability_service_tiers (
                        model_slug, position, tier_id, tier_name
                    )
                    SELECT model_slug, position, tier_id, tier_name
                    FROM imported_usage_history.codex_model_capability_service_tiers
                    """
                )
            }
            if importedHasModelCapabilitySpeedTiers {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_model_capability_speed_tiers (
                        model_slug, position, tier_id
                    )
                    SELECT model_slug, position, tier_id
                    FROM imported_usage_history.codex_model_capability_speed_tiers
                    """
                )
            }
            if importedHasModelCapabilityInputModalities {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_model_capability_input_modalities (
                        model_slug, position, modality
                    )
                    SELECT model_slug, position, modality
                    FROM imported_usage_history.codex_model_capability_input_modalities
                    """
                )
            }
            if importedHasModelCapabilityTools {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_model_capability_tools (
                        model_slug, position, tool_kind, tool_value
                    )
                    SELECT model_slug, position, tool_kind, tool_value
                    FROM imported_usage_history.codex_model_capability_tools
                    """
                )
            }
            if importedHasModelCapabilitiesCaptureState {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_model_capabilities_capture_state (
                        source_key, last_checked_at, cache_fetched_at, status,
                        models_inserted_count, models_updated_count,
                        child_rows_inserted_count, stale_rows_deleted_count,
                        client_version, source_path, last_error_text
                    )
                    SELECT source_key, last_checked_at, cache_fetched_at, status,
                        models_inserted_count, models_updated_count,
                        child_rows_inserted_count, stale_rows_deleted_count,
                        client_version, source_path, last_error_text
                    FROM imported_usage_history.codex_model_capabilities_capture_state
                    """
                )
            }
            // Imported rows are not allowed to become committed database state until remotes have
            // crossed the same sanitizer used by live capture and schema migration.
            try sanitizeStoredGitOrigins()
            try sanitizeStoredSensitiveMetadata()
        }

        try rebuildTurnPerformanceRuntimeDimensionCatalog()
        _ = try cleanupTokenModelLabels()
        _ = try cleanupTokenContextValues()
        _ = try cleanupTokenDimensions()
        while try backfillNextTokenDimensionSetChunk(sampleLimit: 1_000) {}
        _ = try finalizeTokenDimensionSetMigrationIfReady()
        try recomputeStoredUsageConsumption()
        try rebuildSeriesCatalogs()
        if importedHasProjectDisplayNames {
            try importTokenProjectDisplayNamesFromAttachedBackup()
        }
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    private func importTokenProjectDisplayNamesFromAttachedBackup() throws {
        let statement = try prepare(
            """
            SELECT project_path, display_name
            FROM imported_usage_history.token_project_catalog
            WHERE display_name IS NOT NULL
                AND NULLIF(TRIM(display_name), '') IS NOT NULL
            """
        )
        defer { sqlite3_finalize(statement) }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let projectPath = columnText(statement, index: 0)
                let displayName = columnText(statement, index: 1)
                guard !CodexTokenContextNormalizer.isInvalidNonBlankProjectDisplayName(displayName) else {
                    continue
                }
                try updateTokenProjectDisplayName(
                    projectPath: projectPath,
                    displayName: displayName,
                    postNotification: false,
                    requireExisting: false
                )
            case SQLITE_DONE:
                return
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
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

    static func fileByteSize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return fileSize.int64Value
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

        if try backupTableExists("codex_model_capabilities", database: backupDatabase) {
            try validateBackupQuery(
                """
                SELECT slug, display_name, visibility, supported_in_api, priority,
                    context_window, max_context_window, effective_context_window_percent,
                    default_reasoning_level, supports_reasoning_summaries,
                    default_reasoning_summary, supports_verbosity, default_verbosity,
                    shell_type, apply_patch_tool_type, web_search_tool_type,
                    supports_parallel_tool_calls, supports_image_detail_original,
                    supports_search_tool, truncation_policy_mode, truncation_policy_limit,
                    recorded_at
                FROM codex_model_capabilities
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
        // VACUUM rebuilds the copied file after privacy repairs so credential canaries cannot
        // survive in freelist or unused page bytes even though no query can reach them.
        let result = sqlite3_exec(
            backupDatabase,
            "PRAGMA journal_mode=DELETE; VACUUM;",
            nil,
            nil,
            &errorMessage
        )
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
