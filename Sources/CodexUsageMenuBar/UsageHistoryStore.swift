import Foundation
import SQLite3

protocol UsageHistoryRecording: Sendable {
    func record(snapshot: CodexUsageSnapshot, at date: Date) async
}

protocol TokenUsageRecording: Sendable {
    @discardableResult
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals?
    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) async -> TokenCategoryTotals?
    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals?
    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64?
}

extension TokenUsageRecording {
    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) async -> TokenCategoryTotals? {
        nil
    }
}

struct NoOpUsageHistoryRecorder: UsageHistoryRecording {
    func record(snapshot: CodexUsageSnapshot, at date: Date) async {}
}

struct NoOpTokenUsageRecorder: TokenUsageRecording {
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        nil
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        nil
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        nil
    }
}

final class UsageHistoryRecorder: UsageHistoryRecording, @unchecked Sendable {
    private let database: UsageHistoryDatabaseWorking
    private let includeDetailedContext: @Sendable () -> Bool

    init(
        database: UsageHistoryDatabaseWorking,
        includeDetailedContext: @escaping @Sendable () -> Bool = { true }
    ) {
        self.database = database
        self.includeDetailedContext = includeDetailedContext
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {
        await database.record(snapshot: snapshot, at: date)
    }
}

extension UsageHistoryRecorder: TokenUsageRecording {
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        let persistedNotification = includeDetailedContext() ? tokenUsage : tokenUsage.lightweightStorageValue
        return await database.record(tokenUsage: persistedNotification, at: date)
    }

    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) async -> TokenCategoryTotals? {
        await database.tokenCategoryTotals(periodStart: periodStart, periodEnd: periodEnd)
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        await database.todayTokenCategoryTotals(at: date, calendar: calendar)
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        await database.todayTotalTokens(at: date, calendar: calendar)
    }
}

extension CodexTokenUsageNotification {
    var lightweightStorageValue: CodexTokenUsageNotification {
        CodexTokenUsageNotification(
            threadID: threadID,
            turnID: turnID,
            model: nil,
            tokenUsage: CodexThreadTokenUsage(
                last: tokenUsage.last,
                total: tokenUsage.total,
                modelContextWindow: nil
            ),
            dimensions: []
        )
    }
}

extension UsageHistoryStore {
    static let liveSessionTokenFallbackRecentDayCount = 2
    static let liveSessionTokenFallbackMaximumFileSize: Int64 = 128 * 1024 * 1024
    static let turnPerformanceCaptureMaximumRowsPerRun = 2_500
    static let turnPerformanceCaptureMaximumBodyCharacters = CodexOtelTurnPerformanceImporter.defaultMaximumBodyCharacters

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

    @discardableResult
    func captureLiveCodexLogTokenHistory(
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        minimumInterval: TimeInterval = 30,
        force: Bool = false,
        includeDetailedContext: Bool = true,
        logsDatabaseURL: URL = CodexLogTokenUsageImporter.defaultLogsDatabaseURL(),
        sessionTokenBackfillImporter: CodexSessionTokenBackfillImporting? = nil
    ) -> CodexLiveTokenCaptureState {
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: logsDatabaseURL)
        let sourceKey = CodexLiveTokenCaptureState.codexLogSourceKey
        let existingState = (try? codexLiveTokenCaptureState(sourceKey: sourceKey))
            ?? CodexLiveTokenCaptureState(sourceKey: sourceKey)

        if !force,
           let lastCheckedAt = existingState.lastCheckedAt,
           date.timeIntervalSince(lastCheckedAt) < minimumInterval
        {
            return existingState
        }

