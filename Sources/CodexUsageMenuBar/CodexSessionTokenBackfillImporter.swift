import Foundation
import SQLite3

struct ImportedCodexTokenUsageSample: Equatable {
    let notification: CodexTokenUsageNotification
    let receivedAt: Date
    let context: TokenUsageContext?

    init(
        notification: CodexTokenUsageNotification,
        receivedAt: Date,
        context: TokenUsageContext? = nil
    ) {
        self.notification = notification
        self.receivedAt = receivedAt
        self.context = context?.hasAnyValue == true ? context : nil
    }
}

struct TokenUsageImportResult: Equatable, Sendable {
    let insertedCount: Int
    let duplicateCount: Int
    let repairedModelCount: Int
    let repairedContextCount: Int
    let repairedDimensionCount: Int

    init(
        insertedCount: Int,
        duplicateCount: Int,
        repairedModelCount: Int = 0,
        repairedContextCount: Int = 0,
        repairedDimensionCount: Int = 0
    ) {
        self.insertedCount = insertedCount
        self.duplicateCount = duplicateCount
        self.repairedModelCount = repairedModelCount
        self.repairedContextCount = repairedContextCount
        self.repairedDimensionCount = repairedDimensionCount
    }

    static let empty = TokenUsageImportResult(insertedCount: 0, duplicateCount: 0)

    var changedCount: Int {
        insertedCount + repairedModelCount + repairedContextCount + repairedDimensionCount
    }
}

enum CodexLiveTokenCaptureStatus: String, Equatable, Sendable {
    case neverChecked = "never_checked"
    case imported
    case noNewEvents = "no_new_events"
    case duplicateOnly = "duplicate_only"
    case repaired
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            "Not checked yet"
        case .imported:
            "Imported new tokens"
        case .noNewEvents:
            "Checked, no new token events"
        case .duplicateOnly:
            "Checked, duplicates only"
        case .repaired:
            "Checked, repaired context"
        case .failed:
            "Capture failed"
        }
    }

    var isSuccessfulCheck: Bool {
        switch self {
        case .imported, .noNewEvents, .duplicateOnly, .repaired:
            true
        case .neverChecked, .failed:
            false
        }
    }
}

struct CodexLiveTokenCaptureState: Equatable, Sendable {
    static let codexLogSourceKey = "codex-log"

    let sourceKey: String
    let lastCheckedAt: Date?
    let lastImportedEventAt: Date?
    let lastLogRowID: Int64
    let status: CodexLiveTokenCaptureStatus
    let result: TokenUsageImportResult
    let lastErrorText: String?

    init(
        sourceKey: String = Self.codexLogSourceKey,
        lastCheckedAt: Date? = nil,
        lastImportedEventAt: Date? = nil,
        lastLogRowID: Int64 = 0,
        status: CodexLiveTokenCaptureStatus = .neverChecked,
        result: TokenUsageImportResult = .empty,
        lastErrorText: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.lastCheckedAt = lastCheckedAt
        self.lastImportedEventAt = lastImportedEventAt
        self.lastLogRowID = max(lastLogRowID, 0)
        self.status = status
        self.result = result
        self.lastErrorText = lastErrorText
    }

    var hasSuccessfulCheck: Bool {
        status.isSuccessfulCheck && lastCheckedAt != nil && lastErrorText == nil
    }

    func hasSuccessfulCheck(containing date: Date, calendar: Calendar) -> Bool {
        guard let lastCheckedAt, hasSuccessfulCheck else {
            return false
        }

        return calendar.isDate(lastCheckedAt, inSameDayAs: date)
    }
}

struct CodexLiveTokenCaptureRunResult: Equatable, Sendable {
    let importResult: TokenUsageImportResult
    let maxLogRowID: Int64
    let lastImportedEventAt: Date?
}

enum CodexTurnPerformanceCaptureStatus: String, Equatable, Sendable {
    case neverChecked = "never_checked"
    case imported
    case noNewEvents = "no_new_events"
    case duplicateOnly = "duplicate_only"
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            "Not checked yet"
        case .imported:
            "Imported new events"
        case .noNewEvents:
            "Checked, no new events"
        case .duplicateOnly:
            "Checked, duplicates only"
        case .failed:
            "Capture failed"
        }
    }
}

struct CodexTurnPerformanceCaptureState: Equatable, Sendable {
    static let codexOtelLogSourceKey = "codex-otel-logs"

    let sourceKey: String
    let lastCheckedAt: Date?
    let lastImportedEventAt: Date?
    let lastLogRowID: Int64
    let status: CodexTurnPerformanceCaptureStatus
    let insertedCount: Int
    let duplicateCount: Int
    let lastErrorText: String?

    init(
        sourceKey: String = Self.codexOtelLogSourceKey,
        lastCheckedAt: Date? = nil,
        lastImportedEventAt: Date? = nil,
        lastLogRowID: Int64 = 0,
        status: CodexTurnPerformanceCaptureStatus = .neverChecked,
        insertedCount: Int = 0,
        duplicateCount: Int = 0,
        lastErrorText: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.lastCheckedAt = lastCheckedAt
        self.lastImportedEventAt = lastImportedEventAt
        self.lastLogRowID = max(lastLogRowID, 0)
        self.status = status
        self.insertedCount = insertedCount
        self.duplicateCount = duplicateCount
        self.lastErrorText = lastErrorText
    }
}

struct CodexTurnPerformanceImportResult: Equatable, Sendable {
    let insertedCount: Int
    let duplicateCount: Int

    static let empty = CodexTurnPerformanceImportResult(insertedCount: 0, duplicateCount: 0)
}

struct CodexTurnPerformanceCaptureRunResult: Equatable, Sendable {
    let importResult: CodexTurnPerformanceImportResult
    let maxLogRowID: Int64
    let lastImportedEventAt: Date?
}

enum CodexSessionTaskTimingCaptureStatus: String, Equatable, Sendable {
    case neverChecked = "never_checked"
    case imported
    case updated
    case noNewEvents = "no_new_events"
    case duplicateOnly = "duplicate_only"
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            "Not checked yet"
        case .imported:
            "Imported new timing"
        case .updated:
            "Checked, updated timing"
        case .noNewEvents:
            "Checked, no new timing"
        case .duplicateOnly:
            "Checked, duplicates only"
        case .failed:
            "Capture failed"
        }
    }
}

struct CodexSessionTaskTimingCaptureState: Equatable, Sendable {
    static let sessionJSONLSourceKey = "codex-session-task-timing"

    let sourceKey: String
    let lastCheckedAt: Date?
    let lastImportedEventAt: Date?
    let status: CodexSessionTaskTimingCaptureStatus
    let filesDiscovered: Int
    let filesScanned: Int
    let filesSkippedUnchanged: Int
    let insertedCount: Int
    let updatedCount: Int
    let duplicateCount: Int
    let failedLinesSkipped: Int
    let lastErrorText: String?

    init(
        sourceKey: String = Self.sessionJSONLSourceKey,
        lastCheckedAt: Date? = nil,
        lastImportedEventAt: Date? = nil,
        status: CodexSessionTaskTimingCaptureStatus = .neverChecked,
        filesDiscovered: Int = 0,
        filesScanned: Int = 0,
        filesSkippedUnchanged: Int = 0,
        insertedCount: Int = 0,
        updatedCount: Int = 0,
        duplicateCount: Int = 0,
        failedLinesSkipped: Int = 0,
        lastErrorText: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.lastCheckedAt = lastCheckedAt
        self.lastImportedEventAt = lastImportedEventAt
        self.status = status
        self.filesDiscovered = max(filesDiscovered, 0)
        self.filesScanned = max(filesScanned, 0)
        self.filesSkippedUnchanged = max(filesSkippedUnchanged, 0)
        self.insertedCount = max(insertedCount, 0)
        self.updatedCount = max(updatedCount, 0)
        self.duplicateCount = max(duplicateCount, 0)
        self.failedLinesSkipped = max(failedLinesSkipped, 0)
        self.lastErrorText = lastErrorText
    }
}

enum CodexSessionTaskTimingImportFileStatus: String, Sendable {
    case imported
    case failed
}

struct CodexSessionTaskTimingImportFileRecord: Equatable, Sendable {
    let metadata: CodexSessionTokenImportFileMetadata
    let importedAt: Int64
    let status: CodexSessionTaskTimingImportFileStatus
    let timingVersion: String?
}

struct CodexSessionTaskTimingImportResult: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let duplicateCount: Int

    static let empty = CodexSessionTaskTimingImportResult(insertedCount: 0, updatedCount: 0, duplicateCount: 0)
}

struct CodexSessionTaskTimingSummary: Equatable, Sendable {
    let filesDiscovered: Int
    let filesScanned: Int
    let filesSkippedByBounds: Int
    let filesSkippedUnchanged: Int
    let insertedCount: Int
    let updatedCount: Int
    let duplicateCount: Int
    let failedLinesSkipped: Int
    let latestEventAt: Date?
}

