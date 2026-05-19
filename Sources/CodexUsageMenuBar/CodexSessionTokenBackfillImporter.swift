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

struct CodexLogTokenUsageImporter {
    let logsDatabaseURL: URL

    init(logsDatabaseURL: URL = Self.defaultLogsDatabaseURL()) {
        self.logsDatabaseURL = logsDatabaseURL
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
        let context = TokenUsageContext(
            sessionID: conversationID,
            projectPath: metadata.projectPath ?? carriedContext?.projectPath,
            effort: metadata.effort ?? carriedContext?.effort,
            source: metadata.source ?? carriedContext?.source ?? "codex-log",
            dimensions: (carriedContext?.dimensionsList ?? []) + metadata.dimensions
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

private struct CodexLogMetadataExtractor {
    let body: String

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

    private func dimensions(includeProvenanceDefault: Bool) -> [TokenUsageDimension] {
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
        value(for: key, in: body)
    }

    private func contextValue(for key: String) -> String? {
        value(for: key, in: contextLookupBody)
    }

    private func value(for key: String, in searchBody: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?<![A-Za-z0-9_.-])\(escapedKey)\\s*=\\s*(?:\"([^\"\\r\\n]*)\"|'([^'\\r\\n]*)'|([^\\s,;\\}\\]\\)]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(searchBody.startIndex..<searchBody.endIndex, in: searchBody)
        guard let match = regex.firstMatch(in: searchBody, range: range) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            guard match.range(at: index).location != NSNotFound,
                  let valueRange = Range(match.range(at: index), in: searchBody)
            else {
                continue
            }

            let value = String(searchBody[valueRange])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return value.isEmpty ? nil : value
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

    private func firstContextValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = contextValue(for: key) {
                return value
            }
        }

        return nil
    }

    private var contextLookupBody: String {
        guard !isResponseCompleted,
              let eventNameRange = body.range(of: " event.name=") ?? body.range(of: "event.name=")
        else {
            return body
        }

        return String(body[..<eventNameRange.lowerBound])
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

    private static func sessionDate(from fileURL: URL) -> Date? {
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

    private static func sessionIdentifier(for fileURL: URL) -> String {
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