        do {
            let runResult = try importer.importTokenHistory(
                into: self,
                afterLogRowID: existingState.lastLogRowID,
                containing: date,
                calendar: calendar,
                includeDetailedContext: includeDetailedContext
            )
            var importResult = runResult.importResult
            var lastImportedEventAt = runResult.lastImportedEventAt ?? existingState.lastImportedEventAt

            if Self.shouldRunSessionTokenFallback(after: importResult),
               let sessionTokenBackfillImporter
            {
                let sessionSummary = try sessionTokenBackfillImporter.importTokenHistory(
                    into: self,
                    request: Self.liveSessionTokenFallbackRequest(
                        now: date,
                        includeDetailedContext: includeDetailedContext
                    )
                )
                importResult = Self.combinedTokenImportResult(
                    logResult: importResult,
                    sessionSummary: sessionSummary
                )
                if Self.hasMaterialTokenImport(importResult),
                   let latestSampleReceivedAt = try latestTokenSampleReceivedAt(containing: date, calendar: calendar)
                {
                    lastImportedEventAt = latestSampleReceivedAt
                }
            }

            let status = Self.liveTokenCaptureStatus(for: importResult)
            let state = CodexLiveTokenCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                lastImportedEventAt: lastImportedEventAt,
                lastLogRowID: runResult.maxLogRowID,
                status: status,
                result: importResult,
                lastErrorText: nil
            )
            try recordCodexLiveTokenCaptureState(state)
            return state
        } catch {
            let state = CodexLiveTokenCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                lastImportedEventAt: existingState.lastImportedEventAt,
                lastLogRowID: existingState.lastLogRowID,
                status: .failed,
                result: .empty,
                lastErrorText: error.localizedDescription
            )
            try? recordCodexLiveTokenCaptureState(state)
            return state
        }
    }

    private static func liveSessionTokenFallbackRequest(
        now date: Date,
        includeDetailedContext: Bool
    ) -> CodexSessionTokenBackfillRequest {
        .recent(
            now: date,
            days: liveSessionTokenFallbackRecentDayCount,
            forceRescan: false,
            maximumFileSize: liveSessionTokenFallbackMaximumFileSize,
            includeDetailedContext: includeDetailedContext
        )
    }

    private static func shouldRunSessionTokenFallback(after result: TokenUsageImportResult) -> Bool {
        !hasMaterialTokenImport(result)
    }

    private static func hasMaterialTokenImport(_ result: TokenUsageImportResult) -> Bool {
        result.insertedCount > 0
            || result.repairedModelCount > 0
            || result.repairedContextCount > 0
            || result.repairedDimensionCount > 0
    }

    private static func combinedTokenImportResult(
        logResult: TokenUsageImportResult,
        sessionSummary: CodexSessionTokenBackfillSummary
    ) -> TokenUsageImportResult {
        TokenUsageImportResult(
            insertedCount: logResult.insertedCount + sessionSummary.tokenEventsImported,
            duplicateCount: logResult.duplicateCount + sessionSummary.duplicateEventsSkipped,
            repairedModelCount: logResult.repairedModelCount + sessionSummary.modelEventsRepaired,
            repairedContextCount: logResult.repairedContextCount + sessionSummary.contextEventsRepaired,
            repairedDimensionCount: logResult.repairedDimensionCount + sessionSummary.dimensionEventsRepaired
        )
    }

    private func latestTokenSampleReceivedAt(containing date: Date, calendar: Calendar) throws -> Date? {
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            return nil
        }

        let statement = try prepare(
            """
            SELECT MAX(received_at)
            FROM token_usage_samples
            WHERE received_at >= ? AND received_at < ?
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, interval.start.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 2, interval.end.timeIntervalSince1970Int)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
                return nil
            }
            return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
        case SQLITE_DONE:
            return nil
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    private static func liveTokenCaptureStatus(for result: TokenUsageImportResult) -> CodexLiveTokenCaptureStatus {
        if result.insertedCount > 0 {
            return .imported
        }
        if result.repairedModelCount > 0 || result.repairedContextCount > 0 || result.repairedDimensionCount > 0 {
            return .repaired
        }
        if result.duplicateCount > 0 {
            return .duplicateOnly
        }
        return .noNewEvents
    }

    @discardableResult
    func captureCodexOtelTurnPerformance(
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        minimumInterval: TimeInterval = 30,
        force: Bool = false,
        logsDatabaseURL: URL = CodexLogTokenUsageImporter.defaultLogsDatabaseURL(),
        maximumRowsPerRun: Int? = UsageHistoryStore.turnPerformanceCaptureMaximumRowsPerRun,
        maximumBodyCharacters: Int = UsageHistoryStore.turnPerformanceCaptureMaximumBodyCharacters
    ) -> CodexTurnPerformanceCaptureState {
        let importer = CodexOtelTurnPerformanceImporter(
            logsDatabaseURL: logsDatabaseURL,
            maximumRowsPerRun: maximumRowsPerRun,
            maximumBodyCharacters: maximumBodyCharacters
        )
        let sourceKey = CodexTurnPerformanceCaptureState.codexOtelLogSourceKey
        let existingState = (try? codexTurnPerformanceCaptureState(sourceKey: sourceKey))
            ?? CodexTurnPerformanceCaptureState(sourceKey: sourceKey)

        if !force,
           let lastCheckedAt = existingState.lastCheckedAt,
           date.timeIntervalSince(lastCheckedAt) < minimumInterval
        {
            return existingState
        }

        do {
            let runResult = try importer.importTurnPerformanceEvents(
                into: self,
                afterLogRowID: existingState.lastLogRowID,
                containing: date,
                calendar: calendar
            )
            let status = Self.turnPerformanceCaptureStatus(for: runResult.importResult)
            let state = CodexTurnPerformanceCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                lastImportedEventAt: runResult.lastImportedEventAt ?? existingState.lastImportedEventAt,
                lastLogRowID: runResult.maxLogRowID,
                status: status,
                insertedCount: runResult.importResult.insertedCount,
                duplicateCount: runResult.importResult.duplicateCount,
                lastErrorText: nil
            )
            try recordCodexTurnPerformanceCaptureState(state)
            return state
        } catch {
            let state = CodexTurnPerformanceCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                lastImportedEventAt: existingState.lastImportedEventAt,
                lastLogRowID: existingState.lastLogRowID,
                status: .failed,
                lastErrorText: error.localizedDescription
            )
            try? recordCodexTurnPerformanceCaptureState(state)
            return state
        }
    }

    private static func turnPerformanceCaptureStatus(
        for result: CodexTurnPerformanceImportResult
    ) -> CodexTurnPerformanceCaptureStatus {
        if result.insertedCount > 0 {
            return .imported
        }
        if result.duplicateCount > 0 {
            return .duplicateOnly
        }
        return .noNewEvents
    }

    @discardableResult
    func captureCodexSessionTaskTiming(
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        minimumInterval: TimeInterval = 30,
        force: Bool = false,
        importer: CodexSessionTaskTimingImporter = CodexSessionTaskTimingImporter()
    ) -> CodexSessionTaskTimingCaptureState {
        let sourceKey = CodexSessionTaskTimingCaptureState.sessionJSONLSourceKey
        let existingState = (try? codexSessionTaskTimingCaptureState(sourceKey: sourceKey))
            ?? CodexSessionTaskTimingCaptureState(sourceKey: sourceKey)

        if !force,
           let lastCheckedAt = existingState.lastCheckedAt,
           date.timeIntervalSince(lastCheckedAt) < minimumInterval
        {
            return existingState
        }

        do {
            let summary = try importer.importTaskTiming(into: self, now: date)
            let status = Self.sessionTaskTimingCaptureStatus(for: summary)
            let state = CodexSessionTaskTimingCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                lastImportedEventAt: summary.latestEventAt ?? existingState.lastImportedEventAt,
                status: status,
                filesDiscovered: summary.filesDiscovered,
                filesScanned: summary.filesScanned,
                filesSkippedUnchanged: summary.filesSkippedUnchanged + summary.filesSkippedByBounds,
                insertedCount: summary.insertedCount,
                updatedCount: summary.updatedCount,
                duplicateCount: summary.duplicateCount,
                failedLinesSkipped: summary.failedLinesSkipped,
                lastErrorText: nil
            )
            try recordCodexSessionTaskTimingCaptureState(state)
            return state
        } catch {
            let state = CodexSessionTaskTimingCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                lastImportedEventAt: existingState.lastImportedEventAt,
                status: .failed,
                filesDiscovered: existingState.filesDiscovered,
                filesScanned: existingState.filesScanned,
                filesSkippedUnchanged: existingState.filesSkippedUnchanged,
                insertedCount: 0,
                updatedCount: 0,
                duplicateCount: 0,
                failedLinesSkipped: 0,
                lastErrorText: error.localizedDescription
            )
            try? recordCodexSessionTaskTimingCaptureState(state)
            return state
        }
    }

    private static func sessionTaskTimingCaptureStatus(
        for summary: CodexSessionTaskTimingSummary
    ) -> CodexSessionTaskTimingCaptureStatus {
        if summary.insertedCount > 0 {
            return .imported
        }
        if summary.updatedCount > 0 {
            return .updated
        }
        if summary.duplicateCount > 0 {
            return .duplicateOnly
        }
        return .noNewEvents
    }

    @discardableResult
    func captureCodexThreadCatalog(
        at date: Date,
        minimumInterval: TimeInterval = 30,
        force: Bool = false,
        importer: CodexThreadCatalogImporter = CodexThreadCatalogImporter()
    ) -> CodexThreadCatalogCaptureState {
        let sourceKey = CodexThreadCatalogCaptureState.stateSQLiteSourceKey
        let existingState = (try? codexThreadCatalogCaptureState(sourceKey: sourceKey))
            ?? CodexThreadCatalogCaptureState(sourceKey: sourceKey)

        if !force,
           let lastCheckedAt = existingState.lastCheckedAt,
           date.timeIntervalSince(lastCheckedAt) < minimumInterval
        {
            return existingState
        }

        do {
            let result = try importer.importThreadCatalog(into: self)
            let status = Self.threadCatalogCaptureStatus(for: result)
            let state = CodexThreadCatalogCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                lastImportedThreadUpdatedAt: result.latestThreadUpdatedAt ?? existingState.lastImportedThreadUpdatedAt,
                status: status,
                threadsInsertedCount: result.threadsInsertedCount,
                threadsUpdatedCount: result.threadsUpdatedCount,
                spawnEdgesInsertedCount: result.spawnEdgesInsertedCount,
                spawnEdgesUpdatedCount: result.spawnEdgesUpdatedCount,
                dynamicToolsInsertedCount: result.dynamicToolsInsertedCount,
                dynamicToolsUpdatedCount: result.dynamicToolsUpdatedCount,
                staleRowsDeletedCount: result.staleRowsDeletedCount,
                sourcePath: importer.stateDatabaseURL.path,
                lastErrorText: nil
            )
            try recordCodexThreadCatalogCaptureState(state)
            return state
        } catch {
            let state = CodexThreadCatalogCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                lastImportedThreadUpdatedAt: existingState.lastImportedThreadUpdatedAt,
                status: .failed,
                sourcePath: importer.stateDatabaseURL.path,
                lastErrorText: error.localizedDescription
            )
            try? recordCodexThreadCatalogCaptureState(state)
            return state
        }
    }

    private static func threadCatalogCaptureStatus(
        for result: CodexThreadCatalogImportResult
    ) -> CodexThreadCatalogCaptureStatus {
        if result.threadsInsertedCount > 0
            || result.spawnEdgesInsertedCount > 0
            || result.dynamicToolsInsertedCount > 0
        {
            return .imported
        }
        if result.threadsUpdatedCount > 0
            || result.spawnEdgesUpdatedCount > 0
            || result.dynamicToolsUpdatedCount > 0
            || result.staleRowsDeletedCount > 0
        {
            return .updated
        }
        return .noNewEvents
    }

    @discardableResult
    func captureCodexModelCapabilities(
        at date: Date,
        minimumInterval: TimeInterval = 30,
        force: Bool = false,
        importer: CodexModelCapabilitiesImporter = CodexModelCapabilitiesImporter()
    ) -> CodexModelCapabilitiesCaptureState {
        let sourceKey = CodexModelCapabilitiesCaptureState.modelsCacheSourceKey
        let existingState = (try? codexModelCapabilitiesCaptureState(sourceKey: sourceKey))
            ?? CodexModelCapabilitiesCaptureState(sourceKey: sourceKey)

        if !force,
           let lastCheckedAt = existingState.lastCheckedAt,
           date.timeIntervalSince(lastCheckedAt) < minimumInterval
        {
            return existingState
        }

        do {
            let result = try importer.importModelCapabilities(into: self)
            let state = CodexModelCapabilitiesCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                cacheFetchedAt: result.cacheFetchedAt ?? existingState.cacheFetchedAt,
                status: Self.modelCapabilitiesCaptureStatus(for: result),
                modelsInsertedCount: result.modelsInsertedCount,
                modelsUpdatedCount: result.modelsUpdatedCount,
                childRowsInsertedCount: result.childRowsInsertedCount,
                staleRowsDeletedCount: result.staleRowsDeletedCount,
                clientVersion: result.clientVersion ?? existingState.clientVersion,
                sourcePath: importer.modelsCacheURL.path,
                lastErrorText: nil
            )
            try recordCodexModelCapabilitiesCaptureState(state)
            return state
        } catch let error as CodexModelCapabilitiesImporterError {
            let status: CodexModelCapabilitiesCaptureStatus = switch error {
            case .sourceUnavailable:
                .noSource
            case .malformedJSON:
                .malformed
            case .noModels:
                .noModels
            }
            let state = CodexModelCapabilitiesCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                cacheFetchedAt: existingState.cacheFetchedAt,
                status: status,
                clientVersion: existingState.clientVersion,
                sourcePath: importer.modelsCacheURL.path,
                lastErrorText: error.localizedDescription
            )
            try? recordCodexModelCapabilitiesCaptureState(state)
            return state
        } catch {
            let state = CodexModelCapabilitiesCaptureState(
                sourceKey: sourceKey,
                lastCheckedAt: date,
                cacheFetchedAt: existingState.cacheFetchedAt,
                status: .failed,
                clientVersion: existingState.clientVersion,
                sourcePath: importer.modelsCacheURL.path,
                lastErrorText: error.localizedDescription
            )
            try? recordCodexModelCapabilitiesCaptureState(state)
            return state
        }
    }

    private static func modelCapabilitiesCaptureStatus(
        for result: CodexModelCapabilitiesImportResult
    ) -> CodexModelCapabilitiesCaptureStatus {
        if result.modelsInsertedCount > 0 || result.childRowsInsertedCount > 0 {
            return .imported
        }
        if result.modelsUpdatedCount > 0 || result.staleRowsDeletedCount > 0 {
            return .updated
        }
        return .noNewEvents
    }
}

enum UsageHistoryStoreError: LocalizedError {
    case databaseOpenFailed(String)
    case databaseOperationFailed(String)
    case statementPreparationFailed(String)
    case databaseUnavailable
    case invalidBackup
    case invalidProjectDisplayName
    case fileOperationFailed(String)
    case storageBudgetExceeded
    case storageOptimizationNotNeeded
    case storageMaintenanceInProgress
    case insufficientStorage(requiredByteSize: Int64, availableByteSize: Int64)
    case storageMaintenanceRecoveryRequired

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
        case .invalidProjectDisplayName:
            return "Project name cannot contain line breaks or control characters."
        case .fileOperationFailed(let message):
            return "Usage history file operation failed: \(message)"
        case .storageBudgetExceeded:
            return "Detailed analytics collection is paused until storage maintenance returns below its limit."
        case .storageOptimizationNotNeeded:
            return "Storage is already compact enough to skip full optimization."
        case .storageMaintenanceInProgress:
            return "Storage maintenance is safely replacing the local database. This operation can be retried shortly."
        case .insufficientStorage(let requiredByteSize, let availableByteSize):
            return "Optimization needs \(requiredByteSize) bytes of free space; \(availableByteSize) bytes are available. Your data is unchanged."
        case .storageMaintenanceRecoveryRequired:
            return "Storage maintenance could not safely recover its last transaction. Your current database was left unchanged."
        }
    }
}

enum StorageMaintenanceErrorSanitizer {
    static func text(for error: Error) -> String {
        if error is CancellationError {
            return "Storage maintenance was cancelled and can resume safely."
        }
        if let error = error as? UsageHistoryStoreError {
            switch error {
            case .databaseUnavailable,
                 .invalidBackup,
                 .storageBudgetExceeded,
                 .storageOptimizationNotNeeded,
                 .storageMaintenanceInProgress,
                 .insufficientStorage,
                 .storageMaintenanceRecoveryRequired:
                return error.localizedDescription
            case .databaseOpenFailed,
                 .databaseOperationFailed,
                 .statementPreparationFailed:
                return "The local database could not complete this maintenance stage. It can be retried safely."
            case .invalidProjectDisplayName:
                return "Stored project metadata could not be validated. Existing data is unchanged."
            case .fileOperationFailed:
                return "A local file operation could not complete. Existing data is unchanged."
            }
        }
        if let error = error as? HistoricalTokenArchiveError {
            return error.localizedDescription
        }
        return "Storage maintenance could not finish. Existing data is unchanged and the operation can be retried."
    }
}

enum AdvancedIngestionBatchKind: Sendable {
    case tokenNotification
    case tokenCapture
    case turnPerformance
    case sessionTiming
    case threadCatalog
    case modelCapabilities
    case operationalImport

    var conservativeGrowthByteSize: Int64 {
        switch self {
        case .tokenNotification:
            256 * 1_024
        case .tokenCapture:
            2 * 1_024 * 1_024
        case .turnPerformance, .sessionTiming:
            8 * 1_024 * 1_024
        case .threadCatalog:
            4 * 1_024 * 1_024
        case .modelCapabilities:
            1 * 1_024 * 1_024
        case .operationalImport:
            16 * 1_024 * 1_024
        }
    }
}

struct UsageHistoryDatabaseInfo: Equatable {
    let databaseURL: URL
    let totalByteSize: Int64
    let databaseByteSize: Int64
    let walByteSize: Int64
    let sharedMemoryByteSize: Int64
    let archiveByteSize: Int64
    let logicalLiveByteSize: Int64
    let reclaimableByteSize: Int64
    let collectionMode: UsageCollectionMode
    let softTargetByteSize: Int64
    let hardMaximumByteSize: Int64
    let oldestRawBucket: Date?
    let oldestHourlyBucket: Date?
    let oldestDailyBucket: Date?
    let maintenanceState: StorageMaintenanceState

    init(
        databaseURL: URL,
        totalByteSize: Int64,
        databaseByteSize: Int64? = nil,
        walByteSize: Int64 = 0,
        sharedMemoryByteSize: Int64 = 0,
        archiveByteSize: Int64 = 0,
        logicalLiveByteSize: Int64? = nil,
        reclaimableByteSize: Int64 = 0,
        collectionMode: UsageCollectionMode = .lightweight,
        softTargetByteSize: Int64? = nil,
        hardMaximumByteSize: Int64? = nil,
        oldestRawBucket: Date? = nil,
        oldestHourlyBucket: Date? = nil,
        oldestDailyBucket: Date? = nil,
        maintenanceState: StorageMaintenanceState = .idle
    ) {
        let budget = StorageBudgetPolicy.policy(for: collectionMode)
        self.databaseURL = databaseURL
        self.totalByteSize = totalByteSize
        self.databaseByteSize = databaseByteSize ?? totalByteSize
        self.walByteSize = walByteSize
        self.sharedMemoryByteSize = sharedMemoryByteSize
        self.archiveByteSize = archiveByteSize
        self.logicalLiveByteSize = logicalLiveByteSize ?? totalByteSize
        self.reclaimableByteSize = reclaimableByteSize
        self.collectionMode = collectionMode
        self.softTargetByteSize = softTargetByteSize ?? budget.softTargetByteSize
        self.hardMaximumByteSize = hardMaximumByteSize ?? budget.hardMaximumByteSize
        self.oldestRawBucket = oldestRawBucket
        self.oldestHourlyBucket = oldestHourlyBucket
        self.oldestDailyBucket = oldestDailyBucket
        self.maintenanceState = maintenanceState
    }
}

struct StorageBudgetPolicy: Equatable, Sendable {
    static let mebibyte: Int64 = 1_024 * 1_024
    static let physicalReserveByteSize: Int64 = 64 * 1_024

    let softTargetByteSize: Int64
    let hardMaximumByteSize: Int64

    static func policy(for mode: UsageCollectionMode) -> StorageBudgetPolicy {
        switch mode {
        case .lightweight:
            StorageBudgetPolicy(
                softTargetByteSize: 100 * mebibyte,
                hardMaximumByteSize: 250 * mebibyte
            )
        case .detailedAnalytics:
            StorageBudgetPolicy(
                softTargetByteSize: 250 * mebibyte,
                hardMaximumByteSize: 500 * mebibyte
            )
        }
    }

    func projectedPhysicalByteSize(current: Int64, conservativeBatchGrowth: Int64) -> Int64 {
        let (batchTotal, batchOverflow) = max(current, 0).addingReportingOverflow(
            max(conservativeBatchGrowth, 0)
        )
        guard !batchOverflow else { return Int64.max }
        let (projected, reserveOverflow) = batchTotal.addingReportingOverflow(
            Self.physicalReserveByteSize
        )
        return reserveOverflow ? Int64.max : projected
    }

    func allowsAdvancedBatch(current: Int64, conservativeBatchGrowth: Int64) -> Bool {
        projectedPhysicalByteSize(
            current: current,
            conservativeBatchGrowth: conservativeBatchGrowth
        ) <= hardMaximumByteSize
    }

    func isAtMaintenancePressure(_ physicalByteSize: Int64) -> Bool {
        physicalByteSize >= (hardMaximumByteSize * 9 / 10)
    }
}

enum StorageLifecyclePolicy {
    static let rateLimitRawRetention: TimeInterval = 7 * 24 * 60 * 60
    static let detailedRawRetention: TimeInterval = 72 * 60 * 60
    static let hourlyRetention: TimeInterval = 90 * 24 * 60 * 60
    static let dailyRetention: TimeInterval = 365 * 24 * 60 * 60
    static let inactiveTokenBaselineRetention: TimeInterval = 30 * 24 * 60 * 60
    static let maximumHourlyBucketsPerTransaction = 24
    static let maintenanceInterval: TimeInterval = 6 * 60 * 60
    static let launchIdleDelay: TimeInterval = 60
}

enum StorageMaintenanceStage: String, Codable, Equatable, Sendable {
    case idle
    case rawToHourly = "raw_to_hourly"
    case hourlyToDaily = "hourly_to_daily"
    case pruning
    case backfilling
    case checkpointing
    case optimizing
    case validating
    case replacing
    case reopening
    case failed
}

struct StorageMaintenanceState: Codable, Equatable, Sendable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var stage: StorageMaintenanceStage
    var cursor: Date?
    var rowsCompacted: Int64
    var bytesReclaimed: Int64
    var lastErrorText: String?

    static let idle = StorageMaintenanceState(
        lastAttemptAt: nil,
        lastSuccessAt: nil,
        stage: .idle,
        cursor: nil,
        rowsCompacted: 0,
        bytesReclaimed: 0,
        lastErrorText: nil
    )
}

enum StorageOptimizationReason: String, Codable, Sendable {
    case schemaMigration = "schema_migration"
    case backupRestore = "backup_restore"
    case hardBudgetRecovery = "hard_budget_recovery"
    case manual
}

struct StorageOptimizationResult: Equatable, Sendable {
    let performed: Bool
    let beforeByteSize: Int64
    let afterByteSize: Int64

    var reclaimedByteSize: Int64 {
        max(beforeByteSize - afterByteSize, 0)
    }
}

enum StorageOptimizationFailurePoint: String, CaseIterable, Sendable {
    case maintenanceEntry
    case walCheckpoint
    case temporaryCreation
    case rebuild
    case validation
    case atomicReplacement
    case reopen
}

enum TokenUsageDimensionKey: String, CaseIterable, Codable, Sendable {
    case originator
    case sourceKind = "source_kind"
    case threadSource = "thread_source"
    case cliVersion = "cli_version"
    case modelProvider = "model_provider"
    case memoryMode = "memory_mode"
    case approvalPolicy = "approval_policy"
    case sandboxType = "sandbox_type"
    case permissionProfile = "permission_profile"
    case realtimeActive = "realtime_active"
    case truncationPolicy = "truncation_policy"
    case isSubagent = "is_subagent"
    case subagentParentThreadID = "subagent_parent_thread_id"
    case subagentDepth = "subagent_depth"
    case agentRole = "agent_role"
    case agentNickname = "agent_nickname"
    case usageMode = "usage_mode"

    var dashboardDisplayTitle: String {
        switch self {
        case .originator:
            return "Originator"
        case .sourceKind:
            return "Source kind"
        case .threadSource:
            return "Thread source"
        case .cliVersion:
            return "CLI version"
        case .modelProvider:
            return "Model provider"
        case .memoryMode:
            return "Memory mode"
        case .approvalPolicy:
            return "Approval policy"
        case .sandboxType:
            return "Sandbox type"
        case .permissionProfile:
            return "Permission profile"
        case .realtimeActive:
            return "Realtime active"
        case .truncationPolicy:
            return "Truncation policy"
        case .isSubagent:
            return "Subagent"
        case .subagentParentThreadID:
            return "Subagent parent"
        case .subagentDepth:
            return "Subagent depth"
        case .agentRole:
            return "Agent role"
        case .agentNickname:
            return "Agent nickname"
        case .usageMode:
            return "Usage mode"
        }
    }

    func dashboardDisplayValue(_ value: String) -> String {
        switch self {
        case .isSubagent, .realtimeActive:
            if value == "true" {
                return "Yes"
            }

            if value == "false" {
                return "No"
            }

            return value
        case .subagentDepth:
            return "Depth \(value)"
        default:
            return value
        }
    }

    func isMeaningfulDashboardValue(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return false
        }

        switch self {
        case .sourceKind:
            return value != "codex-log"
        default:
            return true
        }
    }
}

struct TokenUsageDimension: Hashable, Equatable, Sendable {
    let key: TokenUsageDimensionKey
    let value: String

    init?(_ key: TokenUsageDimensionKey, _ rawValue: String?) {
        let normalizedValue: String?
        switch key {
        case .usageMode:
            normalizedValue = CodexTokenContextNormalizer.normalizedModeValue(rawValue)
        case .realtimeActive, .isSubagent, .subagentDepth:
            normalizedValue = CodexTokenContextNormalizer.normalizedIdentifier(rawValue)
        default:
            normalizedValue = CodexTokenContextNormalizer.normalizedDimensionValue(rawValue)
        }

        guard let normalizedValue,
              !CodexTokenContextNormalizer.isPrivacySensitiveIdentifier(normalizedValue) else {
            return nil
        }

        self.key = key
        self.value = normalizedValue
    }

    static func boolean(_ key: TokenUsageDimensionKey, _ value: Bool?) -> TokenUsageDimension? {
        guard let value else {
            return nil
        }

        return TokenUsageDimension(key, value ? "true" : "false")
    }

    static func integer(_ key: TokenUsageDimensionKey, _ value: Int?) -> TokenUsageDimension? {
        guard let value else {
            return nil
        }

        return TokenUsageDimension(key, "\(value)")
    }

    static func unique(_ dimensions: [TokenUsageDimension]) -> [TokenUsageDimension] {
        Array(Set(dimensions)).sorted { lhs, rhs in
            if lhs.key.rawValue != rhs.key.rawValue {
                return lhs.key.rawValue < rhs.key.rawValue
            }

            return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
        }
    }
}

struct TokenUsageDimensionCatalogEntry: Equatable, Sendable {
    let key: TokenUsageDimensionKey
    let value: String
    let firstSeenAt: Date
    let lastSeenAt: Date
}

struct TokenProjectCatalogEntry: Identifiable, Equatable, Sendable {
    let projectPath: String
    let generatedName: String
    let displayName: String?
    let firstSeenAt: Date
    let lastSeenAt: Date

    var id: String { projectPath }

    var effectiveDisplayName: String {
        displayName ?? generatedName
    }
}

struct StoredTokenUsageSample: Equatable {
    let threadID: String
    let turnID: String
    let model: String?
    let sessionID: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?
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

struct TokenUsageContext: Equatable, Sendable {
    let sessionID: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?
    let dimensions: [TokenUsageDimension]

    init(
        sessionID: String? = nil,
        projectPath: String? = nil,
        effort: String? = nil,
        source: String? = nil,
        dimensions: [TokenUsageDimension] = []
    ) {
        self.sessionID = CodexTokenContextNormalizer.normalizedMetadataIdentifier(sessionID)
        self.projectPath = CodexTokenContextNormalizer.normalizedProjectPath(projectPath)
        self.projectName = self.projectPath.flatMap(CodexTokenContextNormalizer.projectName)
        self.effort = CodexTokenContextNormalizer.normalizedMetadataIdentifier(effort)
        self.source = CodexTokenContextNormalizer.normalizedMetadataIdentifier(source)
        self.dimensions = TokenUsageDimension.unique(dimensions)
    }

    var hasAnyValue: Bool {
        sessionID != nil
            || projectPath != nil
            || projectName != nil
            || effort != nil
            || source != nil
            || !dimensions.isEmpty
    }
}

enum CodexTokenContextNormalizer {
    private static let trimSet = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    private static let safeIdentifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"
    )

    static func normalizedIdentifier(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: trimSet) ?? ""
        guard !trimmedValue.isEmpty else {
            return nil
        }

        let firstTokenScalars = trimmedValue.unicodeScalars.split { trimSet.contains($0) }.first
        guard let firstTokenScalars else {
            return nil
        }
        guard firstTokenScalars.allSatisfy({ safeIdentifierCharacters.contains($0) }) else {
            return nil
        }

        return String(String.UnicodeScalarView(firstTokenScalars))
    }

    static func normalizedProjectPath(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: trimSet) ?? ""
        guard !trimmedValue.isEmpty, trimmedValue.hasPrefix("/") else {
            return nil
        }
        guard trimmedValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        guard !trimmedValue.contains("{"), !trimmedValue.contains("}") else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmedValue)
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath.hasPrefix("/"), projectName(standardizedPath) != nil else {
            return nil
        }

        return standardizedPath
    }

    static func projectName(_ projectPath: String) -> String? {
        let lastPathComponent = URL(fileURLWithPath: projectPath).lastPathComponent
            .trimmingCharacters(in: trimSet)
        return lastPathComponent.isEmpty ? nil : lastPathComponent
    }

    static func normalizedProjectDisplayName(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: trimSet) ?? ""
        guard !trimmedValue.isEmpty else {
            return nil
        }

        guard trimmedValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }

        return trimmedValue
    }

    static func isInvalidNonBlankProjectDisplayName(_ value: String?) -> Bool {
        let trimmedValue = value?.trimmingCharacters(in: trimSet) ?? ""
        guard !trimmedValue.isEmpty else {
            return false
        }

        return normalizedProjectDisplayName(trimmedValue) == nil
    }

    static func normalizedDimensionValue(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: trimSet) ?? ""
        guard !trimmedValue.isEmpty, trimmedValue.count <= 120 else {
            return nil
        }

        let allowedCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-@ "
        )
        guard trimmedValue.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return trimmedValue
    }

    static func normalizedMetadataDimensionValue(_ value: String?) -> String? {
        guard let value = normalizedDimensionValue(value), !isPrivacySensitiveIdentifier(value) else {
            return nil
        }
        return value
    }

    static func normalizedMetadataIdentifier(_ value: String?) -> String? {
        guard let value = normalizedIdentifier(value), !isPrivacySensitiveIdentifier(value) else {
            return nil
        }
        return value
    }

    static func isPrivacySensitiveIdentifier(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: trimSet).lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        if normalized.contains("@") {
            return true
        }
        let accountPrefixes = [
            "acct_", "account_", "user_", "usr_", "uid_", "org_", "tenant_", "workspace_",
        ]
        return accountPrefixes.contains { prefix in
            normalized.hasPrefix(prefix) && normalized.count > prefix.count + 3
        }
    }

    static func normalizedModeValue(_ value: String?) -> String? {
        var trimmedValue = value?.trimmingCharacters(in: trimSet) ?? ""
        if trimmedValue.hasPrefix("/") {
            trimmedValue.removeFirst()
        }

        return normalizedIdentifier(trimmedValue)
    }
}

final class UsageHistoryStore: @unchecked Sendable {
    enum OpenMode {
        case readWrite
        case readOnly
    }

    static let didChangeNotification = Notification.Name("UsageHistoryStoreDidChange")
    static let maintenanceRequestedNotification = Notification.Name("UsageHistoryStoreMaintenanceRequested")
    static let maintenanceTriggerUserInfoKey = "trigger"
    static let defaultRawRetention: TimeInterval = StorageLifecyclePolicy.detailedRawRetention
    static let defaultBusyTimeoutMilliseconds: Int32 = 5_000
    static let currentSchemaVersion: Int32 = 3
    static let consumptionAlgorithmMetadataKey = "usage_consumption_algorithm_version"
    static let currentConsumptionAlgorithmVersion = "5"
    static let seriesCatalogMetadataKey = "series_catalog_version"
    static let currentSeriesCatalogVersion = "2"
    static let tokenModelCleanupMetadataKey = "token_model_cleanup_version"
    static let currentTokenModelCleanupVersion = "1"
    static let tokenContextCleanupMetadataKey = "token_context_cleanup_version"
    static let currentTokenContextCleanupVersion = "2"
    static let tokenDimensionCleanupMetadataKey = "token_dimension_cleanup_version"
    static let currentTokenDimensionCleanupVersion = "1"
    static let currentSessionTokenContextImportVersion = "3"
    static let currentSessionTaskTimingImportVersion = "2"
    static let resetCohortTolerance: Int64 = 60 * 60
    static let observedTokenComponentsPredicate = """
        observed_input_tokens > 0
        OR observed_cached_input_tokens > 0
        OR observed_output_tokens > 0
        OR observed_reasoning_output_tokens > 0
    """

    let database: OpaquePointer
    let databaseURL: URL?
    let notificationCenter: NotificationCenter
    let calendar: Calendar
    let rawRetentionProvider: () -> TimeInterval
    var transactionSavepointCounter = 0

    convenience init(
        databaseURL: URL,
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetention: TimeInterval = UsageHistoryStore.defaultRawRetention,
        openMode: OpenMode = .readWrite
    ) throws {
        try self.init(
            databaseURL: databaseURL,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetentionProvider: { rawRetention },
            openMode: openMode
        )
    }

    convenience init(
        databaseURL: URL,
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetentionProvider: @escaping () -> TimeInterval,
        openMode: OpenMode = .readWrite
    ) throws {
        try self.init(
            databasePath: databaseURL.path,
            databaseURL: databaseURL,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetentionProvider: rawRetentionProvider,
            openMode: openMode
        )
    }

    private init(
        databasePath: String,
        databaseURL: URL?,
        notificationCenter: NotificationCenter,
        calendar: Calendar,
        rawRetentionProvider: @escaping () -> TimeInterval,
        openMode: OpenMode = .readWrite
    ) throws {
        var openedDatabase: OpaquePointer?
        let flags: Int32
        switch openMode {
        case .readWrite:
            flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }
        guard sqlite3_open_v2(databasePath, &openedDatabase, flags, nil) == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let openedDatabase {
                sqlite3_close(openedDatabase)
            }
            throw UsageHistoryStoreError.databaseOpenFailed(message)
        }
        var initializationSucceeded = false
        defer {
            if !initializationSucceeded {
                sqlite3_close(openedDatabase)
            }
        }

        database = openedDatabase
        self.databaseURL = databaseURL
        self.notificationCenter = notificationCenter
        self.calendar = calendar
        self.rawRetentionProvider = rawRetentionProvider

        guard sqlite3_busy_timeout(openedDatabase, Self.defaultBusyTimeoutMilliseconds) == SQLITE_OK else {
            throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(openedDatabase)))
        }

        switch openMode {
        case .readWrite:
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try migrate()
        case .readOnly:
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA query_only=ON")
            try execute("PRAGMA foreign_keys=ON")
        }
        initializationSucceeded = true
    }

    deinit {
        sqlite3_close(database)
    }

    static func applicationSupportStore(
        rawRetentionProvider: @escaping () -> TimeInterval = {
            StorageLifecyclePolicy.detailedRawRetention
        }
    ) throws -> UsageHistoryStore {
        let directoryURL = try applicationSupportDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let databaseURL = directoryURL.appendingPathComponent("usage-history.sqlite3")
        try recoverStorageMaintenanceIfNeeded(at: databaseURL)
        return try UsageHistoryStore(
            databaseURL: databaseURL,
            rawRetentionProvider: rawRetentionProvider
        )
    }

    static func applicationSupportReadOnlyStore(
        rawRetentionProvider: @escaping () -> TimeInterval = {
            StorageLifecyclePolicy.detailedRawRetention
        }
    ) throws -> UsageHistoryStore {
        let directoryURL = try applicationSupportDirectoryURL()
        return try UsageHistoryStore(
            databaseURL: directoryURL.appendingPathComponent("usage-history.sqlite3"),
            rawRetentionProvider: rawRetentionProvider,
            openMode: .readOnly
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

}
