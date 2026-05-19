import Foundation
import SQLite3

extension UsageHistoryStore {
    func record(snapshot: CodexUsageSnapshot, at date: Date) throws {
        let timestamp = Self.roundedToMinute(date).timeIntervalSince1970Int

        try transaction {
            for bucket in snapshot.bucketsForRecording {
                try record(bucket: bucket, window: .fiveHour, timestamp: timestamp)
                try record(bucket: bucket, window: .sevenDay, timestamp: timestamp)
            }

            try compactRawSamples(
                olderThan: Date(timeIntervalSince1970: TimeInterval(timestamp)).addingTimeInterval(-rawRetentionProvider())
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

    func importTokenUsageSamples(_ samples: [ImportedCodexTokenUsageSample]) throws -> TokenUsageImportResult {
        var insertedCount = 0
        var duplicateCount = 0
        var repairedModelCount = 0
        var repairedContextCount = 0

        try transaction {
            for sample in samples {
                let notification = sample.notification
                let cumulativeTotal = notification.tokenUsage.total.totalTokens

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
                        context: sample.context
                    ) {
                        repairedContextCount += 1
                    }

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
                    timestamp: Self.roundedToSecond(sample.receivedAt).timeIntervalSince1970Int,
                    observedTokens: observedTokens,
                    context: sample.context
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

        if insertedCount > 0 || repairedModelCount > 0 || repairedContextCount > 0 {
            notificationCenter.post(name: Self.didChangeNotification, object: self)
        }

        return TokenUsageImportResult(
            insertedCount: insertedCount,
            duplicateCount: duplicateCount,
            repairedModelCount: repairedModelCount,
            repairedContextCount: repairedContextCount
        )
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

        return CodexTokenUsageBreakdown(
            inputTokens: max(last.inputTokens, 0),
            cachedInputTokens: max(last.cachedInputTokens, 0),
            outputTokens: max(last.outputTokens, 0),
            reasoningOutputTokens: max(last.reasoningOutputTokens, 0),
            totalTokens: max(last.totalTokens, 0)
        )
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

    func upsertTokenSeriesCatalog(
        model: String?,
        seenAt: Int64,
        observedTokens: CodexTokenUsageBreakdown
    ) throws {
        let normalizedModel = CodexModelIdentifier.normalized(model)
        guard observedTokens.totalTokens > 0
                || observedTokens.inputTokens > 0
                || observedTokens.cachedInputTokens > 0
                || observedTokens.outputTokens > 0
                || observedTokens.reasoningOutputTokens > 0
        else {
            return
        }

        try upsertTokenSeriesCatalogRow(
            seriesID: "tokens_all",
            seriesName: "All tokens",
            seriesKind: "aggregate",
            seenAt: seenAt,
            hasTotal: observedTokens.totalTokens > 0,
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
                hasTotal: observedTokens.totalTokens > 0,
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
                hasTotal: false,
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
            return "observed_total_tokens"
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

extension CodexRateLimitSnapshot {
    func window(for usageWindow: UsageLimitWindow) -> CodexRateLimitWindow? {
        switch usageWindow {
        case .fiveHour:
            return primary
        case .sevenDay:
            return secondary
        }
    }
}