struct CodexSessionTaskTimingEvent: Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let sourcePath: String?
    let startedAt: Date?
    let completedAt: Date?
    let durationMilliseconds: Int64?
    let timeToFirstTokenMilliseconds: Int64?
    let modelContextWindow: Int64?
    let collaborationModeKind: String?
    let model: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?
    let dimensionsJSON: String?
    let recordedAt: Date

    init?(
        sessionID: String?,
        turnID: String?,
        sourcePath: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        durationMilliseconds: Int64? = nil,
        timeToFirstTokenMilliseconds: Int64? = nil,
        modelContextWindow: Int64? = nil,
        collaborationModeKind: String? = nil,
        model: String? = nil,
        projectPath: String? = nil,
        effort: String? = nil,
        source: String? = nil,
        dimensions: [TokenUsageDimension] = [],
        dimensionsJSON: String? = nil,
        recordedAt: Date = Date()
    ) {
        guard let normalizedSessionID = CodexTokenContextNormalizer.normalizedIdentifier(sessionID),
              let normalizedTurnID = CodexTokenContextNormalizer.normalizedIdentifier(turnID)
        else {
            return nil
        }

        self.sessionID = normalizedSessionID
        self.turnID = normalizedTurnID
        self.sourcePath = sourcePath
        self.startedAt = startedAt
        self.completedAt = completedAt
        let computedDuration = Self.durationMilliseconds(startedAt: startedAt, completedAt: completedAt)
        self.durationMilliseconds = durationMilliseconds.map { max($0, 0) } ?? computedDuration
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds.map { max($0, 0) }
        self.modelContextWindow = modelContextWindow.map { max($0, 0) }
        self.collaborationModeKind = CodexTokenContextNormalizer.normalizedIdentifier(collaborationModeKind)
        self.model = CodexModelIdentifier.normalized(model)
        self.projectPath = CodexTokenContextNormalizer.normalizedProjectPath(projectPath)
        self.projectName = self.projectPath.flatMap(CodexTokenContextNormalizer.projectName)
        self.effort = CodexTokenContextNormalizer.normalizedIdentifier(effort)
        self.source = CodexTokenContextNormalizer.normalizedIdentifier(source)
        self.dimensionsJSON = dimensionsJSON ?? Self.dimensionsJSON(dimensions)
        self.recordedAt = recordedAt
    }

    var latestEventAt: Date? {
        [startedAt, completedAt].compactMap(\.self).max()
    }

    func merged(with incoming: CodexSessionTaskTimingEvent) -> CodexSessionTaskTimingEvent {
        CodexSessionTaskTimingEvent(
            sessionID: sessionID,
            turnID: turnID,
            sourcePath: incoming.sourcePath ?? sourcePath,
            startedAt: incoming.startedAt ?? startedAt,
            completedAt: incoming.completedAt ?? completedAt,
            durationMilliseconds: incoming.durationMilliseconds ?? durationMilliseconds,
            timeToFirstTokenMilliseconds: incoming.timeToFirstTokenMilliseconds ?? timeToFirstTokenMilliseconds,
            modelContextWindow: incoming.modelContextWindow ?? modelContextWindow,
            collaborationModeKind: incoming.collaborationModeKind ?? collaborationModeKind,
            model: incoming.model ?? model,
            projectPath: incoming.projectPath ?? projectPath,
            effort: incoming.effort ?? effort,
            source: incoming.source ?? source,
            dimensionsJSON: incoming.dimensionsJSON ?? dimensionsJSON,
            recordedAt: incoming.recordedAt
        )!
    }

    func hasSameStoredContent(as other: CodexSessionTaskTimingEvent) -> Bool {
        sessionID == other.sessionID
            && turnID == other.turnID
            && sourcePath == other.sourcePath
            && startedAt == other.startedAt
            && completedAt == other.completedAt
            && durationMilliseconds == other.durationMilliseconds
            && timeToFirstTokenMilliseconds == other.timeToFirstTokenMilliseconds
            && modelContextWindow == other.modelContextWindow
            && collaborationModeKind == other.collaborationModeKind
            && model == other.model
            && projectPath == other.projectPath
            && projectName == other.projectName
            && effort == other.effort
            && source == other.source
            && dimensionsJSON == other.dimensionsJSON
    }

    private static func durationMilliseconds(startedAt: Date?, completedAt: Date?) -> Int64? {
        guard let startedAt, let completedAt, completedAt >= startedAt else {
            return nil
        }

        return Int64((completedAt.timeIntervalSince(startedAt) * 1_000).rounded())
    }

    private static func dimensionsJSON(_ dimensions: [TokenUsageDimension]) -> String? {
        let unique = TokenUsageDimension.unique(dimensions)
            .sorted { left, right in
                left.key.rawValue == right.key.rawValue
                    ? left.value < right.value
                    : left.key.rawValue < right.key.rawValue
            }
        guard !unique.isEmpty else {
            return nil
        }

        let rows = unique.map { ["key": $0.key.rawValue, "value": $0.value] }
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return text
    }
}

struct CodexTurnPerformanceEvent: Equatable, Sendable {
    let sourceKey: String
    let sourceRowID: Int64
    let target: String
    let eventTimestamp: Date
    let eventName: String?
    let eventKind: String?
    let durationMilliseconds: Int64?
    let success: Bool?
    let errorSummary: String?
    let threadID: String?
    let turnID: String?
    let model: String?
    let sessionID: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?
    let originator: String?
    let appVersion: String?
    let terminalType: String?
    let transport: String?
    let wireAPI: String?
    let apiPath: String?
    let recordedAt: Date

    init(
        sourceKey: String,
        sourceRowID: Int64,
        target: String,
        eventTimestamp: Date,
        eventName: String?,
        eventKind: String?,
        durationMilliseconds: Int64?,
        success: Bool?,
        errorSummary: String?,
        threadID: String?,
        turnID: String?,
        model: String?,
        sessionID: String?,
        projectPath: String?,
        effort: String?,
        source: String?,
        originator: String?,
        appVersion: String?,
        terminalType: String?,
        transport: String?,
        wireAPI: String?,
        apiPath: String?,
        recordedAt: Date = Date()
    ) {
        self.sourceKey = sourceKey
        self.sourceRowID = max(sourceRowID, 0)
        self.target = CodexTokenContextNormalizer.normalizedIdentifier(target) ?? "unknown"
        self.eventTimestamp = eventTimestamp
        self.eventName = CodexTokenContextNormalizer.normalizedDimensionValue(eventName)
        self.eventKind = CodexTokenContextNormalizer.normalizedDimensionValue(eventKind)
        self.durationMilliseconds = durationMilliseconds.map { max($0, 0) }
        self.success = success
        self.errorSummary = CodexTokenContextNormalizer.normalizedIdentifier(errorSummary)
        self.threadID = CodexTokenContextNormalizer.normalizedIdentifier(threadID)
        self.turnID = CodexTokenContextNormalizer.normalizedIdentifier(turnID)
        self.model = CodexModelIdentifier.normalized(model)
        self.sessionID = CodexTokenContextNormalizer.normalizedIdentifier(sessionID)
        self.projectPath = CodexTokenContextNormalizer.normalizedProjectPath(projectPath)
        self.projectName = self.projectPath.flatMap(CodexTokenContextNormalizer.projectName)
        self.effort = CodexTokenContextNormalizer.normalizedIdentifier(effort)
        self.source = CodexTokenContextNormalizer.normalizedIdentifier(source)
        self.originator = CodexTokenContextNormalizer.normalizedIdentifier(originator)
        self.appVersion = CodexTokenContextNormalizer.normalizedIdentifier(appVersion)
        self.terminalType = CodexTokenContextNormalizer.normalizedIdentifier(terminalType)
        self.transport = CodexTokenContextNormalizer.normalizedIdentifier(transport)
        self.wireAPI = CodexTokenContextNormalizer.normalizedIdentifier(wireAPI)
        self.apiPath = Self.normalizedAPIPath(apiPath)
        self.recordedAt = recordedAt
    }

    var hasSafePayload: Bool {
        eventName != nil
            || eventKind != nil
            || durationMilliseconds != nil
            || success != nil
            || errorSummary != nil
            || threadID != nil
            || turnID != nil
            || model != nil
            || projectPath != nil
            || effort != nil
            || source != nil
            || originator != nil
            || appVersion != nil
            || terminalType != nil
            || transport != nil
            || wireAPI != nil
            || apiPath != nil
    }

    private static func normalizedAPIPath(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        guard !trimmedValue.isEmpty, trimmedValue.count <= 120 else {
            return nil
        }

        let allowedCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-/"
        )
        guard trimmedValue.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return trimmedValue
    }
}

struct CodexSessionTokenBackfillRequest: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case recent
        case allHistory
    }

    static let defaultRecentDayCount = 30

    let mode: Mode
    let since: Date?
    let forceRescan: Bool

    static func recent(
        now: Date = Date(),
        days: Int = Self.defaultRecentDayCount,
        forceRescan: Bool = false
    ) -> CodexSessionTokenBackfillRequest {
        CodexSessionTokenBackfillRequest(
            mode: .recent,
            since: Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now) ?? now,
            forceRescan: forceRescan
        )
    }

    static func allHistory(forceRescan: Bool = false) -> CodexSessionTokenBackfillRequest {
        CodexSessionTokenBackfillRequest(mode: .allHistory, since: nil, forceRescan: forceRescan)
    }

    var displayTitle: String {
        switch mode {
        case .recent:
            "Recent sessions"
        case .allHistory:
            "All history"
        }
    }
}

enum CodexSessionTokenImportFileStatus: String, Sendable {
    case imported
    case failed
}

struct CodexSessionTokenImportFileMetadata: Equatable, Sendable {
    let path: String
    let fileSize: Int64
    let modifiedAt: Int64
}

struct CodexSessionTokenImportFileRecord: Equatable, Sendable {
    let metadata: CodexSessionTokenImportFileMetadata
    let importedAt: Int64
    let status: CodexSessionTokenImportFileStatus
    let contextVersion: String?

    init(
        metadata: CodexSessionTokenImportFileMetadata,
        importedAt: Int64,
        status: CodexSessionTokenImportFileStatus,
        contextVersion: String? = UsageHistoryStore.currentSessionTokenContextImportVersion
    ) {
        self.metadata = metadata
        self.importedAt = importedAt
        self.status = status
        self.contextVersion = contextVersion
    }
}

struct CodexSessionTokenBackfillSummary: Equatable, Sendable {
    let request: CodexSessionTokenBackfillRequest
    let filesDiscovered: Int
    let filesScanned: Int
    let filesSkippedByBounds: Int
    let filesSkippedUnchanged: Int
    let tokenEventsImported: Int
    let duplicateEventsSkipped: Int
    let modelEventsRepaired: Int
    let contextEventsRepaired: Int
    let dimensionEventsRepaired: Int
    let failedLinesSkipped: Int
    let elapsedTime: TimeInterval

    init(
        request: CodexSessionTokenBackfillRequest = .allHistory(),
        filesDiscovered: Int? = nil,
        filesScanned: Int,
        filesSkippedByBounds: Int = 0,
        filesSkippedUnchanged: Int = 0,
        tokenEventsImported: Int,
        duplicateEventsSkipped: Int,
        modelEventsRepaired: Int = 0,
        contextEventsRepaired: Int = 0,
        dimensionEventsRepaired: Int = 0,
        failedLinesSkipped: Int,
        elapsedTime: TimeInterval = 0
    ) {
        self.request = request
        self.filesDiscovered = filesDiscovered ?? filesScanned
        self.filesScanned = filesScanned
        self.filesSkippedByBounds = filesSkippedByBounds
        self.filesSkippedUnchanged = filesSkippedUnchanged
        self.tokenEventsImported = tokenEventsImported
        self.duplicateEventsSkipped = duplicateEventsSkipped
        self.modelEventsRepaired = modelEventsRepaired
        self.contextEventsRepaired = contextEventsRepaired
        self.dimensionEventsRepaired = dimensionEventsRepaired
        self.failedLinesSkipped = failedLinesSkipped
        self.elapsedTime = elapsedTime
    }

    var statusMessage: String {
        if filesDiscovered == 0 {
            return "No Codex session files found."
        }

        var parts = [
            "\(request.displayTitle): scanned \(filesScanned) of \(filesDiscovered) files.",
            "Imported \(tokenEventsImported) token events.",
        ]

        if filesSkippedByBounds > 0 {
            parts.append("\(filesSkippedByBounds) outside this import scope.")
        }

        if filesSkippedUnchanged > 0 {
            parts.append("\(filesSkippedUnchanged) unchanged files skipped.")
        }

        if duplicateEventsSkipped > 0 {
            parts.append("\(duplicateEventsSkipped) duplicates skipped.")
        }

        if modelEventsRepaired > 0 {
            parts.append("\(modelEventsRepaired) model labels repaired.")
        }

        if contextEventsRepaired > 0 {
            parts.append("\(contextEventsRepaired) context rows repaired.")
        }

        if dimensionEventsRepaired > 0 {
            parts.append("\(dimensionEventsRepaired) dimension rows repaired.")
        }

        if failedLinesSkipped > 0 {
            parts.append("\(failedLinesSkipped) unreadable lines skipped.")
        }

        parts.append(String(format: "%.1fs elapsed.", elapsedTime))
        return parts.joined(separator: " ")
    }
}

