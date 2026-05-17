import Foundation
import SQLite3

protocol UsageHistoryRecording {
    func record(snapshot: CodexUsageSnapshot, at date: Date)
}

protocol TokenUsageRecording {
    @discardableResult
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) -> TokenCategoryTotals?
    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) -> TokenCategoryTotals?
    func todayTotalTokens(at date: Date, calendar: Calendar) -> Int64?
}

struct NoOpUsageHistoryRecorder: UsageHistoryRecording {
    func record(snapshot: CodexUsageSnapshot, at date: Date) {}
}

struct NoOpTokenUsageRecorder: TokenUsageRecording {
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) -> TokenCategoryTotals? {
        nil
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) -> TokenCategoryTotals? {
        nil
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) -> Int64? {
        nil
    }
}

final class UsageHistoryRecorder: UsageHistoryRecording {
    private let store: UsageHistoryStore
    private var lastRecentTokenImportAt: Date?

    init(store: UsageHistoryStore) {
        self.store = store
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) {
        do {
            try store.record(snapshot: snapshot, at: date)
        } catch {
            // History should never interrupt the live menu bar status.
        }
    }
}

extension UsageHistoryRecorder: TokenUsageRecording {
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) -> TokenCategoryTotals? {
        do {
            try store.record(tokenUsage: tokenUsage, at: date)
            return try store.tokenCategoryTotalsForDay(containing: date, calendar: .autoupdatingCurrent)
        } catch {
            // Token telemetry should never interrupt the live menu bar status.
            return nil
        }
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) -> TokenCategoryTotals? {
        importRecentTokenHistoryIfNeeded(at: date, calendar: calendar)
        return try? store.tokenCategoryTotalsForDay(containing: date, calendar: calendar)
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) -> Int64? {
        importRecentTokenHistoryIfNeeded(at: date, calendar: calendar)
        return try? store.tokenTotalForDay(containing: date, calendar: calendar)
    }

    private func importRecentTokenHistoryIfNeeded(at date: Date, calendar: Calendar) {
        if let lastRecentTokenImportAt,
           date.timeIntervalSince(lastRecentTokenImportAt) < 60,
           calendar.isDate(lastRecentTokenImportAt, inSameDayAs: date)
        {
            return
        }

        _ = store.importRecentTokenHistoryIfAvailable(containing: date, calendar: calendar)
        lastRecentTokenImportAt = date
    }
}

extension UsageHistoryStore {
    @discardableResult
    func importRecentTokenHistoryIfAvailable(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        logsDatabaseURL: URL = CodexLogTokenUsageImporter.defaultLogsDatabaseURL()
    ) -> TokenUsageImportResult {
        let logImporter = CodexLogTokenUsageImporter(logsDatabaseURL: logsDatabaseURL)
        return (try? logImporter.importTokenHistory(
            into: self,
            containing: date,
            calendar: calendar
        )) ?? .empty
    }
}

enum UsageHistoryStoreError: LocalizedError {
    case databaseOpenFailed(String)
    case databaseOperationFailed(String)
    case statementPreparationFailed(String)
    case databaseUnavailable
    case invalidBackup
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message):
            return "Usage history database could not be opened: \(message)"
        case .databaseOperationFailed(let message):
            return "Usage history database operation failed: \(message)"
        case .statementPreparationFailed(let message):
            return "Usage history database statement could not be prepared: \(message)"
        case .databaseUnavailable:
            return "Usage history database is not available."
        case .invalidBackup:
            return "Selected file is not a valid usage history backup."
        case .fileOperationFailed(let message):
            return "Usage history file operation failed: \(message)"
        }
    }
}

struct UsageHistoryDatabaseInfo: Equatable {
    let databaseURL: URL
    let totalByteSize: Int64
}

struct StoredTokenUsageSample: Equatable {
    let threadID: String
    let turnID: String
    let model: String?
    let receivedAt: Date
    let modelContextWindow: Int64?
    let last: CodexTokenUsageBreakdown
    let total: CodexTokenUsageBreakdown
    let observedInputTokens: Int64?
    let observedCachedInputTokens: Int64?
    let observedOutputTokens: Int64?
    let observedReasoningOutputTokens: Int64?
    let observedTotalTokens: Int64
}

enum UsageHistoryRawRetention: Int, CaseIterable, Identifiable, Equatable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }

    var displayTitle: String {
        "\(rawValue) days"
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue * 24 * 60 * 60)
    }
}

enum UsageHistoryRawRetentionStore {
    static let defaultsKey = "UsageHistoryRawRetentionDays"
    static let defaultRetention: UsageHistoryRawRetention = .fourteenDays

    static func load(from defaults: UserDefaults = .standard) -> UsageHistoryRawRetention {
        let rawValue = defaults.integer(forKey: defaultsKey)
        return UsageHistoryRawRetention(rawValue: rawValue) ?? defaultRetention
    }

    static func save(_ retention: UsageHistoryRawRetention, to defaults: UserDefaults = .standard) {
        defaults.set(retention.rawValue, forKey: defaultsKey)
    }
}

