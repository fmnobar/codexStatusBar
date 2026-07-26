import Foundation
import SQLite3

extension UsageHistoryStore {
    static let telemetryRollupValueByteLimit = 4_096
    static let telemetryRollupRepresentativeSampleLimit = 192

    func record(snapshot: CodexUsageSnapshot, at date: Date) throws {
        let timestamp = Self.roundedToMinute(date).timeIntervalSince1970Int

        try transaction {
            for bucket in snapshot.bucketsForRecording {
                try record(bucket: bucket, window: .fiveHour, timestamp: timestamp)
                try record(bucket: bucket, window: .sevenDay, timestamp: timestamp)
            }

            try compactRawSamples(
                olderThan: Date(timeIntervalSince1970: TimeInterval(timestamp))
                    .addingTimeInterval(-StorageLifecyclePolicy.rateLimitRawRetention)
            )
        }

        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    func record(tokenUsage notification: CodexTokenUsageNotification, at date: Date) throws {
        let timestamp = Self.roundedToSecond(date).timeIntervalSince1970Int

        try transaction {
            let observedTokens = try observedTokenDelta(
                threadID: notification.threadID,
                cumulative: notification.tokenUsage.total,
                last: notification.tokenUsage.last
            )
            try insertTokenUsageSample(
                notification: notification,
                timestamp: timestamp,
                observedTokens: observedTokens
            )
        }

        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    func importTokenUsageSamples(
        _ samples: [ImportedCodexTokenUsageSample],
        includeDetailedContext: Bool = true
    ) throws -> TokenUsageImportResult {
        var insertedCount = 0
        var duplicateCount = 0
        var repairedModelCount = 0
        var repairedContextCount = 0
        var repairedDimensionCount = 0

        try transaction {
            for sample in samples {
                let notification = includeDetailedContext
                    ? sample.notification
                    : sample.notification.lightweightStorageValue
                let context = includeDetailedContext ? sample.context : nil
                let cumulativeTotal = notification.tokenUsage.total.totalTokens
                let receivedAt = Self.roundedToSecond(sample.receivedAt).timeIntervalSince1970Int

                if try tokenSampleExists(
                    threadID: notification.threadID,
                    turnID: notification.turnID,
                    cumulativeTotalTokens: cumulativeTotal
                ) {
                    if try repairTokenSampleModelIfNeeded(
                        threadID: notification.threadID,
                        turnID: notification.turnID,
                        cumulativeTotalTokens: cumulativeTotal,
                        model: notification.model
                    ) {
                        repairedModelCount += 1
                    }
                    if try repairTokenSampleContextIfNeeded(
                        threadID: notification.threadID,
                        turnID: notification.turnID,
                        cumulativeTotalTokens: cumulativeTotal,
                        context: context
                    ) {
                        repairedContextCount += 1
                    }
                    repairedDimensionCount += try upsertTokenUsageDimensions(
                        notification: notification,
                        context: context,
                        seenAt: receivedAt
                    )

                    duplicateCount += 1
                    continue
                }

                let observedTokens = try observedTokenDelta(
                    threadID: notification.threadID,
                    cumulative: notification.tokenUsage.total,
                    last: notification.tokenUsage.last
                )
                try insertTokenUsageSample(
                    notification: notification,
                    timestamp: receivedAt,
                    observedTokens: observedTokens,
                    context: context
                )
                insertedCount += 1
            }

            if repairedModelCount > 0 {
                try rebuildTokenSeriesCatalog()
            }
            if repairedContextCount > 0 {
                try rebuildTokenContextCatalogs()
            }
        }

        if insertedCount > 0 || repairedModelCount > 0 || repairedContextCount > 0 || repairedDimensionCount > 0 {
            notificationCenter.post(name: Self.didChangeNotification, object: self)
        }

        return TokenUsageImportResult(
            insertedCount: insertedCount,
            duplicateCount: duplicateCount,
            repairedModelCount: repairedModelCount,
            repairedContextCount: repairedContextCount,
            repairedDimensionCount: repairedDimensionCount
        )
    }

    /// Rolls old high-cardinality telemetry into durable hourly summaries in restartable batches.
    /// Each transaction covers at most 24 completed local-calendar hours so a long catch-up cannot
    /// monopolize the writer or create one multi-gigabyte WAL transaction.
    func enforceTelemetryRetention(referenceDate: Date, force: Bool = false) throws {
        guard try beginTelemetryRetention(referenceDate: referenceDate, force: force) else {
            return
        }

        do {
            while try enforceNextTelemetryRetentionBatch(referenceDate: referenceDate) {}
            try finishTelemetryRetention(referenceDate: referenceDate)
            if force {
                notificationCenter.post(name: Self.didChangeNotification, object: self)
            }
        } catch {
            try? failTelemetryRetention(referenceDate: referenceDate, error: error)
            throw error
        }
    }

    func beginTelemetryRetention(referenceDate: Date, force: Bool) throws -> Bool {
        let referenceTimestamp = Self.roundedToSecond(referenceDate).timeIntervalSince1970Int
        if !force,
           let lastRun = try metadataValue(for: Self.telemetryRetentionLastSuccessMetadataKey).flatMap(Int64.init),
           referenceTimestamp - lastRun < Int64(StorageLifecyclePolicy.maintenanceInterval)
        {
            return false
        }

        var state = try storageMaintenanceState()
        state.lastAttemptAt = referenceDate
        state.stage = .rawToHourly
        state.lastErrorText = nil
        try transaction {
            try setMetadataValue(String(referenceTimestamp), for: Self.telemetryRetentionLastAttemptMetadataKey)
            try recordStorageMaintenanceState(state)
        }
        return true
    }

    /// Returns true when another raw-to-hourly batch remains.
    func enforceNextTelemetryRetentionBatch(referenceDate: Date) throws -> Bool {
        let retention = max(rawRetentionProvider(), 60 * 60)
        let referenceTimestamp = Self.roundedToSecond(referenceDate).timeIntervalSince1970Int
        let requestedCutoff = referenceTimestamp - Int64(retention.rounded(.down))
        let targetCutoff = UsageHistoryRange.bucketStart(
            for: Date(timeIntervalSince1970: TimeInterval(requestedCutoff)),
            component: .hour,
            calendar: calendar
        )

        let earliestToken = try earliestUncompactedTokenTimestamp(olderThan: targetCutoff.timeIntervalSince1970Int)
        let earliestPerformance = try earliestUncompactedPerformanceTimestamp(olderThan: targetCutoff.timeIntervalSince1970Int)
        guard let earliestTimestamp = [earliestToken, earliestPerformance].compactMap({ $0 }).min() else {
            if try foldNextHourlyRetentionBatch(referenceDate: referenceDate) {
                return true
            }
            try finalizeTelemetryRetentionTiers(referenceDate: referenceDate)
            return false
        }

        let batchStart = UsageHistoryRange.bucketStart(
            for: Date(timeIntervalSince1970: TimeInterval(earliestTimestamp)),
            component: .hour,
            calendar: calendar
        )
        let proposedBatchEnd = calendar.date(
            byAdding: .hour,
            value: StorageLifecyclePolicy.maximumHourlyBucketsPerTransaction,
            to: batchStart
        ) ?? targetCutoff
        let batchEnd = min(proposedBatchEnd, targetCutoff)
        let beforeChanges = sqlite3_total_changes64(database)

        try transaction {
            try compactTokenTelemetry(olderThan: batchEnd.timeIntervalSince1970Int)
            try compactPerformanceTelemetry(olderThan: batchEnd.timeIntervalSince1970Int)
            var state = try storageMaintenanceState()
            state.stage = .rawToHourly
            state.cursor = batchEnd
            state.rowsCompacted += max(sqlite3_total_changes64(database) - beforeChanges, 0)
            try setMetadataValue(
                String(batchEnd.timeIntervalSince1970Int),
                for: Self.telemetryRetentionCursorMetadataKey
            )
            try recordStorageMaintenanceState(state)
        }

        return batchEnd < targetCutoff
    }

    func finishTelemetryRetention(referenceDate: Date) throws {
        let referenceTimestamp = Self.roundedToSecond(referenceDate).timeIntervalSince1970Int
        var state = try storageMaintenanceState()
        state.lastSuccessAt = referenceDate
        state.stage = .idle
        state.cursor = nil
        state.lastErrorText = nil
        try transaction {
            try setMetadataValue(String(referenceTimestamp), for: Self.telemetryRetentionLastSuccessMetadataKey)
            // Preserve the v2 key for backup and diagnostics compatibility.
            try setMetadataValue(String(referenceTimestamp), for: "telemetry_retention_last_run")
            try setMetadataValue("", for: Self.telemetryRetentionCursorMetadataKey)
            try recordStorageMaintenanceState(state)
        }
    }

    func failTelemetryRetention(referenceDate: Date, error: Error) throws {
        var state = try storageMaintenanceState()
        state.lastAttemptAt = referenceDate
        state.stage = .failed
        state.lastErrorText = StorageMaintenanceErrorSanitizer.text(for: error)
        try transaction {
            try recordStorageMaintenanceState(state)
        }
    }

    func storageMaintenanceState() throws -> StorageMaintenanceState {
        guard let encoded = try metadataValue(for: Self.storageMaintenanceStateMetadataKey),
              let data = encoded.data(using: .utf8),
              let state = try? JSONDecoder().decode(StorageMaintenanceState.self, from: data)
        else {
            return .idle
        }
        return state
    }

    func recordStorageMaintenanceState(_ state: StorageMaintenanceState) throws {
        let data = try JSONEncoder().encode(state)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw UsageHistoryStoreError.databaseOperationFailed("Maintenance state could not be encoded.")
        }
        try setMetadataValue(encoded, for: Self.storageMaintenanceStateMetadataKey)
    }

    private func finalizeTelemetryRetentionTiers(referenceDate: Date) throws {
        let rateCutoff = referenceDate.addingTimeInterval(-StorageLifecyclePolicy.rateLimitRawRetention)
        let baselineCutoff = referenceDate.addingTimeInterval(-StorageLifecyclePolicy.inactiveTokenBaselineRetention)
        let hourlyCutoff = UsageHistoryRange.bucketStart(
            for: referenceDate.addingTimeInterval(-StorageLifecyclePolicy.hourlyRetention),
            component: .hour,
            calendar: calendar
        ).timeIntervalSince1970Int
        let dailyCutoff = UsageHistoryRange.bucketStart(
            for: referenceDate.addingTimeInterval(-StorageLifecyclePolicy.dailyRetention),
            component: .day,
            calendar: calendar
        ).timeIntervalSince1970Int
        try transaction {
            var state = try storageMaintenanceState()
            state.stage = .pruning
            try compactRawSamples(olderThan: rateCutoff)
            try expireInactiveTokenBaselines(olderThan: baselineCutoff.timeIntervalSince1970Int)
            try execute(
                """
                DELETE FROM usage_rollups
                WHERE granularity = '\(UsageHistoryGranularity.hour.rawValue)'
                  AND period_start < \(hourlyCutoff)
                """
            )
            try execute(
                """
                DELETE FROM usage_rollups
                WHERE granularity = '\(UsageHistoryGranularity.day.rawValue)'
                  AND period_start < \(dailyCutoff)
                """
            )
            try execute("DELETE FROM token_usage_daily_rollups WHERE period_start < \(dailyCutoff)")
            try execute("DELETE FROM token_dimension_daily_rollups WHERE period_start < \(dailyCutoff)")
            try execute("DELETE FROM telemetry_daily_rollups WHERE period_start < \(dailyCutoff)")
            try execute("DELETE FROM telemetry_error_daily_rollups WHERE period_start < \(dailyCutoff)")
            try execute("DELETE FROM token_series_catalog WHERE seen_at < \(dailyCutoff)")
            try execute("DELETE FROM token_project_catalog WHERE last_seen_at < \(dailyCutoff)")
            try execute("DELETE FROM token_effort_catalog WHERE last_seen_at < \(dailyCutoff)")
            try execute("DELETE FROM token_source_catalog WHERE last_seen_at < \(dailyCutoff)")
            try execute("DELETE FROM token_dimension_catalog WHERE last_seen_at < \(dailyCutoff)")
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
                  AND NOT EXISTS (
                    SELECT 1 FROM token_dimension_hourly_rollups
                    WHERE token_dimension_hourly_rollups.dimension_key = token_dimension_values.dimension_key
                      AND token_dimension_hourly_rollups.dimension_value = token_dimension_values.dimension_value
                )
                  AND NOT EXISTS (
                    SELECT 1 FROM token_dimension_daily_rollups
                    WHERE token_dimension_daily_rollups.dimension_key = token_dimension_values.dimension_key
                      AND token_dimension_daily_rollups.dimension_value = token_dimension_values.dimension_value
                )
                """
            )
            try recordStorageMaintenanceState(state)
        }
    }

    private func foldNextHourlyRetentionBatch(referenceDate: Date) throws -> Bool {
        let hourlyCutoff = UsageHistoryRange.bucketStart(
            for: referenceDate.addingTimeInterval(-StorageLifecyclePolicy.hourlyRetention),
            component: .hour,
            calendar: calendar
        )
        guard let earliest = try earliestHourlyRollupTimestamp(olderThan: hourlyCutoff.timeIntervalSince1970Int) else {
            return false
        }

        let batchStart = UsageHistoryRange.bucketStart(
            for: Date(timeIntervalSince1970: TimeInterval(earliest)),
            component: .hour,
            calendar: calendar
        )
        let proposedEnd = calendar.date(
            byAdding: .hour,
            value: StorageLifecyclePolicy.maximumHourlyBucketsPerTransaction,
            to: batchStart
        ) ?? hourlyCutoff
        let batchEnd = min(proposedEnd, hourlyCutoff)

        try transaction {
            var hourStart = batchStart
            while hourStart < batchEnd {
                guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart),
                      nextHour > hourStart
                else {
                    break
                }
                let dayStart = UsageHistoryRange.bucketStart(
                    for: hourStart,
                    component: .day,
                    calendar: calendar
                )
                try foldHourlyRollups(
                    hourStart: hourStart.timeIntervalSince1970Int,
                    dayStart: dayStart.timeIntervalSince1970Int
                )
                hourStart = nextHour
            }

            let start = batchStart.timeIntervalSince1970Int
            let end = batchEnd.timeIntervalSince1970Int
            try execute("DELETE FROM token_usage_hourly_rollups WHERE period_start >= \(start) AND period_start < \(end)")
            try execute("DELETE FROM token_dimension_hourly_rollups WHERE period_start >= \(start) AND period_start < \(end)")
            try execute("DELETE FROM telemetry_hourly_rollups WHERE period_start >= \(start) AND period_start < \(end)")
            try execute("DELETE FROM telemetry_error_hourly_rollups WHERE period_start >= \(start) AND period_start < \(end)")

            var state = try storageMaintenanceState()
            state.stage = .hourlyToDaily
            state.cursor = batchEnd
            try recordStorageMaintenanceState(state)
        }
        return true
    }

    /// Folds at most 24 of the oldest hourly buckets even when they are still inside the normal
    /// 90-day tier. This is the budget-wins escape hatch and is intentionally separate from the
    /// ordinary time-retention cursor.
    func foldHourlyBudgetBatch(startingAt earliest: Date) throws -> Bool {
        let batchStart = UsageHistoryRange.bucketStart(
            for: earliest,
            component: .hour,
            calendar: calendar
        )
        let batchEnd = calendar.date(
            byAdding: .hour,
            value: StorageLifecyclePolicy.maximumHourlyBucketsPerTransaction,
            to: batchStart
        ) ?? batchStart.addingTimeInterval(24 * 60 * 60)

        let beforeChanges = sqlite3_total_changes64(database)
        try transaction {
            var hourStart = batchStart
            while hourStart < batchEnd {
                guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart),
                      nextHour > hourStart
                else {
                    break
                }
                let dayStart = UsageHistoryRange.bucketStart(
                    for: hourStart,
                    component: .day,
                    calendar: calendar
                )
                try foldHourlyRollups(
                    hourStart: hourStart.timeIntervalSince1970Int,
                    dayStart: dayStart.timeIntervalSince1970Int
                )
                hourStart = nextHour
            }

            let start = batchStart.timeIntervalSince1970Int
            let end = batchEnd.timeIntervalSince1970Int
            try execute("DELETE FROM token_usage_hourly_rollups WHERE period_start >= \(start) AND period_start < \(end)")
            try execute("DELETE FROM token_dimension_hourly_rollups WHERE period_start >= \(start) AND period_start < \(end)")
            try execute("DELETE FROM telemetry_hourly_rollups WHERE period_start >= \(start) AND period_start < \(end)")
            try execute("DELETE FROM telemetry_error_hourly_rollups WHERE period_start >= \(start) AND period_start < \(end)")
        }
        return sqlite3_total_changes64(database) > beforeChanges
    }

    func compactOldestRawBudgetBatch(referenceDate: Date = Date()) throws -> Bool {
        let completedHourCutoff = UsageHistoryRange.bucketStart(
            for: referenceDate,
            component: .hour,
            calendar: calendar
        ).timeIntervalSince1970Int
        let earliestToken = try earliestUncompactedTokenTimestamp(olderThan: completedHourCutoff)
        let earliestPerformance = try earliestUncompactedPerformanceTimestamp(olderThan: completedHourCutoff)
        guard let earliest = [earliestToken, earliestPerformance].compactMap({ $0 }).min() else {
            return false
        }
        let start = UsageHistoryRange.bucketStart(
            for: Date(timeIntervalSince1970: TimeInterval(earliest)),
            component: .hour,
            calendar: calendar
        )
        let proposedEnd = calendar.date(
            byAdding: .hour,
            value: StorageLifecyclePolicy.maximumHourlyBucketsPerTransaction,
            to: start
        ) ?? start.addingTimeInterval(24 * 60 * 60)
        let end = min(proposedEnd.timeIntervalSince1970Int, completedHourCutoff)
        guard end > earliest else {
            return false
        }

        let beforeChanges = sqlite3_total_changes64(database)
        try transaction {
            try compactTokenTelemetry(olderThan: end)
            try compactPerformanceTelemetry(olderThan: end)
        }
        return sqlite3_total_changes64(database) > beforeChanges
    }

    private func earliestHourlyRollupTimestamp(olderThan cutoff: Int64) throws -> Int64? {
        let statement = try prepare(
            """
            SELECT MIN(period_start) FROM (
                SELECT period_start FROM token_usage_hourly_rollups WHERE period_start < ?
                UNION ALL
                SELECT period_start FROM token_dimension_hourly_rollups WHERE period_start < ?
                UNION ALL
                SELECT period_start FROM telemetry_hourly_rollups WHERE period_start < ?
                UNION ALL
                SELECT period_start FROM telemetry_error_hourly_rollups WHERE period_start < ?
            )
            """
        )
        defer { sqlite3_finalize(statement) }
        for index in 1...4 {
            sqlite3_bind_int64(statement, Int32(index), cutoff)
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL
        else {
            return nil
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func foldHourlyRollups(hourStart: Int64, dayStart: Int64) throws {
        try execute(
            """
            INSERT INTO token_usage_daily_rollups (
                period_start, model, project_path, project_name, effort, source,
                model_context_window, observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens,
                observed_total_tokens, sample_count
            )
            SELECT \(dayStart), model, project_path, project_name, effort, source,
                model_context_window, observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens,
                observed_total_tokens, sample_count
            FROM token_usage_hourly_rollups WHERE period_start = \(hourStart)
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
            INSERT INTO token_dimension_daily_rollups (
                period_start, dimension_key, dimension_value,
                observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens,
                observed_total_tokens, sample_count
            )
            SELECT \(dayStart), dimension_key, dimension_value,
                observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens,
                observed_total_tokens, sample_count
            FROM token_dimension_hourly_rollups WHERE period_start = \(hourStart)
            ON CONFLICT(period_start, dimension_key, dimension_value) DO UPDATE SET
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
            INSERT INTO telemetry_daily_rollups (
                metric, period_start, model, project_path, project_name, effort, source,
                transport, wire_api, sample_count, success_count, failure_count,
                duration_sample_count, duration_total_ms,
                first_token_sample_count, first_token_total_ms,
                completed_count, incomplete_count, duration_values, first_token_values
            )
            SELECT metric, \(dayStart), model, project_path, project_name, effort, source,
                transport, wire_api, sample_count, success_count, failure_count,
                duration_sample_count, duration_total_ms,
                first_token_sample_count, first_token_total_ms,
                completed_count, incomplete_count, duration_values, first_token_values
            FROM telemetry_hourly_rollups WHERE period_start = \(hourStart)
            ON CONFLICT(
                metric, period_start, model, project_path, project_name,
                effort, source, transport, wire_api
            ) DO UPDATE SET
                sample_count = sample_count + excluded.sample_count,
                success_count = success_count + excluded.success_count,
                failure_count = failure_count + excluded.failure_count,
                duration_sample_count = duration_sample_count + excluded.duration_sample_count,
                duration_total_ms = duration_total_ms + excluded.duration_total_ms,
                first_token_sample_count = first_token_sample_count + excluded.first_token_sample_count,
                first_token_total_ms = first_token_total_ms + excluded.first_token_total_ms,
                completed_count = completed_count + excluded.completed_count,
                incomplete_count = incomplete_count + excluded.incomplete_count,
                duration_values = \(Self.representativeTelemetrySampleMergeSQL(
                    existing: "duration_values",
                    incoming: "excluded.duration_values"
                )),
                first_token_values = \(Self.representativeTelemetrySampleMergeSQL(
                    existing: "first_token_values",
                    incoming: "excluded.first_token_values"
                ))
            """
        )
        try execute(
            """
            INSERT INTO telemetry_error_daily_rollups (
                period_start, model, project_path, project_name, effort, source,
                transport, wire_api, error_summary, event_count
            )
            SELECT \(dayStart), model, project_path, project_name, effort, source,
                transport, wire_api, error_summary, event_count
            FROM telemetry_error_hourly_rollups WHERE period_start = \(hourStart)
            ON CONFLICT(
                period_start, model, project_path, project_name, effort, source,
                transport, wire_api, error_summary
            ) DO UPDATE SET event_count = event_count + excluded.event_count
            """
        )
    }

    private func expireInactiveTokenBaselines(olderThan cutoff: Int64) throws {
        try execute(
            """
            INSERT INTO token_expired_baselines(thread_id, expired_at)
            SELECT thread_id, MAX(received_at)
            FROM token_usage_samples
            WHERE is_retention_baseline = 1 AND received_at < \(cutoff)
            GROUP BY thread_id
            ON CONFLICT(thread_id) DO UPDATE SET
                expired_at = MAX(expired_at, excluded.expired_at)
            """
        )
        if try tableExists(table: "token_usage_dimensions") {
            try execute(
                """
                DELETE FROM token_usage_dimensions
                WHERE EXISTS (
                    SELECT 1 FROM token_usage_samples AS samples
                    WHERE samples.thread_id = token_usage_dimensions.thread_id
                      AND samples.turn_id = token_usage_dimensions.turn_id
                      AND samples.total_total_tokens = token_usage_dimensions.total_total_tokens
                      AND samples.is_retention_baseline = 1
                      AND samples.received_at < \(cutoff)
                )
                """
            )
        }
        try execute(
            "DELETE FROM token_usage_samples WHERE is_retention_baseline = 1 AND received_at < \(cutoff)"
        )
    }

    private static let telemetryRetentionLastAttemptMetadataKey = "telemetry_retention_last_attempt"
    private static let telemetryRetentionLastSuccessMetadataKey = "telemetry_retention_last_success"
    private static let telemetryRetentionCursorMetadataKey = "telemetry_retention_cursor"
    private static let storageMaintenanceStateMetadataKey = "storage_maintenance_state"

    func compactTokenTelemetry(olderThan cutoff: Int64) throws {
        if let earliestTimestamp = try earliestUncompactedTokenTimestamp(olderThan: cutoff) {
            var bucketStart = UsageHistoryRange.bucketStart(
                for: Date(timeIntervalSince1970: TimeInterval(earliestTimestamp)),
                component: .hour,
                calendar: calendar
            )
            let cutoffDate = Date(timeIntervalSince1970: TimeInterval(cutoff))

            while bucketStart < cutoffDate {
                guard let nextBucketStart = calendar.date(byAdding: .hour, value: 1, to: bucketStart),
                      nextBucketStart > bucketStart
                else {
                    break
                }
                let rangeEnd = min(nextBucketStart, cutoffDate)
                try compactTokenTelemetryHour(
                    periodStart: bucketStart.timeIntervalSince1970Int,
                    rangeEnd: rangeEnd.timeIntervalSince1970Int
                )
                bucketStart = nextBucketStart
            }
        }

        // A prior baseline is already represented in a rollup. Demote it only when a newer raw
        // row exists; deletion below then removes it without counting it a second time.
        try execute(
            """
            UPDATE token_usage_samples AS baseline
            SET is_retention_baseline = 0
            WHERE baseline.is_retention_baseline = 1
              AND EXISTS (
                  SELECT 1
                  FROM token_usage_samples AS newer
                  WHERE newer.thread_id = baseline.thread_id
                    AND (
                        newer.received_at > baseline.received_at
                        OR (newer.received_at = baseline.received_at AND newer.rowid > baseline.rowid)
                    )
              )
            """
        )
        try execute(
            """
            UPDATE token_usage_samples AS candidate
            SET is_retention_baseline = 1
            WHERE candidate.received_at < \(cutoff)
              AND NOT EXISTS (
                  SELECT 1 FROM token_usage_samples AS recent
                  WHERE recent.thread_id = candidate.thread_id
                    AND recent.received_at >= \(cutoff)
              )
              AND candidate.rowid = (
                  SELECT newest.rowid
                  FROM token_usage_samples AS newest
                  WHERE newest.thread_id = candidate.thread_id
                    AND newest.received_at < \(cutoff)
                  ORDER BY newest.received_at DESC, newest.total_total_tokens DESC, newest.rowid DESC
                  LIMIT 1
              )
            """
        )
        if try tableExists(table: "token_usage_dimensions") {
            try execute(
                """
                DELETE FROM token_usage_dimensions
                WHERE EXISTS (
                    SELECT 1
                    FROM token_usage_samples AS samples
                    WHERE samples.thread_id = token_usage_dimensions.thread_id
                      AND samples.turn_id = token_usage_dimensions.turn_id
                      AND samples.total_total_tokens = token_usage_dimensions.total_total_tokens
                      AND samples.received_at < \(cutoff)
                      AND samples.is_retention_baseline = 0
                )
                """
            )
        }
        try execute(
            "DELETE FROM token_usage_samples WHERE received_at < \(cutoff) AND is_retention_baseline = 0"
        )
    }

    private func compactTokenTelemetryHour(periodStart: Int64, rangeEnd: Int64) throws {
        try execute(
            """
            INSERT INTO token_usage_hourly_rollups (
                period_start, model, project_path, project_name, effort, source,
                model_context_window, observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens,
                observed_total_tokens, sample_count
            )
            SELECT \(periodStart),
                COALESCE(model, ''), COALESCE(project_path, ''), COALESCE(project_name, ''),
                COALESCE(effort, ''), COALESCE(source, ''), COALESCE(model_context_window, -1),
                SUM(MAX(COALESCE(observed_input_tokens, 0), 0)),
                SUM(MAX(COALESCE(observed_cached_input_tokens, 0), 0)),
                SUM(MAX(COALESCE(observed_output_tokens, 0), 0)),
                SUM(MAX(COALESCE(observed_reasoning_output_tokens, 0), 0)),
                SUM(MAX(COALESCE(observed_total_tokens, 0), 0)),
                COUNT(*)
            FROM token_usage_samples
            WHERE received_at >= \(periodStart)
              AND received_at < \(rangeEnd)
              AND is_retention_baseline = 0
            GROUP BY COALESCE(model, ''), COALESCE(project_path, ''), COALESCE(project_name, ''),
                COALESCE(effort, ''), COALESCE(source, ''), COALESCE(model_context_window, -1)
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

        for dimensionKey in TokenUsageDimensionKey.allCases {
            try compactTokenDimensionTelemetryHour(
                dimensionKey: dimensionKey,
                periodStart: periodStart,
                rangeEnd: rangeEnd
            )
        }
    }

    private func compactTokenDimensionTelemetryHour(
        dimensionKey: TokenUsageDimensionKey,
        periodStart: Int64,
        rangeEnd: Int64
    ) throws {
        let rawKey = dimensionKey.rawValue
        try execute(
            """
            INSERT INTO token_dimension_hourly_rollups (
                period_start, dimension_key, dimension_value,
                observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens,
                observed_total_tokens, sample_count
            )
            SELECT \(periodStart), '\(rawKey)', COALESCE(dimension_values.dimension_value, ''),
                SUM(MAX(COALESCE(samples.observed_input_tokens, 0), 0)),
                SUM(MAX(COALESCE(samples.observed_cached_input_tokens, 0), 0)),
                SUM(MAX(COALESCE(samples.observed_output_tokens, 0), 0)),
                SUM(MAX(COALESCE(samples.observed_reasoning_output_tokens, 0), 0)),
                SUM(MAX(COALESCE(samples.observed_total_tokens, 0), 0)),
                COUNT(*)
            FROM token_usage_samples AS samples
            LEFT JOIN (
                SELECT thread_id, turn_id, total_total_tokens,
                    COALESCE(
                        MIN(CASE
                            WHEN NOT (
                                dimension_key = '\(TokenUsageDimensionKey.sourceKind.rawValue)'
                                AND dimension_value = 'codex-log'
                            ) THEN dimension_value
                        END),
                        MIN(dimension_value)
                    ) AS dimension_value
                FROM token_usage_dimension_query_values
                WHERE dimension_key = '\(rawKey)'
                GROUP BY thread_id, turn_id, total_total_tokens
            ) AS dimension_values
                ON dimension_values.thread_id = samples.thread_id
                AND dimension_values.turn_id = samples.turn_id
                AND dimension_values.total_total_tokens = samples.total_total_tokens
            WHERE samples.received_at >= \(periodStart)
              AND samples.received_at < \(rangeEnd)
              AND samples.is_retention_baseline = 0
            GROUP BY COALESCE(dimension_values.dimension_value, '')
            ON CONFLICT(period_start, dimension_key, dimension_value) DO UPDATE SET
                observed_input_tokens = observed_input_tokens + excluded.observed_input_tokens,
                observed_cached_input_tokens = observed_cached_input_tokens + excluded.observed_cached_input_tokens,
                observed_output_tokens = observed_output_tokens + excluded.observed_output_tokens,
                observed_reasoning_output_tokens = observed_reasoning_output_tokens + excluded.observed_reasoning_output_tokens,
                observed_total_tokens = observed_total_tokens + excluded.observed_total_tokens,
                sample_count = sample_count + excluded.sample_count
            """
        )
    }

    private func earliestUncompactedTokenTimestamp(olderThan cutoff: Int64) throws -> Int64? {
        let statement = try prepare(
            "SELECT MIN(received_at) FROM token_usage_samples WHERE received_at < ? AND is_retention_baseline = 0"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func compactPerformanceTelemetry(olderThan cutoff: Int64) throws {
        guard let earliestTimestamp = try earliestUncompactedPerformanceTimestamp(olderThan: cutoff) else {
            return
        }
        var bucketStart = UsageHistoryRange.bucketStart(
            for: Date(timeIntervalSince1970: TimeInterval(earliestTimestamp)),
            component: .hour,
            calendar: calendar
        )
        let cutoffDate = Date(timeIntervalSince1970: TimeInterval(cutoff))
        while bucketStart < cutoffDate {
            guard let nextBucketStart = calendar.date(byAdding: .hour, value: 1, to: bucketStart),
                  nextBucketStart > bucketStart
            else {
                break
            }
            let rangeEnd = min(nextBucketStart, cutoffDate)
            try compactPerformanceTelemetryHour(
                periodStart: bucketStart.timeIntervalSince1970Int,
                rangeEnd: rangeEnd.timeIntervalSince1970Int
            )
            bucketStart = nextBucketStart
        }

        try execute(
            """
            DELETE FROM codex_turn_performance_dimensions
            WHERE EXISTS (
                SELECT 1 FROM codex_turn_performance_events AS events
                WHERE events.source_key = codex_turn_performance_dimensions.source_key
                  AND events.source_row_id = codex_turn_performance_dimensions.source_row_id
                  AND events.event_timestamp < \(cutoff)
            )
            """
        )
        try execute("DELETE FROM codex_turn_performance_events WHERE event_timestamp < \(cutoff)")
        try execute("DELETE FROM codex_session_task_timing_events WHERE event_timestamp < \(cutoff)")
    }

    private func compactPerformanceTelemetryHour(periodStart: Int64, rangeEnd: Int64) throws {
        try execute(
            """
            WITH RECURSIVE
            sample_positions(position) AS (
                SELECT 0
                UNION ALL
                SELECT position + 1
                FROM sample_positions
                WHERE position + 1 < \(Self.telemetryRollupRepresentativeSampleLimit)
            ),
            base AS (
                SELECT rowid AS tie_id,
                    COALESCE(model, '') AS model,
                    COALESCE(project_path, '') AS project_path,
                    COALESCE(project_name, '') AS project_name,
                    COALESCE(effort, '') AS effort,
                    COALESCE(source, '') AS source,
                    COALESCE(transport, '') AS transport,
                    COALESCE(wire_api, '') AS wire_api,
                    event_timestamp, success,
                    CASE WHEN duration_ms IS NOT NULL THEN MAX(duration_ms, 0) END AS duration_value
                FROM codex_turn_performance_events
                WHERE event_timestamp >= \(periodStart) AND event_timestamp < \(rangeEnd)
            ),
            aggregates AS (
                SELECT model, project_path, project_name, effort, source, transport, wire_api,
                    COUNT(*) AS sample_count,
                    SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) AS success_count,
                    SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) AS failure_count,
                    SUM(CASE WHEN duration_value IS NOT NULL THEN 1 ELSE 0 END) AS duration_sample_count,
                    SUM(COALESCE(duration_value, 0)) AS duration_total_ms
                FROM base
                GROUP BY model, project_path, project_name, effort, source, transport, wire_api
            ),
            duration_ranked AS (
                SELECT model, project_path, project_name, effort, source, transport, wire_api,
                    duration_value,
                    ROW_NUMBER() OVER (
                        PARTITION BY model, project_path, project_name, effort, source, transport, wire_api
                        ORDER BY duration_value ASC, event_timestamp ASC, tie_id ASC
                    ) AS sample_rank,
                    COUNT(*) OVER (
                        PARTITION BY model, project_path, project_name, effort, source, transport, wire_api
                    ) AS value_count
                FROM base
                WHERE duration_value IS NOT NULL
            ),
            duration_samples AS (
                SELECT model, project_path, project_name, effort, source, transport, wire_api,
                    GROUP_CONCAT(CAST(duration_value AS TEXT) || ',', '') AS duration_values
                FROM duration_ranked
                WHERE value_count <= \(Self.telemetryRollupRepresentativeSampleLimit)
                    OR EXISTS (
                        SELECT 1
                        FROM sample_positions
                        WHERE sample_rank = 1 + CAST(ROUND(
                            position * (value_count - 1) * 1.0
                                / \(Self.telemetryRollupRepresentativeSampleLimit - 1)
                        ) AS INTEGER)
                    )
                GROUP BY model, project_path, project_name, effort, source, transport, wire_api
            )
            INSERT INTO telemetry_hourly_rollups (
                metric, period_start, model, project_path, project_name, effort, source,
                transport, wire_api, sample_count, success_count, failure_count,
                duration_sample_count, duration_total_ms,
                first_token_sample_count, first_token_total_ms,
                completed_count, incomplete_count, duration_values, first_token_values
            )
            SELECT 'turn_performance', \(periodStart),
                aggregates.model, aggregates.project_path, aggregates.project_name,
                aggregates.effort, aggregates.source, aggregates.transport, aggregates.wire_api,
                aggregates.sample_count, aggregates.success_count, aggregates.failure_count,
                aggregates.duration_sample_count, aggregates.duration_total_ms,
                0, 0, 0, 0, duration_samples.duration_values, NULL
            FROM aggregates
            LEFT JOIN duration_samples USING (
                model, project_path, project_name, effort, source, transport, wire_api
            )
            ON CONFLICT(
                metric, period_start, model, project_path, project_name,
                effort, source, transport, wire_api
            ) DO UPDATE SET
                sample_count = sample_count + excluded.sample_count,
                success_count = success_count + excluded.success_count,
                failure_count = failure_count + excluded.failure_count,
                duration_sample_count = duration_sample_count + excluded.duration_sample_count,
                duration_total_ms = duration_total_ms + excluded.duration_total_ms,
                duration_values = \(Self.representativeTelemetrySampleMergeSQL(
                    existing: "duration_values",
                    incoming: "excluded.duration_values"
                ))
            """
        )
        try execute(
            """
            INSERT INTO telemetry_error_hourly_rollups (
                period_start, model, project_path, project_name, effort, source,
                transport, wire_api, error_summary, event_count
            )
            SELECT \(periodStart), COALESCE(model, ''), COALESCE(project_path, ''),
                COALESCE(project_name, ''), COALESCE(effort, ''), COALESCE(source, ''),
                COALESCE(transport, ''), COALESCE(wire_api, ''), error_summary, COUNT(*)
            FROM codex_turn_performance_events
            WHERE event_timestamp >= \(periodStart) AND event_timestamp < \(rangeEnd)
                AND success = 0 AND error_summary IS NOT NULL
            GROUP BY COALESCE(model, ''), COALESCE(project_path, ''),
                COALESCE(project_name, ''), COALESCE(effort, ''), COALESCE(source, ''),
                COALESCE(transport, ''), COALESCE(wire_api, ''), error_summary
            ON CONFLICT(
                period_start, model, project_path, project_name, effort, source,
                transport, wire_api, error_summary
            ) DO UPDATE SET event_count = event_count + excluded.event_count
            """
        )
        try execute(
            """
            WITH RECURSIVE
            sample_positions(position) AS (
                SELECT 0
                UNION ALL
                SELECT position + 1
                FROM sample_positions
                WHERE position + 1 < \(Self.telemetryRollupRepresentativeSampleLimit)
            ),
            base AS (
                SELECT rowid AS tie_id,
                    COALESCE(model, '') AS model,
                    COALESCE(project_path, '') AS project_path,
                    COALESCE(project_name, '') AS project_name,
                    COALESCE(effort, '') AS effort,
                    COALESCE(source, '') AS source,
                    event_timestamp, completed_at,
                    CASE WHEN duration_ms IS NOT NULL THEN MAX(duration_ms, 0) END AS duration_value,
                    CASE WHEN time_to_first_token_ms IS NOT NULL
                        THEN MAX(time_to_first_token_ms, 0)
                    END AS first_token_value
                FROM codex_session_task_timing_events
                WHERE event_timestamp >= \(periodStart) AND event_timestamp < \(rangeEnd)
            ),
            aggregates AS (
                SELECT model, project_path, project_name, effort, source,
                    COUNT(*) AS sample_count,
                    SUM(CASE WHEN duration_value IS NOT NULL THEN 1 ELSE 0 END) AS duration_sample_count,
                    SUM(COALESCE(duration_value, 0)) AS duration_total_ms,
                    SUM(CASE WHEN first_token_value IS NOT NULL THEN 1 ELSE 0 END) AS first_token_sample_count,
                    SUM(COALESCE(first_token_value, 0)) AS first_token_total_ms,
                    SUM(CASE WHEN completed_at IS NOT NULL THEN 1 ELSE 0 END) AS completed_count,
                    SUM(CASE WHEN completed_at IS NULL THEN 1 ELSE 0 END) AS incomplete_count
                FROM base
                GROUP BY model, project_path, project_name, effort, source
            ),
            duration_ranked AS (
                SELECT model, project_path, project_name, effort, source, duration_value,
                    ROW_NUMBER() OVER (
                        PARTITION BY model, project_path, project_name, effort, source
                        ORDER BY duration_value ASC, event_timestamp ASC, tie_id ASC
                    ) AS sample_rank,
                    COUNT(*) OVER (
                        PARTITION BY model, project_path, project_name, effort, source
                    ) AS value_count
                FROM base
                WHERE duration_value IS NOT NULL
            ),
            first_token_ranked AS (
                SELECT model, project_path, project_name, effort, source, first_token_value,
                    ROW_NUMBER() OVER (
                        PARTITION BY model, project_path, project_name, effort, source
                        ORDER BY first_token_value ASC, event_timestamp ASC, tie_id ASC
                    ) AS sample_rank,
                    COUNT(*) OVER (
                        PARTITION BY model, project_path, project_name, effort, source
                    ) AS value_count
                FROM base
                WHERE first_token_value IS NOT NULL
            ),
            duration_samples AS (
                SELECT model, project_path, project_name, effort, source,
                    GROUP_CONCAT(CAST(duration_value AS TEXT) || ',', '') AS duration_values
                FROM duration_ranked
                WHERE value_count <= \(Self.telemetryRollupRepresentativeSampleLimit)
                    OR EXISTS (
                        SELECT 1 FROM sample_positions
                        WHERE sample_rank = 1 + CAST(ROUND(
                            position * (value_count - 1) * 1.0
                                / \(Self.telemetryRollupRepresentativeSampleLimit - 1)
                        ) AS INTEGER)
                    )
                GROUP BY model, project_path, project_name, effort, source
            ),
            first_token_samples AS (
                SELECT model, project_path, project_name, effort, source,
                    GROUP_CONCAT(CAST(first_token_value AS TEXT) || ',', '') AS first_token_values
                FROM first_token_ranked
                WHERE value_count <= \(Self.telemetryRollupRepresentativeSampleLimit)
                    OR EXISTS (
                        SELECT 1 FROM sample_positions
                        WHERE sample_rank = 1 + CAST(ROUND(
                            position * (value_count - 1) * 1.0
                                / \(Self.telemetryRollupRepresentativeSampleLimit - 1)
                        ) AS INTEGER)
                    )
                GROUP BY model, project_path, project_name, effort, source
            )
            INSERT INTO telemetry_hourly_rollups (
                metric, period_start, model, project_path, project_name, effort, source,
                transport, wire_api, sample_count, success_count, failure_count,
                duration_sample_count, duration_total_ms,
                first_token_sample_count, first_token_total_ms,
                completed_count, incomplete_count, duration_values, first_token_values
            )
            SELECT 'session_timing', \(periodStart),
                aggregates.model, aggregates.project_path, aggregates.project_name,
                aggregates.effort, aggregates.source, '', '', aggregates.sample_count, 0, 0,
                aggregates.duration_sample_count, aggregates.duration_total_ms,
                aggregates.first_token_sample_count, aggregates.first_token_total_ms,
                aggregates.completed_count, aggregates.incomplete_count,
                duration_samples.duration_values, first_token_samples.first_token_values
            FROM aggregates
            LEFT JOIN duration_samples USING (model, project_path, project_name, effort, source)
            LEFT JOIN first_token_samples USING (model, project_path, project_name, effort, source)
            ON CONFLICT(
                metric, period_start, model, project_path, project_name,
                effort, source, transport, wire_api
            ) DO UPDATE SET
                sample_count = sample_count + excluded.sample_count,
                duration_sample_count = duration_sample_count + excluded.duration_sample_count,
                duration_total_ms = duration_total_ms + excluded.duration_total_ms,
                first_token_sample_count = first_token_sample_count + excluded.first_token_sample_count,
                first_token_total_ms = first_token_total_ms + excluded.first_token_total_ms,
                completed_count = completed_count + excluded.completed_count,
                incomplete_count = incomplete_count + excluded.incomplete_count,
                duration_values = \(Self.representativeTelemetrySampleMergeSQL(
                    existing: "duration_values",
                    incoming: "excluded.duration_values"
                )),
                first_token_values = \(Self.representativeTelemetrySampleMergeSQL(
                    existing: "first_token_values",
                    incoming: "excluded.first_token_values"
                ))
            """
        )
    }

    /// Re-samples an existing and incoming CSV as evenly spaced order statistics. This keeps late
    /// imports representative instead of retaining the first values that happened to be compacted.
    static func representativeTelemetrySampleMergeSQL(
        existing: String,
        incoming: String
    ) -> String {
        let normalizedExisting = normalizedRepresentativeTelemetrySampleSQL(value: existing)
        let normalizedIncoming = normalizedRepresentativeTelemetrySampleSQL(value: incoming)
        return """
        (
        WITH normalized(existing_values, incoming_values) AS (
            SELECT \(normalizedExisting), \(normalizedIncoming)
        )
        SELECT CASE
            WHEN existing_values IS NULL THEN incoming_values
            WHEN incoming_values IS NULL THEN existing_values
            WHEN LENGTH(CAST(existing_values AS BLOB))
                    + LENGTH(CAST(incoming_values AS BLOB)) <= \(telemetryRollupValueByteLimit)
                AND (
                    LENGTH(existing_values) - LENGTH(REPLACE(existing_values, ',', ''))
                    + LENGTH(incoming_values) - LENGTH(REPLACE(incoming_values, ',', ''))
                ) <= \(telemetryRollupRepresentativeSampleLimit)
                THEN existing_values || incoming_values
            ELSE (
                WITH RECURSIVE
                csv(rest, value) AS (
                    SELECT existing_values || incoming_values, NULL
                    UNION ALL
                    SELECT SUBSTR(rest, INSTR(rest, ',') + 1),
                        CAST(SUBSTR(rest, 1, INSTR(rest, ',') - 1) AS INTEGER)
                    FROM csv
                    WHERE INSTR(rest, ',') > 0
                ),
                sample_positions(position) AS (
                    SELECT 0
                    UNION ALL
                    SELECT position + 1
                    FROM sample_positions
                    WHERE position + 1 < \(telemetryRollupRepresentativeSampleLimit)
                ),
                ranked AS (
                    SELECT value,
                        ROW_NUMBER() OVER (ORDER BY value ASC) AS sample_rank,
                        COUNT(*) OVER () AS value_count
                    FROM csv
                    WHERE value IS NOT NULL
                )
                SELECT GROUP_CONCAT(CAST(value AS TEXT) || ',', '')
                FROM ranked
                WHERE value_count <= \(telemetryRollupRepresentativeSampleLimit)
                    OR EXISTS (
                        SELECT 1 FROM sample_positions
                        WHERE sample_rank = 1 + CAST(ROUND(
                            position * (value_count - 1) * 1.0
                                / \(telemetryRollupRepresentativeSampleLimit - 1)
                        ) AS INTEGER)
                    )
            )
        END
        FROM normalized
        )
        """
    }

    /// Returns a scalar SQL expression that independently bounds one legacy representative-sample
    /// CSV. Sampling the operands before conflict handling also covers inserts into a new key and
    /// merges where the existing target column is NULL.
    static func normalizedRepresentativeTelemetrySampleSQL(value: String) -> String {
        """
        CASE
            WHEN \(value) IS NULL THEN NULL
            WHEN LENGTH(CAST(\(value) AS BLOB)) <= \(telemetryRollupValueByteLimit)
                AND LENGTH(\(value)) - LENGTH(REPLACE(\(value), ',', ''))
                    <= \(telemetryRollupRepresentativeSampleLimit)
                THEN \(value)
            ELSE (
                WITH RECURSIVE
                csv(rest, value) AS (
                    SELECT \(value), NULL
                    UNION ALL
                    SELECT SUBSTR(rest, INSTR(rest, ',') + 1),
                        CAST(SUBSTR(rest, 1, INSTR(rest, ',') - 1) AS INTEGER)
                    FROM csv
                    WHERE INSTR(rest, ',') > 0
                ),
                sample_positions(position) AS (
                    SELECT 0
                    UNION ALL
                    SELECT position + 1
                    FROM sample_positions
                    WHERE position + 1 < \(telemetryRollupRepresentativeSampleLimit)
                ),
                ranked AS (
                    SELECT value,
                        ROW_NUMBER() OVER (ORDER BY value ASC) AS sample_rank,
                        COUNT(*) OVER () AS value_count
                    FROM csv
                    WHERE value IS NOT NULL
                )
                SELECT GROUP_CONCAT(CAST(value AS TEXT) || ',', '')
                FROM ranked
                WHERE value_count <= \(telemetryRollupRepresentativeSampleLimit)
                    OR EXISTS (
                        SELECT 1 FROM sample_positions
                        WHERE sample_rank = 1 + CAST(ROUND(
                            position * (value_count - 1) * 1.0
                                / \(telemetryRollupRepresentativeSampleLimit - 1)
                        ) AS INTEGER)
                    )
            )
        END
        """
    }

    private func earliestUncompactedPerformanceTimestamp(olderThan cutoff: Int64) throws -> Int64? {
        let statement = try prepare(
            """
            SELECT MIN(timestamp)
            FROM (
                SELECT MIN(event_timestamp) AS timestamp
                FROM codex_turn_performance_events
                WHERE event_timestamp < ?
                UNION ALL
                SELECT MIN(event_timestamp) AS timestamp
                FROM codex_session_task_timing_events
                WHERE event_timestamp < ?
            )
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)
        sqlite3_bind_int64(statement, 2, cutoff)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func metadataValue(for key: String) throws -> String? {
        let statement = try prepare(
            """
            SELECT value
            FROM usage_history_metadata
            WHERE key = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(key, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return columnText(statement, index: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func setMetadataValue(_ value: String, for key: String) throws {
        let statement = try prepare(
            """
            INSERT INTO usage_history_metadata (key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(key, to: 1, in: statement)
        bindText(value, to: 2, in: statement)
        try step(statement)
    }

    func record(bucket: CodexUsageBucket, window: UsageLimitWindow, timestamp: Int64) throws {
        guard let rateLimitWindow = bucket.snapshot.window(for: window) else {
            return
        }

        let consumptionDelta = try observedConsumptionDelta(
            bucketID: bucket.id,
            window: window,
            timestamp: timestamp,
            usedPercent: rateLimitWindow.usedPercent,
            resetAt: rateLimitWindow.resetsAt?.timeIntervalSince1970Int
        )

        try insertRawSample(
            bucket: bucket,
            window: window,
            timestamp: timestamp,
            usedPercent: rateLimitWindow.usedPercent,
            consumedPercent: consumptionDelta.sampleConsumedPercent,
            resetAt: rateLimitWindow.resetsAt?.timeIntervalSince1970Int
        )
        try insertRollup(
            granularity: .hour,
            bucket: bucket,
            window: window,
            timestamp: timestamp,
            usedPercent: rateLimitWindow.usedPercent,
            consumedPercentAdjustment: consumptionDelta.rollupConsumedPercentAdjustment,
            resetAt: rateLimitWindow.resetsAt?.timeIntervalSince1970Int
        )
        try insertRollup(
            granularity: .day,
            bucket: bucket,
            window: window,
            timestamp: timestamp,
            usedPercent: rateLimitWindow.usedPercent,
            consumedPercentAdjustment: consumptionDelta.rollupConsumedPercentAdjustment,
            resetAt: rateLimitWindow.resetsAt?.timeIntervalSince1970Int
        )
    }

    struct ObservedConsumptionDelta {
        let sampleConsumedPercent: Double
        let rollupConsumedPercentAdjustment: Double
    }

    struct ExistingSampleConsumption {
        let usedPercent: Double
        let consumedPercent: Double?
        let resetAt: Int64?
    }

    func observedConsumptionDelta(
        bucketID: String,
        window: UsageLimitWindow,
        timestamp: Int64,
        usedPercent: Int,
        resetAt: Int64?
    ) throws -> ObservedConsumptionDelta {
        let previousUsedPercent = try previousCompatibleUsedPercent(
            bucketID: bucketID,
            window: window,
            before: timestamp,
            resetAt: resetAt
        )
        let sampleConsumedPercent = Self.observedConsumedPercent(
            currentUsedPercent: Double(usedPercent),
            previousUsedPercent: previousUsedPercent
        )
        let existingSample = try existingSampleConsumption(
            bucketID: bucketID,
            window: window,
            timestamp: timestamp
        )
        let existingFallbackConsumedPercent: Double?
        if let existingSample {
            let existingPreviousUsedPercent = try previousCompatibleUsedPercent(
                bucketID: bucketID,
                window: window,
                before: timestamp,
                resetAt: existingSample.resetAt
            )
            existingFallbackConsumedPercent = Self.observedConsumedPercent(
                currentUsedPercent: existingSample.usedPercent,
                previousUsedPercent: existingPreviousUsedPercent
            )
        } else {
            existingFallbackConsumedPercent = nil
        }
        let existingConsumedPercent = existingSample?.consumedPercent ?? existingFallbackConsumedPercent ?? 0

        return ObservedConsumptionDelta(
            sampleConsumedPercent: sampleConsumedPercent,
            rollupConsumedPercentAdjustment: sampleConsumedPercent - existingConsumedPercent
        )
    }

    func previousCompatibleUsedPercent(
        bucketID: String,
        window: UsageLimitWindow,
        before timestamp: Int64,
        resetAt: Int64?
    ) throws -> Double? {
        let statement: OpaquePointer
        if resetAt == nil {
            statement = try prepare(
                """
                SELECT used_percent
                FROM usage_samples
                WHERE bucket_id = ? AND window = ? AND timestamp < ? AND reset_at IS NULL
                ORDER BY timestamp DESC
                LIMIT 1
                """
            )
        } else {
            statement = try prepare(
                """
                SELECT used_percent
                FROM usage_samples
                WHERE bucket_id = ? AND window = ? AND timestamp < ?
                    AND reset_at BETWEEN ? AND ?
                ORDER BY timestamp DESC
                LIMIT 1
                """
            )
        }
        defer { sqlite3_finalize(statement) }

        bindText(bucketID, to: 1, in: statement)
        bindText(window.rawValue, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, timestamp)
        if let resetAt {
            sqlite3_bind_int64(statement, 4, resetAt - Self.resetCohortTolerance)
            sqlite3_bind_int64(statement, 5, resetAt + Self.resetCohortTolerance)
        }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_double(statement, 0)
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func existingSampleConsumption(
        bucketID: String,
        window: UsageLimitWindow,
        timestamp: Int64
    ) throws -> ExistingSampleConsumption? {
        let statement = try prepare(
            """
            SELECT used_percent, consumed_percent, reset_at
            FROM usage_samples
            WHERE bucket_id = ? AND window = ? AND timestamp = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(bucketID, to: 1, in: statement)
        bindText(window.rawValue, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, timestamp)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return ExistingSampleConsumption(
                usedPercent: sqlite3_column_double(statement, 0),
                consumedPercent: optionalColumnDouble(statement, index: 1),
                resetAt: optionalColumnInt(statement, index: 2)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func insertRawSample(
        bucket: CodexUsageBucket,
        window: UsageLimitWindow,
        timestamp: Int64,
        usedPercent: Int,
        consumedPercent: Double,
        resetAt: Int64?
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO usage_samples (
                bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent,
                consumed_percent, reset_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket_id, window, timestamp) DO UPDATE SET
                bucket_name = excluded.bucket_name,
                bucket_kind = excluded.bucket_kind,
                used_percent = excluded.used_percent,
                consumed_percent = excluded.consumed_percent,
                reset_at = excluded.reset_at
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(bucket.id, to: 1, in: statement)
        bindText(bucket.name, to: 2, in: statement)
        bindText(bucket.kind.rawValue, to: 3, in: statement)
        bindText(window.rawValue, to: 4, in: statement)
        sqlite3_bind_int64(statement, 5, timestamp)
        sqlite3_bind_int(statement, 6, Int32(usedPercent))
        sqlite3_bind_double(statement, 7, consumedPercent)
        bindOptionalInt(resetAt, to: 8, in: statement)

        try step(statement)
        try upsertUsageSeriesCatalog(
            bucketID: bucket.id,
            bucketName: bucket.name,
            bucketKind: bucket.kind.rawValue,
            window: window.rawValue,
            seenAt: timestamp
        )
    }

    func insertRollup(
        granularity: UsageHistoryGranularity,
        bucket: CodexUsageBucket,
        window: UsageLimitWindow,
        timestamp: Int64,
        usedPercent: Int,
        consumedPercentAdjustment: Double,
        resetAt: Int64?
    ) throws {
        let periodStart = periodStart(for: timestamp, granularity: granularity)
        let statement = try prepare(
            """
            INSERT INTO usage_rollups (
                granularity, bucket_id, bucket_name, bucket_kind, window, period_start,
                sample_timestamp, used_percent, peak_used_percent, consumed_percent, reset_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(granularity, bucket_id, window, period_start) DO UPDATE SET
                bucket_name = excluded.bucket_name,
                bucket_kind = excluded.bucket_kind,
                sample_timestamp = CASE
                    WHEN excluded.sample_timestamp >= usage_rollups.sample_timestamp
                    THEN excluded.sample_timestamp
                    ELSE usage_rollups.sample_timestamp
                END,
                used_percent = CASE
                    WHEN excluded.sample_timestamp >= usage_rollups.sample_timestamp
                    THEN excluded.used_percent
                    ELSE usage_rollups.used_percent
                END,
                peak_used_percent = MAX(
                    IFNULL(usage_rollups.peak_used_percent, usage_rollups.used_percent),
                    excluded.peak_used_percent
                ),
                consumed_percent = MAX(
                    IFNULL(usage_rollups.consumed_percent, 0) + excluded.consumed_percent,
                    0
                ),
                reset_at = CASE
                    WHEN excluded.sample_timestamp >= usage_rollups.sample_timestamp
                    THEN excluded.reset_at
                    ELSE usage_rollups.reset_at
                END
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(granularity.rawValue, to: 1, in: statement)
        bindText(bucket.id, to: 2, in: statement)
        bindText(bucket.name, to: 3, in: statement)
        bindText(bucket.kind.rawValue, to: 4, in: statement)
        bindText(window.rawValue, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, periodStart)
        sqlite3_bind_int64(statement, 7, timestamp)
        sqlite3_bind_int(statement, 8, Int32(usedPercent))
        sqlite3_bind_int(statement, 9, Int32(usedPercent))
        sqlite3_bind_double(statement, 10, consumedPercentAdjustment)
        bindOptionalInt(resetAt, to: 11, in: statement)

        try step(statement)
        try upsertUsageSeriesCatalog(
            bucketID: bucket.id,
            bucketName: bucket.name,
            bucketKind: bucket.kind.rawValue,
            window: window.rawValue,
            seenAt: timestamp
        )
    }

    func upsertUsageSeriesCatalog(
        bucketID: String,
        bucketName: String,
        bucketKind: String,
        window: String,
        seenAt: Int64
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO usage_series_catalog (
                window, bucket_id, bucket_name, bucket_kind, seen_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(window, bucket_id) DO UPDATE SET
                bucket_name = CASE
                    WHEN excluded.seen_at >= usage_series_catalog.seen_at
                    THEN excluded.bucket_name
                    ELSE usage_series_catalog.bucket_name
                END,
                bucket_kind = CASE
                    WHEN excluded.seen_at >= usage_series_catalog.seen_at
                    THEN excluded.bucket_kind
                    ELSE usage_series_catalog.bucket_kind
                END,
                seen_at = MAX(usage_series_catalog.seen_at, excluded.seen_at)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(window, to: 1, in: statement)
        bindText(bucketID, to: 2, in: statement)
        bindText(bucketName, to: 3, in: statement)
        bindText(bucketKind, to: 4, in: statement)
        sqlite3_bind_int64(statement, 5, seenAt)

        try step(statement)
    }

    func observedTokenDelta(
        threadID: String,
        cumulative: CodexTokenUsageBreakdown,
        last: CodexTokenUsageBreakdown
    ) throws -> CodexTokenUsageBreakdown {
        if try hasTokenSampleAtOrAbove(threadID: threadID, cumulativeTotalTokens: cumulative.totalTokens) {
            return CodexTokenUsageBreakdown(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: 0
            )
        }

        if let previous = try previousCumulativeTokenUsage(
            threadID: threadID,
            before: cumulative.totalTokens
        ) {
            return CodexTokenUsageBreakdown(
                inputTokens: max(cumulative.inputTokens - previous.inputTokens, 0),
                cachedInputTokens: max(cumulative.cachedInputTokens - previous.cachedInputTokens, 0),
                outputTokens: max(cumulative.outputTokens - previous.outputTokens, 0),
                reasoningOutputTokens: max(cumulative.reasoningOutputTokens - previous.reasoningOutputTokens, 0),
                totalTokens: max(cumulative.totalTokens - previous.totalTokens, 0)
            )
        }

        if try hasExpiredTokenBaseline(threadID: threadID) {
            return CodexTokenUsageBreakdown(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: 0
            )
        }

        return CodexTokenUsageBreakdown(
            inputTokens: max(last.inputTokens, 0),
            cachedInputTokens: max(last.cachedInputTokens, 0),
            outputTokens: max(last.outputTokens, 0),
            reasoningOutputTokens: max(last.reasoningOutputTokens, 0),
            totalTokens: max(last.totalTokens, 0)
        )
    }

    private func hasExpiredTokenBaseline(threadID: String) throws -> Bool {
        let statement = try prepare(
            "SELECT EXISTS(SELECT 1 FROM token_expired_baselines WHERE thread_id = ? LIMIT 1)"
        )
        defer { sqlite3_finalize(statement) }
        bindText(threadID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    func hasTokenSampleAtOrAbove(threadID: String, cumulativeTotalTokens: Int64) throws -> Bool {
        let statement = try prepare(
            """
            SELECT EXISTS(
                SELECT 1
                FROM token_usage_samples
                WHERE thread_id = ? AND total_total_tokens >= ?
                LIMIT 1
            )
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(threadID, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, cumulativeTotalTokens)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) != 0
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func tokenSampleExists(threadID: String, turnID: String, cumulativeTotalTokens: Int64) throws -> Bool {
        let statement = try prepare(
            """
            SELECT EXISTS(
                SELECT 1
                FROM token_usage_samples
                WHERE thread_id = ? AND turn_id = ? AND total_total_tokens = ?
                LIMIT 1
            )
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(threadID, to: 1, in: statement)
        bindText(turnID, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, cumulativeTotalTokens)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) != 0
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func previousCumulativeTokenUsage(
        threadID: String,
        before cumulativeTotalTokens: Int64
    ) throws -> CodexTokenUsageBreakdown? {
        let statement = try prepare(
            """
            SELECT total_input_tokens, total_cached_input_tokens, total_output_tokens,
                total_reasoning_output_tokens, total_total_tokens
            FROM token_usage_samples
            WHERE thread_id = ? AND total_total_tokens < ?
            ORDER BY total_total_tokens DESC
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(threadID, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, cumulativeTotalTokens)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return CodexTokenUsageBreakdown(
                inputTokens: sqlite3_column_int64(statement, 0),
                cachedInputTokens: sqlite3_column_int64(statement, 1),
                outputTokens: sqlite3_column_int64(statement, 2),
                reasoningOutputTokens: sqlite3_column_int64(statement, 3),
                totalTokens: sqlite3_column_int64(statement, 4)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func insertTokenUsageSample(
        notification: CodexTokenUsageNotification,
        timestamp: Int64,
        observedTokens: CodexTokenUsageBreakdown,
        context: TokenUsageContext? = nil
    ) throws {
        let normalizedModel = normalizedModelName(notification.model)
        let normalizedContext = context?.hasAnyValue == true ? context : nil
        let existingState = try tokenSampleRepairState(
            threadID: notification.threadID,
            turnID: notification.turnID,
            cumulativeTotalTokens: notification.tokenUsage.total.totalTokens
        )
        let existingNormalizedModel = CodexModelIdentifier.normalized(existingState.model)
        let shouldRepairExistingModel = existingState.exists
            && normalizedModel != nil
            && (
                existingNormalizedModel == nil
                    || (existingNormalizedModel == normalizedModel && existingState.model != normalizedModel)
            )
        let shouldRepairExistingContext = existingState.exists
            && tokenContextNeedsRepair(existing: existingState.context, incoming: normalizedContext)
        let statement = try prepare(
            """
            INSERT INTO token_usage_samples (
                thread_id, turn_id, model, session_id, project_path, project_name,
                effort, source, received_at, model_context_window,
                last_input_tokens, last_cached_input_tokens, last_output_tokens,
                last_reasoning_output_tokens, last_total_tokens,
                total_input_tokens, total_cached_input_tokens, total_output_tokens,
                total_reasoning_output_tokens, total_total_tokens,
                observed_input_tokens, observed_cached_input_tokens, observed_output_tokens,
                observed_reasoning_output_tokens, observed_total_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, turn_id, total_total_tokens) DO UPDATE SET
                model = CASE
                    WHEN NULLIF(TRIM(token_usage_samples.model, char(9) || char(10) || char(13) || ' '), '') IS NULL
                        THEN excluded.model
                    ELSE token_usage_samples.model
                END,
                session_id = CASE
                    WHEN NULLIF(TRIM(token_usage_samples.session_id, char(9) || char(10) || char(13) || ' '), '') IS NULL
                        THEN excluded.session_id
                    ELSE token_usage_samples.session_id
                END,
                project_path = CASE
                    WHEN NULLIF(TRIM(token_usage_samples.project_path, char(9) || char(10) || char(13) || ' '), '') IS NULL
                        THEN excluded.project_path
                    ELSE token_usage_samples.project_path
                END,
                project_name = CASE
                    WHEN NULLIF(TRIM(token_usage_samples.project_name, char(9) || char(10) || char(13) || ' '), '') IS NULL
                        THEN excluded.project_name
                    ELSE token_usage_samples.project_name
                END,
                effort = CASE
                    WHEN NULLIF(TRIM(token_usage_samples.effort, char(9) || char(10) || char(13) || ' '), '') IS NULL
                        THEN excluded.effort
                    ELSE token_usage_samples.effort
                END,
                source = CASE
                    WHEN NULLIF(TRIM(token_usage_samples.source, char(9) || char(10) || char(13) || ' '), '') IS NULL
                        THEN excluded.source
                    ELSE token_usage_samples.source
                END,
                received_at = excluded.received_at,
                model_context_window = excluded.model_context_window,
                last_input_tokens = excluded.last_input_tokens,
                last_cached_input_tokens = excluded.last_cached_input_tokens,
                last_output_tokens = excluded.last_output_tokens,
                last_reasoning_output_tokens = excluded.last_reasoning_output_tokens,
                last_total_tokens = excluded.last_total_tokens,
                total_input_tokens = excluded.total_input_tokens,
                total_cached_input_tokens = excluded.total_cached_input_tokens,
                total_output_tokens = excluded.total_output_tokens,
                total_reasoning_output_tokens = excluded.total_reasoning_output_tokens,
                observed_input_tokens = token_usage_samples.observed_input_tokens,
                observed_cached_input_tokens = token_usage_samples.observed_cached_input_tokens,
                observed_output_tokens = token_usage_samples.observed_output_tokens,
                observed_reasoning_output_tokens = token_usage_samples.observed_reasoning_output_tokens,
                observed_total_tokens = token_usage_samples.observed_total_tokens
            """
        )
        defer { sqlite3_finalize(statement) }

        let last = notification.tokenUsage.last
        let total = notification.tokenUsage.total

        bindText(notification.threadID, to: 1, in: statement)
        bindText(notification.turnID, to: 2, in: statement)
        bindOptionalText(normalizedModel, to: 3, in: statement)
        bindOptionalText(normalizedContext?.sessionID, to: 4, in: statement)
        bindOptionalText(normalizedContext?.projectPath, to: 5, in: statement)
        bindOptionalText(normalizedContext?.projectName, to: 6, in: statement)
        bindOptionalText(normalizedContext?.effort, to: 7, in: statement)
        bindOptionalText(normalizedContext?.source, to: 8, in: statement)
        sqlite3_bind_int64(statement, 9, timestamp)
        bindOptionalInt(notification.tokenUsage.modelContextWindow, to: 10, in: statement)
        sqlite3_bind_int64(statement, 11, last.inputTokens)
        sqlite3_bind_int64(statement, 12, last.cachedInputTokens)
        sqlite3_bind_int64(statement, 13, last.outputTokens)
        sqlite3_bind_int64(statement, 14, last.reasoningOutputTokens)
        sqlite3_bind_int64(statement, 15, last.totalTokens)
        sqlite3_bind_int64(statement, 16, total.inputTokens)
        sqlite3_bind_int64(statement, 17, total.cachedInputTokens)
        sqlite3_bind_int64(statement, 18, total.outputTokens)
        sqlite3_bind_int64(statement, 19, total.reasoningOutputTokens)
        sqlite3_bind_int64(statement, 20, total.totalTokens)
        sqlite3_bind_int64(statement, 21, observedTokens.inputTokens)
        sqlite3_bind_int64(statement, 22, observedTokens.cachedInputTokens)
        sqlite3_bind_int64(statement, 23, observedTokens.outputTokens)
        sqlite3_bind_int64(statement, 24, observedTokens.reasoningOutputTokens)
        sqlite3_bind_int64(statement, 25, observedTokens.totalTokens)

        try step(statement)
        let didRepairExistingModel: Bool
        if shouldRepairExistingModel {
            didRepairExistingModel = try repairTokenSampleModelIfNeeded(
                threadID: notification.threadID,
                turnID: notification.turnID,
                cumulativeTotalTokens: notification.tokenUsage.total.totalTokens,
                model: normalizedModel
            )
        } else {
            didRepairExistingModel = false
        }
        let didRepairExistingContext: Bool
        if shouldRepairExistingContext {
            didRepairExistingContext = try repairTokenSampleContextIfNeeded(
                threadID: notification.threadID,
                turnID: notification.turnID,
                cumulativeTotalTokens: notification.tokenUsage.total.totalTokens,
                context: normalizedContext
            )
        } else {
            didRepairExistingContext = false
        }
        try upsertTokenSeriesCatalog(
            model: normalizedModel,
            seenAt: timestamp,
            observedTokens: observedTokens
        )
        try upsertTokenContextCatalog(context: normalizedContext, seenAt: timestamp, observedTokens: observedTokens)
        _ = try upsertTokenUsageDimensions(
            notification: notification,
            context: normalizedContext,
            seenAt: timestamp
        )
        if didRepairExistingModel || shouldRepairExistingModel {
            try rebuildTokenSeriesCatalog()
        }
        if didRepairExistingContext || shouldRepairExistingContext {
            try rebuildTokenContextCatalogs()
        }
    }

    func tokenSampleRepairState(
        threadID: String,
        turnID: String,
        cumulativeTotalTokens: Int64
    ) throws -> (exists: Bool, model: String?, context: TokenUsageContext?) {
        let statement = try prepare(
            """
            SELECT model, session_id, project_path, effort, source
            FROM token_usage_samples
            WHERE thread_id = ? AND turn_id = ? AND total_total_tokens = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(threadID, to: 1, in: statement)
        bindText(turnID, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, cumulativeTotalTokens)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return (
                true,
                optionalColumnText(statement, index: 0),
                TokenUsageContext(
                    sessionID: optionalColumnText(statement, index: 1),
                    projectPath: optionalColumnText(statement, index: 2),
                    effort: optionalColumnText(statement, index: 3),
                    source: optionalColumnText(statement, index: 4)
                )
            )
        case SQLITE_DONE:
            return (false, nil, nil)
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func repairTokenSampleModelIfNeeded(
        threadID: String,
        turnID: String,
        cumulativeTotalTokens: Int64,
        model: String?
    ) throws -> Bool {
        guard let normalizedModel = CodexModelIdentifier.normalized(model) else {
            return false
        }

        let existingState = try tokenSampleRepairState(
            threadID: threadID,
            turnID: turnID,
            cumulativeTotalTokens: cumulativeTotalTokens
        )
        let existingNormalizedModel = CodexModelIdentifier.normalized(existingState.model)
        guard existingNormalizedModel == nil || existingNormalizedModel == normalizedModel else {
            return false
        }
        guard existingState.model != normalizedModel else {
            return false
        }

        let statement = try prepare(
            """
            UPDATE token_usage_samples
            SET model = ?
            WHERE thread_id = ?
                AND turn_id = ?
                AND total_total_tokens = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(normalizedModel, to: 1, in: statement)
        bindText(threadID, to: 2, in: statement)
        bindText(turnID, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, cumulativeTotalTokens)

        try step(statement)
        return sqlite3_changes(database) > 0
    }

    func repairTokenSampleContextIfNeeded(
        threadID: String,
        turnID: String,
        cumulativeTotalTokens: Int64,
        context: TokenUsageContext?
    ) throws -> Bool {
        guard let context, context.hasAnyValue else {
            return false
        }

        let existingState = try tokenSampleRepairState(
            threadID: threadID,
            turnID: turnID,
            cumulativeTotalTokens: cumulativeTotalTokens
        )
        guard existingState.exists,
              tokenContextNeedsRepair(existing: existingState.context, incoming: context)
        else {
            return false
        }
        let repairedContext = TokenUsageContext(
            sessionID: existingState.context?.sessionID ?? context.sessionID,
            projectPath: existingState.context?.projectPath ?? context.projectPath,
            effort: existingState.context?.effort ?? context.effort,
            source: existingState.context?.source ?? context.source
        )

        let statement = try prepare(
            """
            UPDATE token_usage_samples
            SET session_id = ?,
                project_path = ?,
                project_name = ?,
                effort = ?,
                source = ?
            WHERE thread_id = ?
                AND turn_id = ?
                AND total_total_tokens = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        bindOptionalText(repairedContext.sessionID, to: 1, in: statement)
        bindOptionalText(repairedContext.projectPath, to: 2, in: statement)
        bindOptionalText(repairedContext.projectName, to: 3, in: statement)
        bindOptionalText(repairedContext.effort, to: 4, in: statement)
        bindOptionalText(repairedContext.source, to: 5, in: statement)
        bindText(threadID, to: 6, in: statement)
        bindText(turnID, to: 7, in: statement)
        sqlite3_bind_int64(statement, 8, cumulativeTotalTokens)

        try step(statement)
        return sqlite3_changes(database) > 0
    }

    func tokenContextNeedsRepair(existing: TokenUsageContext?, incoming: TokenUsageContext?) -> Bool {
        guard let incoming, incoming.hasAnyValue else {
            return false
        }

        return (existing?.sessionID == nil && incoming.sessionID != nil)
            || (existing?.projectPath == nil && incoming.projectPath != nil)
            || (existing?.projectName == nil && incoming.projectName != nil)
            || (existing?.effort == nil && incoming.effort != nil)
            || (existing?.source == nil && incoming.source != nil)
    }

    func updateStoredTokenModel(from rawModel: String, to normalizedModel: String?) throws {
        let statement: OpaquePointer
        if let normalizedModel {
            statement = try prepare(
                """
                UPDATE token_usage_samples
                SET model = ?
                WHERE model = ?
                """
            )
            bindText(normalizedModel, to: 1, in: statement)
            bindText(rawModel, to: 2, in: statement)
        } else {
            statement = try prepare(
                """
                UPDATE token_usage_samples
                SET model = NULL
                WHERE model = ?
                """
            )
            bindText(rawModel, to: 1, in: statement)
        }
        defer { sqlite3_finalize(statement) }

        try step(statement)
    }

    @discardableResult
    func upsertTokenUsageDimensions(
        notification: CodexTokenUsageNotification,
        context: TokenUsageContext?,
        seenAt: Int64
    ) throws -> Int {
        let dimensions = TokenUsageDimension.unique(notification.dimensions + (context?.dimensions ?? []))
        guard !dimensions.isEmpty else {
            return 0
        }

        var insertedCount = 0
        let writesLegacyDimensions = try tableExists(table: "token_usage_dimensions")
        for dimension in dimensions {
            if writesLegacyDimensions {
                if try insertTokenUsageDimension(
                    threadID: notification.threadID,
                    turnID: notification.turnID,
                    totalTotalTokens: notification.tokenUsage.total.totalTokens,
                    dimension: dimension,
                    seenAt: seenAt
                ) {
                    insertedCount += 1
                }
            }
            try upsertTokenDimensionCatalog(dimension: dimension, seenAt: seenAt)
        }
        try assignTokenDimensionSet(
            dimensions: dimensions,
            threadID: notification.threadID,
            turnID: notification.turnID,
            totalTotalTokens: notification.tokenUsage.total.totalTokens,
            seenAt: seenAt
        )

        return insertedCount
    }

    func assignTokenDimensionSet(
        dimensions: [TokenUsageDimension],
        threadID: String,
        turnID: String,
        totalTotalTokens: Int64,
        seenAt: Int64
    ) throws {
        let dimensions = TokenUsageDimension.unique(dimensions)
        guard !dimensions.isEmpty else {
            return
        }

        let valueIDs = try dimensions.map { dimension in
            try upsertTokenDimensionValue(dimension, seenAt: seenAt)
        }.sorted()
        let signature = try JSONEncoder().encode(valueIDs)
        let setID = try upsertTokenDimensionSet(signature: signature, valueIDs: valueIDs)

        let statement = try prepare(
            """
            UPDATE token_usage_samples
            SET dimension_set_id = ?
            WHERE thread_id = ? AND turn_id = ? AND total_total_tokens = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, setID)
        bindText(threadID, to: 2, in: statement)
        bindText(turnID, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, totalTotalTokens)
        try step(statement)
    }

    private func upsertTokenDimensionValue(
        _ dimension: TokenUsageDimension,
        seenAt: Int64
    ) throws -> Int64 {
        let insert = try prepare(
            """
            INSERT INTO token_dimension_values (
                dimension_key, dimension_value, first_seen_at, last_seen_at
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(dimension_key, dimension_value) DO UPDATE SET
                first_seen_at = MIN(first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(last_seen_at, excluded.last_seen_at)
            """
        )
        bindText(dimension.key.rawValue, to: 1, in: insert)
        bindText(dimension.value, to: 2, in: insert)
        sqlite3_bind_int64(insert, 3, seenAt)
        sqlite3_bind_int64(insert, 4, seenAt)
        try step(insert)
        sqlite3_finalize(insert)

        let select = try prepare(
            "SELECT value_id FROM token_dimension_values WHERE dimension_key = ? AND dimension_value = ?"
        )
        defer { sqlite3_finalize(select) }
        bindText(dimension.key.rawValue, to: 1, in: select)
        bindText(dimension.value, to: 2, in: select)
        guard sqlite3_step(select) == SQLITE_ROW else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
        return sqlite3_column_int64(select, 0)
    }

    private func upsertTokenDimensionSet(signature: Data, valueIDs: [Int64]) throws -> Int64 {
        let insert = try prepare("INSERT OR IGNORE INTO token_dimension_sets(signature) VALUES (?)")
        _ = signature.withUnsafeBytes { bytes in
            sqlite3_bind_blob(insert, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
        try step(insert)
        sqlite3_finalize(insert)

        let select = try prepare("SELECT set_id FROM token_dimension_sets WHERE signature = ?")
        _ = signature.withUnsafeBytes { bytes in
            sqlite3_bind_blob(select, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(select) == SQLITE_ROW else {
            sqlite3_finalize(select)
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
        let setID = sqlite3_column_int64(select, 0)
        sqlite3_finalize(select)

        let memberInsert = try prepare(
            "INSERT OR IGNORE INTO token_dimension_set_members(set_id, value_id) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(memberInsert) }
        for valueID in valueIDs {
            sqlite3_reset(memberInsert)
            sqlite3_clear_bindings(memberInsert)
            sqlite3_bind_int64(memberInsert, 1, setID)
            sqlite3_bind_int64(memberInsert, 2, valueID)
            try step(memberInsert)
        }
        return setID
    }

    /// Backfills at most `sampleLimit` retained samples and persists the rowid cursor in the same
    /// transaction. Returns true when another chunk may remain.
    func backfillNextTokenDimensionSetChunk(sampleLimit: Int = 500) throws -> Bool {
        struct BackfillSample {
            let rowID: Int64
            let threadID: String
            let turnID: String
            let totalTotalTokens: Int64
            let seenAt: Int64
            var dimensions: [TokenUsageDimension]
        }

        var samplesByRowID = [Int64: BackfillSample]()
        let statement = try prepare(
            """
            WITH selected_samples AS (
                SELECT rowid, thread_id, turn_id, total_total_tokens, received_at
                FROM token_usage_samples
                WHERE dimension_set_id IS NULL
                  AND is_retention_baseline = 0
                  AND EXISTS (
                      SELECT 1 FROM token_usage_dimensions AS legacy
                      WHERE legacy.thread_id = token_usage_samples.thread_id
                        AND legacy.turn_id = token_usage_samples.turn_id
                        AND legacy.total_total_tokens = token_usage_samples.total_total_tokens
                  )
                ORDER BY rowid
                LIMIT ?
            )
            SELECT selected.rowid, selected.thread_id, selected.turn_id,
                selected.total_total_tokens, selected.received_at,
                legacy.dimension_key, legacy.dimension_value
            FROM selected_samples AS selected
            JOIN token_usage_dimensions AS legacy
              ON legacy.thread_id = selected.thread_id
             AND legacy.turn_id = selected.turn_id
             AND legacy.total_total_tokens = selected.total_total_tokens
            ORDER BY selected.rowid, legacy.dimension_key, legacy.dimension_value
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(sampleLimit, 1)))
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            guard let key = TokenUsageDimensionKey(rawValue: columnText(statement, index: 5)),
                  let dimension = TokenUsageDimension(key, columnText(statement, index: 6))
            else {
                continue
            }
            var sample = samplesByRowID[rowID] ?? BackfillSample(
                rowID: rowID,
                threadID: columnText(statement, index: 1),
                turnID: columnText(statement, index: 2),
                totalTotalTokens: sqlite3_column_int64(statement, 3),
                seenAt: sqlite3_column_int64(statement, 4),
                dimensions: []
            )
            sample.dimensions.append(dimension)
            samplesByRowID[rowID] = sample
        }

        let orderedSamples = samplesByRowID.values.sorted { $0.rowID < $1.rowID }
        guard !orderedSamples.isEmpty else {
            return false
        }
        try transaction {
            for sample in orderedSamples {
                try assignTokenDimensionSet(
                    dimensions: sample.dimensions,
                    threadID: sample.threadID,
                    turnID: sample.turnID,
                    totalTotalTokens: sample.totalTotalTokens,
                    seenAt: sample.seenAt
                )
            }
            if let cursor = orderedSamples.last?.rowID {
                try setMetadataValue(String(cursor), for: "token_dimension_v3_backfill_cursor")
            }
        }
        return orderedSamples.count >= max(sampleLimit, 1)
    }

    @discardableResult
    func insertTokenUsageDimension(
        threadID: String,
        turnID: String,
        totalTotalTokens: Int64,
        dimension: TokenUsageDimension,
        seenAt: Int64
    ) throws -> Bool {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO token_usage_dimensions (
                thread_id, turn_id, total_total_tokens, dimension_key, dimension_value, seen_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(threadID, to: 1, in: statement)
        bindText(turnID, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, totalTotalTokens)
        bindText(dimension.key.rawValue, to: 4, in: statement)
        bindText(dimension.value, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, seenAt)

        try step(statement)
        return sqlite3_changes(database) > 0
    }

    func deleteTokenUsageDimension(rowID: Int64) throws {
        let statement = try prepare(
            """
            DELETE FROM token_usage_dimensions
            WHERE rowid = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, rowID)
        try step(statement)
    }

    func upsertTokenDimensionCatalog(dimension: TokenUsageDimension, seenAt: Int64) throws {
        let statement = try prepare(
            """
            INSERT INTO token_dimension_catalog (
                dimension_key, dimension_value, first_seen_at, last_seen_at
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(dimension_key, dimension_value) DO UPDATE SET
                first_seen_at = MIN(token_dimension_catalog.first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(token_dimension_catalog.last_seen_at, excluded.last_seen_at)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(dimension.key.rawValue, to: 1, in: statement)
        bindText(dimension.value, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, seenAt)
        sqlite3_bind_int64(statement, 4, seenAt)
        try step(statement)
    }

    func upsertTokenSeriesCatalog(
        model: String?,
        seenAt: Int64,
        observedTokens: CodexTokenUsageBreakdown
    ) throws {
        let normalizedModel = CodexModelIdentifier.normalized(model)
        let hasComponentTotal = observedTokens.inputTokens > 0
            || observedTokens.cachedInputTokens > 0
            || observedTokens.outputTokens > 0
            || observedTokens.reasoningOutputTokens > 0
        guard observedTokens.totalTokens > 0 || hasComponentTotal else {
            return
        }

        try upsertTokenSeriesCatalogRow(
            seriesID: "tokens_all",
            seriesName: "All tokens",
            seriesKind: "aggregate",
            seenAt: seenAt,
            hasTotal: hasComponentTotal,
            hasInput: observedTokens.inputTokens > 0,
            hasCached: observedTokens.cachedInputTokens > 0,
            hasOutput: observedTokens.outputTokens > 0,
            hasReasoning: observedTokens.reasoningOutputTokens > 0
        )

        if let normalizedModel {
            try upsertTokenSeriesCatalogRow(
                seriesID: "model:\(normalizedModel)",
                seriesName: normalizedModel,
                seriesKind: "model",
                seenAt: seenAt,
                hasTotal: hasComponentTotal,
                hasInput: observedTokens.inputTokens > 0,
                hasCached: observedTokens.cachedInputTokens > 0,
                hasOutput: observedTokens.outputTokens > 0,
                hasReasoning: observedTokens.reasoningOutputTokens > 0
            )
        } else if observedTokens.inputTokens > 0
                    || observedTokens.cachedInputTokens > 0
                    || observedTokens.outputTokens > 0
                    || observedTokens.reasoningOutputTokens > 0 {
            try upsertTokenSeriesCatalogRow(
                seriesID: TokenDashboardSeries.unattributedID,
                seriesName: "Unattributed",
                seriesKind: "unattributed",
                seenAt: seenAt,
                hasTotal: hasComponentTotal,
                hasInput: observedTokens.inputTokens > 0,
                hasCached: observedTokens.cachedInputTokens > 0,
                hasOutput: observedTokens.outputTokens > 0,
                hasReasoning: observedTokens.reasoningOutputTokens > 0
            )
        }
    }

    func upsertTokenContextCatalog(
        context: TokenUsageContext?,
        seenAt: Int64,
        observedTokens: CodexTokenUsageBreakdown
    ) throws {
        guard let context, context.hasAnyValue else {
            return
        }
        guard observedTokens.totalTokens > 0
                || observedTokens.inputTokens > 0
                || observedTokens.cachedInputTokens > 0
                || observedTokens.outputTokens > 0
                || observedTokens.reasoningOutputTokens > 0
        else {
            return
        }

        if let projectPath = context.projectPath, let projectName = context.projectName {
            try upsertTokenProjectCatalog(projectPath: projectPath, projectName: projectName, seenAt: seenAt)
        }
        if let effort = context.effort {
            try upsertTokenDimensionCatalog(table: "token_effort_catalog", column: "effort", value: effort, seenAt: seenAt)
        }
        if let source = context.source {
            try upsertTokenDimensionCatalog(table: "token_source_catalog", column: "source", value: source, seenAt: seenAt)
        }
    }

    func upsertTokenProjectCatalog(projectPath: String, projectName: String, seenAt: Int64) throws {
        let statement = try prepare(
            """
            INSERT INTO token_project_catalog (
                project_path, project_name, first_seen_at, last_seen_at
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(project_path) DO UPDATE SET
                project_name = excluded.project_name,
                first_seen_at = MIN(token_project_catalog.first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(token_project_catalog.last_seen_at, excluded.last_seen_at)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(projectPath, to: 1, in: statement)
        bindText(projectName, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, seenAt)
        sqlite3_bind_int64(statement, 4, seenAt)
        try step(statement)
    }

    func upsertTokenDimensionCatalog(table: String, column: String, value: String, seenAt: Int64) throws {
        let statement = try prepare(
            """
            INSERT INTO \(table) (
                \(column), first_seen_at, last_seen_at
            ) VALUES (?, ?, ?)
            ON CONFLICT(\(column)) DO UPDATE SET
                first_seen_at = MIN(\(table).first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(\(table).last_seen_at, excluded.last_seen_at)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(value, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, seenAt)
        sqlite3_bind_int64(statement, 3, seenAt)
        try step(statement)
    }

    func upsertTokenSeriesCatalogRow(
        seriesID: String,
        seriesName: String,
        seriesKind: String,
        seenAt: Int64,
        hasTotal: Bool,
        hasInput: Bool,
        hasCached: Bool,
        hasOutput: Bool,
        hasReasoning: Bool
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO token_series_catalog (
                series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(series_id) DO UPDATE SET
                series_name = CASE
                    WHEN excluded.seen_at >= token_series_catalog.seen_at
                    THEN excluded.series_name
                    ELSE token_series_catalog.series_name
                END,
                series_kind = excluded.series_kind,
                seen_at = MAX(token_series_catalog.seen_at, excluded.seen_at),
                has_total = MAX(token_series_catalog.has_total, excluded.has_total),
                has_input = MAX(token_series_catalog.has_input, excluded.has_input),
                has_cached = MAX(token_series_catalog.has_cached, excluded.has_cached),
                has_output = MAX(token_series_catalog.has_output, excluded.has_output),
                has_reasoning = MAX(token_series_catalog.has_reasoning, excluded.has_reasoning)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(seriesID, to: 1, in: statement)
        bindText(seriesName, to: 2, in: statement)
        bindText(seriesKind, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, seenAt)
        sqlite3_bind_int(statement, 5, hasTotal ? 1 : 0)
        sqlite3_bind_int(statement, 6, hasInput ? 1 : 0)
        sqlite3_bind_int(statement, 7, hasCached ? 1 : 0)
        sqlite3_bind_int(statement, 8, hasOutput ? 1 : 0)
        sqlite3_bind_int(statement, 9, hasReasoning ? 1 : 0)

        try step(statement)
    }

    func tokenValueExpression(for category: TokenHistoryCategory) -> String {
        switch category {
        case .total:
            return """
            (
                IFNULL(observed_input_tokens, 0)
                + IFNULL(observed_cached_input_tokens, 0)
                + IFNULL(observed_output_tokens, 0)
                + IFNULL(observed_reasoning_output_tokens, 0)
            )
            """
        case .input:
            return "IFNULL(observed_input_tokens, last_input_tokens)"
        case .cached:
            return "IFNULL(observed_cached_input_tokens, last_cached_input_tokens)"
        case .output:
            return "IFNULL(observed_output_tokens, last_output_tokens)"
        case .reasoning:
            return "IFNULL(observed_reasoning_output_tokens, last_reasoning_output_tokens)"
        }
    }

    func tokenSeriesCatalogFlagColumn(for category: TokenHistoryCategory) -> String {
        switch category {
        case .total:
            return "has_total"
        case .input:
            return "has_input"
        case .cached:
            return "has_cached"
        case .output:
            return "has_output"
        case .reasoning:
            return "has_reasoning"
        }
    }
}