struct CodexSessionTaskTimingImporter: @unchecked Sendable {
    let sourceDirectories: [URL]
    let fileManager: FileManager
    let maximumSessionFileSize: Int64

    static let defaultMaximumSessionFileSize: Int64 = 64 * 1024 * 1024
    private static let taskStartedLineNeedle = Data(#""task_started""#.utf8)
    private static let taskCompleteLineNeedle = Data(#""task_complete""#.utf8)
    private static let turnContextLineNeedle = Data(#""turn_context""#.utf8)
    private static let sessionMetaLineNeedle = Data(#""session_meta""#.utf8)

    init(
        sourceDirectories: [URL] = Self.defaultSourceDirectories(),
        fileManager: FileManager = .default,
        maximumSessionFileSize: Int64 = Self.defaultMaximumSessionFileSize
    ) {
        self.sourceDirectories = sourceDirectories
        self.fileManager = fileManager
        self.maximumSessionFileSize = max(maximumSessionFileSize, 0)
    }

    static func defaultSourceDirectories(fileManager: FileManager = .default) -> [URL] {
        [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true),
        ]
    }

    func importTaskTiming(
        into store: UsageHistoryStore,
        now: Date,
        recentDayCount: Int = CodexSessionTokenBackfillRequest.defaultRecentDayCount,
        forceRescan: Bool = false
    ) throws -> CodexSessionTaskTimingSummary {
        let since = Calendar(identifier: .gregorian).date(byAdding: .day, value: -recentDayCount, to: now) ?? now
        let discoveredFiles = sessionFileCandidates()
        var filesSkippedByBounds = 0
        var filesSkippedUnchanged = 0
        var failedLinesSkipped = 0
        var insertedCount = 0
        var updatedCount = 0
        var duplicateCount = 0
        var latestEventAt: Date?

        let sessionFiles = discoveredFiles.filter { candidate in
            guard shouldInclude(candidate: candidate, since: since) else {
                filesSkippedByBounds += 1
                return false
            }

            guard candidate.metadata.fileSize <= maximumSessionFileSize else {
                filesSkippedByBounds += 1
                return false
            }

            guard !shouldSkipUnchanged(candidate.metadata, store: store, forceRescan: forceRescan) else {
                filesSkippedUnchanged += 1
                return false
            }

            return true
        }

        for candidate in sessionFiles {
            let fileResult = parseSessionFile(candidate.url)
            failedLinesSkipped += fileResult.failedLinesSkipped
            let importResult = try store.importSessionTaskTimingEvents(fileResult.events)
            insertedCount += importResult.insertedCount
            updatedCount += importResult.updatedCount
            duplicateCount += importResult.duplicateCount
            latestEventAt = Self.latestDate(latestEventAt, fileResult.events.compactMap(\.latestEventAt).max())
            try store.recordCodexSessionTaskTimingImportFile(
                candidate.metadata,
                importedAt: Int64(Date().timeIntervalSince1970),
                status: fileResult.readSucceeded ? .imported : .failed
            )
        }

        return CodexSessionTaskTimingSummary(
            filesDiscovered: discoveredFiles.count,
            filesScanned: sessionFiles.count,
            filesSkippedByBounds: filesSkippedByBounds,
            filesSkippedUnchanged: filesSkippedUnchanged,
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            duplicateCount: duplicateCount,
            failedLinesSkipped: failedLinesSkipped,
            latestEventAt: latestEventAt
        )
    }

    private struct SessionFileCandidate {
        let url: URL
        let metadata: CodexSessionTokenImportFileMetadata
        let sessionDate: Date?
    }

    private func sessionFileCandidates() -> [SessionFileCandidate] {
        sourceDirectories.flatMap { directoryURL -> [URL] in
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                return []
            }

            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return enumerator.compactMap { item -> URL? in
                guard let fileURL = item as? URL, fileURL.pathExtension == "jsonl" else {
                    return nil
                }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true ? fileURL : nil
            }
        }
        .compactMap { fileURL in
            guard let metadata = fileMetadata(for: fileURL) else {
                return nil
            }
            return SessionFileCandidate(
                url: fileURL,
                metadata: metadata,
                sessionDate: CodexSessionTokenBackfillImporter.sessionDate(from: fileURL)
            )
        }
        .sorted { $0.metadata.path.localizedStandardCompare($1.metadata.path) == .orderedAscending }
    }

    private func fileMetadata(for fileURL: URL) -> CodexSessionTokenImportFileMetadata? {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CodexSessionTokenImportFileMetadata(
            path: fileURL.path,
            fileSize: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate.map { Int64($0.timeIntervalSince1970) } ?? 0
        )
    }

    private func shouldInclude(candidate: SessionFileCandidate, since: Date) -> Bool {
        if let sessionDate = candidate.sessionDate {
            return sessionDate >= since
        }

        return Date(timeIntervalSince1970: TimeInterval(candidate.metadata.modifiedAt)) >= since
    }

    private func shouldSkipUnchanged(
        _ metadata: CodexSessionTokenImportFileMetadata,
        store: UsageHistoryStore,
        forceRescan: Bool
    ) -> Bool {
        guard !forceRescan,
              let record = try? store.codexSessionTaskTimingImportFileRecord(path: metadata.path)
        else {
            return false
        }

        return record.status == .imported
            && record.metadata.fileSize == metadata.fileSize
            && record.metadata.modifiedAt == metadata.modifiedAt
            && record.timingVersion == UsageHistoryStore.currentSessionTaskTimingImportVersion
    }

    private static func latestDate(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case let (left?, right?):
            return max(left, right)
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    private func parseSessionFile(_ fileURL: URL) -> (events: [CodexSessionTaskTimingEvent], failedLinesSkipped: Int, readSucceeded: Bool) {
        guard let lineReader = try? StreamingLineReader(fileURL: fileURL) else {
            return ([], 1, false)
        }
        defer { lineReader.close() }

        let decoder = JSONDecoder()
        let sessionID = CodexSessionTokenBackfillImporter.sessionIdentifier(for: fileURL)
        var currentContext = CodexSessionTokenContextTracker(sessionID: sessionID)
        var currentModel: String?
        var eventsByTurnID: [String: CodexSessionTaskTimingEvent] = [:]
        var failedLinesSkipped = 0

        do {
            while let lineData = try lineReader.nextLineData() {
                guard !lineData.isEmpty, Self.shouldDecodeSessionLine(lineData) else {
                    continue
                }

                do {
                    let line = try decoder.decode(CodexSessionTokenBackfillLine.self, from: lineData)
                    if line.isSessionMetadata {
                        currentContext.applyMetadata(from: line.payload)
                    }
                    if line.isTurnContext {
                        currentContext.applyTurnContext(from: line.payload)
                    }
                    if line.payload?.hasModelMetadata == true {
                        currentModel = line.payload?.modelIdentifier
                    }

                    guard let event = Self.timingEvent(
                        from: line,
                        sourcePath: fileURL.path,
                        fallbackSessionID: sessionID,
                        currentContext: currentContext,
                        currentModel: currentModel
                    ) else {
                        continue
                    }

                    eventsByTurnID[event.turnID] = eventsByTurnID[event.turnID]?.merged(with: event) ?? event
                } catch {
                    failedLinesSkipped += 1
                }
            }
        } catch {
            return (Array(eventsByTurnID.values), failedLinesSkipped + 1, false)
        }

        return (
            eventsByTurnID.values.sorted {
                ($0.startedAt ?? $0.completedAt ?? .distantPast) < ($1.startedAt ?? $1.completedAt ?? .distantPast)
            },
            failedLinesSkipped,
            true
        )
    }

    private static func timingEvent(
        from line: CodexSessionTokenBackfillLine,
        sourcePath: String,
        fallbackSessionID: String,
        currentContext: CodexSessionTokenContextTracker,
        currentModel: String?
    ) -> CodexSessionTaskTimingEvent? {
        guard let payload = line.payload,
              payload.isTaskStarted || payload.isTaskComplete,
              let turnID = payload.turnID
        else {
            return nil
        }

        let lineTimestamp = CodexSessionTokenBackfillImporter.parseTimestamp(line.timestamp)
        let startedAt = payload.isTaskStarted ? (payload.startedAtDate ?? lineTimestamp) : nil
        let completedAt = payload.isTaskComplete ? (payload.completedAtDate ?? lineTimestamp) : nil
        let context = currentContext.context

        return CodexSessionTaskTimingEvent(
            sessionID: context?.sessionID ?? fallbackSessionID,
            turnID: turnID,
            sourcePath: sourcePath,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: payload.durationMilliseconds,
            timeToFirstTokenMilliseconds: payload.timeToFirstTokenMilliseconds,
            modelContextWindow: payload.modelContextWindow,
            collaborationModeKind: payload.collaborationModeKind,
            model: payload.modelIdentifier ?? currentModel,
            projectPath: context?.projectPath,
            effort: context?.effort,
            source: context?.source,
            dimensions: context?.dimensions ?? []
        )
    }

    private static func shouldDecodeSessionLine(_ lineData: Data) -> Bool {
        let searchablePrefix = lineData.prefix(4_096)
        return searchablePrefix.range(of: taskStartedLineNeedle) != nil
            || searchablePrefix.range(of: taskCompleteLineNeedle) != nil
            || searchablePrefix.range(of: turnContextLineNeedle) != nil
            || searchablePrefix.range(of: sessionMetaLineNeedle) != nil
    }

    private final class StreamingLineReader {
        private let handle: FileHandle
        private var buffer = Data()
        private var reachedEnd = false

        init(fileURL: URL) throws {
            handle = try FileHandle(forReadingFrom: fileURL)
        }

        func nextLineData() throws -> Data? {
            while true {
                if let newlineRange = buffer.firstRange(of: Data([0x0A])) {
                    var line = buffer[..<newlineRange.lowerBound]
                    buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                    if line.last == 0x0D {
                        line = line.dropLast()
                    }
                    return Data(line)
                }

                if reachedEnd {
                    guard !buffer.isEmpty else {
                        return nil
                    }
                    var line = buffer
                    buffer.removeAll(keepingCapacity: false)
                    if line.last == 0x0D {
                        line.removeLast()
                    }
                    return line
                }

                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty {
                    reachedEnd = true
                } else {
                    buffer.append(chunk)
                }
            }
        }

        func close() {
            try? handle.close()
        }
    }
}

struct CodexLogTokenUsageImporter {
    let logsDatabaseURL: URL
    let incrementalContextLookbackRowCount: Int64

    init(
        logsDatabaseURL: URL = Self.defaultLogsDatabaseURL(),
        incrementalContextLookbackRowCount: Int64 = 500
    ) {
        self.logsDatabaseURL = logsDatabaseURL
        self.incrementalContextLookbackRowCount = max(incrementalContextLookbackRowCount, 0)
    }

    static func defaultLogsDatabaseURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite")
    }

    func importTokenHistory(
        into store: UsageHistoryStore,
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> TokenUsageImportResult {
        guard FileManager.default.fileExists(atPath: logsDatabaseURL.path),
              let interval = calendar.dateInterval(of: .day, for: date)
        else {
            return .empty
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(logsDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return .empty
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT id, ts, feedback_log_body
        FROM logs
        WHERE ts >= ? AND ts < ?
            AND (
                (
                    feedback_log_body LIKE '%event.name="codex.sse_event"%'
                    AND feedback_log_body LIKE '%event.kind=response.completed%'
                )
                OR (
                    (feedback_log_body LIKE '%conversation.id=%' OR feedback_log_body LIKE '%thread_id=%')
                    AND (
                        feedback_log_body LIKE '%cwd=%'
                        OR feedback_log_body LIKE '%model=%'
                        OR feedback_log_body LIKE '%slug=%'
                        OR feedback_log_body LIKE '%reasoning_effort=%'
                        OR feedback_log_body LIKE '%approval_policy=%'
                        OR feedback_log_body LIKE '%sandbox_type=%'
                        OR feedback_log_body LIKE '%sandbox_policy.type=%'
                        OR feedback_log_body LIKE '%permission_profile=%'
                        OR feedback_log_body LIKE '%truncation_policy=%'
                        OR feedback_log_body LIKE '%originator=%'
                        OR feedback_log_body LIKE '%cli_version=%'
                        OR feedback_log_body LIKE '%app.version=%'
                        OR feedback_log_body LIKE '%model_provider=%'
                        OR feedback_log_body LIKE '%usage_mode=%'
                        OR feedback_log_body LIKE '%speed_mode=%'
                        OR feedback_log_body LIKE '%mode=%'
                    )
                )
            )
        ORDER BY ts ASC, id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(interval.start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(interval.end.timeIntervalSince1970))

        var samples: [ImportedCodexTokenUsageSample] = []
        var contextsByConversationID: [String: CodexLogTokenContextTracker] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bodyPointer = sqlite3_column_text(statement, 2) else {
                continue
            }

            let body = String(cString: bodyPointer)
            let metadata = CodexLogMetadataExtractor(body: body)
            if let conversationID = metadata.conversationID, metadata.hasCarriableMetadata {
                var tracker = contextsByConversationID[conversationID] ?? CodexLogTokenContextTracker(sessionID: conversationID)
                tracker.apply(metadata)
                contextsByConversationID[conversationID] = tracker
            }

            guard metadata.isResponseCompleted,
                  let sample = Self.sample(
                      logID: sqlite3_column_int64(statement, 0),
                      fallbackTimestamp: sqlite3_column_int64(statement, 1),
                      metadata: metadata,
                      carriedContext: metadata.conversationID.flatMap { contextsByConversationID[$0] }
                  )
            else {
                continue
            }
            samples.append(sample)
        }

        return try store.importTokenUsageSamples(samples)
    }

    func importTokenHistory(
        into store: UsageHistoryStore,
        afterLogRowID: Int64,
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> CodexLiveTokenCaptureRunResult {
        guard FileManager.default.fileExists(atPath: logsDatabaseURL.path) else {
            throw UsageHistoryStoreError.fileOperationFailed("Codex log database not found.")
        }
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            throw UsageHistoryStoreError.fileOperationFailed("Current day could not be resolved.")
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(logsDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw UsageHistoryStoreError.fileOperationFailed("Codex log database could not be opened.")
        }
        defer { sqlite3_close(database) }

        let latestLogRowID = try Self.maxLogRowID(
            in: database,
            startTimestamp: interval.start.timeIntervalSince1970Int,
            endTimestamp: interval.end.timeIntervalSince1970Int
        )
        let contextFloorLogRowID = incrementalContextFloorLogRowID(
            afterLogRowID: afterLogRowID,
            latestLogRowID: latestLogRowID
        )

        let sql = """
        SELECT id, ts, feedback_log_body
        FROM logs
        WHERE id > ?
            AND ts >= ? AND ts < ?
            AND (
                (
                    (feedback_log_body LIKE '%conversation.id=%' OR feedback_log_body LIKE '%thread_id=%')
                    AND (
                        feedback_log_body LIKE '%cwd=%'
                        OR feedback_log_body LIKE '%model=%'
                        OR feedback_log_body LIKE '%slug=%'
                        OR feedback_log_body LIKE '%reasoning_effort=%'
                        OR feedback_log_body LIKE '%approval_policy=%'
                        OR feedback_log_body LIKE '%sandbox_type=%'
                        OR feedback_log_body LIKE '%sandbox_policy.type=%'
                        OR feedback_log_body LIKE '%permission_profile=%'
                        OR feedback_log_body LIKE '%truncation_policy=%'
                        OR feedback_log_body LIKE '%originator=%'
                        OR feedback_log_body LIKE '%cli_version=%'
                        OR feedback_log_body LIKE '%app.version=%'
                        OR feedback_log_body LIKE '%model_provider=%'
                        OR feedback_log_body LIKE '%usage_mode=%'
                        OR feedback_log_body LIKE '%speed_mode=%'
                        OR feedback_log_body LIKE '%mode=%'
                    )
                )
                OR (
                    feedback_log_body LIKE '%event.name="codex.sse_event"%'
                    AND feedback_log_body LIKE '%event.kind=response.completed%'
                )
            )
        ORDER BY ts ASC, id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, contextFloorLogRowID)
        sqlite3_bind_int64(statement, 2, interval.start.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 3, interval.end.timeIntervalSince1970Int)

        var samples: [ImportedCodexTokenUsageSample] = []
        var contextsByConversationID: [String: CodexLogTokenContextTracker] = [:]
        var maxLogRowID = max(max(afterLogRowID, 0), latestLogRowID)
        var lastImportedEventAt: Date?

        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let logRowID = sqlite3_column_int64(statement, 0)
                maxLogRowID = max(maxLogRowID, logRowID)
                guard let bodyPointer = sqlite3_column_text(statement, 2) else {
                    continue
                }

                let body = String(cString: bodyPointer)
                let metadata = CodexLogMetadataExtractor(body: body)
                if let conversationID = metadata.conversationID, metadata.hasCarriableMetadata {
                    var tracker = contextsByConversationID[conversationID] ?? CodexLogTokenContextTracker(sessionID: conversationID)
                    tracker.apply(metadata)
                    contextsByConversationID[conversationID] = tracker
                }

                guard logRowID > afterLogRowID,
                      metadata.isResponseCompleted,
                      let sample = Self.sample(
                          logID: logRowID,
                          fallbackTimestamp: sqlite3_column_int64(statement, 1),
                          metadata: metadata,
                          carriedContext: metadata.conversationID.flatMap { contextsByConversationID[$0] }
                      )
                else {
                    continue
                }

                samples.append(sample)
                if let existing = lastImportedEventAt {
                    lastImportedEventAt = max(existing, sample.receivedAt)
                } else {
                    lastImportedEventAt = sample.receivedAt
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }

        let importResult = try store.importTokenUsageSamples(samples)
        return CodexLiveTokenCaptureRunResult(
            importResult: importResult,
            maxLogRowID: maxLogRowID,
            lastImportedEventAt: lastImportedEventAt
        )
    }

    private func incrementalContextFloorLogRowID(afterLogRowID: Int64, latestLogRowID: Int64) -> Int64 {
        let normalizedAfterLogRowID = max(afterLogRowID, 0)
        guard normalizedAfterLogRowID > 0 else {
            return max(latestLogRowID - incrementalContextLookbackRowCount, 0)
        }

        return max(normalizedAfterLogRowID - incrementalContextLookbackRowCount, 0)
    }

    private static func maxLogRowID(
        in database: OpaquePointer,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> Int64 {
        let sql = """
        SELECT COALESCE(MAX(id), 0)
        FROM logs
        WHERE ts >= ? AND ts < ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int64(statement, 0)
        case SQLITE_DONE:
            return 0
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func sample(
        logID _: Int64,
        fallbackTimestamp: Int64,
        metadata: CodexLogMetadataExtractor,
        carriedContext: CodexLogTokenContextTracker?
    ) -> ImportedCodexTokenUsageSample? {
        guard
            let inputTokens = metadata.intValue(for: "input_token_count"),
            let outputTokens = metadata.intValue(for: "output_token_count"),
            let cachedInputTokens = metadata.intValue(for: "cached_token_count"),
            let reasoningOutputTokens = metadata.intValue(for: "reasoning_token_count")
        else {
            return nil
        }

        let totalTokens = metadata.intValue(for: "tool_token_count") ?? (inputTokens + outputTokens)
        let timestampText = metadata.value(for: "event.timestamp")
        let receivedAt = timestampText.flatMap(CodexSessionTokenBackfillImporter.parseTimestamp)
            ?? Date(timeIntervalSince1970: TimeInterval(fallbackTimestamp))
        let conversationID = metadata.conversationID ?? "unknown-conversation"
        let legacyModelID = CodexModelIdentifier.firstNormalized([
            metadata.value(for: "slug"),
            metadata.value(for: "model"),
        ])
        let model = metadata.model ?? carriedContext?.model
        let carriedDimensions = carriedContext?.dimensionsList ?? []
        let explicitMetadataDimensions = metadata.explicitDimensions
        let hasExplicitSourceKind = metadata.source != nil
            || carriedContext?.source != nil
            || explicitMetadataDimensions.contains { $0.key == .sourceKind }
            || carriedDimensions.contains { $0.key == .sourceKind && $0.value != "codex-log" }
        let metadataDimensions = hasExplicitSourceKind
            ? explicitMetadataDimensions
            : metadata.dimensions
        let context = TokenUsageContext(
            sessionID: conversationID,
            projectPath: metadata.projectPath ?? carriedContext?.projectPath,
            effort: metadata.effort ?? carriedContext?.effort,
            source: metadata.source ?? carriedContext?.source ?? "codex-log",
            dimensions: carriedDimensions + metadataDimensions
        )
        let eventID = [
            timestampText ?? "\(fallbackTimestamp)",
            "\(inputTokens)",
            "\(cachedInputTokens)",
            "\(outputTokens)",
            "\(reasoningOutputTokens)",
            legacyModelID ?? "unknown-model",
        ].joined(separator: ":")
        let tokenUsage = CodexThreadTokenUsage(
            last: CodexTokenUsageBreakdown(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                totalTokens: totalTokens
            ),
            total: CodexTokenUsageBreakdown(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                totalTokens: totalTokens
            ),
            modelContextWindow: nil
        )
        let notification = CodexTokenUsageNotification(
            threadID: "codex-log:\(conversationID):\(eventID)",
            turnID: "response.completed",
            model: model,
            tokenUsage: tokenUsage
        )

        return ImportedCodexTokenUsageSample(notification: notification, receivedAt: receivedAt, context: context)
    }
}

struct CodexOtelTurnPerformanceImporter {
    let logsDatabaseURL: URL

    init(logsDatabaseURL: URL = CodexLogTokenUsageImporter.defaultLogsDatabaseURL()) {
        self.logsDatabaseURL = logsDatabaseURL
    }

    func importTurnPerformanceEvents(
        into store: UsageHistoryStore,
        afterLogRowID: Int64,
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> CodexTurnPerformanceCaptureRunResult {
        guard FileManager.default.fileExists(atPath: logsDatabaseURL.path) else {
            throw UsageHistoryStoreError.fileOperationFailed("Codex log database not found.")
        }
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            throw UsageHistoryStoreError.fileOperationFailed("Current day could not be resolved.")
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(logsDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw UsageHistoryStoreError.fileOperationFailed("Codex log database could not be opened.")
        }
        defer { sqlite3_close(database) }

        let latestLogRowID = try Self.maxLogRowID(
            in: database,
            startTimestamp: interval.start.timeIntervalSince1970Int,
            endTimestamp: interval.end.timeIntervalSince1970Int
        )

        let sql = """
        SELECT id, ts, target, feedback_log_body
        FROM logs
        WHERE id > ?
            AND ts >= ? AND ts < ?
            AND target IN (
                'codex_otel.trace_safe',
                'codex_otel.log_only',
                'codex_api::endpoint::responses_websocket',
                'codex_api::sse::responses'
            )
            AND (
                feedback_log_body LIKE '%event.name=%'
                OR feedback_log_body LIKE '%duration_ms=%'
                OR feedback_log_body LIKE '%duration_ms":%'
                OR feedback_log_body LIKE '%success=%'
                OR feedback_log_body LIKE '%transport=%'
                OR feedback_log_body LIKE '%wire_api=%'
                OR feedback_log_body LIKE '%api.path=%'
                OR feedback_log_body LIKE '%codex.turn.reasoning_effort=%'
                OR feedback_log_body LIKE '%reasoning_effort=%'
                OR feedback_log_body LIKE '%model=%'
                OR feedback_log_body LIKE '%slug=%'
                OR feedback_log_body LIKE '%cwd=%'
            )
        ORDER BY id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, max(afterLogRowID, 0))
        sqlite3_bind_int64(statement, 2, interval.start.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 3, interval.end.timeIntervalSince1970Int)

        var events: [CodexTurnPerformanceEvent] = []
        var maxLogRowID = max(max(afterLogRowID, 0), latestLogRowID)
        var lastImportedEventAt: Date?

        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let logRowID = sqlite3_column_int64(statement, 0)
                maxLogRowID = max(maxLogRowID, logRowID)
                guard let targetPointer = sqlite3_column_text(statement, 2),
                      let bodyPointer = sqlite3_column_text(statement, 3)
                else {
                    continue
                }

                let target = String(cString: targetPointer)
                let body = String(cString: bodyPointer)
                let metadata = CodexOtelMetadataExtractor(
                    sourceKey: CodexTurnPerformanceCaptureState.codexOtelLogSourceKey,
                    sourceRowID: logRowID,
                    target: target,
                    fallbackTimestamp: sqlite3_column_int64(statement, 1),
                    body: body
                )
                guard let event = metadata.event(), event.hasSafePayload else {
                    continue
                }

                events.append(event)
                if let existing = lastImportedEventAt {
                    lastImportedEventAt = max(existing, event.eventTimestamp)
                } else {
                    lastImportedEventAt = event.eventTimestamp
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }

        let importResult = try store.importTurnPerformanceEvents(events)
        return CodexTurnPerformanceCaptureRunResult(
            importResult: importResult,
            maxLogRowID: maxLogRowID,
            lastImportedEventAt: lastImportedEventAt
        )
    }

    private static func maxLogRowID(
        in database: OpaquePointer,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> Int64 {
        let sql = """
        SELECT COALESCE(MAX(id), 0)
        FROM logs
        WHERE ts >= ? AND ts < ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int64(statement, 0)
        case SQLITE_DONE:
            return 0
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }
}

private struct CodexOtelMetadataExtractor {
    let sourceKey: String
    let sourceRowID: Int64
    let target: String
    let fallbackTimestamp: Int64
    let body: String

    func event() -> CodexTurnPerformanceEvent? {
        let metadata = CodexLogMetadataExtractor(body: body)
        let eventTimestamp = firstTimestamp(for: [
            "event.timestamp",
            "timestamp",
            "time",
        ]) ?? Date(timeIntervalSince1970: TimeInterval(fallbackTimestamp))
        let eventName = firstValue(for: [
            "event.name",
            "name",
        ])
        let eventKind = firstValue(for: [
            "event.kind",
            "kind",
            "codex.event.kind",
        ])
        let threadID = metadata.conversationID ?? normalizedIdentifier(firstValue(for: [
            "thread_id",
            "thread.id",
            "threadId",
            "conversation_id",
        ]))
        let turnID = normalizedIdentifier(firstValue(for: [
            "turn.id",
            "turn_id",
            "turnId",
            "codex.turn.id",
        ]))

        return CodexTurnPerformanceEvent(
            sourceKey: sourceKey,
            sourceRowID: sourceRowID,
            target: target,
            eventTimestamp: eventTimestamp,
            eventName: eventName,
            eventKind: eventKind,
            durationMilliseconds: firstDurationMilliseconds(for: [
                "duration_ms",
                "duration.milliseconds",
                "duration_millis",
                "duration",
            ]),
            success: firstBool(for: [
                "success",
                "ok",
                "succeeded",
            ]),
            errorSummary: errorSummary,
            threadID: threadID,
            turnID: turnID,
            model: metadata.model,
            sessionID: threadID,
            projectPath: metadata.projectPath,
            effort: metadata.effort,
            source: metadata.source,
            originator: firstIdentifier(for: [
                "originator",
                "codex.originator",
                "codex.session.originator",
            ]),
            appVersion: firstIdentifier(for: [
                "app.version",
                "app_version",
                "cli_version",
                "codex.cli_version",
            ]),
            terminalType: firstIdentifier(for: [
                "terminal.type",
                "terminal_type",
            ]),
            transport: firstIdentifier(for: [
                "transport",
                "codex.transport",
            ]),
            wireAPI: firstIdentifier(for: [
                "wire_api",
                "wire.api",
            ]),
            apiPath: firstValue(for: [
                "api.path",
                "api_path",
                "path",
            ])
        )
    }

    private var errorSummary: String? {
        guard let value = firstRawValue(for: [
            "error.summary",
            "error.kind",
            "error.code",
            "error.message",
        ]) else {
            return nil
        }

        let lowercased = value.lowercased()
        if lowercased.contains("timeout") {
            return "timeout"
        }
        if lowercased.contains("disconnect") || lowercased.contains("connection") {
            return "connection"
        }
        if lowercased.contains("rate") || lowercased.contains("limit") {
            return "rate_limit"
        }
        if lowercased.contains("cancel") {
            return "cancelled"
        }

        return normalizedIdentifier(value) ?? "error"
    }

    private func firstTimestamp(for keys: [String]) -> Date? {
        for key in keys {
            if let timestamp = value(for: key).flatMap(CodexSessionTokenBackfillImporter.parseTimestamp) {
                return timestamp
            }
        }

        return nil
    }

    private func firstIdentifier(for keys: [String]) -> String? {
        normalizedIdentifier(firstValue(for: keys))
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        CodexTokenContextNormalizer.normalizedIdentifier(value)
    }

    private func firstDurationMilliseconds(for keys: [String]) -> Int64? {
        for key in keys {
            guard let value = value(for: key) else {
                continue
            }
            if let intValue = Int64(value) {
                return intValue
            }
            if let doubleValue = Double(value) {
                return Int64((doubleValue * 1000).rounded())
            }
        }

        return nil
    }

    private func firstBool(for keys: [String]) -> Bool? {
        for key in keys {
            guard let value = value(for: key)?.lowercased() else {
                continue
            }
            if ["true", "yes", "1", "ok", "success"].contains(value) {
                return true
            }
            if ["false", "no", "0", "failed", "error"].contains(value) {
                return false
            }
        }

        if let status = firstValue(for: ["status", "otel.status_code"])?.lowercased() {
            if ["ok", "success", "unset"].contains(status) {
                return true
            }
            if ["error", "failed"].contains(status) {
                return false
            }
        }

        return nil
    }

    private func firstValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = value(for: key) {
                return value
            }
        }

        return nil
    }

    private func value(for key: String) -> String? {
        rawValue(for: key, rejectSensitiveValues: true)
    }

    private func firstRawValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = rawValue(for: key, rejectSensitiveValues: false) {
                return value
            }
        }

        return nil
    }

    private func rawValue(for key: String, rejectSensitiveValues: Bool) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?<![A-Za-z0-9_.-])[\"']?\(escapedKey)[\"']?\\s*[:=]\\s*(?:\"([^\"\\r\\n]*)\"|'([^'\\r\\n]*)'|([^\\s,;\\}\\]\\)]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = regex.firstMatch(in: body, range: range) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            guard match.range(at: index).location != NSNotFound,
                  let valueRange = Range(match.range(at: index), in: body)
            else {
                continue
            }

            let value = String(body[valueRange])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !value.isEmpty,
                  !rejectSensitiveValues
                    || (!value.lowercased().contains("user.email")
                        && !value.lowercased().contains("user.account_id")
                        && !value.lowercased().contains("authorization"))
            else {
                return nil
            }
            return value
        }

        return nil
    }
}

private struct CodexLogMetadataExtractor {
    let body: String
    private let bodyValues: [String: String]
    private let contextValues: [String: String]

