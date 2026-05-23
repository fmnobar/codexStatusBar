import Foundation
import SQLite3

extension UsageHistoryStore {
    func codexSessionTaskTimingCaptureState(
        sourceKey: String = CodexSessionTaskTimingCaptureState.sessionJSONLSourceKey
    ) throws -> CodexSessionTaskTimingCaptureState {
        let statement = try prepare(
            """
            SELECT source_key, last_checked_at, last_imported_event_at, status,
                files_discovered, files_scanned, files_skipped_unchanged,
                inserted_count, updated_count, duplicate_count, failed_lines_skipped,
                last_error_text
            FROM codex_session_task_timing_capture_state
            WHERE source_key = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sourceKey, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let rawStatus = columnText(statement, index: 3)
            return CodexSessionTaskTimingCaptureState(
                sourceKey: columnText(statement, index: 0),
                lastCheckedAt: optionalColumnDate(statement, index: 1),
                lastImportedEventAt: optionalColumnDate(statement, index: 2),
                status: CodexSessionTaskTimingCaptureStatus(rawValue: rawStatus) ?? .neverChecked,
                filesDiscovered: Int(sqlite3_column_int64(statement, 4)),
                filesScanned: Int(sqlite3_column_int64(statement, 5)),
                filesSkippedUnchanged: Int(sqlite3_column_int64(statement, 6)),
                insertedCount: Int(sqlite3_column_int64(statement, 7)),
                updatedCount: Int(sqlite3_column_int64(statement, 8)),
                duplicateCount: Int(sqlite3_column_int64(statement, 9)),
                failedLinesSkipped: Int(sqlite3_column_int64(statement, 10)),
                lastErrorText: optionalColumnText(statement, index: 11)
            )
        case SQLITE_DONE:
            return CodexSessionTaskTimingCaptureState(sourceKey: sourceKey)
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func recordCodexSessionTaskTimingCaptureState(_ state: CodexSessionTaskTimingCaptureState) throws {
        let statement = try prepare(
            """
            INSERT INTO codex_session_task_timing_capture_state (
                source_key, last_checked_at, last_imported_event_at, status,
                files_discovered, files_scanned, files_skipped_unchanged,
                inserted_count, updated_count, duplicate_count, failed_lines_skipped,
                last_error_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                last_checked_at = excluded.last_checked_at,
                last_imported_event_at = COALESCE(excluded.last_imported_event_at, codex_session_task_timing_capture_state.last_imported_event_at),
                status = excluded.status,
                files_discovered = excluded.files_discovered,
                files_scanned = excluded.files_scanned,
                files_skipped_unchanged = excluded.files_skipped_unchanged,
                inserted_count = excluded.inserted_count,
                updated_count = excluded.updated_count,
                duplicate_count = excluded.duplicate_count,
                failed_lines_skipped = excluded.failed_lines_skipped,
                last_error_text = excluded.last_error_text
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(state.sourceKey, to: 1, in: statement)
        bindOptionalDate(state.lastCheckedAt, to: 2, in: statement)
        bindOptionalDate(state.lastImportedEventAt, to: 3, in: statement)
        bindText(state.status.rawValue, to: 4, in: statement)
        sqlite3_bind_int64(statement, 5, Int64(state.filesDiscovered))
        sqlite3_bind_int64(statement, 6, Int64(state.filesScanned))
        sqlite3_bind_int64(statement, 7, Int64(state.filesSkippedUnchanged))
        sqlite3_bind_int64(statement, 8, Int64(state.insertedCount))
        sqlite3_bind_int64(statement, 9, Int64(state.updatedCount))
        sqlite3_bind_int64(statement, 10, Int64(state.duplicateCount))
        sqlite3_bind_int64(statement, 11, Int64(state.failedLinesSkipped))
        bindOptionalText(state.lastErrorText, to: 12, in: statement)

        try step(statement)
    }

    func codexSessionTaskTimingImportFileRecord(path: String) throws -> CodexSessionTaskTimingImportFileRecord? {
        let statement = try prepare(
            """
            SELECT file_path, file_size, modified_at, imported_at, status, timing_version
            FROM codex_session_task_timing_import_files
            WHERE file_path = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(path, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let rawStatus = columnText(statement, index: 4)
            let status = CodexSessionTaskTimingImportFileStatus(rawValue: rawStatus) ?? .failed
            return CodexSessionTaskTimingImportFileRecord(
                metadata: CodexSessionTokenImportFileMetadata(
                    path: columnText(statement, index: 0),
                    fileSize: sqlite3_column_int64(statement, 1),
                    modifiedAt: sqlite3_column_int64(statement, 2)
                ),
                importedAt: sqlite3_column_int64(statement, 3),
                status: status,
                timingVersion: optionalColumnText(statement, index: 5)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func recordCodexSessionTaskTimingImportFile(
        _ metadata: CodexSessionTokenImportFileMetadata,
        importedAt: Int64,
        status: CodexSessionTaskTimingImportFileStatus
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO codex_session_task_timing_import_files (
                file_path, file_size, modified_at, imported_at, status, timing_version
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                file_size = excluded.file_size,
                modified_at = excluded.modified_at,
                imported_at = excluded.imported_at,
                status = excluded.status,
                timing_version = excluded.timing_version
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(metadata.path, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, metadata.fileSize)
        sqlite3_bind_int64(statement, 3, metadata.modifiedAt)
        sqlite3_bind_int64(statement, 4, importedAt)
        bindText(status.rawValue, to: 5, in: statement)
        bindText(Self.currentSessionTaskTimingImportVersion, to: 6, in: statement)

        try step(statement)
    }

    func importSessionTaskTimingEvents(_ events: [CodexSessionTaskTimingEvent]) throws -> CodexSessionTaskTimingImportResult {
        guard !events.isEmpty else {
            return .empty
        }

        var insertedCount = 0
        var updatedCount = 0
        var duplicateCount = 0

        try transaction {
            for event in events {
                switch try upsertSessionTaskTimingEvent(event) {
                case .inserted:
                    insertedCount += 1
                case .updated:
                    updatedCount += 1
                case .duplicate:
                    duplicateCount += 1
                }
            }
        }

        return CodexSessionTaskTimingImportResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            duplicateCount: duplicateCount
        )
    }

    func sessionTaskTimingEvents() throws -> [CodexSessionTaskTimingEvent] {
        let statement = try prepare(
            """
            SELECT session_id, turn_id, source_path, started_at, completed_at,
                duration_ms, time_to_first_token_ms, model_context_window,
                collaboration_mode_kind, model, project_path, effort, source,
                dimensions_json, recorded_at
            FROM codex_session_task_timing_events
            ORDER BY COALESCE(started_at, completed_at, recorded_at), session_id, turn_id
            """
        )
        defer { sqlite3_finalize(statement) }

        var events: [CodexSessionTaskTimingEvent] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let event = sessionTaskTimingEvent(from: statement) {
                    events.append(event)
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }

        return events
    }

    private enum SessionTaskTimingUpsertResult {
        case inserted
        case updated
        case duplicate
    }

    private func upsertSessionTaskTimingEvent(_ event: CodexSessionTaskTimingEvent) throws -> SessionTaskTimingUpsertResult {
        if let existingEvent = try sessionTaskTimingEvent(sessionID: event.sessionID, turnID: event.turnID) {
            let mergedEvent = existingEvent.merged(with: event)
            guard !mergedEvent.hasSameStoredContent(as: existingEvent) else {
                return .duplicate
            }
            try updateSessionTaskTimingEvent(mergedEvent)
            return .updated
        }

        try insertSessionTaskTimingEvent(event)
        return .inserted
    }

    private func sessionTaskTimingEvent(sessionID: String, turnID: String) throws -> CodexSessionTaskTimingEvent? {
        let statement = try prepare(
            """
            SELECT session_id, turn_id, source_path, started_at, completed_at,
                duration_ms, time_to_first_token_ms, model_context_window,
                collaboration_mode_kind, model, project_path, effort, source,
                dimensions_json, recorded_at
            FROM codex_session_task_timing_events
            WHERE session_id = ? AND turn_id = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sessionID, to: 1, in: statement)
        bindText(turnID, to: 2, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sessionTaskTimingEvent(from: statement)
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func sessionTaskTimingEvent(from statement: OpaquePointer) -> CodexSessionTaskTimingEvent? {
        CodexSessionTaskTimingEvent(
            sessionID: optionalColumnText(statement, index: 0),
            turnID: optionalColumnText(statement, index: 1),
            sourcePath: optionalColumnText(statement, index: 2),
            startedAt: optionalColumnDate(statement, index: 3),
            completedAt: optionalColumnDate(statement, index: 4),
            durationMilliseconds: optionalColumnInt(statement, index: 5),
            timeToFirstTokenMilliseconds: optionalColumnInt(statement, index: 6),
            modelContextWindow: optionalColumnInt(statement, index: 7),
            collaborationModeKind: optionalColumnText(statement, index: 8),
            model: optionalColumnText(statement, index: 9),
            projectPath: optionalColumnText(statement, index: 10),
            effort: optionalColumnText(statement, index: 11),
            source: optionalColumnText(statement, index: 12),
            dimensionsJSON: optionalColumnText(statement, index: 13),
            recordedAt: optionalColumnDate(statement, index: 14) ?? Date()
        )
    }

    private func insertSessionTaskTimingEvent(_ event: CodexSessionTaskTimingEvent) throws {
        let statement = try prepare(
            """
            INSERT INTO codex_session_task_timing_events (
                session_id, turn_id, source_path, started_at, completed_at,
                duration_ms, time_to_first_token_ms, model_context_window,
                collaboration_mode_kind, model, project_path, project_name, effort,
                source, dimensions_json, recorded_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        bindSessionTaskTimingEvent(event, to: statement)
        try step(statement)
    }

    private func updateSessionTaskTimingEvent(_ event: CodexSessionTaskTimingEvent) throws {
        let statement = try prepare(
            """
            UPDATE codex_session_task_timing_events
            SET source_path = ?, started_at = ?, completed_at = ?, duration_ms = ?,
                time_to_first_token_ms = ?, model_context_window = ?,
                collaboration_mode_kind = ?, model = ?, project_path = ?, project_name = ?,
                effort = ?, source = ?, dimensions_json = ?, recorded_at = ?
            WHERE session_id = ? AND turn_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        bindOptionalText(event.sourcePath, to: 1, in: statement)
        bindOptionalDate(event.startedAt, to: 2, in: statement)
        bindOptionalDate(event.completedAt, to: 3, in: statement)
        bindOptionalInt(event.durationMilliseconds, to: 4, in: statement)
        bindOptionalInt(event.timeToFirstTokenMilliseconds, to: 5, in: statement)
        bindOptionalInt(event.modelContextWindow, to: 6, in: statement)
        bindOptionalText(event.collaborationModeKind, to: 7, in: statement)
        bindOptionalText(event.model, to: 8, in: statement)
        bindOptionalText(event.projectPath, to: 9, in: statement)
        bindOptionalText(event.projectName, to: 10, in: statement)
        bindOptionalText(event.effort, to: 11, in: statement)
        bindOptionalText(event.source, to: 12, in: statement)
        bindOptionalText(event.dimensionsJSON, to: 13, in: statement)
        bindOptionalDate(event.recordedAt, to: 14, in: statement)
        bindText(event.sessionID, to: 15, in: statement)
        bindText(event.turnID, to: 16, in: statement)

        try step(statement)
    }

    private func bindSessionTaskTimingEvent(_ event: CodexSessionTaskTimingEvent, to statement: OpaquePointer) {
        bindText(event.sessionID, to: 1, in: statement)
        bindText(event.turnID, to: 2, in: statement)
        bindOptionalText(event.sourcePath, to: 3, in: statement)
        bindOptionalDate(event.startedAt, to: 4, in: statement)
        bindOptionalDate(event.completedAt, to: 5, in: statement)
        bindOptionalInt(event.durationMilliseconds, to: 6, in: statement)
        bindOptionalInt(event.timeToFirstTokenMilliseconds, to: 7, in: statement)
        bindOptionalInt(event.modelContextWindow, to: 8, in: statement)
        bindOptionalText(event.collaborationModeKind, to: 9, in: statement)
        bindOptionalText(event.model, to: 10, in: statement)
        bindOptionalText(event.projectPath, to: 11, in: statement)
        bindOptionalText(event.projectName, to: 12, in: statement)
        bindOptionalText(event.effort, to: 13, in: statement)
        bindOptionalText(event.source, to: 14, in: statement)
        bindOptionalText(event.dimensionsJSON, to: 15, in: statement)
        bindOptionalDate(event.recordedAt, to: 16, in: statement)
    }

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

    func codexThreadCatalogCaptureState(
        sourceKey: String = CodexThreadCatalogCaptureState.stateSQLiteSourceKey
    ) throws -> CodexThreadCatalogCaptureState {
        let statement = try prepare(
            """
            SELECT source_key, last_checked_at, last_imported_thread_updated_at, status,
                threads_inserted_count, threads_updated_count,
                spawn_edges_inserted_count, spawn_edges_updated_count,
                dynamic_tools_inserted_count, dynamic_tools_updated_count,
                stale_rows_deleted_count, source_path, last_error_text
            FROM codex_thread_catalog_capture_state
            WHERE source_key = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sourceKey, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let status = CodexThreadCatalogCaptureStatus(rawValue: columnText(statement, index: 3)) ?? .neverChecked
            return CodexThreadCatalogCaptureState(
                sourceKey: columnText(statement, index: 0),
                lastCheckedAt: optionalColumnDate(statement, index: 1),
                lastImportedThreadUpdatedAt: optionalColumnDate(statement, index: 2),
                status: status,
                threadsInsertedCount: Int(sqlite3_column_int64(statement, 4)),
                threadsUpdatedCount: Int(sqlite3_column_int64(statement, 5)),
                spawnEdgesInsertedCount: Int(sqlite3_column_int64(statement, 6)),
                spawnEdgesUpdatedCount: Int(sqlite3_column_int64(statement, 7)),
                dynamicToolsInsertedCount: Int(sqlite3_column_int64(statement, 8)),
                dynamicToolsUpdatedCount: Int(sqlite3_column_int64(statement, 9)),
                staleRowsDeletedCount: Int(sqlite3_column_int64(statement, 10)),
                sourcePath: optionalColumnText(statement, index: 11),
                lastErrorText: optionalColumnText(statement, index: 12)
            )
        case SQLITE_DONE:
            return CodexThreadCatalogCaptureState(sourceKey: sourceKey)
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func recordCodexThreadCatalogCaptureState(_ state: CodexThreadCatalogCaptureState) throws {
        let statement = try prepare(
            """
            INSERT INTO codex_thread_catalog_capture_state (
                source_key, last_checked_at, last_imported_thread_updated_at, status,
                threads_inserted_count, threads_updated_count,
                spawn_edges_inserted_count, spawn_edges_updated_count,
                dynamic_tools_inserted_count, dynamic_tools_updated_count,
                stale_rows_deleted_count, source_path, last_error_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                last_checked_at = excluded.last_checked_at,
                last_imported_thread_updated_at = COALESCE(
                    excluded.last_imported_thread_updated_at,
                    codex_thread_catalog_capture_state.last_imported_thread_updated_at
                ),
                status = excluded.status,
                threads_inserted_count = excluded.threads_inserted_count,
                threads_updated_count = excluded.threads_updated_count,
                spawn_edges_inserted_count = excluded.spawn_edges_inserted_count,
                spawn_edges_updated_count = excluded.spawn_edges_updated_count,
                dynamic_tools_inserted_count = excluded.dynamic_tools_inserted_count,
                dynamic_tools_updated_count = excluded.dynamic_tools_updated_count,
                stale_rows_deleted_count = excluded.stale_rows_deleted_count,
                source_path = excluded.source_path,
                last_error_text = excluded.last_error_text
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(state.sourceKey, to: 1, in: statement)
        bindOptionalDate(state.lastCheckedAt, to: 2, in: statement)
        bindOptionalDate(state.lastImportedThreadUpdatedAt, to: 3, in: statement)
        bindText(state.status.rawValue, to: 4, in: statement)
        sqlite3_bind_int64(statement, 5, Int64(state.threadsInsertedCount))
        sqlite3_bind_int64(statement, 6, Int64(state.threadsUpdatedCount))
        sqlite3_bind_int64(statement, 7, Int64(state.spawnEdgesInsertedCount))
        sqlite3_bind_int64(statement, 8, Int64(state.spawnEdgesUpdatedCount))
        sqlite3_bind_int64(statement, 9, Int64(state.dynamicToolsInsertedCount))
        sqlite3_bind_int64(statement, 10, Int64(state.dynamicToolsUpdatedCount))
        sqlite3_bind_int64(statement, 11, Int64(state.staleRowsDeletedCount))
        bindOptionalText(state.sourcePath, to: 12, in: statement)
        bindOptionalText(state.lastErrorText, to: 13, in: statement)

        try step(statement)
    }

    func importCodexThreadCatalog(_ batch: CodexThreadCatalogImportBatch) throws -> CodexThreadCatalogImportResult {
        var threadsInsertedCount = 0
        var threadsUpdatedCount = 0
        var spawnEdgesInsertedCount = 0
        var spawnEdgesUpdatedCount = 0
        var dynamicToolsInsertedCount = 0
        var dynamicToolsUpdatedCount = 0
        var staleRowsDeletedCount = 0
        let recordedAt = Date()

        try transaction {
            if batch.pruneThreads {
                try resetThreadCatalogTempTable(name: "codex_imported_thread_ids", columns: "thread_id TEXT PRIMARY KEY")
            }
            if batch.pruneSpawnEdges {
                try resetThreadCatalogTempTable(name: "codex_imported_spawn_edges", columns: "child_thread_id TEXT PRIMARY KEY")
            }
            if batch.pruneDynamicTools {
                try resetThreadCatalogTempTable(
                    name: "codex_imported_dynamic_tools",
                    columns: "thread_id TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(thread_id, position)"
                )
            }

            for thread in batch.threads {
                try insertThreadCatalogTempID(thread.threadID, table: "codex_imported_thread_ids", column: "thread_id")
                switch try upsertCodexThreadCatalogThread(thread, recordedAt: recordedAt) {
                case .inserted:
                    threadsInsertedCount += 1
                case .updated:
                    threadsUpdatedCount += 1
                case .duplicate:
                    break
                }
            }

            for edge in batch.spawnEdges {
                try insertThreadCatalogTempID(edge.childThreadID, table: "codex_imported_spawn_edges", column: "child_thread_id")
                switch try upsertCodexThreadSpawnEdge(edge, recordedAt: recordedAt) {
                case .inserted:
                    spawnEdgesInsertedCount += 1
                case .updated:
                    spawnEdgesUpdatedCount += 1
                case .duplicate:
                    break
                }
            }

            for tool in batch.dynamicTools {
                try insertDynamicToolTempID(tool)
                switch try upsertCodexThreadDynamicTool(tool, recordedAt: recordedAt) {
                case .inserted:
                    dynamicToolsInsertedCount += 1
                case .updated:
                    dynamicToolsUpdatedCount += 1
                case .duplicate:
                    break
                }
            }

            if batch.pruneDynamicTools {
                try execute(
                    """
                    DELETE FROM codex_thread_dynamic_tools
                    WHERE NOT EXISTS (
                        SELECT 1 FROM codex_imported_dynamic_tools imported
                        WHERE imported.thread_id = codex_thread_dynamic_tools.thread_id
                            AND imported.position = codex_thread_dynamic_tools.position
                    )
                    """
                )
                staleRowsDeletedCount += Int(sqlite3_changes(database))
            }
            if batch.pruneSpawnEdges {
                try execute(
                    """
                    DELETE FROM codex_thread_spawn_edges
                    WHERE child_thread_id NOT IN (SELECT child_thread_id FROM codex_imported_spawn_edges)
                    """
                )
                staleRowsDeletedCount += Int(sqlite3_changes(database))
            }
            if batch.pruneThreads {
                try execute(
                    """
                    DELETE FROM codex_thread_catalog
                    WHERE thread_id NOT IN (SELECT thread_id FROM codex_imported_thread_ids)
                    """
                )
                staleRowsDeletedCount += Int(sqlite3_changes(database))
            }
        }

        return CodexThreadCatalogImportResult(
            threadsInsertedCount: threadsInsertedCount,
            threadsUpdatedCount: threadsUpdatedCount,
            spawnEdgesInsertedCount: spawnEdgesInsertedCount,
            spawnEdgesUpdatedCount: spawnEdgesUpdatedCount,
            dynamicToolsInsertedCount: dynamicToolsInsertedCount,
            dynamicToolsUpdatedCount: dynamicToolsUpdatedCount,
            staleRowsDeletedCount: staleRowsDeletedCount,
            latestThreadUpdatedAt: batch.threads.compactMap(\.updatedAt).max()
        )
    }

    func codexThreadCatalogThreads() throws -> [CodexThreadCatalogThread] {
        let statement = try prepare(
            """
            SELECT thread_id, rollout_path, created_at, updated_at, source, model_provider,
                project_path, sandbox_policy, approval_mode, tokens_used, has_user_event,
                archived, archived_at, git_sha, git_branch, git_origin_url, cli_version,
                agent_nickname, agent_role, agent_path, memory_mode, model, reasoning_effort,
                thread_source
            FROM codex_thread_catalog
            ORDER BY updated_at, thread_id
            """
        )
        defer { sqlite3_finalize(statement) }

        var threads: [CodexThreadCatalogThread] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let thread = CodexThreadCatalogThread(
                    threadID: optionalColumnText(statement, index: 0),
                    rolloutPath: optionalColumnText(statement, index: 1),
                    createdAt: optionalColumnDate(statement, index: 2),
                    updatedAt: optionalColumnDate(statement, index: 3),
                    source: optionalColumnText(statement, index: 4),
                    modelProvider: optionalColumnText(statement, index: 5),
                    cwd: optionalColumnText(statement, index: 6),
                    sandboxPolicy: optionalColumnText(statement, index: 7),
                    approvalMode: optionalColumnText(statement, index: 8),
                    tokensUsed: sqlite3_column_int64(statement, 9),
                    hasUserEvent: sqlite3_column_int(statement, 10) != 0,
                    archived: sqlite3_column_int(statement, 11) != 0,
                    archivedAt: optionalColumnDate(statement, index: 12),
                    gitSHA: optionalColumnText(statement, index: 13),
                    gitBranch: optionalColumnText(statement, index: 14),
                    gitOriginURL: optionalColumnText(statement, index: 15),
                    cliVersion: optionalColumnText(statement, index: 16),
                    agentNickname: optionalColumnText(statement, index: 17),
                    agentRole: optionalColumnText(statement, index: 18),
                    agentPath: optionalColumnText(statement, index: 19),
                    memoryMode: optionalColumnText(statement, index: 20),
                    model: optionalColumnText(statement, index: 21),
                    reasoningEffort: optionalColumnText(statement, index: 22),
                    threadSource: optionalColumnText(statement, index: 23)
                ) {
                    threads.append(thread)
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
        return threads
    }

    func codexThreadSpawnEdges() throws -> [CodexThreadSpawnEdge] {
        let statement = try prepare(
            """
            SELECT parent_thread_id, child_thread_id, status
            FROM codex_thread_spawn_edges
            ORDER BY parent_thread_id, child_thread_id
            """
        )
        defer { sqlite3_finalize(statement) }

        var edges: [CodexThreadSpawnEdge] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let edge = CodexThreadSpawnEdge(
                    parentThreadID: optionalColumnText(statement, index: 0),
                    childThreadID: optionalColumnText(statement, index: 1),
                    status: optionalColumnText(statement, index: 2)
                ) {
                    edges.append(edge)
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
        return edges
    }

    func codexThreadDynamicTools() throws -> [CodexThreadDynamicTool] {
        let statement = try prepare(
            """
            SELECT thread_id, position, name, namespace, defer_loading
            FROM codex_thread_dynamic_tools
            ORDER BY thread_id, position
            """
        )
        defer { sqlite3_finalize(statement) }

        var tools: [CodexThreadDynamicTool] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let tool = CodexThreadDynamicTool(
                    threadID: optionalColumnText(statement, index: 0),
                    position: sqlite3_column_int64(statement, 1),
                    name: optionalColumnText(statement, index: 2),
                    namespace: optionalColumnText(statement, index: 3),
                    deferLoading: sqlite3_column_int(statement, 4) != 0
                ) {
                    tools.append(tool)
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
        return tools
    }

    private enum ThreadCatalogUpsertResult {
        case inserted
        case updated
        case duplicate
    }

    private func resetThreadCatalogTempTable(name: String, columns: String) throws {
        try execute("DROP TABLE IF EXISTS \(name)")
        try execute("CREATE TEMP TABLE \(name) (\(columns))")
    }

    private func insertThreadCatalogTempID(_ id: String, table: String, column: String) throws {
        let statement = try prepare("INSERT OR IGNORE INTO \(table) (\(column)) VALUES (?)")
        defer { sqlite3_finalize(statement) }

        bindText(id, to: 1, in: statement)
        try step(statement)
    }

    private func insertDynamicToolTempID(_ tool: CodexThreadDynamicTool) throws {
        let statement = try prepare(
            "INSERT OR IGNORE INTO codex_imported_dynamic_tools (thread_id, position) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }

        bindText(tool.threadID, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, tool.position)
        try step(statement)
    }

    private func upsertCodexThreadCatalogThread(
        _ thread: CodexThreadCatalogThread,
        recordedAt: Date
    ) throws -> ThreadCatalogUpsertResult {
        let existed = try codexThreadCatalogThreadExists(thread.threadID)
        let statement = try prepare(
            """
            INSERT INTO codex_thread_catalog (
                thread_id, rollout_path, created_at, updated_at, source, model_provider,
                project_path, project_name, sandbox_policy, approval_mode, tokens_used,
                has_user_event, archived, archived_at, git_sha, git_branch, git_origin_url,
                cli_version, agent_nickname, agent_role, agent_path, memory_mode, model,
                reasoning_effort, thread_source, recorded_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
                rollout_path = excluded.rollout_path,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                source = excluded.source,
                model_provider = excluded.model_provider,
                project_path = excluded.project_path,
                project_name = excluded.project_name,
                sandbox_policy = excluded.sandbox_policy,
                approval_mode = excluded.approval_mode,
                tokens_used = excluded.tokens_used,
                has_user_event = excluded.has_user_event,
                archived = excluded.archived,
                archived_at = excluded.archived_at,
                git_sha = excluded.git_sha,
                git_branch = excluded.git_branch,
                git_origin_url = excluded.git_origin_url,
                cli_version = excluded.cli_version,
                agent_nickname = excluded.agent_nickname,
                agent_role = excluded.agent_role,
                agent_path = excluded.agent_path,
                memory_mode = excluded.memory_mode,
                model = excluded.model,
                reasoning_effort = excluded.reasoning_effort,
                thread_source = excluded.thread_source,
                recorded_at = excluded.recorded_at
            WHERE codex_thread_catalog.rollout_path IS NOT excluded.rollout_path
                OR codex_thread_catalog.created_at IS NOT excluded.created_at
                OR codex_thread_catalog.updated_at IS NOT excluded.updated_at
                OR codex_thread_catalog.source IS NOT excluded.source
                OR codex_thread_catalog.model_provider IS NOT excluded.model_provider
                OR codex_thread_catalog.project_path IS NOT excluded.project_path
                OR codex_thread_catalog.project_name IS NOT excluded.project_name
                OR codex_thread_catalog.sandbox_policy IS NOT excluded.sandbox_policy
                OR codex_thread_catalog.approval_mode IS NOT excluded.approval_mode
                OR codex_thread_catalog.tokens_used IS NOT excluded.tokens_used
                OR codex_thread_catalog.has_user_event IS NOT excluded.has_user_event
                OR codex_thread_catalog.archived IS NOT excluded.archived
                OR codex_thread_catalog.archived_at IS NOT excluded.archived_at
                OR codex_thread_catalog.git_sha IS NOT excluded.git_sha
                OR codex_thread_catalog.git_branch IS NOT excluded.git_branch
                OR codex_thread_catalog.git_origin_url IS NOT excluded.git_origin_url
                OR codex_thread_catalog.cli_version IS NOT excluded.cli_version
                OR codex_thread_catalog.agent_nickname IS NOT excluded.agent_nickname
                OR codex_thread_catalog.agent_role IS NOT excluded.agent_role
                OR codex_thread_catalog.agent_path IS NOT excluded.agent_path
                OR codex_thread_catalog.memory_mode IS NOT excluded.memory_mode
                OR codex_thread_catalog.model IS NOT excluded.model
                OR codex_thread_catalog.reasoning_effort IS NOT excluded.reasoning_effort
                OR codex_thread_catalog.thread_source IS NOT excluded.thread_source
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(thread.threadID, to: 1, in: statement)
        bindOptionalText(thread.rolloutPath, to: 2, in: statement)
        bindOptionalDate(thread.createdAt, to: 3, in: statement)
        bindOptionalDate(thread.updatedAt, to: 4, in: statement)
        bindOptionalText(thread.source, to: 5, in: statement)
        bindOptionalText(thread.modelProvider, to: 6, in: statement)
        bindOptionalText(thread.projectPath, to: 7, in: statement)
        bindOptionalText(thread.projectName, to: 8, in: statement)
        bindOptionalText(thread.sandboxPolicy, to: 9, in: statement)
        bindOptionalText(thread.approvalMode, to: 10, in: statement)
        sqlite3_bind_int64(statement, 11, thread.tokensUsed)
        sqlite3_bind_int64(statement, 12, thread.hasUserEvent ? 1 : 0)
        sqlite3_bind_int64(statement, 13, thread.archived ? 1 : 0)
        bindOptionalDate(thread.archivedAt, to: 14, in: statement)
        bindOptionalText(thread.gitSHA, to: 15, in: statement)
        bindOptionalText(thread.gitBranch, to: 16, in: statement)
        bindOptionalText(thread.gitOriginURL, to: 17, in: statement)
        bindOptionalText(thread.cliVersion, to: 18, in: statement)
        bindOptionalText(thread.agentNickname, to: 19, in: statement)
        bindOptionalText(thread.agentRole, to: 20, in: statement)
        bindOptionalText(thread.agentPath, to: 21, in: statement)
        bindOptionalText(thread.memoryMode, to: 22, in: statement)
        bindOptionalText(thread.model, to: 23, in: statement)
        bindOptionalText(thread.reasoningEffort, to: 24, in: statement)
        bindOptionalText(thread.threadSource, to: 25, in: statement)
        bindOptionalDate(recordedAt, to: 26, in: statement)

        try step(statement)
        guard sqlite3_changes(database) > 0 else {
            return .duplicate
        }
        return existed ? .updated : .inserted
    }

    private func upsertCodexThreadSpawnEdge(
        _ edge: CodexThreadSpawnEdge,
        recordedAt: Date
    ) throws -> ThreadCatalogUpsertResult {
        let existed = try codexThreadSpawnEdgeExists(edge.childThreadID)
        let statement = try prepare(
            """
            INSERT INTO codex_thread_spawn_edges (
                parent_thread_id, child_thread_id, status, recorded_at
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(child_thread_id) DO UPDATE SET
                parent_thread_id = excluded.parent_thread_id,
                status = excluded.status,
                recorded_at = excluded.recorded_at
            WHERE codex_thread_spawn_edges.parent_thread_id IS NOT excluded.parent_thread_id
                OR codex_thread_spawn_edges.status IS NOT excluded.status
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(edge.parentThreadID, to: 1, in: statement)
        bindText(edge.childThreadID, to: 2, in: statement)
        bindOptionalText(edge.status, to: 3, in: statement)
        bindOptionalDate(recordedAt, to: 4, in: statement)

        try step(statement)
        guard sqlite3_changes(database) > 0 else {
            return .duplicate
        }
        return existed ? .updated : .inserted
    }

    private func upsertCodexThreadDynamicTool(
        _ tool: CodexThreadDynamicTool,
        recordedAt: Date
    ) throws -> ThreadCatalogUpsertResult {
        let existed = try codexThreadDynamicToolExists(threadID: tool.threadID, position: tool.position)
        let statement = try prepare(
            """
            INSERT INTO codex_thread_dynamic_tools (
                thread_id, position, name, namespace, defer_loading, recorded_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, position) DO UPDATE SET
                name = excluded.name,
                namespace = excluded.namespace,
                defer_loading = excluded.defer_loading,
                recorded_at = excluded.recorded_at
            WHERE codex_thread_dynamic_tools.name IS NOT excluded.name
                OR codex_thread_dynamic_tools.namespace IS NOT excluded.namespace
                OR codex_thread_dynamic_tools.defer_loading IS NOT excluded.defer_loading
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(tool.threadID, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, tool.position)
        bindText(tool.name, to: 3, in: statement)
        bindOptionalText(tool.namespace, to: 4, in: statement)
        sqlite3_bind_int64(statement, 5, tool.deferLoading ? 1 : 0)
        bindOptionalDate(recordedAt, to: 6, in: statement)

        try step(statement)
        guard sqlite3_changes(database) > 0 else {
            return .duplicate
        }
        return existed ? .updated : .inserted
    }

    private func codexThreadCatalogThreadExists(_ threadID: String) throws -> Bool {
        try rowExists("SELECT 1 FROM codex_thread_catalog WHERE thread_id = ? LIMIT 1", bindings: [threadID])
    }

    private func codexThreadSpawnEdgeExists(_ childThreadID: String) throws -> Bool {
        try rowExists("SELECT 1 FROM codex_thread_spawn_edges WHERE child_thread_id = ? LIMIT 1", bindings: [childThreadID])
    }

    private func codexThreadDynamicToolExists(threadID: String, position: Int64) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM codex_thread_dynamic_tools WHERE thread_id = ? AND position = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }

        bindText(threadID, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, position)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private func rowExists(_ sql: String, bindings: [String]) throws -> Bool {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            bindText(binding, to: Int32(offset + 1), in: statement)
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }
}