final class UsageHistoryStore: @unchecked Sendable {
    static let didChangeNotification = Notification.Name("UsageHistoryStoreDidChange")
    static let defaultRawRetention: TimeInterval = 14 * 24 * 60 * 60
    private static let consumptionAlgorithmMetadataKey = "usage_consumption_algorithm_version"
    private static let currentConsumptionAlgorithmVersion = "5"
    private static let resetCohortTolerance: Int64 = 60 * 60

    private let database: OpaquePointer
    private let databaseURL: URL?
    private let notificationCenter: NotificationCenter
    private let calendar: Calendar
    private let rawRetentionProvider: () -> TimeInterval

    convenience init(
        databaseURL: URL,
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetention: TimeInterval = UsageHistoryStore.defaultRawRetention
    ) throws {
        try self.init(
            databaseURL: databaseURL,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetentionProvider: { rawRetention }
        )
    }

    convenience init(
        databaseURL: URL,
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetentionProvider: @escaping () -> TimeInterval
    ) throws {
        try self.init(
            databasePath: databaseURL.path,
            databaseURL: databaseURL,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetentionProvider: rawRetentionProvider
        )
    }

    private init(
        databasePath: String,
        databaseURL: URL?,
        notificationCenter: NotificationCenter,
        calendar: Calendar,
        rawRetentionProvider: @escaping () -> TimeInterval
    ) throws {
        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &openedDatabase, flags, nil) == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw UsageHistoryStoreError.databaseOpenFailed(message)
        }

        database = openedDatabase
        self.databaseURL = databaseURL
        self.notificationCenter = notificationCenter
        self.calendar = calendar
        self.rawRetentionProvider = rawRetentionProvider

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    static func applicationSupportStore(
        rawRetentionProvider: @escaping () -> TimeInterval = {
            UsageHistoryRawRetentionStore.load().timeInterval
        }
    ) throws -> UsageHistoryStore {
        let directoryURL = try applicationSupportDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try UsageHistoryStore(
            databaseURL: directoryURL.appendingPathComponent("usage-history.sqlite3"),
            rawRetentionProvider: rawRetentionProvider
        )
    }

    static func inMemory(
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetention: TimeInterval = UsageHistoryStore.defaultRawRetention
    ) throws -> UsageHistoryStore {
        try UsageHistoryStore(
            databasePath: ":memory:",
            databaseURL: nil,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetentionProvider: { rawRetention }
        )
    }

    static func inMemory(
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetentionProvider: @escaping () -> TimeInterval
    ) throws -> UsageHistoryStore {
        try UsageHistoryStore(
            databasePath: ":memory:",
            databaseURL: nil,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetentionProvider: rawRetentionProvider
        )
    }

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

        try transaction {
            for sample in samples {
                let notification = sample.notification
                let cumulativeTotal = notification.tokenUsage.total.totalTokens

                if try tokenSampleExists(
                    threadID: notification.threadID,
                    turnID: notification.turnID,
                    cumulativeTotalTokens: cumulativeTotal
                ) {
                    if try repairMissingTokenSampleModel(
                        threadID: notification.threadID,
                        turnID: notification.turnID,
                        cumulativeTotalTokens: cumulativeTotal,
                        model: notification.model
                    ) {
                        repairedModelCount += 1
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
                    observedTokens: observedTokens
                )
                insertedCount += 1
            }
        }

        if insertedCount > 0 || repairedModelCount > 0 {
            notificationCenter.post(name: Self.didChangeNotification, object: self)
        }

        return TokenUsageImportResult(
            insertedCount: insertedCount,
            duplicateCount: duplicateCount,
            repairedModelCount: repairedModelCount
        )
    }

    func codexSessionTokenImportFileRecord(path: String) throws -> CodexSessionTokenImportFileRecord? {
        let statement = try prepare(
            """
            SELECT file_path, file_size, modified_at, imported_at, status
            FROM codex_session_token_imports
            WHERE file_path = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(path, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let metadata = CodexSessionTokenImportFileMetadata(
                path: columnText(statement, index: 0),
                fileSize: sqlite3_column_int64(statement, 1),
                modifiedAt: sqlite3_column_int64(statement, 2)
            )
            let status = CodexSessionTokenImportFileStatus(rawValue: columnText(statement, index: 4)) ?? .failed
            return CodexSessionTokenImportFileRecord(
                metadata: metadata,
                importedAt: sqlite3_column_int64(statement, 3),
                status: status
            )
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func recordCodexSessionTokenImportFile(
        _ metadata: CodexSessionTokenImportFileMetadata,
        importedAt: Int64,
        status: CodexSessionTokenImportFileStatus
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO codex_session_token_imports (
                file_path, file_size, modified_at, imported_at, status
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                file_size = excluded.file_size,
                modified_at = excluded.modified_at,
                imported_at = excluded.imported_at,
                status = excluded.status
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(metadata.path, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, metadata.fileSize)
        sqlite3_bind_int64(statement, 3, metadata.modifiedAt)
        sqlite3_bind_int64(statement, 4, importedAt)
        bindText(status.rawValue, to: 5, in: statement)

        try step(statement)
    }

    func codexSessionTokenImportFileRecords() throws -> [CodexSessionTokenImportFileRecord] {
        let statement = try prepare(
            """
            SELECT file_path, file_size, modified_at, imported_at, status
            FROM codex_session_token_imports
            ORDER BY file_path
            """
        )
        defer { sqlite3_finalize(statement) }

        var records: [CodexSessionTokenImportFileRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let metadata = CodexSessionTokenImportFileMetadata(
                    path: columnText(statement, index: 0),
                    fileSize: sqlite3_column_int64(statement, 1),
                    modifiedAt: sqlite3_column_int64(statement, 2)
                )
                let status = CodexSessionTokenImportFileStatus(rawValue: columnText(statement, index: 4)) ?? .failed
                records.append(
                    CodexSessionTokenImportFileRecord(
                        metadata: metadata,
                        importedAt: sqlite3_column_int64(statement, 3),
                        status: status
                    )
                )
            case SQLITE_DONE:
                return records
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenUsageSamples() throws -> [StoredTokenUsageSample] {
        let statement = try prepare(
            """
            SELECT thread_id, turn_id, model, received_at, model_context_window,
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
                        receivedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3))),
                        modelContextWindow: optionalColumnInt(statement, index: 4),
                        last: CodexTokenUsageBreakdown(
                            inputTokens: sqlite3_column_int64(statement, 5),
                            cachedInputTokens: sqlite3_column_int64(statement, 6),
                            outputTokens: sqlite3_column_int64(statement, 7),
                            reasoningOutputTokens: sqlite3_column_int64(statement, 8),
                            totalTokens: sqlite3_column_int64(statement, 9)
                        ),
                        total: CodexTokenUsageBreakdown(
                            inputTokens: sqlite3_column_int64(statement, 10),
                            cachedInputTokens: sqlite3_column_int64(statement, 11),
                            outputTokens: sqlite3_column_int64(statement, 12),
                            reasoningOutputTokens: sqlite3_column_int64(statement, 13),
                            totalTokens: sqlite3_column_int64(statement, 14)
                        ),
                        observedInputTokens: optionalColumnInt(statement, index: 15),
                        observedCachedInputTokens: optionalColumnInt(statement, index: 16),
                        observedOutputTokens: optionalColumnInt(statement, index: 17),
                        observedReasoningOutputTokens: optionalColumnInt(statement, index: 18),
                        observedTotalTokens: sqlite3_column_int64(statement, 19)
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
        let valueExpression = tokenValueExpression(for: category)
        let normalizedModelExpression = Self.normalizedModelSQLExpression(column: "model")
        let statement = try prepare(
            """
            WITH samples AS (
                SELECT received_at,
                    \(normalizedModelExpression) AS normalized_model,
                    \(valueExpression) AS token_count
                FROM token_usage_samples
            )
            SELECT series_id, series_name, series_kind, seen_at
            FROM (
                SELECT
                    'tokens_all' AS series_id,
                    'All tokens' AS series_name,
                    'aggregate' AS series_kind,
                    received_at AS seen_at,
                    token_count
                FROM samples

                UNION ALL

                SELECT
                    'model:' || normalized_model AS series_id,
                    normalized_model AS series_name,
                    'model' AS series_kind,
                    received_at AS seen_at,
                    token_count
                FROM samples
                WHERE normalized_model IS NOT NULL
            )
            WHERE token_count > 0
            ORDER BY seen_at DESC, series_kind ASC, series_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        return try readAvailableSeries(from: statement)
    }

    func availableTokenComponentSeries() throws -> [UsageHistorySeries] {
        let normalizedModelExpression = Self.normalizedModelSQLExpression(column: "model")
        let statement = try prepare(
            """
            WITH samples AS (
                SELECT received_at,
                    \(normalizedModelExpression) AS normalized_model,
                    observed_input_tokens,
                    observed_cached_input_tokens,
                    observed_output_tokens,
                    observed_reasoning_output_tokens
                FROM token_usage_samples
            )
            SELECT series_id, series_name, series_kind, seen_at
            FROM (
                SELECT
                    'tokens_all' AS series_id,
                    'All tokens' AS series_name,
                    'aggregate' AS series_kind,
                    received_at AS seen_at,
                    observed_input_tokens,
                    observed_cached_input_tokens,
                    observed_output_tokens,
                    observed_reasoning_output_tokens
                FROM samples

                UNION ALL

                SELECT
                    'model:' || normalized_model AS series_id,
                    normalized_model AS series_name,
                    'model' AS series_kind,
                    received_at AS seen_at,
                    observed_input_tokens,
                    observed_cached_input_tokens,
                    observed_output_tokens,
                    observed_reasoning_output_tokens
                FROM samples
                WHERE normalized_model IS NOT NULL
            )
            WHERE IFNULL(observed_input_tokens, 0) > 0
                OR IFNULL(observed_cached_input_tokens, 0) > 0
                OR IFNULL(observed_output_tokens, 0) > 0
                OR IFNULL(observed_reasoning_output_tokens, 0) > 0
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
            WHERE IFNULL(observed_input_tokens, 0) > 0
                OR IFNULL(observed_cached_input_tokens, 0) > 0
                OR IFNULL(observed_output_tokens, 0) > 0
                OR IFNULL(observed_reasoning_output_tokens, 0) > 0
            """
        )
        defer { sqlite3_finalize(statement) }

        return try readHistoryBounds(from: statement)
    }

    func tokenDashboardPoints(
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
                observed_input_tokens,
                observed_cached_input_tokens,
                observed_output_tokens,
                observed_reasoning_output_tokens
            FROM token_usage_samples
            WHERE received_at >= ? AND received_at < ?
                AND (
                    IFNULL(observed_input_tokens, 0) > 0
                    OR IFNULL(observed_cached_input_tokens, 0) > 0
                    OR IFNULL(observed_output_tokens, 0) > 0
                    OR IFNULL(observed_reasoning_output_tokens, 0) > 0
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

                    if let normalizedModel, !normalizedModel.isEmpty {
                        addTokenDashboardAccumulator(
                            bucketStart: bucketStart,
                            bucketEnd: bucketEnd,
                            seriesID: "model:\(normalizedModel)",
                            seriesName: normalizedModel,
                            seriesKind: .model,
                            component: component,
                            tokenCount: tokenCount,
                            to: &accumulators
                        )
                    } else {
                        addTokenDashboardAccumulator(
                            bucketStart: bucketStart,
                            bucketEnd: bucketEnd,
                            seriesID: TokenDashboardSeries.unattributedID,
                            seriesName: "Unattributed",
                            seriesKind: .unattributed,
                            component: component,
                            tokenCount: tokenCount,
                            to: &accumulators
                        )
                    }
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

    func tokenDashboardSeries() throws -> [TokenDashboardSeries] {
        let normalizedModelExpression = Self.normalizedModelSQLExpression(column: "model")
        let statement = try prepare(
            """
            WITH samples AS (
                SELECT received_at,
                    \(normalizedModelExpression) AS normalized_model,
                    observed_input_tokens,
                    observed_cached_input_tokens,
                    observed_output_tokens,
                    observed_reasoning_output_tokens
                FROM token_usage_samples
                WHERE IFNULL(observed_input_tokens, 0) > 0
                    OR IFNULL(observed_cached_input_tokens, 0) > 0
                    OR IFNULL(observed_output_tokens, 0) > 0
                    OR IFNULL(observed_reasoning_output_tokens, 0) > 0
            )
            SELECT series_id, series_name, series_kind, seen_at
            FROM (
                SELECT
                    '\(TokenDashboardSeries.aggregateID)' AS series_id,
                    'All captured' AS series_name,
                    'aggregate' AS series_kind,
                    received_at AS seen_at
                FROM samples

                UNION ALL

                SELECT
                    'model:' || normalized_model AS series_id,
                    normalized_model AS series_name,
                    'model' AS series_kind,
                    received_at AS seen_at
                FROM samples
                WHERE normalized_model IS NOT NULL

                UNION ALL

                SELECT
                    '\(TokenDashboardSeries.unattributedID)' AS series_id,
                    'Unattributed' AS series_name,
                    'unattributed' AS series_kind,
                    received_at AS seen_at
                FROM samples
                WHERE normalized_model IS NULL
            )
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

                seriesByID[id] = TokenDashboardSeries(
                    id: id,
                    name: columnText(statement, index: 1),
                    kind: kind
                )
            case SQLITE_DONE:
                return seriesByID.values.sortedByDashboardSeriesOrder()
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tokenDashboardBounds() throws -> UsageHistoryBounds? {
        try tokenComponentHistoryBounds()
    }


    func points(
        range: UsageHistoryRange,
        window: UsageLimitWindow,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> [UsageHistoryPoint] {
        let period = range.period(containing: now, calendar: calendar)
        return try points(
            range: range,
            window: window,
            periodStart: period.start,
            periodEnd: min(period.end, now.addingTimeInterval(1))
        )
    }

    func points(
        range: UsageHistoryRange,
        window: UsageLimitWindow,
        periodStart: Date,
        periodEnd: Date
    ) throws -> [UsageHistoryPoint] {
        let startTimestamp = periodStart.timeIntervalSince1970Int
        let endTimestamp = periodEnd.timeIntervalSince1970Int

        switch range.storageGranularity {
        case .raw:
            return try rawPoints(window: window, startTimestamp: startTimestamp, endTimestamp: endTimestamp)
        case .hour, .day:
            return try rollupPoints(
                granularity: range.storageGranularity,
                window: window,
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp
            )
        }
    }

    func series(
        range: UsageHistoryRange,
        window: UsageLimitWindow,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> [UsageHistorySeries] {
        let points = try points(range: range, window: window, now: now, calendar: calendar)
        return Self.series(from: points)
    }

    func series(
        range: UsageHistoryRange,
        window: UsageLimitWindow,
        periodStart: Date,
        periodEnd: Date
    ) throws -> [UsageHistorySeries] {
        let points = try points(range: range, window: window, periodStart: periodStart, periodEnd: periodEnd)
        return Self.series(from: points)
    }

    func availableSeries(window: UsageLimitWindow) throws -> [UsageHistorySeries] {
        let statement = try prepare(
            """
            SELECT bucket_id, bucket_name, bucket_kind, seen_at
            FROM (
                SELECT bucket_id, bucket_name, bucket_kind, timestamp AS seen_at
                FROM usage_samples
                WHERE window = ?

                UNION ALL

                SELECT bucket_id, bucket_name, bucket_kind, sample_timestamp AS seen_at
                FROM usage_rollups
                WHERE window = ?
            )
            ORDER BY seen_at DESC, bucket_kind ASC, bucket_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(window.rawValue, to: 1, in: statement)
        bindText(window.rawValue, to: 2, in: statement)

        return try readAvailableSeries(from: statement)
    }

    func historyBounds(
        window: UsageLimitWindow,
        granularity: UsageHistoryGranularity
    ) throws -> UsageHistoryBounds? {
        switch granularity {
        case .raw:
            return try rawHistoryBounds(window: window)
        case .hour, .day:
            return try rollupHistoryBounds(window: window, granularity: granularity)
        }
    }

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

        try recomputeStoredUsageConsumption()
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    private static func applicationSupportDirectoryURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL.appendingPathComponent("CodexStatusBar", isDirectory: true)
    }

    private func migrate() throws {
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
                status TEXT NOT NULL
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
        try addColumnIfNeeded(table: "usage_rollups", column: "peak_used_percent", definition: "INTEGER")
        try addColumnIfNeeded(table: "usage_samples", column: "consumed_percent", definition: "REAL")
        try addColumnIfNeeded(table: "usage_rollups", column: "consumed_percent", definition: "REAL")
        try addColumnIfNeeded(table: "token_usage_samples", column: "observed_input_tokens", definition: "INTEGER")
        try addColumnIfNeeded(table: "token_usage_samples", column: "observed_cached_input_tokens", definition: "INTEGER")
        try addColumnIfNeeded(table: "token_usage_samples", column: "observed_output_tokens", definition: "INTEGER")
        try addColumnIfNeeded(table: "token_usage_samples", column: "observed_reasoning_output_tokens", definition: "INTEGER")

        try execute("CREATE INDEX IF NOT EXISTS idx_usage_samples_window_timestamp ON usage_samples(window, timestamp)")
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_rollups_window_sample_timestamp ON usage_rollups(granularity, window, sample_timestamp)")
        try execute("CREATE INDEX IF NOT EXISTS idx_token_usage_samples_received_at ON token_usage_samples(received_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_codex_session_token_imports_status ON codex_session_token_imports(status, imported_at)")

        try recomputeStoredUsageConsumptionIfNeeded()
    }

    private func addColumnIfNeeded(table: String, column: String, definition: String) throws {
        guard try !tableHasColumn(table: table, column: column) else {
            return
        }

        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private struct StoredUsageSampleConsumptionRow: Hashable {
        let bucketID: String
        let bucketName: String
        let bucketKind: String
        let window: String
        let timestamp: Int64
        let usedPercent: Double
        let resetAt: Int64?
    }

    private struct StoredUsageRollupConsumptionRow {
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

    private struct RecomputedUsageSampleConsumption {
        let consumedPercent: Double
        let isAccepted: Bool
    }

    private struct UsageConsumptionSeriesKey: Hashable {
        let bucketID: String
        let window: String
    }

    private struct UsageRollupConsumptionKey: Hashable {
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

    private struct UsageRollupRecomputeSummary {
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

    private struct UsageConsumptionRecomputeState {
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

        private static func shouldAccept(resetAt: Int64?, activeResetAt: Int64?, timestamp: Int64) -> Bool {
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

        private static func resetsAreCompatible(_ lhs: Int64?, _ rhs: Int64?) -> Bool {
            guard let lhs, let rhs else {
                return true
            }

            return abs(lhs - rhs) <= UsageHistoryStore.resetCohortTolerance
        }
    }

    private func recomputeStoredUsageConsumptionIfNeeded() throws {
        guard try metadataValue(for: Self.consumptionAlgorithmMetadataKey) != Self.currentConsumptionAlgorithmVersion else {
            return
        }

        try recomputeStoredUsageConsumption()
    }

    private func recomputeStoredUsageConsumption() throws {
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

    private func recomputeRawSampleConsumption(
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

    private func recomputeRollupConsumption(
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

    private func usageSampleConsumptionRows() throws -> [StoredUsageSampleConsumptionRow] {
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

    private func deleteRollups(keys: Set<UsageRollupConsumptionKey>) throws {
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

    private func usageRollupConsumptionRows() throws -> [StoredUsageRollupConsumptionRow] {
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

    private func metadataValue(for key: String) throws -> String? {
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

    private func setMetadataValue(_ value: String, for key: String) throws {
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

    private func record(bucket: CodexUsageBucket, window: UsageLimitWindow, timestamp: Int64) throws {
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

    private struct ObservedConsumptionDelta {
        let sampleConsumedPercent: Double
        let rollupConsumedPercentAdjustment: Double
    }

    private struct ExistingSampleConsumption {
        let usedPercent: Double
        let consumedPercent: Double?
        let resetAt: Int64?
    }

    private func observedConsumptionDelta(
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

    private func previousCompatibleUsedPercent(
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

    private func existingSampleConsumption(
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

    private func insertRawSample(
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
    }

    private func insertRollup(
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
    }

    private func observedTokenDelta(
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

    private func hasTokenSampleAtOrAbove(threadID: String, cumulativeTotalTokens: Int64) throws -> Bool {
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

    private func tokenSampleExists(threadID: String, turnID: String, cumulativeTotalTokens: Int64) throws -> Bool {
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

    private func previousCumulativeTokenUsage(
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

    private func insertTokenUsageSample(
        notification: CodexTokenUsageNotification,
        timestamp: Int64,
        observedTokens: CodexTokenUsageBreakdown
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO token_usage_samples (
                thread_id, turn_id, model, received_at, model_context_window,
                last_input_tokens, last_cached_input_tokens, last_output_tokens,
                last_reasoning_output_tokens, last_total_tokens,
                total_input_tokens, total_cached_input_tokens, total_output_tokens,
                total_reasoning_output_tokens, total_total_tokens,
                observed_input_tokens, observed_cached_input_tokens, observed_output_tokens,
                observed_reasoning_output_tokens, observed_total_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, turn_id, total_total_tokens) DO UPDATE SET
                model = CASE
                    WHEN NULLIF(TRIM(token_usage_samples.model, char(9) || char(10) || char(13) || ' '), '') IS NULL
                        THEN excluded.model
                    ELSE token_usage_samples.model
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
        bindOptionalText(normalizedModelName(notification.model), to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, timestamp)
        bindOptionalInt(notification.tokenUsage.modelContextWindow, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, last.inputTokens)
        sqlite3_bind_int64(statement, 7, last.cachedInputTokens)
        sqlite3_bind_int64(statement, 8, last.outputTokens)
        sqlite3_bind_int64(statement, 9, last.reasoningOutputTokens)
        sqlite3_bind_int64(statement, 10, last.totalTokens)
        sqlite3_bind_int64(statement, 11, total.inputTokens)
        sqlite3_bind_int64(statement, 12, total.cachedInputTokens)
        sqlite3_bind_int64(statement, 13, total.outputTokens)
        sqlite3_bind_int64(statement, 14, total.reasoningOutputTokens)
        sqlite3_bind_int64(statement, 15, total.totalTokens)
        sqlite3_bind_int64(statement, 16, observedTokens.inputTokens)
        sqlite3_bind_int64(statement, 17, observedTokens.cachedInputTokens)
        sqlite3_bind_int64(statement, 18, observedTokens.outputTokens)
        sqlite3_bind_int64(statement, 19, observedTokens.reasoningOutputTokens)
        sqlite3_bind_int64(statement, 20, observedTokens.totalTokens)

        try step(statement)
    }

    private func repairMissingTokenSampleModel(
        threadID: String,
        turnID: String,
        cumulativeTotalTokens: Int64,
        model: String?
    ) throws -> Bool {
        guard let normalizedModel = CodexModelIdentifier.normalized(model) else {
            return false
        }

        let statement = try prepare(
            """
            UPDATE token_usage_samples
            SET model = ?
            WHERE thread_id = ?
                AND turn_id = ?
                AND total_total_tokens = ?
                AND NULLIF(TRIM(model, char(9) || char(10) || char(13) || ' '), '') IS NULL
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

    private func tokenValueExpression(for category: TokenHistoryCategory) -> String {
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

    private func rawHistoryBounds(window: UsageLimitWindow) throws -> UsageHistoryBounds? {
        let statement = try prepare(
            """
            SELECT MIN(timestamp), MAX(timestamp)
            FROM usage_samples
            WHERE window = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(window.rawValue, to: 1, in: statement)
        return try readHistoryBounds(from: statement)
    }

    private func rollupHistoryBounds(
        window: UsageLimitWindow,
        granularity: UsageHistoryGranularity
    ) throws -> UsageHistoryBounds? {
        let statement = try prepare(
            """
            SELECT MIN(sample_timestamp), MAX(sample_timestamp)
            FROM usage_rollups
            WHERE granularity = ? AND window = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(granularity.rawValue, to: 1, in: statement)
        bindText(window.rawValue, to: 2, in: statement)
        return try readHistoryBounds(from: statement)
    }

    private func readHistoryBounds(from statement: OpaquePointer) throws -> UsageHistoryBounds? {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  sqlite3_column_type(statement, 1) != SQLITE_NULL
            else {
                return nil
            }

            let earliest = sqlite3_column_int64(statement, 0)
            let latest = sqlite3_column_int64(statement, 1)
            return UsageHistoryBounds(
                earliest: Date(timeIntervalSince1970: TimeInterval(earliest)),
                latest: Date(timeIntervalSince1970: TimeInterval(latest))
            )
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func rawPoints(window: UsageLimitWindow, startTimestamp: Int64, endTimestamp: Int64) throws -> [UsageHistoryPoint] {
        let statement = try prepare(
            """
            SELECT bucket_id, bucket_name, bucket_kind, timestamp, used_percent,
                used_percent, consumed_percent
            FROM usage_samples
            WHERE window = ? AND timestamp >= ? AND timestamp < ?
            ORDER BY timestamp ASC, bucket_kind ASC, bucket_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(window.rawValue, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, startTimestamp)
        sqlite3_bind_int64(statement, 3, endTimestamp)

        return try readPoints(from: statement, window: window)
    }

    private func rollupPoints(
        granularity: UsageHistoryGranularity,
        window: UsageLimitWindow,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> [UsageHistoryPoint] {
        let statement = try prepare(
            """
            SELECT bucket_id, bucket_name, bucket_kind, sample_timestamp,
                used_percent, IFNULL(peak_used_percent, used_percent), consumed_percent
            FROM usage_rollups
            WHERE granularity = ? AND window = ? AND sample_timestamp >= ? AND sample_timestamp < ?
            ORDER BY sample_timestamp ASC, bucket_kind ASC, bucket_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(granularity.rawValue, to: 1, in: statement)
        bindText(window.rawValue, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, startTimestamp)
        sqlite3_bind_int64(statement, 4, endTimestamp)

        return try readPoints(from: statement, window: window)
    }

    private func readPoints(from statement: OpaquePointer, window: UsageLimitWindow) throws -> [UsageHistoryPoint] {
        struct PointRow {
            let timestamp: Date
            let bucketID: String
            let bucketName: String
            let bucketKind: CodexUsageBucketKind
            let usedPercent: Double
            let peakUsedPercent: Double
            let consumedPercent: Double?
        }

        var rows: [PointRow] = []

        func points(from rows: [PointRow], window: UsageLimitWindow) -> [UsageHistoryPoint] {
            var previousUsedPercentByBucket = [String: Double]()

            return rows.map { row in
                let key = "\(row.bucketID)-\(window.rawValue)"
                let consumedPercent = row.consumedPercent ?? Self.observedConsumedPercent(
                    currentUsedPercent: row.usedPercent,
                    previousUsedPercent: previousUsedPercentByBucket[key]
                )
                previousUsedPercentByBucket[key] = row.usedPercent

                return UsageHistoryPoint(
                    timestamp: row.timestamp,
                    bucketID: row.bucketID,
                    bucketName: row.bucketName,
                    bucketKind: row.bucketKind,
                    window: window,
                    usedPercent: row.usedPercent,
                    peakUsedPercent: row.peakUsedPercent,
                    consumedPercent: consumedPercent
                )
            }
        }

        while true {
            let result = sqlite3_step(statement)

            switch result {
            case SQLITE_ROW:
                let bucketID = columnText(statement, index: 0)
                let bucketName = columnText(statement, index: 1)
                let bucketKind = CodexUsageBucketKind(rawValue: columnText(statement, index: 2)) ?? .model
                let timestamp = sqlite3_column_int64(statement, 3)
                let usedPercent = sqlite3_column_double(statement, 4)
                let peakUsedPercent = sqlite3_column_double(statement, 5)
                let consumedPercent = optionalColumnDouble(statement, index: 6)
                rows.append(
                    PointRow(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                        bucketID: bucketID,
                        bucketName: bucketName,
                        bucketKind: bucketKind,
                        usedPercent: usedPercent,
                        peakUsedPercent: peakUsedPercent,
                        consumedPercent: consumedPercent
                    )
                )
            case SQLITE_DONE:
                return points(from: rows, window: window)
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private static func series(from points: [UsageHistoryPoint]) -> [UsageHistorySeries] {
        var seen = Set<String>()
        return points
            .compactMap { point in
                guard seen.insert(point.bucketID).inserted else {
                    return nil
                }

                return UsageHistorySeries(id: point.bucketID, name: point.bucketName, kind: point.bucketKind)
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .aggregate
                }

                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static func series(from points: [TokenHistoryPoint]) -> [UsageHistorySeries] {
        var seen = Set<String>()
        return points
            .compactMap { point in
                guard seen.insert(point.seriesID).inserted else {
                    return nil
                }

                return UsageHistorySeries(id: point.seriesID, name: point.seriesName, kind: point.seriesKind)
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .aggregate
                }

                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func readAvailableSeries(from statement: OpaquePointer) throws -> [UsageHistorySeries] {
        var seen = Set<String>()
        var series: [UsageHistorySeries] = []

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let id = columnText(statement, index: 0)
                guard seen.insert(id).inserted else {
                    continue
                }

                series.append(
                    UsageHistorySeries(
                        id: id,
                        name: columnText(statement, index: 1),
                        kind: CodexUsageBucketKind(rawValue: columnText(statement, index: 2)) ?? .model
                    )
                )
            case SQLITE_DONE:
                return series.sorted { lhs, rhs in
                    if lhs.kind != rhs.kind {
                        return lhs.kind == .aggregate
                    }

                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private func compactRawSamples(olderThan date: Date) throws {
        let statement = try prepare("DELETE FROM usage_samples WHERE timestamp < ?")
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, date.timeIntervalSince1970Int)
        try step(statement)
    }

    private func checkpointWriteAheadLog() throws {
        let result = sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard result == SQLITE_OK else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func attachBackupDatabase(at sourceURL: URL) throws {
        let statement = try prepare("ATTACH DATABASE ? AS imported_usage_history")
        defer { sqlite3_finalize(statement) }

        bindText(sourceURL.path, to: 1, in: statement)
        try step(statement)
    }

    private func detachBackupDatabase() throws {
        try execute("DETACH DATABASE imported_usage_history")
    }

    private func tableHasColumn(table: String, column: String, schema: String? = nil) throws -> Bool {
        let pragmaPrefix = schema.map { "\($0)." } ?? ""
        let statement = try prepare("PRAGMA \(pragmaPrefix)table_info(\(table))")
        defer { sqlite3_finalize(statement) }

        while true {
            let result = sqlite3_step(statement)

            switch result {
            case SQLITE_ROW:
                if columnText(statement, index: 1) == column {
                    return true
                }
            case SQLITE_DONE:
                return false
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    private func tableExists(table: String, schema: String? = nil) throws -> Bool {
        let schemaName = schema ?? "main"
        let statement = try prepare(
            "SELECT EXISTS(SELECT 1 FROM \(schemaName).sqlite_master WHERE type = 'table' AND name = ?)"
        )
        defer { sqlite3_finalize(statement) }

        bindText(table, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) != 0
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func periodStart(for timestamp: Int64, granularity: UsageHistoryGranularity) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let components: Set<Calendar.Component> = if granularity == .hour {
            [.year, .month, .day, .hour]
        } else {
            [.year, .month, .day]
        }

        return calendar.date(from: calendar.dateComponents(components, from: date))?.timeIntervalSince1970Int ?? timestamp
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")

        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)

        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw UsageHistoryStoreError.databaseOperationFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(lastErrorMessage)
        }

        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func bindText(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            bindText(value, to: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalInt(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func normalizedModelName(_ value: String?) -> String? {
        CodexModelIdentifier.normalized(value)
    }

    private static func normalizedModelSQLExpression(column: String) -> String {
        let cleanedModelExpression = """
        TRIM(REPLACE(REPLACE(REPLACE(\(column), char(9), ' '), char(10), ' '), char(13), ' '))
        """
        return """
        NULLIF(CASE
            WHEN INSTR(\(cleanedModelExpression), ' ') > 0
                THEN SUBSTR(\(cleanedModelExpression), 1, INSTR(\(cleanedModelExpression), ' ') - 1)
            ELSE \(cleanedModelExpression)
        END, '')
        """
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }

        return String(cString: text)
    }

    private func optionalColumnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return columnText(statement, index: index)
    }

    private func optionalColumnInt(_ statement: OpaquePointer, index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return sqlite3_column_int64(statement, index)
    }

    private func optionalColumnDouble(_ statement: OpaquePointer, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return sqlite3_column_double(statement, index)
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func observedConsumedPercent(
        currentUsedPercent: Double,
        previousUsedPercent: Double?
    ) -> Double {
        guard let previousUsedPercent else {
            return 0
        }

        let consumedPercent = currentUsedPercent - previousUsedPercent
        return min(max(consumedPercent, 0), 100)
    }

    private static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval((date.timeIntervalSince1970Int / 60) * 60))
    }

    private static func roundedToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(date.timeIntervalSince1970Int))
    }

    private static func totalByteSize(for databaseURL: URL, fileManager: FileManager) -> Int64 {
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

    private static func databaseFileURLs(for databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    private static func validateBackup(at sourceURL: URL) throws {
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

    private static func backupTableExists(_ table: String, database: OpaquePointer) throws -> Bool {
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

    private static func validateBackupQuery(_ sql: String, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.invalidBackup
        }
        sqlite3_finalize(statement)
    }

    private static func normalizeBackupJournalMode(at backupURL: URL) throws {
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

    private static func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        return value
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
        case .model:
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

private extension CodexRateLimitSnapshot {
    func window(for usageWindow: UsageLimitWindow) -> CodexRateLimitWindow? {
        switch usageWindow {
        case .fiveHour:
            return primary
        case .sevenDay:
            return secondary
        }
    }
}

private extension Date {
    var timeIntervalSince1970Int: Int64 {
        Int64(timeIntervalSince1970.rounded(.down))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