    init(body: String) {
        self.body = body
        let bodyValues = CodexLogMetadataExtractor.keyValuePairs(in: body)
        self.bodyValues = bodyValues

        let contextBody = CodexLogMetadataExtractor.contextLookupBody(for: body)
        if contextBody == body {
            self.contextValues = bodyValues
        } else {
            self.contextValues = CodexLogMetadataExtractor.keyValuePairs(in: contextBody)
        }
    }

    var isResponseCompleted: Bool {
        body.contains("event.kind=response.completed")
    }

    var conversationID: String? {
        CodexTokenContextNormalizer.normalizedIdentifier(
            firstValue(for: [
                "conversation.id",
                "thread_id",
                "thread.id",
                "threadId",
            ])
        )
    }

    var model: String? {
        CodexModelIdentifier.firstNormalized([
            contextValue(for: "slug"),
            contextValue(for: "model"),
            contextValue(for: "model_slug"),
            contextValue(for: "modelSlug"),
            contextValue(for: "codex.turn.slug"),
            contextValue(for: "codex.turn.model"),
            contextValue(for: "codex.turn.model_slug"),
            contextValue(for: "codex.model"),
        ])
    }

    var projectPath: String? {
        firstContextValue(for: [
            "cwd",
            "project_path",
            "codex.cwd",
            "codex.project.cwd",
            "codex.session.cwd",
            "codex.turn.cwd",
        ])
    }

