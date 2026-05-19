import Foundation
import SQLite3

extension UsageHistoryStore {
    func latestUsageSnapshot() throws -> CachedCodexUsageSnapshot? {
        let statement = try prepare(
            """
            SELECT window, used_percent, reset_at, timestamp
            FROM usage_samples AS sample
            WHERE bucket_kind = 'aggregate'
                AND bucket_id = 'codex'
                AND window IN (?, ?)
                AND timestamp = (
                    SELECT MAX(latest.timestamp)
                    FROM usage_samples AS latest
                    WHERE latest.bucket_kind = sample.bucket_kind
                        AND latest.bucket_id = sample.bucket_id
                        AND latest.window = sample.window
                )
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(UsageLimitWindow.fiveHour.rawValue, to: 1, in: statement)
        bindText(UsageLimitWindow.sevenDay.rawValue, to: 2, in: statement)

        var primary: CodexRateLimitWindow?
        var secondary: CodexRateLimitWindow?
        var latestTimestamp: Int64?

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard
                    let rawWindow = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                    let window = UsageLimitWindow(rawValue: rawWindow)
                else {
                    continue
                }

                let usedPercent = Int(sqlite3_column_int(statement, 1))
                let resetAt = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2)))
                let timestamp = sqlite3_column_int64(statement, 3)
                latestTimestamp = max(latestTimestamp ?? timestamp, timestamp)

                let limitWindow = CodexRateLimitWindow(
                    usedPercent: usedPercent,
                    windowDurationMinutes: nil,
                    resetsAt: resetAt
                )

                switch window {
                case .fiveHour:
                    primary = limitWindow
                case .sevenDay:
                    secondary = limitWindow
                }
            case SQLITE_DONE:
                guard primary != nil || secondary != nil, let latestTimestamp else {
                    return nil
                }

                return CachedCodexUsageSnapshot(
                    snapshot: CodexUsageSnapshot.aggregateOnly(
                        displaySnapshot: CodexRateLimitSnapshot(primary: primary, secondary: secondary)
                    ),
                    recordedAt: Date(timeIntervalSince1970: TimeInterval(latestTimestamp))
                )
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
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
            FROM usage_series_catalog
            WHERE window = ?
            ORDER BY seen_at DESC, bucket_kind ASC, bucket_name ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(window.rawValue, to: 1, in: statement)

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

    func rawHistoryBounds(window: UsageLimitWindow) throws -> UsageHistoryBounds? {
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

    func rollupHistoryBounds(
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

    func readHistoryBounds(from statement: OpaquePointer) throws -> UsageHistoryBounds? {
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

    func rawPoints(window: UsageLimitWindow, startTimestamp: Int64, endTimestamp: Int64) throws -> [UsageHistoryPoint] {
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

    func rollupPoints(
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

    func readPoints(from statement: OpaquePointer, window: UsageLimitWindow) throws -> [UsageHistoryPoint] {
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

    static func series(from points: [UsageHistoryPoint]) -> [UsageHistorySeries] {
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

    static func series(from points: [TokenHistoryPoint]) -> [UsageHistorySeries] {
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

    func readAvailableSeries(from statement: OpaquePointer) throws -> [UsageHistorySeries] {
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

    static func tokenHistoryBucketIntervals(
        range: UsageHistoryRange,
        periodStart: Date,
        periodEnd: Date,
        now: Date,
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
            let displayEnd = max(min(queryEnd, now), bucketStart)
            if queryEnd > bucketStart {
                intervals.append((start: bucketStart, queryEnd: queryEnd, displayEnd: displayEnd))
            }
            bucketStart = nextBucketStart
        }

        return intervals
    }

    func compactRawSamples(olderThan date: Date) throws {
        let statement = try prepare("DELETE FROM usage_samples WHERE timestamp < ?")
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, date.timeIntervalSince1970Int)
        try step(statement)
    }
}
