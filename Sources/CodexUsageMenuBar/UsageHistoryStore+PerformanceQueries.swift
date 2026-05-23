import Foundation
import SQLite3

extension UsageHistoryStore {
    func performanceDashboardTimingSamples(
        periodStart: Date,
        periodEnd: Date
    ) throws -> [PerformanceDashboardTimingSample] {
        let statement = try prepare(
            """
            SELECT COALESCE(started_at, completed_at, recorded_at) AS event_timestamp,
                session_id, turn_id, started_at, completed_at, duration_ms,
                time_to_first_token_ms, model, project_path, project_name,
                effort, source
            FROM codex_session_task_timing_events
            WHERE COALESCE(started_at, completed_at, recorded_at) >= ?
              AND COALESCE(started_at, completed_at, recorded_at) < ?
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

    func performanceDashboardBounds() throws -> UsageHistoryBounds? {
        let statement = try prepare(
            """
            SELECT MIN(timestamp), MAX(timestamp)
            FROM (
                SELECT COALESCE(started_at, completed_at, recorded_at) AS timestamp
                FROM codex_session_task_timing_events
                WHERE COALESCE(started_at, completed_at, recorded_at) IS NOT NULL
                UNION ALL
                SELECT event_timestamp AS timestamp
                FROM codex_turn_performance_events
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
}