    var effort: String? {
        firstContextValue(for: [
            "model_reasoning_effort",
            "reasoning_effort",
            "collaboration_mode.settings.reasoning_effort",
            "codex.reasoning_effort",
            "codex.turn.reasoning_effort",
        ])
    }

    var source: String? {
        firstContextValue(for: [
            "source",
            "codex.source",
            "codex.session.source",
            "codex.turn.source",
        ])
    }

    var dimensions: [TokenUsageDimension] {
        dimensions(includeProvenanceDefault: true)
    }

    var explicitDimensions: [TokenUsageDimension] {
        dimensions(includeProvenanceDefault: false)
    }

    var hasCarriableMetadata: Bool {
        model != nil
            || projectPath != nil
            || effort != nil
            || source != nil
            || !explicitDimensions.isEmpty
    }

    func dimensions(includeProvenanceDefault: Bool) -> [TokenUsageDimension] {
        TokenUsageDimension.unique(
            [
                TokenUsageDimension(.originator, firstContextValue(for: [
                    "originator",
                    "codex.originator",
                    "codex.session.originator",
                ])),
                TokenUsageDimension(.sourceKind, source ?? firstContextValue(for: [
                    "source_kind",
                    "codex.source_kind",
                    "codex.session.source_kind",
                    "codex.turn.source_kind",
                ]) ?? (includeProvenanceDefault ? "codex-log" : nil)),
                TokenUsageDimension(.threadSource, firstContextValue(for: [
                    "thread_source",
                    "codex.thread_source",
                    "codex.session.thread_source",
                ])),
                TokenUsageDimension(.cliVersion, firstContextValue(for: [
                    "cli_version",
                    "app.version",
                    "app_version",
                    "codex.cli_version",
                    "codex.session.cli_version",
                ])),
                TokenUsageDimension(.modelProvider, firstContextValue(for: [
                    "model_provider",
                    "codex.model_provider",
                    "codex.turn.model_provider",
                ])),
                TokenUsageDimension(.memoryMode, firstContextValue(for: [
                    "memory_mode",
                    "codex.memory_mode",
                    "codex.turn.memory_mode",
                ])),
                TokenUsageDimension(.approvalPolicy, firstContextValue(for: [
                    "approval_policy",
                    "codex.approval_policy",
                    "codex.turn.approval_policy",
                ])),
                TokenUsageDimension(.sandboxType, firstContextValue(for: [
                    "sandbox_type",
                    "sandbox_policy.type",
                    "codex.sandbox_type",
                    "codex.turn.sandbox_type",
                    "codex.turn.sandbox_policy.type",
                ])),
                TokenUsageDimension(.permissionProfile, firstContextValue(for: [
                    "permission_profile",
                    "permission_profile.type",
                    "codex.permission_profile",
                    "codex.turn.permission_profile",
                    "codex.turn.permission_profile.type",
                ])),
                TokenUsageDimension(.realtimeActive, firstContextValue(for: [
                    "realtime_active",
                    "codex.realtime_active",
                    "codex.turn.realtime_active",
                ])),
                TokenUsageDimension(.truncationPolicy, firstContextValue(for: [
                    "truncation_policy",
                    "truncation_policy.mode",
                    "codex.truncation_policy",
                    "codex.turn.truncation_policy",
                    "codex.turn.truncation_policy.mode",
                ])),
                TokenUsageDimension(.usageMode, firstContextValue(for: [
                    "usage_mode",
                    "speed_mode",
                    "mode",
                    "codex.usage_mode",
                    "codex.turn.usage_mode",
                    "codex.turn.speed_mode",
                    "codex.turn.mode",
                ])),
            ].compactMap(\.self)
        )
    }

