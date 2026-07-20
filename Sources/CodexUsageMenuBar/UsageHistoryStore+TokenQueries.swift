import Foundation
import SQLite3

extension UsageHistoryStore {
    func tokenUsageSamples() throws -> [StoredTokenUsageSample] {
        let statement = try prepare(
            """
            SELECT thread_id, turn_id, model, session_id, project_path, project_name,
                effort, source, received_at, model_context_window,
                last_input_tokens, last_cached_input_tokens, last_output_tokens,
                last_reasoning_output_tokens, last_total_tokens,
                total_input_tokens, total_cached_input_tokens, total_output_tokens,
                total_reasoning_output_tokens, total_total_tokens,
                observed_input_tokens, observed_cached_input_tokens, observed_output_tokens,
                observed_reasoning_output_tokens, observed_total_tokens
            FROM token_usage_query_samples
            ORDER BY received_at ASC, thread_id ASC, turn_id ASC, total_total_tokens ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var samples: [StoredTokenUsageSample] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                samples.append(
                    StoredTokenUsageSample(
                        threadID: columnText(statement, index: 0),
                        turnID: columnText(statement, index: 1),
                        model: optionalColumnText(statement, index: 2),
                        sessionID: optionalColumnText(statement, index: 3),
                        projectPath: optionalColumnText(statement, index: 4),
                        projectName: optionalColumnText(statement, index: 5),
                        effort: optionalColumnText(statement, index: 6),
                        source: optionalColumnText(statement, index: 7),
                        receivedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8))),
                        modelContextWindow: optionalColumnInt(statement, index: 9),
                        last: CodexTokenUsageBreakdown(
                            inputTokens: sqlite3_column_int64(statement, 10),
                            cachedInputTokens: sqlite3_column_int64(statement, 11),
                            outputTokens: sqlite3_column_int64(statement, 12),
                            reasoningOutputTokens: sqlite3_column_int64(statement, 13),
                            totalTokens: sqlite3_column_int64(statement, 14)
                        ),
                        total: CodexTokenUsageBreakdown(
                            inputTokens: sqlite3_column_int64(statement, 15),
                            cachedInputTokens: sqlite3_column_int64(statement, 16),
                            outputTokens: sqlite3_column_int64(statement, 17),
                            reasoningOutputTokens: sqlite3_column_int64(statement, 18),
                            totalTokens: sqlite3_column_int64(statement, 19)
                        ),
                        observedInputTokens: optionalColumnInt(statement, index: 20),
                        observedCachedInputTokens: optionalColumnInt(statement, index: 21),
                        observedOutputTokens: optionalColumnInt(statement, index: 22),
                        observedReasoningOutputTokens: optionalColumnInt(statement, index: 23),
                        observedTotalTokens: sqlite3_column_int64(statement, 24)
                    )
                )
            case SQLITE_DONE:
                return samples
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenTotalForDay(containing date: Date, calendar: Calendar = .autoupdatingCurrent) throws -> Int64? {
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            return nil
        }

        let statement = try prepare(
            """
            SELECT COUNT(*),
                SUM(CASE
                    WHEN observed_input_tokens IS NULL
                        OR observed_cached_input_tokens IS NULL
                        OR observed_output_tokens IS NULL
                        OR observed_reasoning_output_tokens IS NULL
                    THEN 1 ELSE 0
                END),
                IFNULL(SUM(
                    IFNULL(observed_input_tokens, 0)
                    + IFNULL(observed_cached_input_tokens, 0)
                    + IFNULL(observed_output_tokens, 0)
                    + IFNULL(observed_reasoning_output_tokens, 0)
                ), 0)
            FROM token_usage_query_samples
            WHERE received_at >= ?1 AND received_at < ?2
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, interval.start.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, interval.end.timeIntervalSince1970Int)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard sqlite3_column_int64(statement, 0) > 0 else {
                return nil
            }

            guard sqlite3_column_int64(statement, 1) == 0 else {
                return nil
            }

            return sqlite3_column_int64(statement, 2)
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func tokenCategoryTotalsForDay(containing date: Date, calendar: Calendar = .autoupdatingCurrent) throws -> TokenCategoryTotals? {
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            return nil
        }

        return try tokenCategoryTotals(periodStart: interval.start, periodEnd: interval.end)
    }

    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) throws -> TokenCategoryTotals? {
        guard periodStart < periodEnd else {
            return nil
        }

        let statement = try prepare(
            """
            SELECT COUNT(*),
                SUM(CASE
                    WHEN observed_input_tokens IS NULL
                        OR observed_cached_input_tokens IS NULL
                        OR observed_output_tokens IS NULL
                        OR observed_reasoning_output_tokens IS NULL
                    THEN 1 ELSE 0
                END),
                IFNULL(SUM(observed_input_tokens), 0),
                IFNULL(SUM(observed_cached_input_tokens), 0),
                IFNULL(SUM(observed_output_tokens), 0),
                IFNULL(SUM(observed_reasoning_output_tokens), 0)
            FROM token_usage_query_samples
            WHERE received_at >= ? AND received_at < ?
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, periodStart.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, periodEnd.timeIntervalSince1970Int)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard sqlite3_column_int64(statement, 0) > 0 else {
                return nil
            }

            guard sqlite3_column_int64(statement, 1) == 0 else {
                return nil
            }

            let inputTokens = sqlite3_column_int64(statement, 2)
            let cachedInputTokens = sqlite3_column_int64(statement, 3)
            let outputTokens = sqlite3_column_int64(statement, 4)
            let reasoningOutputTokens = sqlite3_column_int64(statement, 5)

            return TokenCategoryTotals(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                totalTokens: inputTokens + cachedInputTokens + outputTokens + reasoningOutputTokens
            )
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func localTokenComparisonTotals(now: Date) throws -> LocalTokenComparisonTotals {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let monthInterval = utcCalendar.dateInterval(of: .month, for: now)
        let dayInterval = utcCalendar.dateInterval(of: .day, for: now)

        return LocalTokenComparisonTotals(
            generatedAt: now,
            allTimeTokens: try componentTokenTotal(),
            currentUTCMonthTokens: try componentTokenTotal(
                periodStart: monthInterval?.start,
                periodEnd: monthInterval?.end
            ),
            currentUTCDayTokens: try componentTokenTotal(
                periodStart: dayInterval?.start,
                periodEnd: dayInterval?.end
            )
        )
    }

    private func componentTokenTotal(periodStart: Date? = nil, periodEnd: Date? = nil) throws -> Int64 {
        let hasBounds = periodStart != nil && periodEnd != nil
        let statement = try prepare(
            """
            SELECT IFNULL(SUM(
                IFNULL(observed_input_tokens, 0)
                + IFNULL(observed_cached_input_tokens, 0)
                + IFNULL(observed_output_tokens, 0)
                + IFNULL(observed_reasoning_output_tokens, 0)
            ), 0)
            FROM token_usage_query_samples
            WHERE (
                observed_input_tokens IS NOT NULL
                OR observed_cached_input_tokens IS NOT NULL
                OR observed_output_tokens IS NOT NULL
                OR observed_reasoning_output_tokens IS NOT NULL
            )
            \(hasBounds ? "AND received_at >= ? AND received_at < ?" : "")
            """
        )
        defer { sqlite3_finalize(statement) }

        if let periodStart, let periodEnd {
            sqlite3_bind_int64(statement, 1, periodStart.timeIntervalSince1970Int)
            sqlite3_bind_int64(statement, 2, periodEnd.timeIntervalSince1970Int)
        }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int64(statement, 0)
        case SQLITE_DONE:
            return 0
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func tokenPoints(
        category: TokenHistoryCategory,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date
    ) throws -> [TokenHistoryPoint] {
        let startTimestamp = periodStart.timeIntervalSince1970Int
        let endTimestamp = periodEnd.timeIntervalSince1970Int
        let valueExpression = tokenValueExpression(for: category)
        let normalizedModelExpression = Self.normalizedModelSQLExpression(column: "model")
        let statement = try prepare(
            """
            WITH period_samples AS (
                SELECT received_at,
                    \(normalizedModelExpression) AS normalized_model,
                    \(valueExpression) AS token_count
                FROM token_usage_query_samples
                WHERE received_at >= ? AND received_at < ?
            )
            SELECT received_at, series_id, series_name, series_kind, token_count
            FROM (
                SELECT received_at,
                    'tokens_all' AS series_id,
                    'All tokens' AS series_name,
                    'aggregate' AS series_kind,
                    token_count
                FROM period_samples

                UNION ALL

                SELECT received_at,
                    'model:' || normalized_model AS series_id,
                    normalized_model AS series_name,
                    'model' AS series_kind,
                    token_count
                FROM period_samples
                WHERE normalized_model IS NOT NULL
            )
            WHERE token_count > 0
            ORDER BY received_at ASC, series_kind ASC, series_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)

        var points: [TokenHistoryPoint] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let timestamp = sqlite3_column_int64(statement, 0)
                points.append(
                    TokenHistoryPoint(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                        seriesID: columnText(statement, index: 1),
                        seriesName: columnText(statement, index: 2),
                        seriesKind: CodexUsageBucketKind(rawValue: columnText(statement, index: 3)) ?? .model,
                        tokenCount: sqlite3_column_int64(statement, 4)
                    )
                )
            case SQLITE_DONE:
                return points
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenComponentPoints(
        range _: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date
    ) throws -> [TokenHistoryComponentPoint] {
        let startTimestamp = periodStart.timeIntervalSince1970Int
        let endTimestamp = periodEnd.timeIntervalSince1970Int
        let normalizedModelExpression = Self.normalizedModelSQLExpression(column: "model")
        let statement = try prepare(
            """
            WITH period_samples AS (
                SELECT received_at,
                    \(normalizedModelExpression) AS model,
                    observed_input_tokens,
                    observed_cached_input_tokens,
                    observed_output_tokens,
                    observed_reasoning_output_tokens
                FROM token_usage_query_samples
                WHERE received_at >= ? AND received_at < ?
            ),
            series_samples AS (
                SELECT received_at,
                    'tokens_all' AS series_id,
                    'All tokens' AS series_name,
                    'aggregate' AS series_kind,
                    observed_input_tokens,
                    observed_cached_input_tokens,
                    observed_output_tokens,
                    observed_reasoning_output_tokens
                FROM period_samples

                UNION ALL

                SELECT received_at,
                    'model:' || model AS series_id,
                    model AS series_name,
                    'model' AS series_kind,
                    observed_input_tokens,
                    observed_cached_input_tokens,
                    observed_output_tokens,
                    observed_reasoning_output_tokens
                FROM period_samples
                WHERE model IS NOT NULL AND model != ''
            ),
            component_points AS (
                SELECT received_at, series_id, series_name, series_kind,
                    'input' AS component, observed_input_tokens AS token_count
                FROM series_samples

                UNION ALL

                SELECT received_at, series_id, series_name, series_kind,
                    'cached' AS component, observed_cached_input_tokens AS token_count
                FROM series_samples

                UNION ALL

                SELECT received_at, series_id, series_name, series_kind,
                    'output' AS component, observed_output_tokens AS token_count
                FROM series_samples

                UNION ALL

                SELECT received_at, series_id, series_name, series_kind,
                    'reasoning' AS component, observed_reasoning_output_tokens AS token_count
                FROM series_samples
            )
            SELECT received_at, series_id, series_name, series_kind, component, token_count
            FROM component_points
            WHERE token_count > 0
            ORDER BY received_at ASC,
                series_kind ASC,
                series_name ASC,
                CASE component
                    WHEN 'input' THEN 0
                    WHEN 'cached' THEN 1
                    WHEN 'output' THEN 2
                    WHEN 'reasoning' THEN 3
                    ELSE 4
                END ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)

        var points: [TokenHistoryComponentPoint] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let component = TokenHistoryComponent(rawValue: columnText(statement, index: 4)) else {
                    continue
                }

                let timestamp = sqlite3_column_int64(statement, 0)
                points.append(
                    TokenHistoryComponentPoint(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                        seriesID: columnText(statement, index: 1),
                        seriesName: columnText(statement, index: 2),
                        seriesKind: CodexUsageBucketKind(rawValue: columnText(statement, index: 3)) ?? .model,
                        component: component,
                        tokenCount: sqlite3_column_int64(statement, 5)
                    )
                )
            case SQLITE_DONE:
                return points
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenComponentBucketPoints(
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        now: Date,
        calendar: Calendar
    ) throws -> [TokenHistoryComponentBucketPoint] {
        let bucketIntervals = Self.tokenHistoryBucketIntervals(
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd,
            now: now,
            calendar: calendar
        )
        guard !bucketIntervals.isEmpty else {
            return []
        }

        let bucketValuesSQL = bucketIntervals
            .map { _ in "(?, ?, ?)" }
            .joined(separator: ",\n")
        let componentTokenExpression = """
        CASE c.component
            WHEN 'input' THEN IFNULL(s.observed_input_tokens, 0)
            WHEN 'cached' THEN IFNULL(s.observed_cached_input_tokens, 0)
            WHEN 'output' THEN IFNULL(s.observed_output_tokens, 0)
            WHEN 'reasoning' THEN IFNULL(s.observed_reasoning_output_tokens, 0)
            ELSE 0
        END
        """
        let statement = try prepare(
            """
            WITH buckets(bucket_start, bucket_end, display_end) AS (
                VALUES \(bucketValuesSQL)
            ),
            components(component, sort_order) AS (
                VALUES
                    ('input', 0),
                    ('cached', 1),
                    ('output', 2),
                    ('reasoning', 3)
            ),
            component_totals AS (
                SELECT
                    b.bucket_start,
                    b.display_end,
                    MAX(s.received_at) AS latest_sample_timestamp,
                    c.component,
                    c.sort_order,
                    SUM(\(componentTokenExpression)) AS token_count
                FROM buckets b
                JOIN token_usage_query_samples s
                    ON s.received_at >= b.bucket_start
                    AND s.received_at < b.bucket_end
                CROSS JOIN components c
                WHERE s.received_at >= ?
                    AND s.received_at < ?
                    AND (
                        s.observed_input_tokens > 0
                        OR s.observed_cached_input_tokens > 0
                        OR s.observed_output_tokens > 0
                        OR s.observed_reasoning_output_tokens > 0
                    )
                GROUP BY b.bucket_start, b.display_end, c.component, c.sort_order
            )
            SELECT
                bucket_start,
                display_end,
                latest_sample_timestamp,
                'tokens_all' AS series_id,
                'All tokens' AS series_name,
                'aggregate' AS series_kind,
                component,
                token_count
            FROM component_totals
            WHERE token_count > 0
            ORDER BY bucket_start ASC, sort_order ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        for interval in bucketIntervals {
            sqlite3_bind_int64(statement, bindIndex, interval.start.timeIntervalSince1970Int)
            bindIndex += 1
            sqlite3_bind_int64(statement, bindIndex, interval.queryEnd.timeIntervalSince1970Int)
            bindIndex += 1
            sqlite3_bind_int64(statement, bindIndex, interval.displayEnd.timeIntervalSince1970Int)
            bindIndex += 1
        }
        sqlite3_bind_int64(statement, bindIndex, periodStart.timeIntervalSince1970Int)
        bindIndex += 1
        sqlite3_bind_int64(statement, bindIndex, periodEnd.timeIntervalSince1970Int)

        var points: [TokenHistoryComponentBucketPoint] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let component = TokenHistoryComponent(rawValue: columnText(statement, index: 6)) else {
                    continue
                }

                points.append(
                    TokenHistoryComponentBucketPoint(
                        bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                        bucketEnd: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
                        latestSampleTimestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2))),
                        seriesID: columnText(statement, index: 3),
                        seriesName: columnText(statement, index: 4),
                        seriesKind: CodexUsageBucketKind(rawValue: columnText(statement, index: 5)) ?? .aggregate,
                        component: component,
                        tokenCount: sqlite3_column_int64(statement, 7)
                    )
                )
            case SQLITE_DONE:
                return points
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenSeries(
        category: TokenHistoryCategory,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date
    ) throws -> [UsageHistorySeries] {
        let points = try tokenPoints(
            category: category,
            range: range,
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        return Self.series(from: points)
    }

    func availableTokenSeries(category: TokenHistoryCategory) throws -> [UsageHistorySeries] {
        let flagColumn = tokenSeriesCatalogFlagColumn(for: category)
        let statement = try prepare(
            """
            SELECT series_id, series_name, series_kind, seen_at
            FROM token_series_catalog
            WHERE \(flagColumn) = 1
                AND series_kind IN ('aggregate', 'model')
            ORDER BY seen_at DESC, series_kind ASC, series_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        return try readAvailableSeries(from: statement)
    }

    func availableTokenComponentSeries() throws -> [UsageHistorySeries] {
        let statement = try prepare(
            """
            SELECT series_id, series_name, series_kind, seen_at
            FROM token_series_catalog
            WHERE series_kind IN ('aggregate', 'model')
                AND (
                    has_input = 1
                    OR has_cached = 1
                    OR has_output = 1
                    OR has_reasoning = 1
                )
            ORDER BY seen_at DESC, series_kind ASC, series_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        return try readAvailableSeries(from: statement)
    }

    func tokenHistoryBounds(category: TokenHistoryCategory) throws -> UsageHistoryBounds? {
        let valueExpression = tokenValueExpression(for: category)
        let statement = try prepare(
            """
            SELECT MIN(received_at), MAX(received_at)
            FROM token_usage_query_samples
            WHERE \(valueExpression) > 0
            """
        )
        defer { sqlite3_finalize(statement) }

        return try readHistoryBounds(from: statement)
    }

    func tokenComponentHistoryBounds() throws -> UsageHistoryBounds? {
        let statement = try prepare(
            """
            SELECT MIN(received_at), MAX(received_at)
            FROM token_usage_query_samples
            WHERE \(Self.observedTokenComponentsPredicate)
            """
        )
        defer { sqlite3_finalize(statement) }

        return try readHistoryBounds(from: statement)
    }

    func tokenDashboardPoints(
        breakdownDimension: TokenDashboardBreakdownDimension = .model,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date
    ) throws -> [TokenDashboardComponentPoint] {
        if let dimensionKey = breakdownDimension.dimensionKey {
            return try tokenDashboardDimensionPoints(
                dimensionKey: dimensionKey,
                range: range,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        }

        let startTimestamp = periodStart.timeIntervalSince1970Int
        let endTimestamp = periodEnd.timeIntervalSince1970Int
        let normalizedModelExpression = Self.normalizedModelSQLExpression(column: "model")
        let statement = try prepare(
            """
            SELECT received_at,
                \(normalizedModelExpression) AS normalized_model,
                project_path,
                project_name,
                effort,
                observed_input_tokens,
                observed_cached_input_tokens,
                observed_output_tokens,
                observed_reasoning_output_tokens
            FROM token_usage_query_samples
            WHERE received_at >= ? AND received_at < ?
                AND (
                    \(Self.observedTokenComponentsPredicate)
                )
            ORDER BY received_at ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)

        var accumulators = [TokenDashboardAccumulatorKey: TokenDashboardAccumulator]()

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let receivedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
                let normalizedModel = optionalColumnText(statement, index: 1)
                let projectPath = optionalColumnText(statement, index: 2)
                let projectName = optionalColumnText(statement, index: 3)
                let effort = optionalColumnText(statement, index: 4)
                let bucketStart = UsageHistoryRange.bucketStart(
                    for: receivedAt,
                    component: range.chartBucketComponent,
                    calendar: calendar
                )
                let bucketEnd = calendar.date(byAdding: range.chartBucketComponent, value: 1, to: bucketStart)
                    ?? bucketStart

                let components: [(TokenHistoryComponent, Int64)] = [
                    (.input, sqlite3_column_int64(statement, 5)),
                    (.cached, sqlite3_column_int64(statement, 6)),
                    (.output, sqlite3_column_int64(statement, 7)),
                    (.reasoning, sqlite3_column_int64(statement, 8)),
                ]

                for (component, tokenCount) in components where tokenCount > 0 {
                    addTokenDashboardAccumulator(
                        bucketStart: bucketStart,
                        bucketEnd: bucketEnd,
                        seriesID: TokenDashboardSeries.aggregateID,
                        seriesName: "All captured",
                        seriesKind: .aggregate,
                        component: component,
                        tokenCount: tokenCount,
                        to: &accumulators
                    )

                    let dimensionSeries = Self.tokenDashboardSeriesIdentity(
                        breakdownDimension: breakdownDimension,
                        model: normalizedModel,
                        effort: effort,
                        projectPath: projectPath,
                        projectName: projectName
                    )
                    addTokenDashboardAccumulator(
                        bucketStart: bucketStart,
                        bucketEnd: bucketEnd,
                        seriesID: dimensionSeries.id,
                        seriesName: dimensionSeries.name,
                        seriesKind: dimensionSeries.kind,
                        component: component,
                        tokenCount: tokenCount,
                        to: &accumulators
                    )
                }
            case SQLITE_DONE:
                return accumulators.values
                    .map { accumulator in
                        TokenDashboardComponentPoint(
                            bucketStart: accumulator.bucketStart,
                            bucketEnd: accumulator.bucketEnd,
                            seriesID: accumulator.seriesID,
                            seriesName: accumulator.seriesName,
                            seriesKind: accumulator.seriesKind,
                            component: accumulator.component,
                            tokenCount: accumulator.tokenCount
                        )
                    }
                    .sortedByStoreDashboardDisplayOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private func tokenDashboardDimensionPoints(
        dimensionKey: TokenUsageDimensionKey,
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date
    ) throws -> [TokenDashboardComponentPoint] {
        let startTimestamp = periodStart.timeIntervalSince1970Int
        let endTimestamp = periodEnd.timeIntervalSince1970Int
        let statement = try prepare(
            """
            WITH dimension_values AS (
                SELECT thread_id,
                    turn_id,
                    total_total_tokens,
                    COALESCE(
                        MIN(
                            CASE
                                WHEN NOT (
                                    dimension_key = '\(TokenUsageDimensionKey.sourceKind.rawValue)'
                                    AND dimension_value = 'codex-log'
                                )
                                THEN dimension_value
                            END
                        ),
                        MIN(dimension_value)
                    ) AS dimension_value
                FROM token_usage_dimension_query_values
                WHERE dimension_key = ?
                GROUP BY thread_id, turn_id, total_total_tokens
            )
            , dimension_points AS (
                SELECT samples.received_at,
                    dimension_values.dimension_value,
                    samples.observed_input_tokens,
                    samples.observed_cached_input_tokens,
                    samples.observed_output_tokens,
                    samples.observed_reasoning_output_tokens
                FROM token_usage_samples AS samples
                LEFT JOIN dimension_values
                    ON dimension_values.thread_id = samples.thread_id
                    AND dimension_values.turn_id = samples.turn_id
                    AND dimension_values.total_total_tokens = samples.total_total_tokens
                WHERE samples.is_retention_baseline = 0
                    AND samples.received_at >= ? AND samples.received_at < ?
                    AND (
                        \(Self.observedTokenComponentsPredicate.replacingOccurrences(of: "observed_", with: "samples.observed_"))
                    )

                UNION ALL

                SELECT period_start, NULLIF(dimension_value, ''),
                    observed_input_tokens, observed_cached_input_tokens,
                    observed_output_tokens, observed_reasoning_output_tokens
                FROM token_dimension_query_rollups
                WHERE dimension_key = ?
                    AND period_start >= ? AND period_start < ?
            )
            SELECT received_at, dimension_value, observed_input_tokens,
                observed_cached_input_tokens, observed_output_tokens,
                observed_reasoning_output_tokens
            FROM dimension_points
            ORDER BY received_at ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(dimensionKey.rawValue, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, startTimestamp)
        sqlite3_bind_int64(statement, 3, endTimestamp)
        bindText(dimensionKey.rawValue, to: 4, in: statement)
        sqlite3_bind_int64(statement, 5, startTimestamp)
        sqlite3_bind_int64(statement, 6, endTimestamp)

        var accumulators = [TokenDashboardAccumulatorKey: TokenDashboardAccumulator]()

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let receivedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
                let dimensionValue = optionalColumnText(statement, index: 1)
                let bucketStart = UsageHistoryRange.bucketStart(
                    for: receivedAt,
                    component: range.chartBucketComponent,
                    calendar: calendar
                )
                let bucketEnd = calendar.date(byAdding: range.chartBucketComponent, value: 1, to: bucketStart)
                    ?? bucketStart

                let components: [(TokenHistoryComponent, Int64)] = [
                    (.input, sqlite3_column_int64(statement, 2)),
                    (.cached, sqlite3_column_int64(statement, 3)),
                    (.output, sqlite3_column_int64(statement, 4)),
                    (.reasoning, sqlite3_column_int64(statement, 5)),
                ]

                for (component, tokenCount) in components where tokenCount > 0 {
                    addTokenDashboardAccumulator(
                        bucketStart: bucketStart,
                        bucketEnd: bucketEnd,
                        seriesID: TokenDashboardSeries.aggregateID,
                        seriesName: "All captured",
                        seriesKind: .aggregate,
                        component: component,
                        tokenCount: tokenCount,
                        to: &accumulators
                    )

                    let dimensionSeries = Self.tokenDashboardDimensionSeriesIdentity(
                        key: dimensionKey,
                        value: dimensionValue
                    )
                    addTokenDashboardAccumulator(
                        bucketStart: bucketStart,
                        bucketEnd: bucketEnd,
                        seriesID: dimensionSeries.id,
                        seriesName: dimensionSeries.name,
                        seriesKind: dimensionSeries.kind,
                        component: component,
                        tokenCount: tokenCount,
                        to: &accumulators
                    )
                }
            case SQLITE_DONE:
                return accumulators.values
                    .map { accumulator in
                        TokenDashboardComponentPoint(
                            bucketStart: accumulator.bucketStart,
                            bucketEnd: accumulator.bucketEnd,
                            seriesID: accumulator.seriesID,
                            seriesName: accumulator.seriesName,
                            seriesKind: accumulator.seriesKind,
                            component: accumulator.component,
                            tokenCount: accumulator.tokenCount
                        )
                    }
                    .sortedByStoreDashboardDisplayOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenDashboardSeries(
        breakdownDimension: TokenDashboardBreakdownDimension = .model
    ) throws -> [TokenDashboardSeries] {
        try tokenDashboardSeries(
            breakdownDimension: breakdownDimension,
            periodStart: nil,
            periodEnd: nil
        )
    }

    func tokenDashboardSeries(
        breakdownDimension: TokenDashboardBreakdownDimension = .model,
        periodStart: Date?,
        periodEnd: Date?
    ) throws -> [TokenDashboardSeries] {
        if let dimensionKey = breakdownDimension.dimensionKey {
            return try tokenDashboardDimensionSeries(
                for: dimensionKey,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        }

        switch breakdownDimension {
        case .model:
            return try tokenDashboardModelSeries()
        case .effort:
            return try tokenDashboardEffortSeries()
        case .project:
            return try tokenDashboardProjectSeries()
        default:
            return []
        }
    }

    func tokenDashboardAvailableBreakdownDimensions() throws -> [TokenDashboardBreakdownDimension] {
        var dimensions: [TokenDashboardBreakdownDimension] = [.model]

        if try hasRows(in: "token_effort_catalog") {
            dimensions.append(.effort)
        }

        if try hasRows(in: "token_project_catalog") {
            dimensions.append(.project)
        }

        let statement = try prepare(
            """
            SELECT DISTINCT dimension_key
            FROM token_dimension_values
            WHERE dimension_value IS NOT NULL
                AND trim(dimension_value) <> ''
                AND NOT (
                    dimension_key = '\(TokenUsageDimensionKey.sourceKind.rawValue)'
                    AND dimension_value = 'codex-log'
                )
            ORDER BY dimension_key ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var seen = Set(dimensions)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let dimension = TokenDashboardBreakdownDimension(rawValue: columnText(statement, index: 0)),
                      dimension.dimensionKey != nil,
                      seen.insert(dimension).inserted
                else {
                    continue
                }
                dimensions.append(dimension)
            case SQLITE_DONE:
                return dimensions
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenDashboardAvailableBreakdownDimensions(periodStart: Date, periodEnd: Date) throws -> [TokenDashboardBreakdownDimension] {
        var dimensions: [TokenDashboardBreakdownDimension] = [.model]

        if try hasTokenDashboardContextRows(column: "effort", periodStart: periodStart, periodEnd: periodEnd) {
            dimensions.append(.effort)
        }

        if try hasTokenDashboardContextRows(column: "project_path", periodStart: periodStart, periodEnd: periodEnd) {
            dimensions.append(.project)
        }

        let statement = try prepare(
            """
            SELECT dimension_key
            FROM (
                SELECT DISTINCT dimensions.dimension_key
                FROM token_usage_dimension_query_values AS dimensions
                JOIN token_usage_samples AS samples
                    ON samples.thread_id = dimensions.thread_id
                    AND samples.turn_id = dimensions.turn_id
                    AND samples.total_total_tokens = dimensions.total_total_tokens
                WHERE samples.is_retention_baseline = 0
                    AND samples.received_at >= ? AND samples.received_at < ?
                    AND (
                        \(Self.observedTokenComponentsPredicate.replacingOccurrences(of: "observed_", with: "samples.observed_"))
                    )
                    AND dimensions.dimension_value IS NOT NULL
                    AND trim(dimensions.dimension_value) <> ''
                    AND NOT (
                        dimensions.dimension_key = '\(TokenUsageDimensionKey.sourceKind.rawValue)'
                        AND dimensions.dimension_value = 'codex-log'
                    )

                UNION

                SELECT DISTINCT dimension_key
                FROM token_dimension_query_rollups
                WHERE period_start >= ? AND period_start < ?
                    AND dimension_value <> ''
                    AND NOT (
                        dimension_key = '\(TokenUsageDimensionKey.sourceKind.rawValue)'
                        AND dimension_value = 'codex-log'
                    )
            )
            ORDER BY dimension_key ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, periodStart.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, periodEnd.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 3, periodStart.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 4, periodEnd.timeIntervalSince1970Int)

        var meaningfulKeys = Set<TokenDashboardBreakdownDimension>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let dimension = TokenDashboardBreakdownDimension(rawValue: columnText(statement, index: 0)),
                      dimension.dimensionKey != nil
                else {
                    continue
                }
                meaningfulKeys.insert(dimension)
            case SQLITE_DONE:
                var seen = Set(dimensions)
                for dimension in TokenDashboardBreakdownDimension.allCases {
                    guard meaningfulKeys.contains(dimension),
                          seen.insert(dimension).inserted
                    else {
                        continue
                    }
                    dimensions.append(dimension)
                }
                return dimensions
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private func hasTokenDashboardContextRows(column: String, periodStart: Date, periodEnd: Date) throws -> Bool {
        let statement = try prepare(
            """
            SELECT 1
            FROM token_usage_query_samples
            WHERE received_at >= ? AND received_at < ?
                AND \(column) IS NOT NULL
                AND trim(\(column)) <> ''
                AND (
                    \(Self.observedTokenComponentsPredicate)
                )
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, periodStart.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, periodEnd.timeIntervalSince1970Int)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func hasRows(in table: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM \(table) LIMIT 1")
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func tokenDashboardModelSeries() throws -> [TokenDashboardSeries] {
        let statement = try prepare(
            """
            SELECT series_id, series_name, series_kind, seen_at
            FROM token_series_catalog
            WHERE has_input = 1
                OR has_cached = 1
                OR has_output = 1
                OR has_reasoning = 1
            ORDER BY seen_at DESC, series_kind ASC, series_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var seriesByID = [String: TokenDashboardSeries]()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let id = columnText(statement, index: 0)
                guard seriesByID[id] == nil,
                      let kind = TokenDashboardSeriesKind(rawValue: columnText(statement, index: 2))
                else {
                    continue
                }

                let storedName = columnText(statement, index: 1)
                seriesByID[id] = TokenDashboardSeries(
                    id: id,
                    name: id == TokenDashboardSeries.aggregateID ? "All captured" : storedName,
                    kind: kind,
                    contextID: Self.tokenDashboardContextID(seriesID: id, fallback: storedName)
                )
            case SQLITE_DONE:
                return seriesByID.values.sortedByDashboardSeriesOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private func tokenDashboardEffortSeries() throws -> [TokenDashboardSeries] {
        var series = try tokenDashboardAggregateAndUnattributedSeries()
        let statement = try prepare(
            """
            SELECT effort, last_seen_at
            FROM token_effort_catalog
            ORDER BY last_seen_at DESC, effort ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let effort = columnText(statement, index: 0)
                series.append(
                    TokenDashboardSeries(
                        id: "effort:\(effort)",
                        name: effort,
                        kind: .effort,
                        contextID: effort
                    )
                )
            case SQLITE_DONE:
                return series.sortedByDashboardSeriesOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private func tokenDashboardProjectSeries() throws -> [TokenDashboardSeries] {
        var series = try tokenDashboardAggregateAndUnattributedSeries()
        let statement = try prepare(
            """
            SELECT project_path, project_name, display_name, last_seen_at
            FROM token_project_catalog
            ORDER BY last_seen_at DESC, project_name ASC, project_path ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var projectRows: [(path: String, generatedName: String, displayName: String?)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                projectRows.append((
                    path: columnText(statement, index: 0),
                    generatedName: columnText(statement, index: 1),
                    displayName: optionalColumnText(statement, index: 2)
                ))
            case SQLITE_DONE:
                let displayNames = Self.disambiguatedProjectDisplayNames(for: projectRows)
                for row in projectRows {
                    series.append(
                        TokenDashboardSeries(
                            id: "project:\(row.path)",
                            name: displayNames[row.path] ?? Self.projectBaseDisplayName(for: row),
                            kind: .project,
                            contextID: row.path,
                            projectPath: row.path
                        )
                    )
                }
                return series.sortedByDashboardSeriesOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private func tokenDashboardDimensionSeries(
        for key: TokenUsageDimensionKey,
        periodStart: Date?,
        periodEnd: Date?
    ) throws -> [TokenDashboardSeries] {
        var series = try tokenDashboardAggregateAndUnattributedSeries()
        let periodFilter: String
        if periodStart != nil, periodEnd != nil {
            periodFilter = """
                AND (
                    EXISTS (
                        SELECT 1
                        FROM token_usage_dimension_query_values AS dimensions
                        JOIN token_usage_samples AS samples
                            ON samples.thread_id = dimensions.thread_id
                            AND samples.turn_id = dimensions.turn_id
                            AND samples.total_total_tokens = dimensions.total_total_tokens
                        WHERE samples.is_retention_baseline = 0
                            AND dimensions.dimension_key = token_dimension_values.dimension_key
                            AND dimensions.dimension_value = token_dimension_values.dimension_value
                            AND samples.received_at >= ? AND samples.received_at < ?
                            AND (
                                \(Self.observedTokenComponentsPredicate.replacingOccurrences(of: "observed_", with: "samples.observed_"))
                            )
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM token_dimension_query_rollups AS rollups
                        WHERE rollups.dimension_key = token_dimension_values.dimension_key
                            AND rollups.dimension_value = token_dimension_values.dimension_value
                            AND rollups.period_start >= ? AND rollups.period_start < ?
                            AND NOT (
                                rollups.dimension_key = '\(TokenUsageDimensionKey.sourceKind.rawValue)'
                                AND rollups.dimension_value = 'codex-log'
                            )
                    )
                )
            """
        } else {
            periodFilter = ""
        }

        let statement = try prepare(
            """
            SELECT dimension_value, last_seen_at
            FROM token_dimension_values
            WHERE dimension_key = ?
            \(periodFilter)
            ORDER BY last_seen_at DESC, dimension_value ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(key.rawValue, to: 1, in: statement)
        if let periodStart, let periodEnd {
            sqlite3_bind_int64(statement, 2, periodStart.timeIntervalSince1970Int)
            sqlite3_bind_int64(statement, 3, periodEnd.timeIntervalSince1970Int)
            sqlite3_bind_int64(statement, 4, periodStart.timeIntervalSince1970Int)
            sqlite3_bind_int64(statement, 5, periodEnd.timeIntervalSince1970Int)
        }

        var values = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let value = columnText(statement, index: 0)
                guard key.isMeaningfulDashboardValue(value),
                      values.insert(value).inserted
                else {
                    continue
                }
                series.append(
                    TokenDashboardSeries(
                        id: "dimension:\(key.rawValue):\(value)",
                        name: key.dashboardDisplayValue(value),
                        kind: .dimension,
                        contextID: value,
                        dimensionKey: key
                    )
                )
            case SQLITE_DONE:
                return series.sortedByDashboardSeriesOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private func tokenDashboardAggregateAndUnattributedSeries() throws -> [TokenDashboardSeries] {
        let hasTokens = try tokenDashboardModelSeries().contains { $0.id == TokenDashboardSeries.aggregateID }
        guard hasTokens else {
            return []
        }

        return [
            TokenDashboardSeries(
                id: TokenDashboardSeries.aggregateID,
                name: "All captured",
                kind: .aggregate,
                contextID: "all"
            ),
            TokenDashboardSeries(
                id: TokenDashboardSeries.unattributedID,
                name: "Unattributed",
                kind: .unattributed,
                contextID: "unattributed"
            ),
        ]
    }

    func tokenDashboardBounds() throws -> UsageHistoryBounds? {
        try tokenComponentHistoryBounds()
    }

    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) throws -> [TokenAttributionCoverageRow] {
        let statement = try prepare(
            Self.tokenAttributionCoverageSQL()
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, periodStart.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, periodEnd.timeIntervalSince1970Int)

        var coreRowsByID: [String: TokenAttributionCoverageRow] = [:]
        var dimensionRowsByKey: [TokenUsageDimensionKey: TokenAttributionCoverageRow] = [:]
        var totalTokenCount: Int64 = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                totalTokenCount = sqlite3_column_int64(statement, 5)
                guard totalTokenCount > 0 else {
                    continue
                }

                let id = columnText(statement, index: 0)
                let attributedTokenCount = sqlite3_column_int64(statement, 3)
                let row = TokenAttributionCoverageRow(
                    id: id,
                    title: tokenAttributionCoverageTitle(id: id, dimensionKey: optionalColumnText(statement, index: 2)),
                    attributedTokenCount: attributedTokenCount,
                    missingTokenCount: max(totalTokenCount - attributedTokenCount, 0),
                    distinctValueCount: Int(sqlite3_column_int(statement, 4)),
                    dimensionKey: optionalColumnText(statement, index: 2).flatMap(TokenUsageDimensionKey.init(rawValue:))
                )
                if let dimensionKey = row.dimensionKey {
                    guard attributedTokenCount > 0, row.distinctValueCount > 0 else {
                        continue
                    }
                    dimensionRowsByKey[dimensionKey] = row
                } else {
                    coreRowsByID[id] = row
                }
            case SQLITE_DONE:
                guard totalTokenCount > 0 else {
                    return []
                }

                let coreRows = ["model", "project", "effort", "source"].compactMap { coreRowsByID[$0] }
                return coreRows + TokenUsageDimensionKey.allCases.compactMap { dimensionRowsByKey[$0] }
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    static func tokenAttributionCoverageSQL() -> String {
        """
        WITH period_samples AS MATERIALIZED (
            SELECT thread_id,
                turn_id,
                total_total_tokens,
                \(observedTokenVolumeSQLExpression()) AS token_count,
                \(normalizedModelSQLExpression(column: "model")) AS model_value,
                project_path,
                effort,
                source
            FROM token_usage_query_samples
            WHERE received_at >= ?1 AND received_at < ?2
                AND (
                    \(observedTokenComponentsPredicate)
                )
        ),
        total AS (
            SELECT IFNULL(SUM(token_count), 0) AS total_token_count
            FROM period_samples
        ),
        core_values AS (
            SELECT 'model' AS id, model_value AS value, token_count FROM period_samples
            UNION ALL
            SELECT 'project' AS id, project_path AS value, token_count FROM period_samples
            UNION ALL
            SELECT 'effort' AS id, effort AS value, token_count FROM period_samples
            UNION ALL
            SELECT 'source' AS id, source AS value, token_count FROM period_samples
        ),
        core_coverage AS (
            SELECT id,
                NULL AS dimension_key,
                IFNULL(SUM(
                    CASE
                        WHEN value IS NOT NULL AND trim(value) <> ''
                            THEN token_count
                        ELSE 0
                    END
                ), 0) AS attributed_token_count,
                COUNT(DISTINCT
                    CASE
                        WHEN value IS NOT NULL AND trim(value) <> ''
                            THEN value
                    END
                ) AS distinct_value_count
            FROM core_values
            GROUP BY id
        ),
        dimension_sample_values AS (
            SELECT period_samples.thread_id,
                period_samples.turn_id,
                period_samples.total_total_tokens,
                dimensions.dimension_key,
                period_samples.token_count,
                MIN(
                    CASE
                        WHEN dimensions.dimension_value IS NOT NULL
                            AND trim(dimensions.dimension_value) <> ''
                            AND NOT (
                                dimensions.dimension_key = '\(TokenUsageDimensionKey.sourceKind.rawValue)'
                                AND dimensions.dimension_value = 'codex-log'
                            )
                            THEN dimensions.dimension_value
                    END
                ) AS value
            FROM period_samples
            JOIN token_usage_dimension_query_values AS dimensions
                ON dimensions.thread_id = period_samples.thread_id
                AND dimensions.turn_id = period_samples.turn_id
                AND dimensions.total_total_tokens = period_samples.total_total_tokens
            GROUP BY period_samples.thread_id,
                period_samples.turn_id,
                period_samples.total_total_tokens,
                dimensions.dimension_key,
                period_samples.token_count
        ),
        dimension_coverage AS (
            SELECT 'dimension:' || dimension_key AS id,
                dimension_key,
                IFNULL(SUM(
                    CASE
                        WHEN value IS NOT NULL AND trim(value) <> ''
                            THEN token_count
                        ELSE 0
                    END
                ), 0) AS attributed_token_count,
                COUNT(DISTINCT
                    CASE
                        WHEN value IS NOT NULL AND trim(value) <> ''
                            THEN value
                    END
                ) AS distinct_value_count
            FROM (
                SELECT dimension_key, value, token_count
                FROM dimension_sample_values

                UNION ALL

                SELECT dimension_key,
                    NULLIF(dimension_value, '') AS value,
                    \(observedTokenVolumeSQLExpression()) AS token_count
                FROM token_dimension_query_rollups
                WHERE period_start >= ?1 AND period_start < ?2
            )
            GROUP BY dimension_key
        )
        SELECT coverage.id,
            coverage.row_order,
            coverage.dimension_key,
            coverage.attributed_token_count,
            coverage.distinct_value_count,
            total.total_token_count
        FROM (
            SELECT id,
                CASE id
                    WHEN 'model' THEN 0
                    WHEN 'project' THEN 1
                    WHEN 'effort' THEN 2
                    WHEN 'source' THEN 3
                    ELSE 4
                END AS row_order,
                dimension_key,
                attributed_token_count,
                distinct_value_count
            FROM core_coverage
            UNION ALL
            SELECT id,
                4 AS row_order,
                dimension_key,
                attributed_token_count,
                distinct_value_count
            FROM dimension_coverage
            WHERE attributed_token_count > 0 AND distinct_value_count > 0
        ) AS coverage
        CROSS JOIN total
        ORDER BY coverage.row_order ASC, coverage.id ASC
        """
    }

    private func tokenAttributionCoverageTitle(id: String, dimensionKey: String?) -> String {
        if let dimensionKey, let key = TokenUsageDimensionKey(rawValue: dimensionKey) {
            return key.dashboardDisplayTitle
        }

        switch id {
        case "model":
            return "Model"
        case "project":
            return "Project"
        case "effort":
            return "Effort"
        case "source":
            return "Source"
        default:
            return id
        }
    }

    func tokenProjectCatalogEntries() throws -> [TokenProjectCatalogEntry] {
        let statement = try prepare(
            """
            SELECT project_path, project_name, display_name, first_seen_at, last_seen_at
            FROM token_project_catalog
            ORDER BY last_seen_at DESC, project_name ASC, project_path ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var entries: [TokenProjectCatalogEntry] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                entries.append(
                    TokenProjectCatalogEntry(
                        projectPath: columnText(statement, index: 0),
                        generatedName: columnText(statement, index: 1),
                        displayName: optionalColumnText(statement, index: 2),
                        firstSeenAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3))),
                        lastSeenAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4)))
                    )
                )
            case SQLITE_DONE:
                return entries.sorted { lhs, rhs in
                    if lhs.lastSeenAt != rhs.lastSeenAt {
                        return lhs.lastSeenAt > rhs.lastSeenAt
                    }

                    let nameComparison = lhs.effectiveDisplayName.localizedStandardCompare(rhs.effectiveDisplayName)
                    if nameComparison != .orderedSame {
                        return nameComparison == .orderedAscending
                    }

                    return lhs.projectPath.localizedStandardCompare(rhs.projectPath) == .orderedAscending
                }
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenDimensionCatalogEntries() throws -> [TokenUsageDimensionCatalogEntry] {
        let statement = try prepare(
            """
            SELECT dimension_key, dimension_value, first_seen_at, last_seen_at
            FROM token_dimension_values
            ORDER BY dimension_key ASC, last_seen_at DESC, dimension_value ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var entries: [TokenUsageDimensionCatalogEntry] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let key = TokenUsageDimensionKey(rawValue: columnText(statement, index: 0)) else {
                    continue
                }
                entries.append(
                    TokenUsageDimensionCatalogEntry(
                        key: key,
                        value: columnText(statement, index: 1),
                        firstSeenAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2))),
                        lastSeenAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3)))
                    )
                )
            case SQLITE_DONE:
                return entries
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) throws {
        try updateTokenProjectDisplayName(projectPath: projectPath, displayName: displayName, postNotification: true)
    }

    func updateTokenProjectDisplayName(
        projectPath: String,
        displayName: String?,
        postNotification: Bool,
        requireExisting: Bool = true
    ) throws {
        let normalizedDisplayName = try Self.normalizedProjectDisplayNameForStorage(displayName)
        let statement = try prepare(
            """
            UPDATE token_project_catalog
            SET display_name = ?
            WHERE project_path = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        bindOptionalText(normalizedDisplayName, to: 1, in: statement)
        bindText(projectPath, to: 2, in: statement)
        try step(statement)

        guard !requireExisting || sqlite3_changes(database) > 0 else {
            throw UsageHistoryStoreError.databaseOperationFailed("Project was not found.")
        }

        if postNotification {
            notificationCenter.post(name: Self.didChangeNotification, object: self)
        }
    }

    private static func tokenDashboardSeriesIdentity(
        breakdownDimension: TokenDashboardBreakdownDimension,
        model: String?,
        effort: String?,
        projectPath: String?,
        projectName: String?
    ) -> (id: String, name: String, kind: TokenDashboardSeriesKind) {
        switch breakdownDimension {
        case .model:
            guard let model, !model.isEmpty else {
                return unattributedTokenDashboardSeriesIdentity()
            }

            return ("model:\(model)", model, .model)
        case .effort:
            guard let effort, !effort.isEmpty else {
                return unattributedTokenDashboardSeriesIdentity()
            }

            return ("effort:\(effort)", effort, .effort)
        case .project:
            guard let projectPath, !projectPath.isEmpty else {
                return unattributedTokenDashboardSeriesIdentity()
            }

            let fallbackName = URL(fileURLWithPath: projectPath).lastPathComponent
            let name = projectName.flatMap { $0.isEmpty ? nil : $0 } ?? (fallbackName.isEmpty ? projectPath : fallbackName)
            return ("project:\(projectPath)", name, .project)
        default:
            return unattributedTokenDashboardSeriesIdentity()
        }
    }

    private static func tokenDashboardDimensionSeriesIdentity(
        key: TokenUsageDimensionKey,
        value: String?
    ) -> (id: String, name: String, kind: TokenDashboardSeriesKind) {
        guard let value, key.isMeaningfulDashboardValue(value) else {
            return unattributedTokenDashboardSeriesIdentity()
        }

        return ("dimension:\(key.rawValue):\(value)", key.dashboardDisplayValue(value), .dimension)
    }

    private static func unattributedTokenDashboardSeriesIdentity() -> (id: String, name: String, kind: TokenDashboardSeriesKind) {
        (TokenDashboardSeries.unattributedID, "Unattributed", .unattributed)
    }

    private static func tokenDashboardContextID(seriesID: String, fallback: String) -> String {
        if seriesID == TokenDashboardSeries.aggregateID {
            return "all"
        }

        if seriesID == TokenDashboardSeries.unattributedID {
            return "unattributed"
        }

        return fallback
    }

    private static func observedTokenVolumeSQLExpression(prefix: String = "") -> String {
        let columnPrefix = prefix.isEmpty ? "" : "\(prefix)."
        return """
        IFNULL(\(columnPrefix)observed_input_tokens, 0)
            + IFNULL(\(columnPrefix)observed_cached_input_tokens, 0)
            + IFNULL(\(columnPrefix)observed_output_tokens, 0)
            + IFNULL(\(columnPrefix)observed_reasoning_output_tokens, 0)
        """
    }

    static func normalizedProjectDisplayNameForStorage(_ value: String?) throws -> String? {
        if CodexTokenContextNormalizer.isInvalidNonBlankProjectDisplayName(value) {
            throw UsageHistoryStoreError.invalidProjectDisplayName
        }

        return CodexTokenContextNormalizer.normalizedProjectDisplayName(value)
    }

    private static func disambiguatedProjectDisplayNames(
        for rows: [(path: String, generatedName: String, displayName: String?)]
    ) -> [String: String] {
        let nameCounts = Dictionary(grouping: rows) { row in
            projectBaseDisplayName(for: row)
        }.mapValues(\.count)
        var displayNames = [String: String]()
        var candidateCounts = [String: Int]()

        for row in rows {
            let baseName = projectBaseDisplayName(for: row)
            guard nameCounts[baseName, default: 0] > 1 else {
                displayNames[row.path] = baseName
                continue
            }

            let parent = URL(fileURLWithPath: row.path)
                .deletingLastPathComponent()
                .lastPathComponent
            let candidate = parent.isEmpty ? baseName : "\(baseName) (\(parent))"
            candidateCounts[candidate, default: 0] += 1
            displayNames[row.path] = candidate
        }

        for row in rows {
            guard let candidate = displayNames[row.path],
                  candidateCounts[candidate, default: 0] > 1
            else {
                continue
            }

            displayNames[row.path] = "\(candidate) - \(row.path)"
        }

        return displayNames
    }

    private static func projectBaseDisplayName(
        for row: (path: String, generatedName: String, displayName: String?)
    ) -> String {
        if let displayName = row.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty
        {
            return displayName
        }

        let generatedName = row.generatedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !generatedName.isEmpty {
            return generatedName
        }

        let fallback = URL(fileURLWithPath: row.path).lastPathComponent
        return fallback.isEmpty ? row.path : fallback
    }
}

private struct TokenDashboardAccumulatorKey: Hashable {
    let bucketStart: Date
    let seriesID: String
    let component: TokenHistoryComponent
}

private struct TokenDashboardAccumulator {
    let bucketStart: Date
    let bucketEnd: Date
    let seriesID: String
    let seriesName: String
    let seriesKind: TokenDashboardSeriesKind
    let component: TokenHistoryComponent
    var tokenCount: Int64
}

private func addTokenDashboardAccumulator(
    bucketStart: Date,
    bucketEnd: Date,
    seriesID: String,
    seriesName: String,
    seriesKind: TokenDashboardSeriesKind,
    component: TokenHistoryComponent,
    tokenCount: Int64,
    to accumulators: inout [TokenDashboardAccumulatorKey: TokenDashboardAccumulator]
) {
    let key = TokenDashboardAccumulatorKey(
        bucketStart: bucketStart,
        seriesID: seriesID,
        component: component
    )
    var accumulator = accumulators[key] ?? TokenDashboardAccumulator(
        bucketStart: bucketStart,
        bucketEnd: bucketEnd,
        seriesID: seriesID,
        seriesName: seriesName,
        seriesKind: seriesKind,
        component: component,
        tokenCount: 0
    )
    accumulator.tokenCount += tokenCount
    accumulators[key] = accumulator
}

private extension Array where Element == TokenDashboardComponentPoint {
    func sortedByStoreDashboardDisplayOrder() -> [TokenDashboardComponentPoint] {
        sorted { lhs, rhs in
            if lhs.bucketStart != rhs.bucketStart {
                return lhs.bucketStart < rhs.bucketStart
            }

            if lhs.seriesKind != rhs.seriesKind {
                return lhs.seriesKind.storeSortIndex < rhs.seriesKind.storeSortIndex
            }

            if lhs.seriesName != rhs.seriesName {
                return lhs.seriesName.localizedStandardCompare(rhs.seriesName) == .orderedAscending
            }

            return lhs.component.storeSortIndex < rhs.component.storeSortIndex
        }
    }
}

private extension Collection where Element == TokenDashboardSeries {
    func sortedByDashboardSeriesOrder() -> [TokenDashboardSeries] {
        sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind.storeSortIndex < rhs.kind.storeSortIndex
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

private extension TokenDashboardSeriesKind {
    var storeSortIndex: Int {
        switch self {
        case .aggregate:
            return 0
        case .model, .effort, .project, .dimension:
            return 1
        case .unattributed:
            return 2
        }
    }
}

private extension TokenHistoryComponent {
    var storeSortIndex: Int {
        switch self {
        case .input:
            return 0
        case .cached:
            return 1
        case .output:
            return 2
        case .reasoning:
            return 3
        }
    }
}
