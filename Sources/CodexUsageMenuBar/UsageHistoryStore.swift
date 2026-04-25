import Foundation
import SQLite3

protocol UsageHistoryRecording {
    func record(snapshot: CodexUsageSnapshot, at date: Date)
}

struct NoOpUsageHistoryRecorder: UsageHistoryRecording {
    func record(snapshot: CodexUsageSnapshot, at date: Date) {}
}

final class UsageHistoryRecorder: UsageHistoryRecording {
    private let store: UsageHistoryStore

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

final class UsageHistoryStore {
    static let didChangeNotification = Notification.Name("UsageHistoryStoreDidChange")
    static let defaultRawRetention: TimeInterval = 14 * 24 * 60 * 60

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

    func points(
        range: UsageHistoryRange,
        window: UsageLimitWindow,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> [UsageHistoryPoint] {
        let startTimestamp = range.startDate(before: now, calendar: calendar).timeIntervalSince1970Int
        let endTimestamp = now.timeIntervalSince1970Int

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
        }

        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    func hasAnyHistory() throws -> Bool {
        let statement = try prepare(
            """
            SELECT EXISTS(SELECT 1 FROM usage_samples LIMIT 1)
                OR EXISTS(SELECT 1 FROM usage_rollups LIMIT 1)
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

        try transaction {
            try execute("DELETE FROM usage_samples")
            try execute("DELETE FROM usage_rollups")
            try execute(
                """
                INSERT INTO usage_samples (
                    bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent, reset_at
                )
                SELECT bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent, reset_at
                FROM imported_usage_history.usage_samples
                """
            )
            try execute(
                """
                INSERT INTO usage_rollups (
                    granularity, bucket_id, bucket_name, bucket_kind, window, period_start,
                    sample_timestamp, used_percent, peak_used_percent, reset_at
                )
                SELECT granularity, bucket_id, bucket_name, bucket_kind, window, period_start,
                    sample_timestamp, used_percent, \(importedPeakExpression), reset_at
                FROM imported_usage_history.usage_rollups
                """
            )
        }

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
                reset_at INTEGER,
                PRIMARY KEY (granularity, bucket_id, window, period_start)
            )
            """
        )
        try addColumnIfNeeded(table: "usage_rollups", column: "peak_used_percent", definition: "INTEGER")

        try execute("CREATE INDEX IF NOT EXISTS idx_usage_samples_window_timestamp ON usage_samples(window, timestamp)")
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_rollups_window_sample_timestamp ON usage_rollups(granularity, window, sample_timestamp)")
    }

    private func addColumnIfNeeded(table: String, column: String, definition: String) throws {
        guard try !tableHasColumn(table: table, column: column) else {
            return
        }

        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func record(bucket: CodexUsageBucket, window: UsageLimitWindow, timestamp: Int64) throws {
        guard let rateLimitWindow = bucket.snapshot.window(for: window) else {
            return
        }

        try insertRawSample(
            bucket: bucket,
            window: window,
            timestamp: timestamp,
            usedPercent: rateLimitWindow.usedPercent,
            resetAt: rateLimitWindow.resetsAt?.timeIntervalSince1970Int
        )
        try insertRollup(
            granularity: .hour,
            bucket: bucket,
            window: window,
            timestamp: timestamp,
            usedPercent: rateLimitWindow.usedPercent,
            resetAt: rateLimitWindow.resetsAt?.timeIntervalSince1970Int
        )
        try insertRollup(
            granularity: .day,
            bucket: bucket,
            window: window,
            timestamp: timestamp,
            usedPercent: rateLimitWindow.usedPercent,
            resetAt: rateLimitWindow.resetsAt?.timeIntervalSince1970Int
        )
    }

    private func insertRawSample(
        bucket: CodexUsageBucket,
        window: UsageLimitWindow,
        timestamp: Int64,
        usedPercent: Int,
        resetAt: Int64?
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO usage_samples (
                bucket_id, bucket_name, bucket_kind, window, timestamp, used_percent, reset_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket_id, window, timestamp) DO UPDATE SET
                bucket_name = excluded.bucket_name,
                bucket_kind = excluded.bucket_kind,
                used_percent = excluded.used_percent,
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
        bindOptionalInt(resetAt, to: 7, in: statement)

        try step(statement)
    }

    private func insertRollup(
        granularity: UsageHistoryGranularity,
        bucket: CodexUsageBucket,
        window: UsageLimitWindow,
        timestamp: Int64,
        usedPercent: Int,
        resetAt: Int64?
    ) throws {
        let periodStart = periodStart(for: timestamp, granularity: granularity)
        let statement = try prepare(
            """
            INSERT INTO usage_rollups (
                granularity, bucket_id, bucket_name, bucket_kind, window, period_start,
                sample_timestamp, used_percent, peak_used_percent, reset_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        bindOptionalInt(resetAt, to: 10, in: statement)

        try step(statement)
    }

    private func rawPoints(window: UsageLimitWindow, startTimestamp: Int64, endTimestamp: Int64) throws -> [UsageHistoryPoint] {
        let statement = try prepare(
            """
            SELECT bucket_id, bucket_name, bucket_kind, timestamp, used_percent, used_percent
            FROM usage_samples
            WHERE window = ? AND timestamp >= ? AND timestamp <= ?
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
                used_percent, IFNULL(peak_used_percent, used_percent)
            FROM usage_rollups
            WHERE granularity = ? AND window = ? AND sample_timestamp >= ? AND sample_timestamp <= ?
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
        var points: [UsageHistoryPoint] = []

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
                points.append(
                    UsageHistoryPoint(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                        bucketID: bucketID,
                        bucketName: bucketName,
                        bucketKind: bucketKind,
                        window: window,
                        usedPercent: usedPercent,
                        peakUsedPercent: peakUsedPercent
                    )
                )
            case SQLITE_DONE:
                return points
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

    private func bindOptionalInt(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }

        return String(cString: text)
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval((date.timeIntervalSince1970Int / 60) * 60))
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