    func intValue(for key: String) -> Int64? {
        value(for: key).flatMap(Int64.init)
    }

    func value(for key: String) -> String? {
        bodyValues[key]
    }

    private func contextValue(for key: String) -> String? {
        contextValues[key]
    }

    private func firstValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = value(for: key) {
                return value
            }
        }

        return nil
    }

    private func firstContextValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = contextValue(for: key) {
                return value
            }
        }

        return nil
    }

    private static func contextLookupBody(for body: String) -> String {
        guard !body.contains("event.kind=response.completed"),
              let eventNameRange = body.range(of: " event.name=") ?? body.range(of: "event.name=")
        else {
            return body
        }

        return String(body[..<eventNameRange.lowerBound])
    }

    private static func keyValuePairs(in searchBody: String) -> [String: String] {
        var values: [String: String] = [:]
        var cursor = searchBody.startIndex

        while cursor < searchBody.endIndex {
            guard isIdentifierCharacter(searchBody[cursor]) else {
                cursor = searchBody.index(after: cursor)
                continue
            }

            if cursor > searchBody.startIndex {
                let previousIndex = searchBody.index(before: cursor)
                guard !isIdentifierCharacter(searchBody[previousIndex]) else {
                    cursor = searchBody.index(after: cursor)
                    continue
                }
            }

            let keyStart = cursor
            var keyEnd = cursor
            while keyEnd < searchBody.endIndex, isIdentifierCharacter(searchBody[keyEnd]) {
                keyEnd = searchBody.index(after: keyEnd)
            }
            var valueCursor = keyEnd
            while valueCursor < searchBody.endIndex, searchBody[valueCursor].isWhitespace {
                valueCursor = searchBody.index(after: valueCursor)
            }
            guard valueCursor < searchBody.endIndex, searchBody[valueCursor] == "=" else {
                cursor = keyEnd
                continue
            }
            valueCursor = searchBody.index(after: valueCursor)

            while valueCursor < searchBody.endIndex, searchBody[valueCursor].isWhitespace {
                valueCursor = searchBody.index(after: valueCursor)
            }
            guard valueCursor < searchBody.endIndex else {
                cursor = keyEnd
                continue
            }

            let valueStart: String.Index
            let valueEnd: String.Index
            if searchBody[valueCursor] == "\"" || searchBody[valueCursor] == "'" {
                let quote = searchBody[valueCursor]
                valueStart = searchBody.index(after: valueCursor)
                var end = valueStart
                while end < searchBody.endIndex, searchBody[end] != quote, !searchBody[end].isNewline {
                    end = searchBody.index(after: end)
                }
                valueEnd = end
                cursor = end < searchBody.endIndex ? searchBody.index(after: end) : end
            } else {
                valueStart = valueCursor
                var end = valueCursor
                while end < searchBody.endIndex, !isUnquotedValueTerminator(searchBody[end]) {
                    end = searchBody.index(after: end)
                }
                valueEnd = end
                cursor = end
            }

            let key = String(searchBody[keyStart..<keyEnd])
            let value = String(searchBody[valueStart..<valueEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !value.isEmpty {
                values[key, default: value] = values[key] ?? value
            }
        }

        return values
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "." || character == "-"
    }

    private static func isUnquotedValueTerminator(_ character: Character) -> Bool {
        character.isWhitespace || character == "," || character == ";" || character == "}" || character == "]" || character == ")"
    }
}

private struct CodexLogTokenContextTracker {
    var model: String?
    var sessionID: String?
    var projectPath: String?
    var effort: String?
    var source: String?
    var dimensions: [TokenUsageDimensionKey: TokenUsageDimension] = [:]

    init(sessionID: String?) {
        self.sessionID = CodexTokenContextNormalizer.normalizedIdentifier(sessionID)
    }

    mutating func apply(_ metadata: CodexLogMetadataExtractor) {
        if let conversationID = metadata.conversationID {
            sessionID = conversationID
        }
        if let model = metadata.model {
            self.model = model
        }
        if let projectPath = metadata.projectPath {
            self.projectPath = projectPath
        }
        if let effort = metadata.effort {
            self.effort = effort
        }
        if let source = metadata.source {
            self.source = source
        }
        for dimension in metadata.explicitDimensions {
            dimensions[dimension.key] = dimension
        }
    }

    var dimensionsList: [TokenUsageDimension] {
        Array(dimensions.values)
    }
}

protocol CodexSessionTokenBackfillImporting: Sendable {
    func importTokenHistory(
        into store: UsageHistoryStore,
        request: CodexSessionTokenBackfillRequest
    ) throws -> CodexSessionTokenBackfillSummary
}

extension CodexSessionTokenBackfillImporting {
    func importTokenHistory(into store: UsageHistoryStore) throws -> CodexSessionTokenBackfillSummary {
        try importTokenHistory(into: store, request: .allHistory())
    }
}

struct CodexSessionTokenBackfillImporter: CodexSessionTokenBackfillImporting, @unchecked Sendable {
    let sourceDirectories: [URL]
    let fileManager: FileManager
    private static let tokenCountLineNeedle = Data(#""token_count""#.utf8)
    private static let turnContextLineNeedle = Data(#""turn_context""#.utf8)
    private static let sessionMetaLineNeedle = Data(#""session_meta""#.utf8)

    init(
        sourceDirectories: [URL] = Self.defaultSourceDirectories(),
        fileManager: FileManager = .default
    ) {
        self.sourceDirectories = sourceDirectories
        self.fileManager = fileManager
    }

    static func defaultSourceDirectories(fileManager: FileManager = .default) -> [URL] {
        let codexDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return [
            codexDirectory.appendingPathComponent("sessions", isDirectory: true),
            codexDirectory.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    func importTokenHistory(
        into store: UsageHistoryStore,
        request: CodexSessionTokenBackfillRequest
    ) throws -> CodexSessionTokenBackfillSummary {
        let startedAt = Date()
        let discoveredFiles = sessionFileCandidates()
        var filesSkippedByBounds = 0
        var filesSkippedUnchanged = 0
        var failedLinesSkipped = 0
        var tokenEventsImported = 0
        var duplicateEventsSkipped = 0
        var modelEventsRepaired = 0
        var contextEventsRepaired = 0
        var dimensionEventsRepaired = 0

        let sessionFiles = discoveredFiles.filter { candidate in
            guard shouldInclude(candidate: candidate, request: request) else {
                filesSkippedByBounds += 1
                return false
            }

            guard !shouldSkipUnchanged(candidate.metadata, store: store, request: request) else {
                filesSkippedUnchanged += 1
                return false
            }

            return true
        }

        for candidate in sessionFiles {
            let fileResult = parseSessionFile(candidate.url)
            failedLinesSkipped += fileResult.failedLinesSkipped
            let importResult = try store.importTokenUsageSamples(fileResult.samples)
            tokenEventsImported += importResult.insertedCount
            duplicateEventsSkipped += importResult.duplicateCount
            modelEventsRepaired += importResult.repairedModelCount
            contextEventsRepaired += importResult.repairedContextCount
            dimensionEventsRepaired += importResult.repairedDimensionCount
            try store.recordCodexSessionTokenImportFile(
                candidate.metadata,
                importedAt: Int64(Date().timeIntervalSince1970),
                status: fileResult.readSucceeded ? .imported : .failed
            )
        }

        return CodexSessionTokenBackfillSummary(
            request: request,
            filesDiscovered: discoveredFiles.count,
            filesScanned: sessionFiles.count,
            filesSkippedByBounds: filesSkippedByBounds,
            filesSkippedUnchanged: filesSkippedUnchanged,
            tokenEventsImported: tokenEventsImported,
            duplicateEventsSkipped: duplicateEventsSkipped,
            modelEventsRepaired: modelEventsRepaired,
            contextEventsRepaired: contextEventsRepaired,
            dimensionEventsRepaired: dimensionEventsRepaired,
            failedLinesSkipped: failedLinesSkipped,
            elapsedTime: Date().timeIntervalSince(startedAt)
        )
    }

    private struct SessionFileCandidate {
        let url: URL
        let metadata: CodexSessionTokenImportFileMetadata
        let sessionDate: Date?
        let isArchived: Bool
    }

    private func sessionFileCandidates() -> [SessionFileCandidate] {
        return sourceDirectories.flatMap { directoryURL -> [URL] in
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                return []
            }

            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return enumerator.compactMap { item -> URL? in
                guard let fileURL = item as? URL, fileURL.pathExtension == "jsonl" else {
                    return nil
                }

                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true ? fileURL : nil
            }
        }
        .compactMap { fileURL in
            guard let metadata = fileMetadata(for: fileURL) else {
                return nil
            }

            return SessionFileCandidate(
                url: fileURL,
                metadata: metadata,
                sessionDate: Self.sessionDate(from: fileURL),
                isArchived: Self.isArchivedSessionFile(fileURL)
            )
        }
        .sorted { $0.metadata.path.localizedStandardCompare($1.metadata.path) == .orderedAscending }
    }

    private static func isArchivedSessionFile(_ fileURL: URL) -> Bool {
        fileURL.pathComponents.contains("archived_sessions")
    }

    private func fileMetadata(for fileURL: URL) -> CodexSessionTokenImportFileMetadata? {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CodexSessionTokenImportFileMetadata(
            path: fileURL.path,
            fileSize: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate.map { Int64($0.timeIntervalSince1970) } ?? 0
        )
    }

    private func shouldInclude(
        candidate: SessionFileCandidate,
        request: CodexSessionTokenBackfillRequest
    ) -> Bool {
        guard let since = request.since else {
            return true
        }

        guard !candidate.isArchived else {
            return false
        }

        if let sessionDate = candidate.sessionDate {
            return sessionDate >= since
        }

        let modifiedAt = Date(timeIntervalSince1970: TimeInterval(candidate.metadata.modifiedAt))
        return modifiedAt >= since
    }

    private func shouldSkipUnchanged(
        _ metadata: CodexSessionTokenImportFileMetadata,
        store: UsageHistoryStore,
        request: CodexSessionTokenBackfillRequest
    ) -> Bool {
        guard !request.forceRescan,
              let record = try? store.codexSessionTokenImportFileRecord(path: metadata.path)
        else {
            return false
        }

        return record.status == .imported
            && record.metadata.fileSize == metadata.fileSize
            && record.metadata.modifiedAt == metadata.modifiedAt
            && record.contextVersion == UsageHistoryStore.currentSessionTokenContextImportVersion
    }

    private func parseSessionFile(_ fileURL: URL) -> (samples: [ImportedCodexTokenUsageSample], failedLinesSkipped: Int, readSucceeded: Bool) {
        if let lineReader = try? GrepRelevantLineReader(fileURL: fileURL) {
            return parseSessionFile(fileURL, relevantLineReader: lineReader)
        }

        guard let lineReader = try? FileLineReader(fileURL: fileURL) else {
            return ([], 1, false)
        }
        defer { lineReader.close() }

        return parseSessionFile(fileURL, fallbackLineReader: lineReader)
    }

    private func parseSessionFile(
        _ fileURL: URL,
        relevantLineReader lineReader: GrepRelevantLineReader
    ) -> (samples: [ImportedCodexTokenUsageSample], failedLinesSkipped: Int, readSucceeded: Bool) {
        defer { lineReader.close() }

        let decoder = JSONDecoder()
        var samples: [ImportedCodexTokenUsageSample] = []
        var failedLinesSkipped = 0
        let sessionID = Self.sessionIdentifier(for: fileURL)
        var currentContext = CodexSessionTokenContextTracker(sessionID: sessionID)
        var currentModel: String?

        do {
            while let line = try lineReader.nextRelevantLineData() {
                do {
                    let decodedLine = try decoder.decode(CodexSessionTokenBackfillLine.self, from: line.data)
                    if decodedLine.isSessionMetadata {
                        currentContext.applyMetadata(from: decodedLine.payload)
                    }
                    if decodedLine.isTurnContext {
                        currentContext.applyTurnContext(from: decodedLine.payload)
                    }
                    if decodedLine.payload?.hasModelMetadata == true {
                        currentModel = decodedLine.payload?.modelIdentifier
                    }

                    guard let payload = decodedLine.payload, payload.type == "token_count", let info = payload.info else {
                        continue
                    }

                    guard let receivedAt = Self.parseTimestamp(decodedLine.timestamp) else {
                        failedLinesSkipped += 1
                        continue
                    }

                    let tokenUsage = CodexThreadTokenUsage(
                        last: info.lastTokenUsage.toDomainBreakdown(),
                        total: info.totalTokenUsage.toDomainBreakdown(),
                        modelContextWindow: info.modelContextWindow
                    )
                    let notification = CodexTokenUsageNotification(
                        threadID: sessionID,
                        turnID: "line:\(line.lineNumber)",
                        model: info.hasModelMetadata ? info.modelIdentifier : currentModel,
                        tokenUsage: tokenUsage
                    )
                    samples.append(ImportedCodexTokenUsageSample(
                        notification: notification,
                        receivedAt: receivedAt,
                        context: currentContext.context(adding: info.dimensions)
                    ))
                } catch {
                    failedLinesSkipped += 1
                }
            }
        } catch {
            return (samples, failedLinesSkipped + 1, false)
        }

        return (samples, failedLinesSkipped, lineReader.readSucceeded)
    }

    private func parseSessionFile(
        _ fileURL: URL,
        fallbackLineReader lineReader: FileLineReader
    ) -> (samples: [ImportedCodexTokenUsageSample], failedLinesSkipped: Int, readSucceeded: Bool) {
        let decoder = JSONDecoder()
        var samples: [ImportedCodexTokenUsageSample] = []
        var failedLinesSkipped = 0
        let sessionID = Self.sessionIdentifier(for: fileURL)
        var currentContext = CodexSessionTokenContextTracker(sessionID: sessionID)
        var currentModel: String?
        var lineIndex = 0

        do {
            while let lineData = try lineReader.nextLineData() {
                guard !lineData.isEmpty else {
                    lineIndex += 1
                    continue
                }

                lineIndex += 1
                guard Self.shouldDecodeSessionLine(lineData) else {
                    continue
                }

                do {
                    let line = try decoder.decode(CodexSessionTokenBackfillLine.self, from: lineData)
                    if line.isSessionMetadata {
                        currentContext.applyMetadata(from: line.payload)
                    }
                    if line.isTurnContext {
                        currentContext.applyTurnContext(from: line.payload)
                    }
                    if line.payload?.hasModelMetadata == true {
                        currentModel = line.payload?.modelIdentifier
                    }

                    guard let payload = line.payload, payload.type == "token_count", let info = payload.info else {
                        continue
                    }

                    guard let receivedAt = Self.parseTimestamp(line.timestamp) else {
                        failedLinesSkipped += 1
                        continue
                    }

                    let tokenUsage = CodexThreadTokenUsage(
                        last: info.lastTokenUsage.toDomainBreakdown(),
                        total: info.totalTokenUsage.toDomainBreakdown(),
                        modelContextWindow: info.modelContextWindow
                    )
                    let notification = CodexTokenUsageNotification(
                        threadID: sessionID,
                        turnID: "line:\(lineIndex)",
                        model: info.hasModelMetadata ? info.modelIdentifier : currentModel,
                        tokenUsage: tokenUsage
                    )
                    samples.append(ImportedCodexTokenUsageSample(
                        notification: notification,
                        receivedAt: receivedAt,
                        context: currentContext.context(adding: info.dimensions)
                    ))
                } catch {
                    failedLinesSkipped += 1
                }
            }
        } catch {
            return (samples, failedLinesSkipped + 1, false)
        }

        return (samples, failedLinesSkipped, true)
    }

    private static func shouldDecodeSessionLine(_ lineData: Data) -> Bool {
        let searchablePrefix = lineData.prefix(4_096)
        return searchablePrefix.range(of: tokenCountLineNeedle) != nil
            || searchablePrefix.range(of: turnContextLineNeedle) != nil
            || searchablePrefix.range(of: sessionMetaLineNeedle) != nil
    }

    private final class GrepRelevantLineReader {
        private let process: Process
        private let lineReader: FileLineReader
        private var hasClosed = false

        var readSucceeded = true

        init(fileURL: URL) throws {
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = [
                "-anE",
                #""token_count"|"turn_context"|"session_meta""#,
                fileURL.path,
            ]
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()

            self.process = process
            self.lineReader = FileLineReader(handle: pipe.fileHandleForReading)
        }

        func nextRelevantLineData() throws -> (lineNumber: Int, data: Data)? {
            while let lineData = try lineReader.nextLineData() {
                guard let parsedLine = Self.parseGrepLine(lineData) else {
                    continue
                }

                return parsedLine
            }

            close()
            return nil
        }

        func close() {
            guard !hasClosed else {
                return
            }

            hasClosed = true
            lineReader.close()
            process.waitUntilExit()
            readSucceeded = process.terminationStatus == 0 || process.terminationStatus == 1
        }

        private static func parseGrepLine(_ lineData: Data) -> (lineNumber: Int, data: Data)? {
            guard let separator = lineData.firstIndex(of: 0x3A), separator > lineData.startIndex else {
                return nil
            }

            let prefix = lineData[lineData.startIndex..<separator]
            guard let rawLineNumber = String(data: prefix, encoding: .utf8),
                  let lineNumber = Int(rawLineNumber)
            else {
                return nil
            }

            let payloadStart = lineData.index(after: separator)
            return (lineNumber, Data(lineData[payloadStart...]))
        }
    }

    private final class FileLineReader {
        private let handle: FileHandle
        private var buffer = Data()
        private var reachedEnd = false

        init(fileURL: URL) throws {
            handle = try FileHandle(forReadingFrom: fileURL)
        }

        init(handle: FileHandle) {
            self.handle = handle
        }

        func nextLineData() throws -> Data? {
            while true {
                if let newlineRange = buffer.firstRange(of: Data([0x0A])) {
                    var line = buffer[..<newlineRange.lowerBound]
                    buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                    if line.last == 0x0D {
                        line = line.dropLast()
                    }
                    return Data(line)
                }

                if reachedEnd {
                    guard !buffer.isEmpty else {
                        return nil
                    }

                    var line = buffer
                    buffer.removeAll(keepingCapacity: false)
                    if line.last == 0x0D {
                        line.removeLast()
                    }
                    return line
                }

                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty {
                    reachedEnd = true
                } else {
                    buffer.append(chunk)
                }
            }
        }

        func close() {
            try? handle.close()
        }
    }

    static func sessionDate(from fileURL: URL) -> Date? {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let pattern = #"rollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
              match.numberOfRanges == 7
        else {
            return nil
        }

        let parts = (1..<7).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: name) else {
                return nil
            }
            return String(name[range])
        }

        guard parts.count == 6 else {
            return nil
        }

        return parseTimestamp("\(parts[0])-\(parts[1])-\(parts[2])T\(parts[3]):\(parts[4]):\(parts[5])Z")
    }

    static func sessionIdentifier(for fileURL: URL) -> String {
        "session:\(fileURL.deletingPathExtension().lastPathComponent)"
    }

    static func parseTimestamp(_ rawValue: String?) -> Date? {
        guard let rawValue else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: rawValue) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }
}

private struct CodexSessionTokenBackfillLine: Decodable {
    let type: String?
    let timestamp: String?
    let payload: Payload?

    var isSessionMetadata: Bool {
        type == "session_meta"
    }

    var isTurnContext: Bool {
        type == "turn_context" || payload?.type == "turn_context"
    }

    struct Payload: Decodable {
        let type: String?
        let id: String?
        let cwd: String?
        let source: CodexSafeSourceMetadataPayload?
        let effort: String?
        let originator: String?
        let cliVersion: String?
        let modelProvider: String?
        let memoryMode: String?
        let threadSource: String?
        let approvalPolicy: String?
        let sandboxPolicy: CodexSandboxPolicyPayload?
        let permissionProfile: String?
        let realtimeActive: Bool?
        let truncationPolicy: String?
        let usageMode: String?
        let speedMode: String?
        let mode: String?
        let collaborationMode: CollaborationMode?
        let turnID: String?
        let startedAt: Int64?
        let completedAt: Int64?
        let durationMilliseconds: Int64?
        let timeToFirstTokenMilliseconds: Int64?
        let modelContextWindow: Int64?
        let collaborationModeKind: String?
        let info: Info?
        let model: String?
        let slug: String?
        let modelSlug: String?

        var modelIdentifier: String? {
            CodexModelIdentifier.firstNormalized([model, slug, modelSlug])
        }

        var safeSessionID: String? {
            CodexTokenContextNormalizer.normalizedIdentifier(id)
        }

        var safeProjectPath: String? {
            CodexTokenContextNormalizer.normalizedProjectPath(cwd)
        }

        var safeEffort: String? {
            CodexTokenContextNormalizer.normalizedIdentifier(
                effort ?? collaborationMode?.settings?.reasoningEffort
            )
        }

        var safeSource: String? {
            source?.dimensions.first { $0.key == .sourceKind }?.value
        }

        var hasModelMetadata: Bool {
            model != nil || slug != nil || modelSlug != nil
        }

        var isTaskStarted: Bool {
            type == "task_started"
        }

        var isTaskComplete: Bool {
            type == "task_complete"
        }

        var startedAtDate: Date? {
            Self.date(fromEpoch: startedAt)
        }

        var completedAtDate: Date? {
            Self.date(fromEpoch: completedAt)
        }

        var dimensions: [TokenUsageDimension] {
            TokenUsageDimension.unique(
                [
                    TokenUsageDimension(.originator, originator),
                    TokenUsageDimension(.sourceKind, safeSource),
                    TokenUsageDimension(.threadSource, threadSource),
                    TokenUsageDimension(.cliVersion, cliVersion),
                    TokenUsageDimension(.modelProvider, modelProvider),
                    TokenUsageDimension(.memoryMode, memoryMode),
                    TokenUsageDimension(.approvalPolicy, approvalPolicy),
                    TokenUsageDimension(.sandboxType, sandboxPolicy?.type),
                    TokenUsageDimension(.permissionProfile, permissionProfile),
                    TokenUsageDimension.boolean(.realtimeActive, realtimeActive),
                    TokenUsageDimension(.truncationPolicy, truncationPolicy),
                    TokenUsageDimension(.usageMode, usageMode ?? speedMode ?? mode),
                    TokenUsageDimension(.usageMode, info?.usageMode ?? info?.speedMode ?? info?.mode),
                ].compactMap(\.self)
                    + (source?.dimensions ?? [])
                    + (info?.dimensions ?? [])
            )
        }

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case cwd
            case source
            case effort
            case originator
            case cliVersion = "cli_version"
            case modelProvider = "model_provider"
            case memoryMode = "memory_mode"
            case threadSource = "thread_source"
            case approvalPolicy = "approval_policy"
            case sandboxPolicy = "sandbox_policy"
            case permissionProfile = "permission_profile"
            case realtimeActive = "realtime_active"
            case truncationPolicy = "truncation_policy"
            case usageMode = "usage_mode"
            case speedMode = "speed_mode"
            case mode
            case collaborationMode = "collaboration_mode"
            case turnID = "turn_id"
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case durationMilliseconds = "duration_ms"
            case timeToFirstTokenMilliseconds = "time_to_first_token_ms"
            case modelContextWindow = "model_context_window"
            case collaborationModeKind = "collaboration_mode_kind"
            case info
            case model
            case slug
            case modelSlug
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
            source = try? container.decodeIfPresent(CodexSafeSourceMetadataPayload.self, forKey: .source)
            effort = try? container.decodeIfPresent(String.self, forKey: .effort)
            originator = try? container.decodeIfPresent(String.self, forKey: .originator)
            cliVersion = try? container.decodeIfPresent(String.self, forKey: .cliVersion)
            modelProvider = try? container.decodeIfPresent(String.self, forKey: .modelProvider)
            memoryMode = try? container.decodeIfPresent(String.self, forKey: .memoryMode)
            threadSource = try? container.decodeIfPresent(String.self, forKey: .threadSource)
            approvalPolicy = try? container.decodeIfPresent(String.self, forKey: .approvalPolicy)
            sandboxPolicy = try? container.decodeIfPresent(CodexSandboxPolicyPayload.self, forKey: .sandboxPolicy)
            permissionProfile = Self.decodeFlexibleString(from: container, .permissionProfile)
            realtimeActive = try? container.decodeIfPresent(Bool.self, forKey: .realtimeActive)
            truncationPolicy = Self.decodeFlexibleString(from: container, .truncationPolicy)
            usageMode = try? container.decodeIfPresent(String.self, forKey: .usageMode)
            speedMode = try? container.decodeIfPresent(String.self, forKey: .speedMode)
            mode = try? container.decodeIfPresent(String.self, forKey: .mode)
            collaborationMode = try? container.decode(CollaborationMode.self, forKey: .collaborationMode)
            turnID = try? container.decodeIfPresent(String.self, forKey: .turnID)
            startedAt = Self.decodeFlexibleInt64(from: container, .startedAt)
            completedAt = Self.decodeFlexibleInt64(from: container, .completedAt)
            durationMilliseconds = Self.decodeFlexibleInt64(from: container, .durationMilliseconds)
            timeToFirstTokenMilliseconds = Self.decodeFlexibleInt64(from: container, .timeToFirstTokenMilliseconds)
            modelContextWindow = Self.decodeFlexibleInt64(from: container, .modelContextWindow)
            collaborationModeKind = try? container.decodeIfPresent(String.self, forKey: .collaborationModeKind)
            info = try? container.decode(Info.self, forKey: .info)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            slug = try container.decodeIfPresent(String.self, forKey: .slug)
            modelSlug = try container.decodeIfPresent(String.self, forKey: .modelSlug)
        }

        private static func decodeFlexibleString(
            from container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }

            return (try? container.decodeIfPresent(CodexSafeMetadataValuePayload.self, forKey: key))?.value
        }

        private static func decodeFlexibleInt64(
            from container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> Int64? {
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int64(value.rounded())
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int64(value)
            }
            return nil
        }

        private static func date(fromEpoch rawValue: Int64?) -> Date? {
            guard let rawValue, rawValue > 0 else {
                return nil
            }

            if rawValue > 10_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(rawValue) / 1_000)
            }
            return Date(timeIntervalSince1970: TimeInterval(rawValue))
        }
    }

    struct Info: Decodable {
        let lastTokenUsage: SessionTokenUsageBreakdown
        let totalTokenUsage: SessionTokenUsageBreakdown
        let modelContextWindow: Int64?
        let model: String?
        let slug: String?
        let modelSlug: String?
        let usageMode: String?
        let speedMode: String?
        let mode: String?

        var modelIdentifier: String? {
            CodexModelIdentifier.firstNormalized([model, slug, modelSlug])
        }

        var dimensions: [TokenUsageDimension] {
            TokenUsageDimension.unique(
                [
                    TokenUsageDimension(.usageMode, usageMode ?? speedMode ?? mode),
                ].compactMap(\.self)
            )
        }

        var hasModelMetadata: Bool {
            model != nil || slug != nil || modelSlug != nil
        }

        enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
            case totalTokenUsage = "total_token_usage"
            case modelContextWindow = "model_context_window"
            case model
            case slug
            case modelSlug
            case usageMode = "usage_mode"
            case speedMode = "speed_mode"
            case mode
        }
    }

    struct CollaborationMode: Decodable {
        let settings: Settings?

        struct Settings: Decodable {
            let reasoningEffort: String?

            enum CodingKeys: String, CodingKey {
                case reasoningEffort = "reasoning_effort"
            }
        }
    }
}

