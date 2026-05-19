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

    init(
        insertedCount: Int,
        duplicateCount: Int,
        repairedModelCount: Int = 0,
        repairedContextCount: Int = 0
    ) {
        self.insertedCount = insertedCount
        self.duplicateCount = duplicateCount
        self.repairedModelCount = repairedModelCount
        self.repairedContextCount = repairedContextCount
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
            AND feedback_log_body LIKE '%event.name="codex.sse_event"%'
            AND feedback_log_body LIKE '%event.kind=response.completed%'
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
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let bodyPointer = sqlite3_column_text(statement, 2),
                let sample = Self.sample(
                    logID: sqlite3_column_int64(statement, 0),
                    fallbackTimestamp: sqlite3_column_int64(statement, 1),
                    body: String(cString: bodyPointer)
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
        body: String
    ) -> ImportedCodexTokenUsageSample? {
        guard
            let inputTokens = intValue(for: "input_token_count", in: body),
            let outputTokens = intValue(for: "output_token_count", in: body),
            let cachedInputTokens = intValue(for: "cached_token_count", in: body),
            let reasoningOutputTokens = intValue(for: "reasoning_token_count", in: body)
        else {
            return nil
        }

        let totalTokens = intValue(for: "tool_token_count", in: body) ?? (inputTokens + outputTokens)
        let timestampText = value(for: "event.timestamp", in: body)
        let receivedAt = timestampText.flatMap(CodexSessionTokenBackfillImporter.parseTimestamp)
            ?? Date(timeIntervalSince1970: TimeInterval(fallbackTimestamp))
        let conversationID = value(for: "conversation.id", in: body) ?? "unknown-conversation"
        let model = CodexModelIdentifier.firstNormalized([
            value(for: "slug", in: body),
            value(for: "model", in: body),
        ])
        let context = TokenUsageContext(
            sessionID: conversationID,
            projectPath: value(for: "cwd", in: body),
            effort: value(for: "model_reasoning_effort", in: body) ?? value(for: "reasoning_effort", in: body),
            source: value(for: "source", in: body) ?? "codex-log"
        )
        let eventID = [
            timestampText ?? "\(fallbackTimestamp)",
            "\(inputTokens)",
            "\(cachedInputTokens)",
            "\(outputTokens)",
            "\(reasoningOutputTokens)",
            model ?? "unknown-model",
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

    private static func intValue(for key: String, in body: String) -> Int64? {
        value(for: key, in: body).flatMap(Int64.init)
    }

    private static func value(for key: String, in body: String) -> String? {
        let pattern = "(?:^| )\(NSRegularExpression.escapedPattern(for: key))=([^ ]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let valueRange = Range(match.range(at: 1), in: body)
        else {
            return nil
        }

        return String(body[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
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
                        context: currentContext.context
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
                        context: currentContext.context
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
        let source: String?
        let effort: String?
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
            CodexTokenContextNormalizer.normalizedIdentifier(source)
        }

        var hasModelMetadata: Bool {
            model != nil || slug != nil || modelSlug != nil
        }

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case cwd
            case source
            case effort
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
            source = try? container.decodeIfPresent(String.self, forKey: .source)
            effort = try? container.decodeIfPresent(String.self, forKey: .effort)
            collaborationMode = try? container.decode(CollaborationMode.self, forKey: .collaborationMode)
            info = try? container.decode(Info.self, forKey: .info)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            slug = try container.decodeIfPresent(String.self, forKey: .slug)
            modelSlug = try container.decodeIfPresent(String.self, forKey: .modelSlug)
        }
    }

    struct Info: Decodable {
        let lastTokenUsage: SessionTokenUsageBreakdown
        let totalTokenUsage: SessionTokenUsageBreakdown
        let modelContextWindow: Int64?
        let model: String?
        let slug: String?
        let modelSlug: String?

        var modelIdentifier: String? {
            CodexModelIdentifier.firstNormalized([model, slug, modelSlug])
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
    }

    var context: TokenUsageContext? {
        let context = TokenUsageContext(
            sessionID: sessionID,
            projectPath: projectPath,
            effort: effort,
            source: source
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
