import Foundation
import SQLite3

extension UsageHistoryStore {
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
