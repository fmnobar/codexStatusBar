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

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message):
            return "Usage history database could not be opened: \(message)"
        case .databaseOperationFailed(let message):
            return "Usage history database operation failed: \(message)"
        case .statementPreparationFailed(let message):
            return "Usage history database statement could not be prepared: \(message)"
        }
    }
}

final class UsageHistoryStore {
    static let didChangeNotification = Notification.Name("UsageHistoryStoreDidChange")
    static let defaultRawRetention: TimeInterval = 14 * 24 * 60 * 60

    private let database: OpaquePointer
    private let notificationCenter: NotificationCenter
    private let calendar: Calendar
    private let rawRetention: TimeInterval

    convenience init(
        databaseURL: URL,
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetention: TimeInterval = UsageHistoryStore.defaultRawRetention
    ) throws {
        try self.init(
            databasePath: databaseURL.path,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetention: rawRetention
        )
    }

    private init(
        databasePath: String,
        notificationCenter: NotificationCenter,
        calendar: Calendar,
        rawRetention: TimeInterval
    ) throws {
        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &openedDatabase, flags, nil) == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw UsageHistoryStoreError.databaseOpenFailed(message)
        }

        database = openedDatabase
        self.notificationCenter = notificationCenter
        self.calendar = calendar
        self.rawRetention = rawRetention

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    static func applicationSupportStore() throws -> UsageHistoryStore {
        let directoryURL = try applicationSupportDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try UsageHistoryStore(databaseURL: directoryURL.appendingPathComponent("usage-history.sqlite3"))
    }

    static func inMemory(
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetention: TimeInterval = UsageHistoryStore.defaultRawRetention
    ) throws -> UsageHistoryStore {
        try UsageHistoryStore(
            databasePath: ":memory:",
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetention: rawRetention
        )
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) throws {
        let timestamp = Self.roundedToMinute(date).timeIntervalSince1970Int

        try transaction {
            for bucket in snapshot.bucketsForRecording {
                try record(bucket: bucket, window: .fiveHour, timestamp: timestamp)
                try record(bucket: bucket, window: .sevenDay, timestamp: timestamp)
            }

            try compactRawSamples(olderThan: Date(timeIntervalSince1970: TimeInterval(timestamp)).addingTimeInterval(-rawRetention))
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
                reset_at INTEGER,
                PRIMARY KEY (granularity, bucket_id, window, period_start)
            )
            """
        )

        try execute("CREATE INDEX IF NOT EXISTS idx_usage_samples_window_timestamp ON usage_samples(window, timestamp)")
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_rollups_window_sample_timestamp ON usage_rollups(granularity, window, sample_timestamp)")
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
                sample_timestamp, used_percent, reset_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(granularity, bucket_id, window, period_start) DO UPDATE SET
                bucket_name = excluded.bucket_name,
                bucket_kind = excluded.bucket_kind,
                sample_timestamp = excluded.sample_timestamp,
                used_percent = excluded.used_percent,
                reset_at = excluded.reset_at
            WHERE excluded.sample_timestamp >= usage_rollups.sample_timestamp
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
        bindOptionalInt(resetAt, to: 9, in: statement)

        try step(statement)
    }

    private func rawPoints(window: UsageLimitWindow, startTimestamp: Int64, endTimestamp: Int64) throws -> [UsageHistoryPoint] {
        let statement = try prepare(
            """
            SELECT bucket_id, bucket_name, bucket_kind, timestamp, used_percent
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
            SELECT bucket_id, bucket_name, bucket_kind, sample_timestamp, used_percent
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
                points.append(
                    UsageHistoryPoint(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                        bucketID: bucketID,
                        bucketName: bucketName,
                        bucketKind: bucketKind,
                        window: window,
                        usedPercent: usedPercent
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
