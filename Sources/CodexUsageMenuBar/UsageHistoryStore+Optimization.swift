import Foundation
import SQLite3

extension UsageHistoryStore {
    typealias StorageOptimizationFailureInjector = @Sendable (StorageOptimizationFailurePoint) throws -> Void

    static func optimizeDatabase(
        at databaseURL: URL,
        reason: StorageOptimizationReason,
        fileManager: FileManager = .default,
        failureInjector: StorageOptimizationFailureInjector = { _ in }
    ) throws -> StorageOptimizationResult {
        let canonicalURL = databaseURL.standardizedFileURL
        try recoverStorageMaintenanceIfNeeded(at: canonicalURL, fileManager: fileManager)

        let identifier = UUID().uuidString.lowercased()
        let candidateURL = canonicalURL
            .deletingLastPathComponent()
            .appendingPathComponent(".usage-history-\(identifier).candidate.sqlite3")
        let rollbackName = ".usage-history-\(identifier).rollback.sqlite3"
        let rollbackURL = canonicalURL.deletingLastPathComponent().appendingPathComponent(rollbackName)

        var beforeInfo: UsageHistoryDatabaseInfo!
        var invariants: [String: Int64]!
        do {
            let store = try UsageHistoryStore(databaseURL: canonicalURL)
            beforeInfo = try store.databaseInfo(collectionMode: .lightweight, fileManager: fileManager)
            invariants = try store.storageOptimizationInvariants()
            let reclaimableEnough = beforeInfo.reclaimableByteSize >= 64 * StorageBudgetPolicy.mebibyte
                && beforeInfo.reclaimableByteSize * 5 >= max(beforeInfo.databaseByteSize, 1)
            let requiresFullRebuild = reason == .schemaMigration
                || reason == .backupRestore
                || reason == .hardBudgetRecovery
            guard reclaimableEnough || requiresFullRebuild else {
                return StorageOptimizationResult(
                    performed: false,
                    beforeByteSize: beforeInfo.totalByteSize,
                    afterByteSize: beforeInfo.totalByteSize
                )
            }

            try store.recordOptimizationJournal(
                operation: reason.rawValue,
                phase: StorageOptimizationFailurePoint.maintenanceEntry.rawValue,
                canonicalURL: canonicalURL,
                candidateURL: candidateURL,
                rollbackURL: rollbackURL,
                errorText: nil
            )
            var maintenance = try store.storageMaintenanceState()
            maintenance.lastAttemptAt = Date()
            maintenance.stage = .checkpointing
            maintenance.lastErrorText = nil
            try store.recordStorageMaintenanceState(maintenance)
            try failureInjector(.maintenanceEntry)

            try store.checkpointWriteAheadLog()
            try failureInjector(.walCheckpoint)

            let requiredByteSize = Int64(
                (Double(max(beforeInfo.logicalLiveByteSize, 1) + beforeInfo.walByteSize) * 1.25).rounded(.up)
            )
            let availableByteSize = try availableCapacity(
                at: canonicalURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
            guard availableByteSize >= requiredByteSize else {
                throw UsageHistoryStoreError.insufficientStorage(
                    requiredByteSize: requiredByteSize,
                    availableByteSize: availableByteSize
                )
            }

            guard !fileManager.fileExists(atPath: candidateURL.path),
                  !fileManager.fileExists(atPath: rollbackURL.path)
            else {
                throw UsageHistoryStoreError.storageMaintenanceRecoveryRequired
            }
            try store.recordOptimizationJournal(
                operation: reason.rawValue,
                phase: StorageOptimizationFailurePoint.temporaryCreation.rawValue,
                canonicalURL: canonicalURL,
                candidateURL: candidateURL,
                rollbackURL: rollbackURL,
                errorText: nil
            )
            try failureInjector(.temporaryCreation)

            try store.execute("PRAGMA auto_vacuum=INCREMENTAL")
            try store.recordOptimizationJournal(
                operation: reason.rawValue,
                phase: StorageOptimizationFailurePoint.rebuild.rawValue,
                canonicalURL: canonicalURL,
                candidateURL: candidateURL,
                rollbackURL: rollbackURL,
                errorText: nil
            )
            try store.checkpointWriteAheadLog()
            try store.vacuum(into: candidateURL)
            try failureInjector(.rebuild)
        } catch {
            if fileManager.fileExists(atPath: candidateURL.path) {
                try? fileManager.removeItem(at: candidateURL)
            }
            try? recordOptimizationFailure(error, at: canonicalURL)
            throw error
        }

        do {
            let candidateStore = try UsageHistoryStore(databaseURL: candidateURL)
            try candidateStore.validateStorageOptimizationCandidate(expectedInvariants: invariants)
            try candidateStore.recordOptimizationJournal(
                operation: reason.rawValue,
                phase: StorageOptimizationFailurePoint.validation.rawValue,
                canonicalURL: canonicalURL,
                candidateURL: candidateURL,
                rollbackURL: rollbackURL,
                errorText: nil
            )
            try candidateStore.checkpointWriteAheadLog()
            try failureInjector(.validation)
        } catch {
            try? fileManager.removeItem(at: candidateURL)
            try? recordOptimizationFailure(error, at: canonicalURL)
            throw error
        }

        do {
            let candidateStore = try UsageHistoryStore(databaseURL: candidateURL)
            try candidateStore.recordOptimizationJournal(
                operation: reason.rawValue,
                phase: StorageOptimizationFailurePoint.atomicReplacement.rawValue,
                canonicalURL: canonicalURL,
                candidateURL: candidateURL,
                rollbackURL: rollbackURL,
                errorText: nil
            )
            try candidateStore.checkpointWriteAheadLog()
            try failureInjector(.atomicReplacement)
        }

        do {
            _ = try fileManager.replaceItemAt(
                canonicalURL,
                withItemAt: candidateURL,
                backupItemName: rollbackName,
                options: []
            )

            do {
                let reopenedStore = try UsageHistoryStore(databaseURL: canonicalURL)
                try reopenedStore.validateStorageOptimizationCandidate(expectedInvariants: invariants)
                var maintenance = try reopenedStore.storageMaintenanceState()
                maintenance.lastSuccessAt = Date()
                maintenance.stage = .idle
                maintenance.cursor = nil
                maintenance.bytesReclaimed += max(
                    beforeInfo.totalByteSize
                        - Self.totalByteSize(for: canonicalURL, fileManager: fileManager),
                    0
                )
                maintenance.lastErrorText = nil
                try reopenedStore.recordStorageMaintenanceState(maintenance)
                try reopenedStore.clearOptimizationJournal()
                try reopenedStore.checkpointWriteAheadLog()
                try failureInjector(.reopen)
            } catch {
                try restoreRollback(
                    canonicalURL: canonicalURL,
                    rollbackURL: rollbackURL,
                    fileManager: fileManager
                )
                throw error
            }

            if fileManager.fileExists(atPath: rollbackURL.path) {
                try fileManager.removeItem(at: rollbackURL)
            }
            let afterByteSize = Self.totalByteSize(for: canonicalURL, fileManager: fileManager)
            return StorageOptimizationResult(
                performed: true,
                beforeByteSize: beforeInfo.totalByteSize,
                afterByteSize: afterByteSize
            )
        } catch {
            if fileManager.fileExists(atPath: candidateURL.path) {
                try? fileManager.removeItem(at: candidateURL)
            }
            try? recordOptimizationFailure(error, at: canonicalURL)
            throw error
        }
    }

    static func restoreOperationalBackup(
        from sourceURL: URL,
        to databaseURL: URL,
        mode: UsageCollectionMode,
        referenceDate: Date = Date(),
        fileManager: FileManager = .default,
        failureInjector: StorageOptimizationFailureInjector = { _ in }
    ) throws {
        let sourceURL = sourceURL.standardizedFileURL
        let canonicalURL = databaseURL.standardizedFileURL
        guard sourceURL != canonicalURL,
              fileManager.fileExists(atPath: canonicalURL.path)
        else {
            throw UsageHistoryStoreError.invalidBackup
        }

        try validateBackup(at: sourceURL)
        let sourceIdentity = try sqliteFileIdentity(at: sourceURL, fileManager: fileManager)
        let identifier = UUID().uuidString.lowercased()
        let parentURL = canonicalURL.deletingLastPathComponent()
        let candidateURL = parentURL.appendingPathComponent(
            ".usage-history-restore-\(identifier).candidate.sqlite3"
        )
        let rollbackName = ".usage-history-restore-\(identifier).rollback.sqlite3"
        let rollbackURL = parentURL.appendingPathComponent(rollbackName)
        let sourceByteSize = max(sourceIdentity.byteSize, 1)
        let requiredCapacity = sourceByteSize > Int64.max / 3
            ? Int64.max
            : sourceByteSize * 3
        let availableByteSize = try availableCapacity(at: parentURL, fileManager: fileManager)
        guard availableByteSize >= requiredCapacity else {
            throw UsageHistoryStoreError.insufficientStorage(
                requiredByteSize: requiredCapacity,
                availableByteSize: availableByteSize
            )
        }
        guard !fileManager.fileExists(atPath: candidateURL.path),
              !fileManager.fileExists(atPath: rollbackURL.path)
        else {
            throw UsageHistoryStoreError.storageMaintenanceRecoveryRequired
        }

        defer {
            if fileManager.fileExists(atPath: candidateURL.path) {
                try? fileManager.removeItem(at: candidateURL)
            }
        }

        do {
            let canonicalStore = try UsageHistoryStore(databaseURL: canonicalURL)
            try canonicalStore.checkpointWriteAheadLog()
            try canonicalStore.recordOptimizationJournal(
                operation: StorageOptimizationReason.backupRestore.rawValue,
                phase: StorageOptimizationFailurePoint.maintenanceEntry.rawValue,
                canonicalURL: canonicalURL,
                candidateURL: candidateURL,
                rollbackURL: rollbackURL,
                errorText: nil
            )
            var maintenance = try canonicalStore.storageMaintenanceState()
            maintenance.lastAttemptAt = referenceDate
            maintenance.stage = .checkpointing
            maintenance.lastErrorText = nil
            try canonicalStore.recordStorageMaintenanceState(maintenance)
            try canonicalStore.checkpointWriteAheadLog()
            try failureInjector(.maintenanceEntry)
            try failureInjector(.walCheckpoint)
        }

        do {
            try sqliteBackupCopy(from: sourceURL, to: candidateURL, fileManager: fileManager)
            guard try sqliteFileIdentity(at: sourceURL, fileManager: fileManager) == sourceIdentity else {
                throw HistoricalTokenArchiveError.pathChanged
            }
            try failureInjector(.temporaryCreation)

            do {
                let candidateStore = try UsageHistoryStore(databaseURL: candidateURL)
                guard try candidateStore.metadataValue(for: "archive_format") == nil else {
                    throw UsageHistoryStoreError.invalidBackup
                }
                try candidateStore.sanitizeForOfflineRestore()
                if try candidateStore.beginTelemetryRetention(referenceDate: referenceDate, force: true) {
                    while try candidateStore.enforceNextTelemetryRetentionBatch(referenceDate: referenceDate) {}
                    while try candidateStore.backfillNextTokenDimensionSetChunk(sampleLimit: 1_000) {}
                    _ = try candidateStore.finalizeTokenDimensionSetMigrationIfReady()
                    try candidateStore.finishTelemetryRetention(referenceDate: referenceDate)
                }
                let budgetedInfo = try candidateStore.enforceStorageBudget(mode: mode)
                guard budgetedInfo.logicalLiveByteSize <= budgetedInfo.hardMaximumByteSize else {
                    throw UsageHistoryStoreError.storageBudgetExceeded
                }
                try candidateStore.checkpointWriteAheadLog()
            }

            _ = try optimizeDatabase(
                at: candidateURL,
                reason: .backupRestore,
                fileManager: fileManager,
                failureInjector: failureInjector
            )
            try validateOperationalDatabase(at: candidateURL, mode: mode, fileManager: fileManager)
            try failureInjector(.validation)

            do {
                let canonicalStore = try UsageHistoryStore(databaseURL: canonicalURL)
                try canonicalStore.recordOptimizationJournal(
                    operation: StorageOptimizationReason.backupRestore.rawValue,
                    phase: StorageOptimizationFailurePoint.atomicReplacement.rawValue,
                    canonicalURL: canonicalURL,
                    candidateURL: candidateURL,
                    rollbackURL: rollbackURL,
                    errorText: nil
                )
                try canonicalStore.checkpointWriteAheadLog()
            }
            try failureInjector(.atomicReplacement)

            for sidecarURL in databaseFileURLs(for: canonicalURL).dropFirst()
                where fileManager.fileExists(atPath: sidecarURL.path)
            {
                try fileManager.removeItem(at: sidecarURL)
            }
            _ = try fileManager.replaceItemAt(
                canonicalURL,
                withItemAt: candidateURL,
                backupItemName: rollbackName,
                options: []
            )

            do {
                try validateOperationalDatabase(at: canonicalURL, mode: mode, fileManager: fileManager)
                let reopenedStore = try UsageHistoryStore(databaseURL: canonicalURL)
                var maintenance = try reopenedStore.storageMaintenanceState()
                maintenance.lastSuccessAt = referenceDate
                maintenance.stage = .idle
                maintenance.cursor = nil
                maintenance.lastErrorText = nil
                try reopenedStore.recordStorageMaintenanceState(maintenance)
                try reopenedStore.clearOptimizationJournal()
                try reopenedStore.checkpointWriteAheadLog()
                try failureInjector(.reopen)
            } catch {
                try restoreRollback(
                    canonicalURL: canonicalURL,
                    rollbackURL: rollbackURL,
                    fileManager: fileManager
                )
                throw error
            }

            if fileManager.fileExists(atPath: rollbackURL.path) {
                try fileManager.removeItem(at: rollbackURL)
            }
        } catch {
            if fileManager.fileExists(atPath: rollbackURL.path),
               !(try isValidSQLiteDatabase(at: canonicalURL))
            {
                try? restoreRollback(
                    canonicalURL: canonicalURL,
                    rollbackURL: rollbackURL,
                    fileManager: fileManager
                )
            }
            try? recordOptimizationFailure(error, at: canonicalURL)
            throw error
        }
    }

    static func recoverStorageMaintenanceIfNeeded(
        at databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let canonicalURL = databaseURL.standardizedFileURL
        guard fileManager.fileExists(atPath: canonicalURL.path),
              let journal = try readOptimizationJournal(at: canonicalURL)
        else {
            return
        }
        let parent = canonicalURL.deletingLastPathComponent().standardizedFileURL
        let candidateURL = URL(fileURLWithPath: journal.candidatePath).standardizedFileURL
        let rollbackURL = URL(fileURLWithPath: journal.rollbackPath).standardizedFileURL
        guard candidateURL.deletingLastPathComponent() == parent,
              rollbackURL.deletingLastPathComponent() == parent,
              journal.canonicalPath == canonicalURL.path
        else {
            throw UsageHistoryStoreError.storageMaintenanceRecoveryRequired
        }

        if try isValidSQLiteDatabase(at: canonicalURL) {
            if fileManager.fileExists(atPath: candidateURL.path) {
                try fileManager.removeItem(at: candidateURL)
            }
            if fileManager.fileExists(atPath: rollbackURL.path) {
                try fileManager.removeItem(at: rollbackURL)
            }
            try clearOptimizationJournal(at: canonicalURL)
            return
        }

        guard fileManager.fileExists(atPath: rollbackURL.path),
              try isValidSQLiteDatabase(at: rollbackURL)
        else {
            throw UsageHistoryStoreError.storageMaintenanceRecoveryRequired
        }
        try restoreRollback(
            canonicalURL: canonicalURL,
            rollbackURL: rollbackURL,
            fileManager: fileManager
        )
        try clearOptimizationJournal(at: canonicalURL)
    }

    private struct OptimizationJournal {
        let canonicalPath: String
        let candidatePath: String
        let rollbackPath: String
    }

    private struct SQLiteFileIdentity: Equatable {
        let fileIdentifier: UInt64
        let byteSize: Int64
        let modificationDate: Date?
    }

    private static func sqliteFileIdentity(
        at url: URL,
        fileManager: FileManager
    ) throws -> SQLiteFileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let identifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let byteSize = (attributes[.size] as? NSNumber)?.int64Value
        else {
            throw UsageHistoryStoreError.invalidBackup
        }
        return SQLiteFileIdentity(
            fileIdentifier: identifier,
            byteSize: byteSize,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private func recordOptimizationJournal(
        operation: String,
        phase: String,
        canonicalURL: URL,
        candidateURL: URL,
        rollbackURL: URL,
        errorText: String?
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO storage_maintenance_journal (
                journal_id, operation, phase, canonical_path, candidate_path,
                rollback_path, updated_at, error_text
            ) VALUES (1, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(journal_id) DO UPDATE SET
                operation = excluded.operation,
                phase = excluded.phase,
                canonical_path = excluded.canonical_path,
                candidate_path = excluded.candidate_path,
                rollback_path = excluded.rollback_path,
                updated_at = excluded.updated_at,
                error_text = excluded.error_text
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(operation, to: 1, in: statement)
        bindText(phase, to: 2, in: statement)
        bindText(canonicalURL.path, to: 3, in: statement)
        bindText(candidateURL.path, to: 4, in: statement)
        bindText(rollbackURL.path, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Date().timeIntervalSince1970Int)
        bindOptionalText(errorText.map { String($0.prefix(512)) }, to: 7, in: statement)
        try step(statement)
    }

    private func clearOptimizationJournal() throws {
        try execute("DELETE FROM storage_maintenance_journal WHERE journal_id = 1")
    }

    private func vacuum(into destinationURL: URL) throws {
        let statement = try prepare("VACUUM INTO ?")
        defer { sqlite3_finalize(statement) }
        bindText(destinationURL.path, to: 1, in: statement)
        try step(statement)
    }

    private func storageOptimizationInvariants() throws -> [String: Int64] {
        [
            "usage_count": try optimizationScalar("SELECT COUNT(*) FROM usage_samples"),
            "usage_rollup_count": try optimizationScalar("SELECT COUNT(*) FROM usage_rollups"),
            "token_count": try optimizationScalar("SELECT COUNT(*) FROM token_usage_samples"),
            "token_total": try optimizationScalar("SELECT IFNULL(SUM(observed_total_tokens), 0) FROM token_usage_samples"),
            "token_hourly_total": try optimizationScalar("SELECT IFNULL(SUM(observed_total_tokens), 0) FROM token_usage_hourly_rollups"),
            "token_daily_total": try optimizationScalar("SELECT IFNULL(SUM(observed_total_tokens), 0) FROM token_usage_daily_rollups"),
            "performance_count": try optimizationScalar("SELECT COUNT(*) FROM codex_turn_performance_events"),
            "session_count": try optimizationScalar("SELECT COUNT(*) FROM codex_session_task_timing_events"),
        ]
    }

    private func validateStorageOptimizationCandidate(expectedInvariants: [String: Int64]) throws {
        guard try optimizationScalar("PRAGMA user_version") == Int64(Self.currentSchemaVersion),
              try optimizationText("PRAGMA quick_check") == "ok",
              try optimizationScalar("SELECT COUNT(*) FROM pragma_foreign_key_check") == 0
        else {
            throw UsageHistoryStoreError.invalidBackup
        }
        for table in [
            "usage_history_metadata", "usage_samples", "token_usage_samples",
            "token_dimension_values", "token_dimension_sets", "token_dimension_set_members",
        ] where try !tableExists(table: table) {
            throw UsageHistoryStoreError.invalidBackup
        }
        guard try storageOptimizationInvariants() == expectedInvariants else {
            throw UsageHistoryStoreError.databaseOperationFailed(
                "Optimization validation found an aggregate mismatch."
            )
        }
    }

    private static func validateOperationalDatabase(
        at databaseURL: URL,
        mode: UsageCollectionMode,
        fileManager: FileManager
    ) throws {
        let store = try UsageHistoryStore(databaseURL: databaseURL, openMode: .readOnly)
        guard try store.metadataValue(for: "archive_format") == nil,
              try store.optimizationScalar("PRAGMA user_version") == Int64(Self.currentSchemaVersion),
              try store.optimizationText("PRAGMA quick_check") == "ok",
              try store.optimizationScalar("SELECT COUNT(*) FROM pragma_foreign_key_check") == 0
        else {
            throw UsageHistoryStoreError.invalidBackup
        }
        for table in [
            "usage_history_metadata", "usage_samples", "usage_rollups",
            "token_usage_samples", "token_dimension_values", "token_dimension_sets",
            "token_dimension_set_members", "storage_maintenance_journal",
        ] where try !store.tableExists(table: table) {
            throw UsageHistoryStoreError.invalidBackup
        }
        let info = try store.databaseInfo(collectionMode: mode, fileManager: fileManager)
        guard info.totalByteSize <= info.hardMaximumByteSize else {
            throw UsageHistoryStoreError.storageBudgetExceeded
        }
    }

    private func optimizationScalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func optimizationText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
        return columnText(statement, index: 0)
    }

    private static func availableCapacity(at directoryURL: URL, fileManager: FileManager) throws -> Int64 {
        let values = try directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return max(capacity, 0)
        }
        let attributes = try fileManager.attributesOfFileSystem(forPath: directoryURL.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private static func recordOptimizationFailure(_ error: Error, at databaseURL: URL) throws {
        guard let journal = try readOptimizationJournal(at: databaseURL) else {
            return
        }
        let store = try UsageHistoryStore(databaseURL: databaseURL)
        try store.recordOptimizationJournal(
            operation: "recovery",
            phase: StorageMaintenanceStage.failed.rawValue,
            canonicalURL: URL(fileURLWithPath: journal.canonicalPath),
            candidateURL: URL(fileURLWithPath: journal.candidatePath),
            rollbackURL: URL(fileURLWithPath: journal.rollbackPath),
            errorText: StorageMaintenanceErrorSanitizer.text(for: error)
        )
    }

    private static func readOptimizationJournal(at databaseURL: URL) throws -> OptimizationJournal? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT canonical_path, candidate_path, rollback_path FROM storage_maintenance_journal WHERE journal_id = 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return OptimizationJournal(
            canonicalPath: String(cString: sqlite3_column_text(statement, 0)),
            candidatePath: String(cString: sqlite3_column_text(statement, 1)),
            rollbackPath: String(cString: sqlite3_column_text(statement, 2))
        )
    }

    private static func clearOptimizationJournal(at databaseURL: URL) throws {
        let store = try UsageHistoryStore(databaseURL: databaseURL)
        try store.clearOptimizationJournal()
        try store.checkpointWriteAheadLog()
    }

    private static func isValidSQLiteDatabase(at databaseURL: URL) throws -> Bool {
        do {
            let store = try UsageHistoryStore(databaseURL: databaseURL, openMode: .readOnly)
            return try store.optimizationText("PRAGMA quick_check") == "ok"
                && store.optimizationScalar("SELECT COUNT(*) FROM pragma_foreign_key_check") == 0
        } catch {
            return false
        }
    }

    private static func restoreRollback(
        canonicalURL: URL,
        rollbackURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: rollbackURL.path) else {
            throw UsageHistoryStoreError.storageMaintenanceRecoveryRequired
        }
        if fileManager.fileExists(atPath: canonicalURL.path) {
            _ = try fileManager.replaceItemAt(
                canonicalURL,
                withItemAt: rollbackURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: rollbackURL, to: canonicalURL)
        }
    }
}