private struct CodexSessionTokenContextTracker {
    var sessionID: String?
    var projectPath: String?
    var effort: String?
    var source: String?
    var dimensions: [TokenUsageDimensionKey: TokenUsageDimension] = [:]

    init(sessionID: String?) {
        self.sessionID = CodexTokenContextNormalizer.normalizedIdentifier(sessionID)
    }

    mutating func applyMetadata(from payload: CodexSessionTokenBackfillLine.Payload?) {
        guard let payload else {
            return
        }

        if let sessionID = payload.safeSessionID {
            self.sessionID = sessionID
        }
        if let projectPath = payload.safeProjectPath {
            self.projectPath = projectPath
        }
        if let source = payload.safeSource {
            self.source = source
        }
        if let effort = payload.safeEffort {
            self.effort = effort
        }
        applyDimensions(payload.dimensions)
    }

    mutating func applyTurnContext(from payload: CodexSessionTokenBackfillLine.Payload?) {
        guard let payload else {
            return
        }

        if let projectPath = payload.safeProjectPath {
            self.projectPath = projectPath
        }
        if let effort = payload.safeEffort {
            self.effort = effort
        }
        if let source = payload.safeSource {
            self.source = source
        }
        applyDimensions(payload.dimensions)
    }

    mutating func applyDimensions(_ newDimensions: [TokenUsageDimension]) {
        for dimension in newDimensions {
            dimensions[dimension.key] = dimension
        }
    }

    var context: TokenUsageContext? {
        context(adding: [])
    }

    func context(adding additionalDimensions: [TokenUsageDimension]) -> TokenUsageContext? {
        let context = TokenUsageContext(
            sessionID: sessionID,
            projectPath: projectPath,
            effort: effort,
            source: source,
            dimensions: Array(dimensions.values) + additionalDimensions
        )
        return context.hasAnyValue ? context : nil
    }
}

private struct SessionTokenUsageBreakdown: Decodable {
    let cachedInputTokens: Int64
    let inputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case cachedInputTokens = "cached_input_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }

    func toDomainBreakdown() -> CodexTokenUsageBreakdown {
        CodexTokenUsageBreakdown(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: totalTokens
        )
    }
}
