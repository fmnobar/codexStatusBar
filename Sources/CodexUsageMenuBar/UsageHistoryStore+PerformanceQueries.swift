import Foundation
import SQLite3

extension UsageHistoryStore {
    func performanceDashboardTimingSamples(
        periodStart: Date,
        periodEnd: Date
    ) throws -> [PerformanceDashboardTimingSample] {
        let statement = try prepare(
            """
            SELECT event_timestamp,
                session_id, turn_id, started_at, completed_at, duration_ms,
                time_to_first_token_ms, model, project_path, project_name,
                effort, source
            FROM codex_session_task_timing_events
            WHERE event_timestamp >= ?
              AND event_timestamp < ?
            ORDER BY event_timestamp ASC, session_id ASC, turn_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, periodStart.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, periodEnd.timeIntervalSince1970Int)

        var samples: [PerformanceDashboardTimingSample] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                samples.append(
                    PerformanceDashboardTimingSample(
                        eventTimestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                        sessionID: columnText(statement, index: 1),
                        turnID: columnText(statement, index: 2),
                        startedAt: optionalColumnDate(statement, index: 3),
                        completedAt: optionalColumnDate(statement, index: 4),
                        durationMilliseconds: optionalColumnInt(statement, index: 5),
                        timeToFirstTokenMilliseconds: optionalColumnInt(statement, index: 6),
                        model: optionalColumnText(statement, index: 7),
                        projectPath: optionalColumnText(statement, index: 8),
                        projectName: optionalColumnText(statement, index: 9),
                        effort: optionalColumnText(statement, index: 10),
                        source: optionalColumnText(statement, index: 11)
                    )
                )
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }

        return samples
    }

    func performanceDashboardReliabilitySamples(
        periodStart: Date,
        periodEnd: Date
    ) throws -> [PerformanceDashboardReliabilitySample] {
        let statement = try prepare(
            """
            SELECT event_timestamp, source_key, source_row_id, success, error_summary,
                model, project_path, project_name, effort, source, transport,
                wire_api, api_path
            FROM codex_turn_performance_events
            WHERE event_timestamp >= ?
              AND event_timestamp < ?
            ORDER BY event_timestamp ASC, source_key ASC, source_row_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, periodStart.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, periodEnd.timeIntervalSince1970Int)

        var samples: [PerformanceDashboardReliabilitySample] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                samples.append(
                    PerformanceDashboardReliabilitySample(
                        eventTimestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                        sourceKey: columnText(statement, index: 1),
                        sourceRowID: sqlite3_column_int64(statement, 2),
                        success: optionalColumnBool(statement, index: 3),
                        errorSummary: optionalColumnText(statement, index: 4),
                        model: optionalColumnText(statement, index: 5),
                        projectPath: optionalColumnText(statement, index: 6),
                        projectName: optionalColumnText(statement, index: 7),
                        effort: optionalColumnText(statement, index: 8),
                        source: optionalColumnText(statement, index: 9),
                        transport: optionalColumnText(statement, index: 10),
                        wireAPI: optionalColumnText(statement, index: 11),
                        apiPath: optionalColumnText(statement, index: 12)
                    )
                )
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }

        return samples
    }

    func performanceDashboardEfficiencyTokenSamples(
        periodStart: Date,
        periodEnd: Date
    ) throws -> [PerformanceDashboardEfficiencyTokenSample] {
        let statement = try prepare(
            """
            SELECT received_at, model, project_path, project_name, effort, source,
                model_context_window, observed_input_tokens, observed_cached_input_tokens,
                observed_output_tokens, observed_reasoning_output_tokens
            FROM token_usage_query_samples
            WHERE received_at >= ?
              AND received_at < ?
              AND (
                \(Self.observedTokenComponentsPredicate)
              )
            ORDER BY received_at ASC, thread_id ASC, turn_id ASC, total_total_tokens ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, periodStart.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, periodEnd.timeIntervalSince1970Int)

        var samples: [PerformanceDashboardEfficiencyTokenSample] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                samples.append(
                    PerformanceDashboardEfficiencyTokenSample(
                        eventTimestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                        model: optionalColumnText(statement, index: 1),
                        projectPath: optionalColumnText(statement, index: 2),
                        projectName: optionalColumnText(statement, index: 3),
                        effort: optionalColumnText(statement, index: 4),
                        source: optionalColumnText(statement, index: 5),
                        modelContextWindow: optionalColumnInt(statement, index: 6),
                        inputTokens: max(sqlite3_column_int64(statement, 7), 0),
                        cachedInputTokens: max(sqlite3_column_int64(statement, 8), 0),
                        outputTokens: max(sqlite3_column_int64(statement, 9), 0),
                        reasoningOutputTokens: max(sqlite3_column_int64(statement, 10), 0)
                    )
                )
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }

        return samples
    }

    func performanceDashboardPresentation(
        breakdownDimension: PerformanceDashboardBreakdownDimension,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar
    ) throws -> PerformanceDashboardPresentation {
        let durationPoints = try performanceDashboardDurationPoints(
            breakdownDimension: breakdownDimension,
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )
        let reliabilityPoints = try performanceDashboardReliabilityPoints(
            breakdownDimension: breakdownDimension,
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )
        let rows = Self.performanceDashboardRows(
            durationPoints: durationPoints,
            reliabilityPoints: reliabilityPoints
        )

        return PerformanceDashboardPresentation(
            durationPoints: durationPoints,
            reliabilityPoints: reliabilityPoints,
            breakdownRows: rows,
            series: rows.map(\.series)
        )
    }

    func performanceDashboardEfficiencyPresentation(
        breakdownDimension requestedBreakdownDimension: PerformanceDashboardBreakdownDimension,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar
    ) throws -> PerformanceDashboardEfficiencyPresentation {
        let breakdownDimension = requestedBreakdownDimension.isSupportedByEfficiencyDashboard
            ? requestedBreakdownDimension
            : .model
        let tokenPoints = try performanceDashboardEfficiencyTokenPoints(
            breakdownDimension: breakdownDimension,
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )
        let durationPoints = try performanceDashboardDurationPoints(
            breakdownDimension: breakdownDimension,
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )
        let reliabilityPoints = try performanceDashboardReliabilityPoints(
            breakdownDimension: breakdownDimension,
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )

        let points = Self.performanceDashboardEfficiencyPoints(
            tokenPoints: tokenPoints,
            durationPoints: durationPoints,
            reliabilityPoints: reliabilityPoints
        )
        let rows = Self.performanceDashboardEfficiencyRows(points: points)
        return PerformanceDashboardEfficiencyPresentation(
            points: points,
            rows: rows,
            series: rows.map(\.series)
        )
    }

    func performanceDashboardDurationPoints(
        breakdownDimension: PerformanceDashboardBreakdownDimension,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar
    ) throws -> [PerformanceDashboardDurationPoint] {
        let intervals = Self.performanceDashboardBucketIntervals(
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )
        guard !intervals.isEmpty else {
            return []
        }

        let bucketValuesSQL = Self.performanceDashboardBucketValuesSQL(intervals)
        let breakdown = Self.performanceDashboardBreakdownSQL(
            dimension: breakdownDimension,
            unavailableAsUnattributed: breakdownDimension == .transport || breakdownDimension == .wireAPI
        )
        let statement = try prepare(
            """
            WITH buckets(bucket_start, query_end, bucket_end) AS (
                VALUES \(bucketValuesSQL)
            ),
            timing_base AS (
                SELECT
                    b.bucket_start,
                    b.bucket_end,
                    1 AS turn_count,
                    CASE WHEN t.completed_at IS NOT NULL THEN 1 ELSE 0 END AS completed_turn_count,
                    CASE WHEN t.completed_at IS NULL THEN 1 ELSE 0 END AS incomplete_turn_count,
                    CAST(t.duration_ms AS TEXT) AS duration_values,
                    CAST(t.time_to_first_token_ms AS TEXT) AS first_token_values,
                    t.model,
                    t.project_path,
                    t.project_name,
                    t.effort,
                    t.source,
                    NULL AS transport,
                    NULL AS wire_api
                FROM buckets b
                JOIN codex_session_task_timing_events t
                    ON t.event_timestamp >= b.bucket_start
                    AND t.event_timestamp < b.query_end
                WHERE t.event_timestamp >= ?
                    AND t.event_timestamp < ?

                UNION ALL

                SELECT b.bucket_start, b.bucket_end,
                    r.sample_count, r.completed_count, r.incomplete_count,
                    r.duration_values, r.first_token_values,
                    NULLIF(r.model, ''), NULLIF(r.project_path, ''), NULLIF(r.project_name, ''),
                    NULLIF(r.effort, ''), NULLIF(r.source, ''), NULL, NULL
                FROM buckets b
                JOIN telemetry_hourly_rollups r
                    ON r.period_start >= b.bucket_start
                    AND r.period_start < b.query_end
                WHERE r.metric = 'session_timing'
                    AND r.period_start >= ?
                    AND r.period_start < ?
            ),
            expanded AS (
                SELECT
                    bucket_start,
                    bucket_end,
                    'aggregate' AS series_kind,
                    NULL AS series_value,
                    NULL AS series_project_path,
                    NULL AS series_project_name,
                    turn_count,
                    completed_turn_count,
                    incomplete_turn_count,
                    duration_values,
                    first_token_values
                FROM timing_base
                UNION ALL
                SELECT
                    bucket_start,
                    bucket_end,
                    \(breakdown.kindSQL) AS series_kind,
                    \(breakdown.valueSQL) AS series_value,
                    \(breakdown.projectPathSQL) AS series_project_path,
                    \(breakdown.projectNameSQL) AS series_project_name,
                    turn_count,
                    completed_turn_count,
                    incomplete_turn_count,
                    duration_values,
                    first_token_values
                FROM timing_base
            )
            SELECT
                bucket_start,
                bucket_end,
                series_kind,
                series_value,
                series_project_path,
                series_project_name,
                SUM(turn_count) AS turn_count,
                SUM(completed_turn_count) AS completed_turn_count,
                SUM(incomplete_turn_count) AS incomplete_turn_count,
                GROUP_CONCAT(duration_values) AS duration_values,
                GROUP_CONCAT(first_token_values) AS first_token_values
            FROM expanded
            GROUP BY
                bucket_start,
                bucket_end,
                series_kind,
                series_value,
                series_project_path,
                series_project_name
            ORDER BY bucket_start ASC, series_kind ASC, series_value ASC, series_project_path ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var bindIndex = Self.bindPerformanceDashboardBucketIntervals(intervals, in: statement)
        sqlite3_bind_int64(statement, bindIndex, periodStart.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(statement, bindIndex, periodEnd.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(statement, bindIndex, periodStart.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(statement, bindIndex, periodEnd.timeIntervalSince1970Int)

        var points: [PerformanceDashboardDurationPoint] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let series = Self.performanceDashboardSeries(
                    kindRawValue: columnText(statement, index: 2),
                    value: optionalColumnText(statement, index: 3),
                    projectPath: optionalColumnText(statement, index: 4),
                    projectName: optionalColumnText(statement, index: 5)
                )
                points.append(
                    PerformanceDashboardDurationPoint(
                        bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                        bucketEnd: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
                        series: series,
                        turnCount: Int(sqlite3_column_int64(statement, 6)),
                        completedTurnCount: Int(sqlite3_column_int64(statement, 7)),
                        incompleteTurnCount: Int(sqlite3_column_int64(statement, 8)),
                        durationValues: Self.performanceDashboardIntValues(optionalColumnText(statement, index: 9)),
                        firstTokenValues: Self.performanceDashboardIntValues(optionalColumnText(statement, index: 10))
                    )
                )
            case SQLITE_DONE:
                return points.sortedByDashboardDisplayOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func performanceDashboardReliabilityPoints(
        breakdownDimension: PerformanceDashboardBreakdownDimension,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar
    ) throws -> [PerformanceDashboardReliabilityPoint] {
        let intervals = Self.performanceDashboardBucketIntervals(
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )
        guard !intervals.isEmpty else {
            return []
        }

        let bucketValuesSQL = Self.performanceDashboardBucketValuesSQL(intervals)
        let breakdown = Self.performanceDashboardBreakdownSQL(dimension: breakdownDimension)
        var accumulators = [PerformanceDashboardBucketSeriesKey: PerformanceDashboardReliabilityAccumulator]()

        let statusStatement = try prepare(
            """
            WITH buckets(bucket_start, query_end, bucket_end) AS (
                VALUES \(bucketValuesSQL)
            ),
            reliability_base AS (
                SELECT b.bucket_start, b.bucket_end,
                    r.model, r.project_path, r.project_name, r.effort, r.source,
                    r.transport, r.wire_api,
                    CASE
                        WHEN r.success IS NULL THEN 'unknown'
                        WHEN r.success = 1 THEN 'success'
                        ELSE 'failure'
                    END AS status,
                    1 AS event_count
                FROM buckets b
                JOIN codex_turn_performance_events r
                    ON r.event_timestamp >= b.bucket_start
                    AND r.event_timestamp < b.query_end
                WHERE r.event_timestamp >= ? AND r.event_timestamp < ?

                UNION ALL

                SELECT b.bucket_start, b.bucket_end,
                    NULLIF(r.model, ''), NULLIF(r.project_path, ''), NULLIF(r.project_name, ''),
                    NULLIF(r.effort, ''), NULLIF(r.source, ''), NULLIF(r.transport, ''),
                    NULLIF(r.wire_api, ''), 'success', r.success_count
                FROM buckets b
                JOIN telemetry_hourly_rollups r
                    ON r.period_start >= b.bucket_start AND r.period_start < b.query_end
                WHERE r.metric = 'turn_performance' AND r.success_count > 0

                UNION ALL

                SELECT b.bucket_start, b.bucket_end,
                    NULLIF(r.model, ''), NULLIF(r.project_path, ''), NULLIF(r.project_name, ''),
                    NULLIF(r.effort, ''), NULLIF(r.source, ''), NULLIF(r.transport, ''),
                    NULLIF(r.wire_api, ''), 'failure', r.failure_count
                FROM buckets b
                JOIN telemetry_hourly_rollups r
                    ON r.period_start >= b.bucket_start AND r.period_start < b.query_end
                WHERE r.metric = 'turn_performance' AND r.failure_count > 0

                UNION ALL

                SELECT b.bucket_start, b.bucket_end,
                    NULLIF(r.model, ''), NULLIF(r.project_path, ''), NULLIF(r.project_name, ''),
                    NULLIF(r.effort, ''), NULLIF(r.source, ''), NULLIF(r.transport, ''),
                    NULLIF(r.wire_api, ''), 'unknown',
                    r.sample_count - r.success_count - r.failure_count
                FROM buckets b
                JOIN telemetry_hourly_rollups r
                    ON r.period_start >= b.bucket_start AND r.period_start < b.query_end
                WHERE r.metric = 'turn_performance'
                    AND r.sample_count > r.success_count + r.failure_count
            ),
            expanded AS (
                SELECT
                    bucket_start,
                    bucket_end,
                    'aggregate' AS series_kind,
                    NULL AS series_value,
                    NULL AS series_project_path,
                    NULL AS series_project_name,
                    status,
                    event_count
                FROM reliability_base
                UNION ALL
                SELECT
                    bucket_start,
                    bucket_end,
                    \(breakdown.kindSQL) AS series_kind,
                    \(breakdown.valueSQL) AS series_value,
                    \(breakdown.projectPathSQL) AS series_project_path,
                    \(breakdown.projectNameSQL) AS series_project_name,
                    status,
                    event_count
                FROM reliability_base
            )
            SELECT
                bucket_start,
                bucket_end,
                series_kind,
                series_value,
                series_project_path,
                series_project_name,
                status,
                SUM(event_count) AS event_count
            FROM expanded
            GROUP BY
                bucket_start,
                bucket_end,
                series_kind,
                series_value,
                series_project_path,
                series_project_name,
                status
            """
        )
        defer { sqlite3_finalize(statusStatement) }

        var bindIndex = Self.bindPerformanceDashboardBucketIntervals(intervals, in: statusStatement)
        sqlite3_bind_int64(statusStatement, bindIndex, periodStart.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(statusStatement, bindIndex, periodEnd.timeIntervalSince1970Int)

        statusRows: while true {
            switch sqlite3_step(statusStatement) {
            case SQLITE_ROW:
                let bucketStart = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statusStatement, 0)))
                let bucketEnd = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statusStatement, 1)))
                let series = Self.performanceDashboardSeries(
                    kindRawValue: columnText(statusStatement, index: 2),
                    value: optionalColumnText(statusStatement, index: 3),
                    projectPath: optionalColumnText(statusStatement, index: 4),
                    projectName: optionalColumnText(statusStatement, index: 5)
                )
                let key = PerformanceDashboardBucketSeriesKey(bucketStart: bucketStart, seriesID: series.id)
                var accumulator = accumulators[key] ?? PerformanceDashboardReliabilityAccumulator(
                    bucketStart: bucketStart,
                    bucketEnd: bucketEnd,
                    series: series
                )
                let count = Int(sqlite3_column_int64(statusStatement, 7))
                switch columnText(statusStatement, index: 6) {
                case "success":
                    accumulator.successCount += count
                case "failure":
                    accumulator.failureCount += count
                default:
                    accumulator.unknownCount += count
                }
                accumulators[key] = accumulator
            case SQLITE_DONE:
                break statusRows
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }

        let errorStatement = try prepare(
            """
            WITH buckets(bucket_start, query_end, bucket_end) AS (
                VALUES \(bucketValuesSQL)
            ),
            expanded AS (
                SELECT
                    b.bucket_start,
                    b.bucket_end,
                    'aggregate' AS series_kind,
                    NULL AS series_value,
                    NULL AS series_project_path,
                    NULL AS series_project_name,
                    r.error_summary,
                    1 AS event_count
                FROM buckets b
                JOIN codex_turn_performance_events r
                    ON r.event_timestamp >= b.bucket_start
                    AND r.event_timestamp < b.query_end
                WHERE r.event_timestamp >= ?
                    AND r.event_timestamp < ?
                    AND r.success = 0
                    AND r.error_summary IS NOT NULL
                UNION ALL
                SELECT
                    b.bucket_start,
                    b.bucket_end,
                    \(breakdown.kindSQL) AS series_kind,
                    \(breakdown.valueSQL) AS series_value,
                    \(breakdown.projectPathSQL) AS series_project_path,
                    \(breakdown.projectNameSQL) AS series_project_name,
                    r.error_summary,
                    1 AS event_count
                FROM buckets b
                JOIN codex_turn_performance_events r
                    ON r.event_timestamp >= b.bucket_start
                    AND r.event_timestamp < b.query_end
                WHERE r.event_timestamp >= ?
                    AND r.event_timestamp < ?
                    AND r.success = 0
                    AND r.error_summary IS NOT NULL

                UNION ALL

                SELECT b.bucket_start, b.bucket_end,
                    'aggregate', NULL, NULL, NULL, r.error_summary, r.event_count
                FROM buckets b
                JOIN telemetry_error_hourly_rollups r
                    ON r.period_start >= b.bucket_start AND r.period_start < b.query_end

                UNION ALL

                SELECT b.bucket_start, b.bucket_end,
                    \(breakdown.kindSQL), \(breakdown.valueSQL),
                    \(breakdown.projectPathSQL), \(breakdown.projectNameSQL),
                    r.error_summary, r.event_count
                FROM buckets b
                JOIN telemetry_error_hourly_rollups r
                    ON r.period_start >= b.bucket_start AND r.period_start < b.query_end
            )
            SELECT
                bucket_start,
                bucket_end,
                series_kind,
                series_value,
                series_project_path,
                series_project_name,
                error_summary,
                SUM(event_count) AS event_count
            FROM expanded
            GROUP BY
                bucket_start,
                bucket_end,
                series_kind,
                series_value,
                series_project_path,
                series_project_name,
                error_summary
            """
        )
        defer { sqlite3_finalize(errorStatement) }

        bindIndex = Self.bindPerformanceDashboardBucketIntervals(intervals, in: errorStatement)
        sqlite3_bind_int64(errorStatement, bindIndex, periodStart.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(errorStatement, bindIndex, periodEnd.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(errorStatement, bindIndex, periodStart.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(errorStatement, bindIndex, periodEnd.timeIntervalSince1970Int)

        while true {
            switch sqlite3_step(errorStatement) {
            case SQLITE_ROW:
                let bucketStart = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(errorStatement, 0)))
                let bucketEnd = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(errorStatement, 1)))
                let series = Self.performanceDashboardSeries(
                    kindRawValue: columnText(errorStatement, index: 2),
                    value: optionalColumnText(errorStatement, index: 3),
                    projectPath: optionalColumnText(errorStatement, index: 4),
                    projectName: optionalColumnText(errorStatement, index: 5)
                )
                let key = PerformanceDashboardBucketSeriesKey(bucketStart: bucketStart, seriesID: series.id)
                var accumulator = accumulators[key] ?? PerformanceDashboardReliabilityAccumulator(
                    bucketStart: bucketStart,
                    bucketEnd: bucketEnd,
                    series: series
                )
                if let errorSummary = optionalColumnText(errorStatement, index: 6) {
                    accumulator.errorCounts[errorSummary, default: 0] += Int(sqlite3_column_int64(errorStatement, 7))
                }
                accumulators[key] = accumulator
            case SQLITE_DONE:
                return accumulators.values.map(\.point).sortedByDashboardDisplayOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func performanceDashboardEfficiencyTokenPoints(
        breakdownDimension: PerformanceDashboardBreakdownDimension,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar
    ) throws -> [PerformanceDashboardEfficiencyPoint] {
        let intervals = Self.performanceDashboardBucketIntervals(
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )
        guard !intervals.isEmpty else {
            return []
        }

        let bucketValuesSQL = Self.performanceDashboardBucketValuesSQL(intervals)
        let breakdown = Self.performanceDashboardBreakdownSQL(dimension: breakdownDimension)
        let totalTokensSQL = """
        MAX(IFNULL(t.observed_input_tokens, 0), 0)
            + MAX(IFNULL(t.observed_cached_input_tokens, 0), 0)
            + MAX(IFNULL(t.observed_output_tokens, 0), 0)
            + MAX(IFNULL(t.observed_reasoning_output_tokens, 0), 0)
        """
        let contextWindowSQL = "COALESCE(c.max_context_window, c.context_window, t.model_context_window)"
        let statement = try prepare(
            """
            WITH buckets(bucket_start, query_end, bucket_end) AS (
                VALUES \(bucketValuesSQL)
            ),
            token_base AS (
                SELECT
                    b.bucket_start,
                    b.bucket_end,
                    t.model,
                    t.project_path,
                    t.project_name,
                    t.effort,
                    t.source,
                    NULL AS transport,
                    NULL AS wire_api,
                    MAX(IFNULL(t.observed_input_tokens, 0), 0) AS input_tokens,
                    MAX(IFNULL(t.observed_cached_input_tokens, 0), 0) AS cached_input_tokens,
                    MAX(IFNULL(t.observed_output_tokens, 0), 0) AS output_tokens,
                    MAX(IFNULL(t.observed_reasoning_output_tokens, 0), 0) AS reasoning_output_tokens,
                    CASE
                        WHEN \(contextWindowSQL) > 0 THEN CAST((\(totalTokensSQL)) AS REAL) / CAST(\(contextWindowSQL) AS REAL)
                        ELSE NULL
                    END AS context_pressure
                FROM buckets b
                JOIN token_usage_query_samples t
                    ON t.received_at >= b.bucket_start
                    AND t.received_at < b.query_end
                LEFT JOIN codex_model_capabilities c
                    ON c.slug = t.model
                WHERE t.received_at >= ?
                    AND t.received_at < ?
                    AND (
                        t.observed_input_tokens > 0
                        OR t.observed_cached_input_tokens > 0
                        OR t.observed_output_tokens > 0
                        OR t.observed_reasoning_output_tokens > 0
                    )
            ),
            expanded AS (
                SELECT
                    bucket_start,
                    bucket_end,
                    'aggregate' AS series_kind,
                    NULL AS series_value,
                    NULL AS series_project_path,
                    NULL AS series_project_name,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    context_pressure
                FROM token_base
                UNION ALL
                SELECT
                    bucket_start,
                    bucket_end,
                    \(breakdown.kindSQL) AS series_kind,
                    \(breakdown.valueSQL) AS series_value,
                    \(breakdown.projectPathSQL) AS series_project_path,
                    \(breakdown.projectNameSQL) AS series_project_name,
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                    reasoning_output_tokens,
                    context_pressure
                FROM token_base
            )
            SELECT
                bucket_start,
                bucket_end,
                series_kind,
                series_value,
                series_project_path,
                series_project_name,
                SUM(input_tokens) AS input_tokens,
                SUM(cached_input_tokens) AS cached_input_tokens,
                SUM(output_tokens) AS output_tokens,
                SUM(reasoning_output_tokens) AS reasoning_output_tokens,
                MAX(context_pressure) AS context_pressure
            FROM expanded
            GROUP BY
                bucket_start,
                bucket_end,
                series_kind,
                series_value,
                series_project_path,
                series_project_name
            HAVING input_tokens > 0
                OR cached_input_tokens > 0
                OR output_tokens > 0
                OR reasoning_output_tokens > 0
            ORDER BY bucket_start ASC, series_kind ASC, series_value ASC, series_project_path ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var bindIndex = Self.bindPerformanceDashboardBucketIntervals(intervals, in: statement)
        sqlite3_bind_int64(statement, bindIndex, periodStart.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(statement, bindIndex, periodEnd.timeIntervalSince1970Int)

        var points: [PerformanceDashboardEfficiencyPoint] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let series = Self.performanceDashboardSeries(
                    kindRawValue: columnText(statement, index: 2),
                    value: optionalColumnText(statement, index: 3),
                    projectPath: optionalColumnText(statement, index: 4),
                    projectName: optionalColumnText(statement, index: 5)
                )
                var accumulator = PerformanceDashboardEfficiencyAccumulator(
                    bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    bucketEnd: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
                    series: series
                )
                accumulator.addTokenTotals(
                    inputTokens: sqlite3_column_int64(statement, 6),
                    cachedInputTokens: sqlite3_column_int64(statement, 7),
                    outputTokens: sqlite3_column_int64(statement, 8),
                    reasoningOutputTokens: sqlite3_column_int64(statement, 9),
                    contextPressure: optionalColumnDouble(statement, index: 10)
                )
                points.append(accumulator.point)
            case SQLITE_DONE:
                return points.sortedByDashboardDisplayOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func performanceDashboardBounds(includeEfficiencyTokens: Bool = true) throws -> UsageHistoryBounds? {
        let tokenBoundsSQL = includeEfficiencyTokens
            ? """
                UNION ALL
                SELECT received_at AS timestamp
                FROM token_usage_query_samples
                WHERE \(Self.observedTokenComponentsPredicate)
            """
            : ""
        let statement = try prepare(
            """
            SELECT MIN(timestamp), MAX(timestamp)
            FROM (
                SELECT event_timestamp AS timestamp
                FROM codex_session_task_timing_events
                WHERE event_timestamp IS NOT NULL
                UNION ALL
                SELECT event_timestamp AS timestamp
                FROM codex_turn_performance_events
                UNION ALL
                SELECT period_start AS timestamp
                FROM telemetry_hourly_rollups
                \(tokenBoundsSQL)
            )
            """
        )
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  sqlite3_column_type(statement, 1) != SQLITE_NULL
            else {
                return nil
            }
            return UsageHistoryBounds(
                earliest: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                latest: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
            )
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    static func performanceDashboardBucketIntervals(
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar
    ) -> [(start: Date, queryEnd: Date, displayEnd: Date)] {
        guard periodEnd > periodStart else {
            return []
        }

        let component = range.chartBucketComponent
        var intervals: [(start: Date, queryEnd: Date, displayEnd: Date)] = []
        var bucketStart = UsageHistoryRange.bucketStart(
            for: periodStart,
            component: component,
            calendar: calendar
        )

        while bucketStart < periodEnd {
            guard let nextBucketStart = calendar.date(byAdding: component, value: 1, to: bucketStart),
                  nextBucketStart > bucketStart
            else {
                break
            }

            let queryEnd = min(nextBucketStart, periodEnd)
            if queryEnd > bucketStart {
                intervals.append((start: bucketStart, queryEnd: queryEnd, displayEnd: nextBucketStart))
            }
            bucketStart = nextBucketStart
        }

        return intervals
    }

    static func performanceDashboardRows(
        durationPoints: [PerformanceDashboardDurationPoint],
        reliabilityPoints: [PerformanceDashboardReliabilityPoint]
    ) -> [PerformanceDashboardBreakdownRow] {
        var accumulators = [String: PerformanceDashboardRowAccumulator]()
        for point in durationPoints {
            var accumulator = accumulators[point.series.id] ?? PerformanceDashboardRowAccumulator(series: point.series)
            accumulator.add(point)
            accumulators[point.series.id] = accumulator
        }
        for point in reliabilityPoints {
            var accumulator = accumulators[point.series.id] ?? PerformanceDashboardRowAccumulator(series: point.series)
            accumulator.add(point)
            accumulators[point.series.id] = accumulator
        }
        return accumulators.values
            .map(\.row)
            .filter { $0.turnCount > 0 || $0.eventCount > 0 }
            .sortedByDashboardSeriesOrder()
    }

    static func performanceDashboardEfficiencyPoints(
        tokenPoints: [PerformanceDashboardEfficiencyPoint],
        durationPoints: [PerformanceDashboardDurationPoint],
        reliabilityPoints: [PerformanceDashboardReliabilityPoint]
    ) -> [PerformanceDashboardEfficiencyPoint] {
        var accumulators = [PerformanceDashboardBucketSeriesKey: PerformanceDashboardEfficiencyAccumulator]()
        for point in tokenPoints {
            var accumulator = accumulators[PerformanceDashboardBucketSeriesKey(bucketStart: point.bucketStart, seriesID: point.series.id)]
                ?? PerformanceDashboardEfficiencyAccumulator(
                    bucketStart: point.bucketStart,
                    bucketEnd: point.bucketEnd,
                    series: point.series
                )
            accumulator.add(point)
            accumulators[PerformanceDashboardBucketSeriesKey(bucketStart: point.bucketStart, seriesID: point.series.id)] = accumulator
        }
        for point in durationPoints {
            var accumulator = accumulators[PerformanceDashboardBucketSeriesKey(bucketStart: point.bucketStart, seriesID: point.series.id)]
                ?? PerformanceDashboardEfficiencyAccumulator(
                    bucketStart: point.bucketStart,
                    bucketEnd: point.bucketEnd,
                    series: point.series
                )
            accumulator.add(point)
            accumulators[PerformanceDashboardBucketSeriesKey(bucketStart: point.bucketStart, seriesID: point.series.id)] = accumulator
        }
        for point in reliabilityPoints {
            var accumulator = accumulators[PerformanceDashboardBucketSeriesKey(bucketStart: point.bucketStart, seriesID: point.series.id)]
                ?? PerformanceDashboardEfficiencyAccumulator(
                    bucketStart: point.bucketStart,
                    bucketEnd: point.bucketEnd,
                    series: point.series
                )
            accumulator.add(point)
            accumulators[PerformanceDashboardBucketSeriesKey(bucketStart: point.bucketStart, seriesID: point.series.id)] = accumulator
        }
        return accumulators.values
            .map(\.point)
            .filter { $0.totalTokens > 0 || $0.turnCount > 0 || $0.eventCount > 0 }
            .sortedByDashboardDisplayOrder()
    }

    static func performanceDashboardEfficiencyRows(
        points: [PerformanceDashboardEfficiencyPoint]
    ) -> [PerformanceDashboardEfficiencyRow] {
        var accumulators = [String: PerformanceDashboardEfficiencyAccumulator]()
        for point in points {
            var accumulator = accumulators[point.series.id] ?? PerformanceDashboardEfficiencyAccumulator(
                bucketStart: point.bucketStart,
                bucketEnd: point.bucketEnd,
                series: point.series
            )
            accumulator.add(point)
            accumulators[point.series.id] = accumulator
        }
        return accumulators.values
            .map(\.row)
            .filter { $0.totalTokens > 0 || $0.turnCount > 0 || $0.eventCount > 0 }
            .sortedByDashboardSeriesOrder()
    }

    static func performanceDashboardBucketValuesSQL(
        _ intervals: [(start: Date, queryEnd: Date, displayEnd: Date)]
    ) -> String {
        intervals.map { _ in "(?, ?, ?)" }.joined(separator: ",\n")
    }

    static func bindPerformanceDashboardBucketIntervals(
        _ intervals: [(start: Date, queryEnd: Date, displayEnd: Date)],
        in statement: OpaquePointer
    ) -> Int32 {
        var bindIndex: Int32 = 1
        for interval in intervals {
            sqlite3_bind_int64(statement, bindIndex, interval.start.timeIntervalSince1970Int)
            bindIndex += 1
            sqlite3_bind_int64(statement, bindIndex, interval.queryEnd.timeIntervalSince1970Int)
            bindIndex += 1
            sqlite3_bind_int64(statement, bindIndex, interval.displayEnd.timeIntervalSince1970Int)
            bindIndex += 1
        }
        return bindIndex
    }

    static func performanceDashboardBreakdownSQL(
        dimension: PerformanceDashboardBreakdownDimension,
        unavailableAsUnattributed: Bool = false
    ) -> PerformanceDashboardBreakdownSQL {
        if unavailableAsUnattributed {
            return PerformanceDashboardBreakdownSQL(
                kindSQL: "'unattributed'",
                valueSQL: "NULL",
                projectPathSQL: "NULL",
                projectNameSQL: "NULL"
            )
        }

        switch dimension {
        case .model:
            return contextPerformanceDashboardBreakdownSQL(column: "model", kind: "model")
        case .effort:
            return contextPerformanceDashboardBreakdownSQL(column: "effort", kind: "effort")
        case .project:
            return PerformanceDashboardBreakdownSQL(
                kindSQL: "CASE WHEN NULLIF(project_path, '') IS NULL THEN 'unattributed' ELSE 'project' END",
                valueSQL: "NULL",
                projectPathSQL: "CASE WHEN NULLIF(project_path, '') IS NULL THEN NULL ELSE project_path END",
                projectNameSQL: "CASE WHEN NULLIF(project_path, '') IS NULL THEN NULL ELSE NULLIF(project_name, '') END"
            )
        case .source:
            return contextPerformanceDashboardBreakdownSQL(column: "source", kind: "source")
        case .transport:
            return contextPerformanceDashboardBreakdownSQL(column: "transport", kind: "transport")
        case .wireAPI:
            return contextPerformanceDashboardBreakdownSQL(column: "wire_api", kind: "wire_api")
        }
    }

    static func contextPerformanceDashboardBreakdownSQL(
        column: String,
        kind: String
    ) -> PerformanceDashboardBreakdownSQL {
        PerformanceDashboardBreakdownSQL(
            kindSQL: "CASE WHEN NULLIF(\(column), '') IS NULL THEN 'unattributed' ELSE '\(kind)' END",
            valueSQL: "NULLIF(\(column), '')",
            projectPathSQL: "NULL",
            projectNameSQL: "NULL"
        )
    }

    static func performanceDashboardSeries(
        kindRawValue: String,
        value: String?,
        projectPath: String?,
        projectName: String?
    ) -> PerformanceDashboardSeries {
        guard let kind = PerformanceDashboardSeriesKind(rawValue: kindRawValue) else {
            return .unattributed
        }

        switch kind {
        case .aggregate:
            return .aggregate
        case .unattributed:
            return .unattributed
        case .project:
            guard let projectPath, !projectPath.isEmpty else {
                return .unattributed
            }
            let displayName = projectName ?? URL(fileURLWithPath: projectPath).lastPathComponent
            return PerformanceDashboardSeries(
                id: "project:\(projectPath)",
                name: displayName.isEmpty ? projectPath : displayName,
                kind: .project,
                contextID: projectPath,
                projectPath: projectPath
            )
        case .model, .effort, .source, .transport, .wireAPI:
            guard let value, !value.isEmpty else {
                return .unattributed
            }
            return PerformanceDashboardSeries(
                id: "\(kind.performanceDashboardSeriesPrefix):\(value)",
                name: value,
                kind: kind,
                contextID: value
            )
        }
    }

    static func performanceDashboardIntValues(_ value: String?) -> [Int64] {
        guard let value, !value.isEmpty else {
            return []
        }
        return value.split(separator: ",").compactMap { Int64($0) }
    }
}

struct PerformanceDashboardBreakdownSQL {
    let kindSQL: String
    let valueSQL: String
    let projectPathSQL: String
    let projectNameSQL: String
}

private extension PerformanceDashboardBreakdownDimension {
    var isSupportedByEfficiencyDashboard: Bool {
        switch self {
        case .model, .project, .effort, .source:
            return true
        case .transport, .wireAPI:
            return false
        }
    }
}

private extension PerformanceDashboardSeriesKind {
    var performanceDashboardSeriesPrefix: String {
        switch self {
        case .model:
            return "model"
        case .effort:
            return "effort"
        case .source:
            return "source"
        case .transport:
            return "transport"
        case .wireAPI:
            return "wire-api"
        case .aggregate, .project, .unattributed:
            return rawValue
        }
    }
}
