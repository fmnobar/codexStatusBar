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
            FROM token_usage_samples
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
                IFNULL(SUM(observed_total_tokens), 0)
            FROM token_usage_samples
            WHERE received_at >= ? AND received_at < ?
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

            return sqlite3_column_int64(statement, 1)
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
                IFNULL(SUM(observed_reasoning_output_tokens), 0),
                IFNULL(SUM(observed_total_tokens), 0)
            FROM token_usage_samples
            WHERE received_at >= ? AND received_at < ?
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

            return TokenCategoryTotals(
                inputTokens: sqlite3_column_int64(statement, 2),
                cachedInputTokens: sqlite3_column_int64(statement, 3),
                outputTokens: sqlite3_column_int64(statement, 4),
                reasoningOutputTokens: sqlite3_column_int64(statement, 5),
                totalTokens: sqlite3_column_int64(statement, 6)
            )
        case SQLITE_DONE:
            return nil
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
                FROM token_usage_samples
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
                FROM token_usage_samples
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
                JOIN token_usage_samples s
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
            FROM token_usage_samples
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
            FROM token_usage_samples
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
            FROM token_usage_samples
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

    func tokenDashboardSeries(
        breakdownDimension: TokenDashboardBreakdownDimension = .model
    ) throws -> [TokenDashboardSeries] {
        switch breakdownDimension {
        case .model:
            return try tokenDashboardModelSeries()
        case .effort:
            return try tokenDashboardEffortSeries()
        case .project:
            return try tokenDashboardProjectSeries()
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
            SELECT project_path, project_name, last_seen_at
            FROM token_project_catalog
            ORDER BY last_seen_at DESC, project_name ASC, project_path ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var projectRows: [(path: String, name: String)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                projectRows.append((
                    path: columnText(statement, index: 0),
                    name: columnText(statement, index: 1)
                ))
            case SQLITE_DONE:
                let displayNames = Self.disambiguatedProjectDisplayNames(for: projectRows)
                for row in projectRows {
                    series.append(
                        TokenDashboardSeries(
                            id: "project:\(row.path)",
                            name: displayNames[row.path] ?? row.name,
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
        }
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

    private static func disambiguatedProjectDisplayNames(
        for rows: [(path: String, name: String)]
    ) -> [String: String] {
        let nameCounts = Dictionary(grouping: rows, by: \.name).mapValues(\.count)
        var displayNames = [String: String]()
        var candidateCounts = [String: Int]()

        for row in rows {
            let baseName = row.name.isEmpty ? URL(fileURLWithPath: row.path).lastPathComponent : row.name
            guard nameCounts[row.name, default: 0] > 1 else {
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
        case .model, .effort, .project:
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
