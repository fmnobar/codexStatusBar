import Foundation
import SQLite3

extension UsageHistoryStore {
    func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS usage_samples (
                bucket_id TEXT NOT NULL,
                bucket_name TEXT NOT NULL,
                bucket_kind TEXT NOT NULL,
                window TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                used_percent INTEGER NOT NULL,
                consumed_percent REAL,
                reset_at INTEGER,
                PRIMARY KEY (bucket_id, window, timestamp)
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS usage_rollups (
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
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS token_usage_samples (
                thread_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                model TEXT,
                session_id TEXT,
                project_path TEXT,
                project_name TEXT,
                effort TEXT,
                source TEXT,
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
                observed_input_tokens INTEGER,
                observed_cached_input_tokens INTEGER,
                observed_output_tokens INTEGER,
                observed_reasoning_output_tokens INTEGER,
                observed_total_tokens INTEGER NOT NULL,
                PRIMARY KEY (thread_id, turn_id, total_total_tokens)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS codex_session_token_imports (
                file_path TEXT PRIMARY KEY,
                file_size INTEGER NOT NULL,
                modified_at INTEGER NOT NULL,
                imported_at INTEGER NOT NULL,
                status TEXT NOT NULL,
                context_version TEXT
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS usage_history_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS usage_series_catalog (
                window TEXT NOT NULL,
                bucket_id TEXT NOT NULL,
                bucket_name TEXT NOT NULL,
                bucket_kind TEXT NOT NULL,
                seen_at INTEGER NOT NULL,
                PRIMARY KEY (window, bucket_id)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS token_series_catalog (
                series_id TEXT PRIMARY KEY,
                series_name TEXT NOT NULL,
                series_kind TEXT NOT NULL,
                seen_at INTEGER NOT NULL,
                has_total INTEGER NOT NULL DEFAULT 0,
                has_input INTEGER NOT NULL DEFAULT 0,
                has_cached INTEGER NOT NULL DEFAULT 0,
                has_output INTEGER NOT NULL DEFAULT 0,
                has_reasoning INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS token_project_catalog (
                project_path TEXT PRIMARY KEY,
                project_name TEXT NOT NULL,
                display_name TEXT,
                first_seen_at INTEGER NOT NULL,
                last_seen_at INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS token_effort_catalog (
                effort TEXT PRIMARY KEY,
                first_seen_at INTEGER NOT NULL,
                last_seen_at INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS token_source_catalog (
                source TEXT PRIMARY KEY,
                first_seen_at INTEGER NOT NULL,
                last_seen_at INTEGER NOT NULL
            )
            """
        )
        try addColumnIfNeeded(table: "usage_rollups", column: "peak_used_percent", definition: "INTEGER")
        try addColumnIfNeeded(table: "usage_samples", column: "consumed_percent", definition: "REAL")
        try addColumnIfNeeded(table: "usage_rollups", column: "consumed_percent", definition: "REAL")
        try addColumnIfNeeded(table: "token_usage_samples", column: "session_id", definition: "TEXT")
        try addColumnIfNeeded(table: "token_usage_samples", column: "project_path", definition: "TEXT")
        try addColumnIfNeeded(table: "token_usage_samples", column: "project_name", definition: "TEXT")
        try addColumnIfNeeded(table: "token_usage_samples", column: "effort", definition: "TEXT")
        try addColumnIfNeeded(table: "token_usage_samples", column: "source", definition: "TEXT")
        try addColumnIfNeeded(table: "token_usage_samples", column: "observed_input_tokens", definition: "INTEGER")
        try addColumnIfNeeded(table: "token_usage_samples", column: "observed_cached_input_tokens", definition: "INTEGER")
        try addColumnIfNeeded(table: "token_usage_samples", column: "observed_output_tokens", definition: "INTEGER")
        try addColumnIfNeeded(table: "token_usage_samples", column: "observed_reasoning_output_tokens", definition: "INTEGER")
        try addColumnIfNeeded(table: "codex_session_token_imports", column: "context_version", definition: "TEXT")
        try addColumnIfNeeded(table: "token_series_catalog", column: "has_total", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded(table: "token_series_catalog", column: "has_input", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded(table: "token_series_catalog", column: "has_cached", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded(table: "token_series_catalog", column: "has_output", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded(table: "token_series_catalog", column: "has_reasoning", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded(table: "token_project_catalog", column: "display_name", definition: "TEXT")

        try execute("CREATE INDEX IF NOT EXISTS idx_usage_samples_window_timestamp ON usage_samples(window, timestamp)")
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_samples_window_bucket_timestamp ON usage_samples(window, bucket_id, timestamp DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_rollups_window_sample_timestamp ON usage_rollups(granularity, window, sample_timestamp)")
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_rollups_window_bucket_sample_timestamp ON usage_rollups(window, bucket_id, sample_timestamp DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_usage_samples_received_at ON token_usage_samples(received_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_usage_samples_model_received_at ON token_usage_samples(model, received_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_usage_samples_project_received_at ON token_usage_samples(project_path, received_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_usage_samples_effort_received_at ON token_usage_samples(effort, received_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_usage_samples_source_received_at ON token_usage_samples(source, received_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_usage_samples_thread_total ON token_usage_samples(thread_id, total_total_tokens)")
        try execute(
            """
            CREATE INDEX IF NOT EXISTS idx_token_usage_samples_observed_components_received_at
            ON token_usage_samples(received_at)
            WHERE \(Self.observedTokenComponentsPredicate)
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_codex_session_token_imports_status ON codex_session_token_imports(status, imported_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_series_catalog_window_seen ON usage_series_catalog(window, seen_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_series_catalog_kind_seen ON token_series_catalog(series_kind, seen_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_project_catalog_last_seen ON token_project_catalog(last_seen_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_effort_catalog_last_seen ON token_effort_catalog(last_seen_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_source_catalog_last_seen ON token_source_catalog(last_seen_at DESC)")

        try cleanupTokenModelLabelsIfNeeded()
        try cleanupTokenContextValuesIfNeeded()
        try recomputeStoredUsageConsumptionIfNeeded()
        try rebuildSeriesCatalogsIfNeeded()
    }

    func cleanupTokenModelLabelsIfNeeded() throws {
        guard try metadataValue(for: Self.tokenModelCleanupMetadataKey) != Self.currentTokenModelCleanupVersion else {
            return
        }

        if try cleanupTokenModelLabels() {
            try rebuildTokenSeriesCatalog()
        }
        try setMetadataValue(Self.currentTokenModelCleanupVersion, for: Self.tokenModelCleanupMetadataKey)
    }

    @discardableResult
    func cleanupTokenModelLabels() throws -> Bool {
        var rawModels: [String] = []
        do {
            let statement = try prepare(
                """
                SELECT DISTINCT model
                FROM token_usage_samples
                WHERE model IS NOT NULL
                """
            )
            defer { sqlite3_finalize(statement) }

            rawModelLoop:
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    rawModels.append(columnText(statement, index: 0))
                case SQLITE_DONE:
                    break rawModelLoop
                default:
                    throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
                }
            }
        }

        guard !rawModels.isEmpty else {
            return false
        }

        var didChange = false
        try transaction {
            for rawModel in rawModels {
                let normalizedModel = normalizedModelName(rawModel)
                guard normalizedModel != rawModel else {
                    continue
                }

                try updateStoredTokenModel(from: rawModel, to: normalizedModel)
                didChange = true
            }
        }

        return didChange
    }

    func cleanupTokenContextValuesIfNeeded() throws {
        guard try metadataValue(for: Self.tokenContextCleanupMetadataKey) != Self.currentTokenContextCleanupVersion else {
            return
        }

        if try cleanupTokenContextValues() {
            try rebuildTokenContextCatalogs()
        }
        try setMetadataValue(Self.currentTokenContextCleanupVersion, for: Self.tokenContextCleanupMetadataKey)
    }

    @discardableResult
    func cleanupTokenContextValues() throws -> Bool {
        struct ContextRow {
            let rowID: Int64
            let context: TokenUsageContext
        }

        var rows: [ContextRow] = []
        do {
            let statement = try prepare(
                """
                SELECT rowid, session_id, project_path, effort, source
                FROM token_usage_samples
                WHERE session_id IS NOT NULL
                    OR project_path IS NOT NULL
                    OR project_name IS NOT NULL
                    OR effort IS NOT NULL
                    OR source IS NOT NULL
                """
            )
            defer { sqlite3_finalize(statement) }

            rowLoop:
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    rows.append(
                        ContextRow(
                            rowID: sqlite3_column_int64(statement, 0),
                            context: TokenUsageContext(
                                sessionID: optionalColumnText(statement, index: 1),
                                projectPath: optionalColumnText(statement, index: 2),
                                effort: optionalColumnText(statement, index: 3),
                                source: optionalColumnText(statement, index: 4)
                            )
                        )
                    )
                case SQLITE_DONE:
                    break rowLoop
                default:
                    throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
                }
            }
        }

        guard !rows.isEmpty else {
            return false
        }

        var didChange = false
        try transaction {
            for row in rows {
                let statement = try prepare(
                    """
                    UPDATE token_usage_samples
                    SET session_id = ?,
                        project_path = ?,
                        project_name = ?,
                        effort = ?,
                        source = ?
                    WHERE rowid = ?
                    """
                )
                defer { sqlite3_finalize(statement) }

                bindOptionalText(row.context.sessionID, to: 1, in: statement)
                bindOptionalText(row.context.projectPath, to: 2, in: statement)
                bindOptionalText(row.context.projectName, to: 3, in: statement)
                bindOptionalText(row.context.effort, to: 4, in: statement)
                bindOptionalText(row.context.source, to: 5, in: statement)
                sqlite3_bind_int64(statement, 6, row.rowID)
                try step(statement)
                didChange = didChange || sqlite3_changes(database) > 0
            }
        }

        return didChange
    }

    func rebuildSeriesCatalogsIfNeeded() throws {
        guard try metadataValue(for: Self.seriesCatalogMetadataKey) != Self.currentSeriesCatalogVersion else {
            return
        }

        try rebuildSeriesCatalogs()
    }

    func rebuildSeriesCatalogs() throws {
        try rebuildUsageSeriesCatalog()
        try rebuildTokenSeriesCatalog()
        try rebuildTokenContextCatalogs()
        try setMetadataValue(Self.currentSeriesCatalogVersion, for: Self.seriesCatalogMetadataKey)
    }

    func rebuildUsageSeriesCatalog() throws {
        try execute("DELETE FROM usage_series_catalog")
        try execute(
            """
            INSERT INTO usage_series_catalog (
                window, bucket_id, bucket_name, bucket_kind, seen_at
            )
            SELECT latest.window,
                latest.bucket_id,
                COALESCE(
                    (
                        SELECT source.bucket_name
                        FROM (
                            SELECT bucket_id, bucket_name, bucket_kind, window, timestamp AS seen_at
                            FROM usage_samples
                            UNION ALL
                            SELECT bucket_id, bucket_name, bucket_kind, window, sample_timestamp AS seen_at
                            FROM usage_rollups
                        ) source
                        WHERE source.window = latest.window
                            AND source.bucket_id = latest.bucket_id
                            AND source.seen_at = latest.seen_at
                        ORDER BY source.bucket_kind ASC, source.bucket_name ASC
                        LIMIT 1
                    ),
                    latest.bucket_id
                ) AS bucket_name,
                COALESCE(
                    (
                        SELECT source.bucket_kind
                        FROM (
                            SELECT bucket_id, bucket_name, bucket_kind, window, timestamp AS seen_at
                            FROM usage_samples
                            UNION ALL
                            SELECT bucket_id, bucket_name, bucket_kind, window, sample_timestamp AS seen_at
                            FROM usage_rollups
                        ) source
                        WHERE source.window = latest.window
                            AND source.bucket_id = latest.bucket_id
                            AND source.seen_at = latest.seen_at
                        ORDER BY source.bucket_kind ASC, source.bucket_name ASC
                        LIMIT 1
                    ),
                    'model'
                ) AS bucket_kind,
                latest.seen_at
            FROM (
                SELECT window, bucket_id, MAX(seen_at) AS seen_at
                FROM (
                    SELECT window, bucket_id, timestamp AS seen_at
                    FROM usage_samples
                    UNION ALL
                    SELECT window, bucket_id, sample_timestamp AS seen_at
                    FROM usage_rollups
                )
                GROUP BY window, bucket_id
            ) latest
            """
        )
    }

    func rebuildTokenSeriesCatalog() throws {
        try execute("DELETE FROM token_series_catalog")
        try execute(
            """
            INSERT INTO token_series_catalog (
                series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            )
            SELECT series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            FROM (
                SELECT 'tokens_all' AS series_id,
                    'All tokens' AS series_name,
                    'aggregate' AS series_kind,
                    MAX(received_at) AS seen_at,
                    MAX(CASE WHEN observed_total_tokens > 0 THEN 1 ELSE 0 END) AS has_total,
                    MAX(CASE WHEN observed_input_tokens > 0 THEN 1 ELSE 0 END) AS has_input,
                    MAX(CASE WHEN observed_cached_input_tokens > 0 THEN 1 ELSE 0 END) AS has_cached,
                    MAX(CASE WHEN observed_output_tokens > 0 THEN 1 ELSE 0 END) AS has_output,
                    MAX(CASE WHEN observed_reasoning_output_tokens > 0 THEN 1 ELSE 0 END) AS has_reasoning
                FROM token_usage_samples
            )
            WHERE has_total = 1
                OR has_input = 1
                OR has_cached = 1
                OR has_output = 1
                OR has_reasoning = 1
            """
        )

        let normalizedModelExpression = Self.normalizedModelSQLExpression(column: "model")
        try execute(
            """
            INSERT INTO token_series_catalog (
                series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            )
            SELECT series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            FROM (
                SELECT 'model:' || normalized_model AS series_id,
                    normalized_model AS series_name,
                    'model' AS series_kind,
                    MAX(received_at) AS seen_at,
                    MAX(CASE WHEN observed_total_tokens > 0 THEN 1 ELSE 0 END) AS has_total,
                    MAX(CASE WHEN observed_input_tokens > 0 THEN 1 ELSE 0 END) AS has_input,
                    MAX(CASE WHEN observed_cached_input_tokens > 0 THEN 1 ELSE 0 END) AS has_cached,
                    MAX(CASE WHEN observed_output_tokens > 0 THEN 1 ELSE 0 END) AS has_output,
                    MAX(CASE WHEN observed_reasoning_output_tokens > 0 THEN 1 ELSE 0 END) AS has_reasoning
                FROM (
                    SELECT received_at,
                        \(normalizedModelExpression) AS normalized_model,
                        observed_total_tokens,
                        observed_input_tokens,
                        observed_cached_input_tokens,
                        observed_output_tokens,
                        observed_reasoning_output_tokens
                    FROM token_usage_samples
                )
                WHERE normalized_model IS NOT NULL
                GROUP BY normalized_model
            )
            WHERE has_total = 1
                OR has_input = 1
                OR has_cached = 1
                OR has_output = 1
                OR has_reasoning = 1
            """
        )
        try execute(
            """
            INSERT INTO token_series_catalog (
                series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            )
            SELECT series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            FROM (
                SELECT '\(TokenDashboardSeries.unattributedID)' AS series_id,
                    'Unattributed' AS series_name,
                    'unattributed' AS series_kind,
                    MAX(received_at) AS seen_at,
                    0 AS has_total,
                    MAX(CASE WHEN observed_input_tokens > 0 THEN 1 ELSE 0 END) AS has_input,
                    MAX(CASE WHEN observed_cached_input_tokens > 0 THEN 1 ELSE 0 END) AS has_cached,
                    MAX(CASE WHEN observed_output_tokens > 0 THEN 1 ELSE 0 END) AS has_output,
                    MAX(CASE WHEN observed_reasoning_output_tokens > 0 THEN 1 ELSE 0 END) AS has_reasoning
                FROM (
                    SELECT received_at,
                        \(normalizedModelExpression) AS normalized_model,
                        observed_input_tokens,
                        observed_cached_input_tokens,
                        observed_output_tokens,
                        observed_reasoning_output_tokens
                    FROM token_usage_samples
                )
                WHERE normalized_model IS NULL
            )
            WHERE has_input = 1
                OR has_cached = 1
                OR has_output = 1
                OR has_reasoning = 1
            """
        )
    }

    func rebuildTokenContextCatalogs() throws {
        try execute("DROP TABLE IF EXISTS temp_token_project_display_names")
        try execute(
            """
            CREATE TEMP TABLE temp_token_project_display_names AS
            SELECT project_path, display_name
            FROM token_project_catalog
            WHERE display_name IS NOT NULL
                AND NULLIF(TRIM(display_name), '') IS NOT NULL
            """
        )
        defer {
            try? execute("DROP TABLE IF EXISTS temp_token_project_display_names")
        }

        try execute("DELETE FROM token_project_catalog")
        try execute("DELETE FROM token_effort_catalog")
        try execute("DELETE FROM token_source_catalog")

        try execute(
            """
            INSERT INTO token_project_catalog (
                project_path, project_name, first_seen_at, last_seen_at
            )
            SELECT project_path,
                COALESCE(NULLIF(TRIM(project_name), ''), project_path) AS project_name,
                MIN(received_at) AS first_seen_at,
                MAX(received_at) AS last_seen_at
            FROM token_usage_samples
            WHERE project_path IS NOT NULL
                AND (
                    \(Self.observedTokenComponentsPredicate)
                    OR observed_total_tokens > 0
                )
            GROUP BY project_path
            """
        )
        try execute(
            """
            UPDATE token_project_catalog
            SET display_name = (
                SELECT display_name
                FROM temp_token_project_display_names
                WHERE temp_token_project_display_names.project_path = token_project_catalog.project_path
            )
            WHERE EXISTS (
                SELECT 1
                FROM temp_token_project_display_names
                WHERE temp_token_project_display_names.project_path = token_project_catalog.project_path
            )
            """
        )
        try execute(
            """
            INSERT INTO token_effort_catalog (
                effort, first_seen_at, last_seen_at
            )
            SELECT effort,
                MIN(received_at) AS first_seen_at,
                MAX(received_at) AS last_seen_at
            FROM token_usage_samples
            WHERE effort IS NOT NULL
                AND (
                    \(Self.observedTokenComponentsPredicate)
                    OR observed_total_tokens > 0
                )
            GROUP BY effort
            """
        )
        try execute(
            """
            INSERT INTO token_source_catalog (
                source, first_seen_at, last_seen_at
            )
            SELECT source,
                MIN(received_at) AS first_seen_at,
                MAX(received_at) AS last_seen_at
            FROM token_usage_samples
            WHERE source IS NOT NULL
                AND (
                    \(Self.observedTokenComponentsPredicate)
                    OR observed_total_tokens > 0
                )
            GROUP BY source
            """
        )
    }

    func addColumnIfNeeded(table: String, column: String, definition: String) throws {
        guard try !tableHasColumn(table: table, column: column) else {
            return
        }

        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    struct StoredUsageSampleConsumptionRow: Hashable {
        let bucketID: String
        let bucketName: String
        let bucketKind: String
        let window: String
        let timestamp: Int64
        let usedPercent: Double
        let resetAt: Int64?
    }

    struct StoredUsageRollupConsumptionRow {
        let granularity: UsageHistoryGranularity
        let bucketID: String
        let bucketName: String
        let bucketKind: String
        let window: String
        let periodStart: Int64
        let sampleTimestamp: Int64
        let usedPercent: Double
        let resetAt: Int64?
    }

    struct RecomputedUsageSampleConsumption {
        let consumedPercent: Double
        let isAccepted: Bool
    }

    struct UsageConsumptionSeriesKey: Hashable {
        let bucketID: String
        let window: String
    }

    struct UsageRollupConsumptionKey: Hashable {
        let granularity: String
        let bucketID: String
        let window: String
        let periodStart: Int64

        init(granularity: String, bucketID: String, window: String, periodStart: Int64) {
            self.granularity = granularity
            self.bucketID = bucketID
            self.window = window
            self.periodStart = periodStart
        }

        init(_ row: StoredUsageRollupConsumptionRow) {
            granularity = row.granularity.rawValue
            bucketID = row.bucketID
            window = row.window
            periodStart = row.periodStart
        }
    }

    struct UsageRollupRecomputeSummary {
        let bucketName: String
        let bucketKind: String
        let sampleTimestamp: Int64
        let usedPercent: Double
        let peakUsedPercent: Double
        let consumedPercent: Double
        let resetAt: Int64?

        func appending(row: StoredUsageSampleConsumptionRow, consumedPercent: Double) -> UsageRollupRecomputeSummary {
            UsageRollupRecomputeSummary(
                bucketName: row.timestamp >= sampleTimestamp ? row.bucketName : bucketName,
                bucketKind: row.timestamp >= sampleTimestamp ? row.bucketKind : bucketKind,
                sampleTimestamp: max(sampleTimestamp, row.timestamp),
                usedPercent: row.timestamp >= sampleTimestamp ? row.usedPercent : usedPercent,
                peakUsedPercent: max(peakUsedPercent, row.usedPercent),
                consumedPercent: self.consumedPercent + consumedPercent,
                resetAt: row.timestamp >= sampleTimestamp ? row.resetAt : resetAt
            )
        }
    }

    struct UsageConsumptionRecomputeState {
        var activeResetAt: Int64?
        var previousUsedPercent: Double?

        mutating func recompute(row: StoredUsageSampleConsumptionRow) -> RecomputedUsageSampleConsumption {
            recompute(timestamp: row.timestamp, usedPercent: row.usedPercent, resetAt: row.resetAt)
        }

        mutating func recompute(row: StoredUsageRollupConsumptionRow) -> RecomputedUsageSampleConsumption {
            recompute(timestamp: row.sampleTimestamp, usedPercent: row.usedPercent, resetAt: row.resetAt)
        }

        private mutating func recompute(
            timestamp: Int64,
            usedPercent: Double,
            resetAt: Int64?
        ) -> RecomputedUsageSampleConsumption {
            if activeResetAt == nil {
                activeResetAt = resetAt
            }

            guard Self.shouldAccept(resetAt: resetAt, activeResetAt: activeResetAt, timestamp: timestamp) else {
                return RecomputedUsageSampleConsumption(consumedPercent: 0, isAccepted: false)
            }

            if !Self.resetsAreCompatible(resetAt, activeResetAt) {
                previousUsedPercent = nil
            }

            if let resetAt {
                activeResetAt = resetAt
            }

            let consumedPercent = UsageHistoryStore.observedConsumedPercent(
                currentUsedPercent: usedPercent,
                previousUsedPercent: previousUsedPercent
            )
            previousUsedPercent = usedPercent
            return RecomputedUsageSampleConsumption(consumedPercent: consumedPercent, isAccepted: true)
        }

        static func shouldAccept(resetAt: Int64?, activeResetAt: Int64?, timestamp: Int64) -> Bool {
            guard !resetsAreCompatible(resetAt, activeResetAt) else {
                return true
            }
            guard let activeResetAt, let resetAt else {
                return true
            }
            if resetAt <= activeResetAt {
                return true
            }

            return timestamp >= activeResetAt - UsageHistoryStore.resetCohortTolerance
        }

        static func resetsAreCompatible(_ lhs: Int64?, _ rhs: Int64?) -> Bool {
            guard let lhs, let rhs else {
                return true
            }

            return abs(lhs - rhs) <= UsageHistoryStore.resetCohortTolerance
        }
    }

    func recomputeStoredUsageConsumptionIfNeeded() throws {
        guard try metadataValue(for: Self.consumptionAlgorithmMetadataKey) != Self.currentConsumptionAlgorithmVersion else {
            return
        }

        try recomputeStoredUsageConsumption()
    }

    func recomputeStoredUsageConsumption() throws {
        try transaction {
            let sampleRows = try usageSampleConsumptionRows()
            let sampleConsumedByRow = try recomputeRawSampleConsumption(sampleRows)
            try recomputeRollupConsumption(rawSamples: sampleRows, sampleConsumedByRow: sampleConsumedByRow)
            try setMetadataValue(
                Self.currentConsumptionAlgorithmVersion,
                for: Self.consumptionAlgorithmMetadataKey
            )
        }
    }

    func recomputeRawSampleConsumption(
        _ rows: [StoredUsageSampleConsumptionRow]
    ) throws -> [StoredUsageSampleConsumptionRow: RecomputedUsageSampleConsumption] {
        var stateByKey = [UsageConsumptionSeriesKey: UsageConsumptionRecomputeState]()
        var resultByRow = [StoredUsageSampleConsumptionRow: RecomputedUsageSampleConsumption]()
        let statement = try prepare(
            """
            UPDATE usage_samples
            SET consumed_percent = ?
            WHERE bucket_id = ? AND window = ? AND timestamp = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        for row in rows {
            let key = UsageConsumptionSeriesKey(
                bucketID: row.bucketID,
                window: row.window
            )
            var state = stateByKey[key] ?? UsageConsumptionRecomputeState()
            let result = state.recompute(row: row)
            stateByKey[key] = state
            resultByRow[row] = result

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_double(statement, 1, result.consumedPercent)
            bindText(row.bucketID, to: 2, in: statement)
            bindText(row.window, to: 3, in: statement)
            sqlite3_bind_int64(statement, 4, row.timestamp)
            try step(statement)
        }

        return resultByRow
    }

    func recomputeRollupConsumption(
        rawSamples: [StoredUsageSampleConsumptionRow],
        sampleConsumedByRow: [StoredUsageSampleConsumptionRow: RecomputedUsageSampleConsumption]
    ) throws {
        let rollupRows = try usageRollupConsumptionRows()
        var stateByKey = [String: UsageConsumptionRecomputeState]()
        var rollupSummaryByKey = [UsageRollupConsumptionKey: UsageRollupRecomputeSummary]()
        var rollupDeleteKeys = Set<UsageRollupConsumptionKey>()

        for row in rollupRows {
            let timelineKey = "\(row.granularity.rawValue)\u{1F}\(row.bucketID)\u{1F}\(row.window)"
            var state = stateByKey[timelineKey] ?? UsageConsumptionRecomputeState()
            let result = state.recompute(row: row)
            stateByKey[timelineKey] = state

            let key = UsageRollupConsumptionKey(row)
            if result.isAccepted {
                rollupSummaryByKey[key] = UsageRollupRecomputeSummary(
                    bucketName: row.bucketName,
                    bucketKind: row.bucketKind,
                    sampleTimestamp: row.sampleTimestamp,
                    usedPercent: row.usedPercent,
                    peakUsedPercent: row.usedPercent,
                    consumedPercent: result.consumedPercent,
                    resetAt: row.resetAt
                )
            } else {
                rollupDeleteKeys.insert(key)
            }
        }

        var rawRollupTouchedKeys = Set<UsageRollupConsumptionKey>()
        var rawRollupSummaryByKey = [UsageRollupConsumptionKey: UsageRollupRecomputeSummary]()
        for row in rawSamples {
            for granularity in [UsageHistoryGranularity.hour, .day] {
                let key = UsageRollupConsumptionKey(
                    granularity: granularity.rawValue,
                    bucketID: row.bucketID,
                    window: row.window,
                    periodStart: periodStart(for: row.timestamp, granularity: granularity)
                )
                rawRollupTouchedKeys.insert(key)
                guard let result = sampleConsumedByRow[row], result.isAccepted else {
                    continue
                }

                if let existingSummary = rawRollupSummaryByKey[key] {
                    rawRollupSummaryByKey[key] = existingSummary.appending(
                        row: row,
                        consumedPercent: result.consumedPercent
                    )
                } else {
                    rawRollupSummaryByKey[key] = UsageRollupRecomputeSummary(
                        bucketName: row.bucketName,
                        bucketKind: row.bucketKind,
                        sampleTimestamp: row.timestamp,
                        usedPercent: row.usedPercent,
                        peakUsedPercent: row.usedPercent,
                        consumedPercent: result.consumedPercent,
                        resetAt: row.resetAt
                    )
                }
            }
        }

        for key in rawRollupTouchedKeys {
            if let summary = rawRollupSummaryByKey[key] {
                rollupSummaryByKey[key] = summary
                rollupDeleteKeys.remove(key)
            } else {
                rollupSummaryByKey.removeValue(forKey: key)
                rollupDeleteKeys.insert(key)
            }
        }

        let statement = try prepare(
            """
            INSERT INTO usage_rollups (
                granularity, bucket_id, bucket_name, bucket_kind, window, period_start,
                sample_timestamp, used_percent, peak_used_percent, consumed_percent, reset_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(granularity, bucket_id, window, period_start) DO UPDATE SET
                bucket_name = excluded.bucket_name,
                bucket_kind = excluded.bucket_kind,
                sample_timestamp = excluded.sample_timestamp,
                used_percent = excluded.used_percent,
                peak_used_percent = excluded.peak_used_percent,
                consumed_percent = excluded.consumed_percent,
                reset_at = excluded.reset_at
            """
        )
        defer { sqlite3_finalize(statement) }

        for (key, summary) in rollupSummaryByKey {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bindText(key.granularity, to: 1, in: statement)
            bindText(key.bucketID, to: 2, in: statement)
            bindText(summary.bucketName, to: 3, in: statement)
            bindText(summary.bucketKind, to: 4, in: statement)
            bindText(key.window, to: 5, in: statement)
            sqlite3_bind_int64(statement, 6, key.periodStart)
            sqlite3_bind_int64(statement, 7, summary.sampleTimestamp)
            sqlite3_bind_int(statement, 8, Int32(summary.usedPercent.rounded()))
            sqlite3_bind_int(statement, 9, Int32(summary.peakUsedPercent.rounded()))
            sqlite3_bind_double(statement, 10, summary.consumedPercent)
            bindOptionalInt(summary.resetAt, to: 11, in: statement)
            try step(statement)
        }

        try deleteRollups(keys: rollupDeleteKeys.subtracting(rollupSummaryByKey.keys))
    }

    func usageSampleConsumptionRows() throws -> [StoredUsageSampleConsumptionRow] {
        let statement = try prepare(
            """
            SELECT bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent, reset_at
            FROM usage_samples
            ORDER BY bucket_id ASC, window ASC, timestamp ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var rows: [StoredUsageSampleConsumptionRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(
                    StoredUsageSampleConsumptionRow(
                        bucketID: columnText(statement, index: 0),
                        bucketName: columnText(statement, index: 1),
                        bucketKind: columnText(statement, index: 2),
                        window: columnText(statement, index: 3),
                        timestamp: sqlite3_column_int64(statement, 4),
                        usedPercent: sqlite3_column_double(statement, 5),
                        resetAt: optionalColumnInt(statement, index: 6)
                    )
                )
            case SQLITE_DONE:
                return rows
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func deleteRollups(keys: Set<UsageRollupConsumptionKey>) throws {
        guard !keys.isEmpty else {
            return
        }

        let statement = try prepare(
            """
            DELETE FROM usage_rollups
            WHERE granularity = ? AND bucket_id = ? AND window = ? AND period_start = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        for key in keys {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bindText(key.granularity, to: 1, in: statement)
            bindText(key.bucketID, to: 2, in: statement)
            bindText(key.window, to: 3, in: statement)
            sqlite3_bind_int64(statement, 4, key.periodStart)
            try step(statement)
        }
    }

    func usageRollupConsumptionRows() throws -> [StoredUsageRollupConsumptionRow] {
        let statement = try prepare(
            """
            SELECT granularity, bucket_id, bucket_name, bucket_kind, window,
                period_start, sample_timestamp, used_percent, reset_at
            FROM usage_rollups
            ORDER BY granularity ASC, bucket_id ASC, window ASC, sample_timestamp ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var rows: [StoredUsageRollupConsumptionRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let granularity = UsageHistoryGranularity(rawValue: columnText(statement, index: 0)) else {
                    continue
                }

                rows.append(
                    StoredUsageRollupConsumptionRow(
                        granularity: granularity,
                        bucketID: columnText(statement, index: 1),
                        bucketName: columnText(statement, index: 2),
                        bucketKind: columnText(statement, index: 3),
                        window: columnText(statement, index: 4),
                        periodStart: sqlite3_column_int64(statement, 5),
                        sampleTimestamp: sqlite3_column_int64(statement, 6),
                        usedPercent: sqlite3_column_double(statement, 7),
                        resetAt: optionalColumnInt(statement, index: 8)
                    )
                )
            case SQLITE_DONE:
                return rows
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }
}
