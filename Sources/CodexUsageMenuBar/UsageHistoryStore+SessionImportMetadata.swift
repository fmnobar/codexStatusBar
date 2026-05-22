import Foundation
import SQLite3

extension UsageHistoryStore {
    func codexTurnPerformanceCaptureState(
        sourceKey: String = CodexTurnPerformanceCaptureState.codexOtelLogSourceKey
    ) throws -> CodexTurnPerformanceCaptureState {
        let statement = try prepare(
            """
            SELECT source_key, last_checked_at, last_imported_event_at, last_log_row_id,
                status, inserted_count, duplicate_count, last_error_text
            FROM codex_turn_performance_capture_state
            WHERE source_key = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sourceKey, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let rawStatus = columnText(statement, index: 4)
            let status = CodexTurnPerformanceCaptureStatus(rawValue: rawStatus) ?? .neverChecked
            return CodexTurnPerformanceCaptureState(
                sourceKey: columnText(statement, index: 0),
                lastCheckedAt: optionalColumnDate(statement, index: 1),
                lastImportedEventAt: optionalColumnDate(statement, index: 2),
                lastLogRowID: sqlite3_column_int64(statement, 3),
                status: status,
                insertedCount: Int(sqlite3_column_int64(statement, 5)),
                duplicateCount: Int(sqlite3_column_int64(statement, 6)),
                lastErrorText: optionalColumnText(statement, index: 7)
            )
        case SQLITE_DONE:
            return CodexTurnPerformanceCaptureState(sourceKey: sourceKey)
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func recordCodexTurnPerformanceCaptureState(_ state: CodexTurnPerformanceCaptureState) throws {
        let statement = try prepare(
            """
            INSERT INTO codex_turn_performance_capture_state (
                source_key, last_checked_at, last_imported_event_at, last_log_row_id,
                status, inserted_count, duplicate_count, last_error_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                last_checked_at = excluded.last_checked_at,
                last_imported_event_at = COALESCE(excluded.last_imported_event_at, codex_turn_performance_capture_state.last_imported_event_at),
                last_log_row_id = MAX(codex_turn_performance_capture_state.last_log_row_id, excluded.last_log_row_id),
                status = excluded.status,
                inserted_count = excluded.inserted_count,
                duplicate_count = excluded.duplicate_count,
                last_error_text = excluded.last_error_text
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(state.sourceKey, to: 1, in: statement)
        bindOptionalDate(state.lastCheckedAt, to: 2, in: statement)
        bindOptionalDate(state.lastImportedEventAt, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, state.lastLogRowID)
        bindText(state.status.rawValue, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(state.insertedCount))
        sqlite3_bind_int64(statement, 7, Int64(state.duplicateCount))
        bindOptionalText(state.lastErrorText, to: 8, in: statement)

        try step(statement)
    }

    func importTurnPerformanceEvents(_ events: [CodexTurnPerformanceEvent]) throws -> CodexTurnPerformanceImportResult {
        guard !events.isEmpty else {
            return .empty
        }

        var insertedCount = 0
        var duplicateCount = 0

        try transaction {
            for event in events {
                if try insertTurnPerformanceEvent(event) {
                    insertedCount += 1
                } else {
                    duplicateCount += 1
                }
            }
        }

        return CodexTurnPerformanceImportResult(insertedCount: insertedCount, duplicateCount: duplicateCount)
    }

    func turnPerformanceEvents() throws -> [CodexTurnPerformanceEvent] {
        let statement = try prepare(
            """
            SELECT source_key, source_row_id, target, event_timestamp, event_name, event_kind,
                duration_ms, success, error_summary, thread_id, turn_id, model, session_id,
                project_path, effort, source, originator, app_version, terminal_type,
                transport, wire_api, api_path, recorded_at
            FROM codex_turn_performance_events
            ORDER BY event_timestamp ASC, source_row_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var events: [CodexTurnPerformanceEvent] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                events.append(
                    CodexTurnPerformanceEvent(
                        sourceKey: columnText(statement, index: 0),
                        sourceRowID: sqlite3_column_int64(statement, 1),
                        target: columnText(statement, index: 2),
                        eventTimestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3))),
                        eventName: optionalColumnText(statement, index: 4),
                        eventKind: optionalColumnText(statement, index: 5),
                        durationMilliseconds: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6),
                        success: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 7) != 0,
                        errorSummary: optionalColumnText(statement, index: 8),
                        threadID: optionalColumnText(statement, index: 9),
                        turnID: optionalColumnText(statement, index: 10),
                        model: optionalColumnText(statement, index: 11),
                        sessionID: optionalColumnText(statement, index: 12),
                        projectPath: optionalColumnText(statement, index: 13),
                        effort: optionalColumnText(statement, index: 14),
                        source: optionalColumnText(statement, index: 15),
                        originator: optionalColumnText(statement, index: 16),
                        appVersion: optionalColumnText(statement, index: 17),
                        terminalType: optionalColumnText(statement, index: 18),
                        transport: optionalColumnText(statement, index: 19),
                        wireAPI: optionalColumnText(statement, index: 20),
                        apiPath: optionalColumnText(statement, index: 21),
                        recordedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 22)))
                    )
                )
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }

        return events
    }

    private func insertTurnPerformanceEvent(_ event: CodexTurnPerformanceEvent) throws -> Bool {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO codex_turn_performance_events (
                source_key, source_row_id, target, event_timestamp, event_name, event_kind,
                duration_ms, success, error_summary, thread_id, turn_id, model, session_id,
                project_path, project_name, effort, source, originator, app_version,
                terminal_type, transport, wire_api, api_path, recorded_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(event.sourceKey, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, event.sourceRowID)
        bindText(event.target, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, event.eventTimestamp.timeIntervalSince1970Int)
        bindOptionalText(event.eventName, to: 5, in: statement)
        bindOptionalText(event.eventKind, to: 6, in: statement)
        bindOptionalInt(event.durationMilliseconds, to: 7, in: statement)
        if let success = event.success {
            sqlite3_bind_int64(statement, 8, success ? 1 : 0)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        bindOptionalText(event.errorSummary, to: 9, in: statement)
        bindOptionalText(event.threadID, to: 10, in: statement)
        bindOptionalText(event.turnID, to: 11, in: statement)
        bindOptionalText(event.model, to: 12, in: statement)
        bindOptionalText(event.sessionID, to: 13, in: statement)
        bindOptionalText(event.projectPath, to: 14, in: statement)
        bindOptionalText(event.projectName, to: 15, in: statement)
        bindOptionalText(event.effort, to: 16, in: statement)
        bindOptionalText(event.source, to: 17, in: statement)
        bindOptionalText(event.originator, to: 18, in: statement)
        bindOptionalText(event.appVersion, to: 19, in: statement)
        bindOptionalText(event.terminalType, to: 20, in: statement)
        bindOptionalText(event.transport, to: 21, in: statement)
        bindOptionalText(event.wireAPI, to: 22, in: statement)
        bindOptionalText(event.apiPath, to: 23, in: statement)
        sqlite3_bind_int64(statement, 24, event.recordedAt.timeIntervalSince1970Int)

        try step(statement)
        return sqlite3_changes(database) > 0
    }

    func codexLiveTokenCaptureState(
        sourceKey: String = CodexLiveTokenCaptureState.codexLogSourceKey
    ) throws -> CodexLiveTokenCaptureState {
        let statement = try prepare(
            """
            SELECT source_key, last_checked_at, last_imported_event_at, last_log_row_id,
                status, inserted_count, duplicate_count, repaired_model_count,
                repaired_context_count, repaired_dimension_count, last_error_text
            FROM codex_live_token_capture_state
            WHERE source_key = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sourceKey, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let rawStatus = columnText(statement, index: 4)
            let status = CodexLiveTokenCaptureStatus(rawValue: rawStatus) ?? .neverChecked
            return CodexLiveTokenCaptureState(
                sourceKey: columnText(statement, index: 0),
                lastCheckedAt: optionalColumnDate(statement, index: 1),
                lastImportedEventAt: optionalColumnDate(statement, index: 2),
                lastLogRowID: sqlite3_column_int64(statement, 3),
                status: status,
                result: TokenUsageImportResult(
                    insertedCount: Int(sqlite3_column_int64(statement, 5)),
                    duplicateCount: Int(sqlite3_column_int64(statement, 6)),
                    repairedModelCount: Int(sqlite3_column_int64(statement, 7)),
                    repairedContextCount: Int(sqlite3_column_int64(statement, 8)),
                    repairedDimensionCount: Int(sqlite3_column_int64(statement, 9))
                ),
                lastErrorText: optionalColumnText(statement, index: 10)
            )
        case SQLITE_DONE:
            return CodexLiveTokenCaptureState(sourceKey: sourceKey)
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func recordCodexLiveTokenCaptureState(_ state: CodexLiveTokenCaptureState) throws {
        let statement = try prepare(
            """
            INSERT INTO codex_live_token_capture_state (
                source_key, last_checked_at, last_imported_event_at, last_log_row_id,
                status, inserted_count, duplicate_count, repaired_model_count,
                repaired_context_count, repaired_dimension_count, last_error_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                last_checked_at = excluded.last_checked_at,
                last_imported_event_at = COALESCE(excluded.last_imported_event_at, codex_live_token_capture_state.last_imported_event_at),
                last_log_row_id = MAX(codex_live_token_capture_state.last_log_row_id, excluded.last_log_row_id),
                status = excluded.status,
                inserted_count = excluded.inserted_count,
                duplicate_count = excluded.duplicate_count,
                repaired_model_count = excluded.repaired_model_count,
                repaired_context_count = excluded.repaired_context_count,
                repaired_dimension_count = excluded.repaired_dimension_count,
                last_error_text = excluded.last_error_text
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(state.sourceKey, to: 1, in: statement)
        bindOptionalDate(state.lastCheckedAt, to: 2, in: statement)
        bindOptionalDate(state.lastImportedEventAt, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, state.lastLogRowID)
        bindText(state.status.rawValue, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(state.result.insertedCount))
        sqlite3_bind_int64(statement, 7, Int64(state.result.duplicateCount))
        sqlite3_bind_int64(statement, 8, Int64(state.result.repairedModelCount))
        sqlite3_bind_int64(statement, 9, Int64(state.result.repairedContextCount))
        sqlite3_bind_int64(statement, 10, Int64(state.result.repairedDimensionCount))
        bindOptionalText(state.lastErrorText, to: 11, in: statement)

        try step(statement)
    }

    func codexSessionTokenImportFileRecord(path: String) throws -> CodexSessionTokenImportFileRecord? {
        let statement = try prepare(
            """
            SELECT file_path, file_size, modified_at, imported_at, status, context_version
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
                status: status,
                contextVersion: optionalColumnText(statement, index: 5)
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
                file_path, file_size, modified_at, imported_at, status, context_version
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                file_size = excluded.file_size,
                modified_at = excluded.modified_at,
                imported_at = excluded.imported_at,
                status = excluded.status,
                context_version = excluded.context_version
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(metadata.path, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, metadata.fileSize)
        sqlite3_bind_int64(statement, 3, metadata.modifiedAt)
        sqlite3_bind_int64(statement, 4, importedAt)
        bindText(status.rawValue, to: 5, in: statement)
        bindText(Self.currentSessionTokenContextImportVersion, to: 6, in: statement)

        try step(statement)
    }

    func codexSessionTokenImportFileRecords() throws -> [CodexSessionTokenImportFileRecord] {
        let statement = try prepare(
            """
            SELECT file_path, file_size, modified_at, imported_at, status, context_version
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
                        status: status,
                        contextVersion: optionalColumnText(statement, index: 5)
                    )
                )
            case SQLITE_DONE:
                return records
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }
}
