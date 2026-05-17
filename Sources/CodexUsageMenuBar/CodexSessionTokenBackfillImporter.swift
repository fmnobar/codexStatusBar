import Foundation
import SQLite3

struct ImportedCodexTokenUsageSample: Equatable {
    let notification: CodexTokenUsageNotification
    let receivedAt: Date
}

struct TokenUsageImportResult: Equatable {
    let insertedCount: Int
    let duplicateCount: Int

    static let empty = TokenUsageImportResult(insertedCount: 0, duplicateCount: 0)
}

struct CodexSessionTokenBackfillSummary: Equatable {
    let filesScanned: Int
    let tokenEventsImported: Int
    let duplicateEventsSkipped: Int
    let failedLinesSkipped: Int

    var statusMessage: String {
        if filesScanned == 0 {
            return "No Codex session files found."
        }

        var parts = [
            "Imported \(tokenEventsImported) token events from \(filesScanned) files.",
        ]

        if duplicateEventsSkipped > 0 {
            parts.append("\(duplicateEventsSkipped) duplicates skipped.")
        }

        if failedLinesSkipped > 0 {
            parts.append("\(failedLinesSkipped) unreadable lines skipped.")
        }

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
        let model = value(for: "slug", in: body) ?? value(for: "model", in: body)
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

        return ImportedCodexTokenUsageSample(notification: notification, receivedAt: receivedAt)
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

protocol CodexSessionTokenBackfillImporting {
    func importTokenHistory(into store: UsageHistoryStore) throws -> CodexSessionTokenBackfillSummary
}

struct CodexSessionTokenBackfillImporter: CodexSessionTokenBackfillImporting {
    let sourceDirectories: [URL]
    let fileManager: FileManager

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

    func importTokenHistory(into store: UsageHistoryStore) throws -> CodexSessionTokenBackfillSummary {
        let sessionFiles = sessionFileURLs()
        var parsedSamples: [ImportedCodexTokenUsageSample] = []
        var failedLinesSkipped = 0

        for fileURL in sessionFiles {
            let fileResult = parseSessionFile(fileURL)
            parsedSamples += fileResult.samples
            failedLinesSkipped += fileResult.failedLinesSkipped
        }

        let importResult = try store.importTokenUsageSamples(parsedSamples)
        return CodexSessionTokenBackfillSummary(
            filesScanned: sessionFiles.count,
            tokenEventsImported: importResult.insertedCount,
            duplicateEventsSkipped: importResult.duplicateCount,
            failedLinesSkipped: failedLinesSkipped
        )
    }

    private func sessionFileURLs() -> [URL] {
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
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func parseSessionFile(_ fileURL: URL) -> (samples: [ImportedCodexTokenUsageSample], failedLinesSkipped: Int) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ([], 1)
        }

        let decoder = JSONDecoder()
        var samples: [ImportedCodexTokenUsageSample] = []
        var failedLinesSkipped = 0
        let sessionID = Self.sessionIdentifier(for: fileURL)

        for (lineIndex, rawLine) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let lineData = rawLine.data(using: .utf8) else {
                failedLinesSkipped += 1
                continue
            }

            do {
                let line = try decoder.decode(CodexSessionTokenBackfillLine.self, from: lineData)
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
                    turnID: "line:\(lineIndex + 1)",
                    model: nil,
                    tokenUsage: tokenUsage
                )
                samples.append(ImportedCodexTokenUsageSample(notification: notification, receivedAt: receivedAt))
            } catch {
                failedLinesSkipped += 1
            }
        }

        return (samples, failedLinesSkipped)
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

    struct Payload: Decodable {
        let type: String?
        let info: Info?

        enum CodingKeys: String, CodingKey {
            case type
            case info
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            info = try? container.decode(Info.self, forKey: .info)
        }
    }

    struct Info: Decodable {
        let lastTokenUsage: SessionTokenUsageBreakdown
        let totalTokenUsage: SessionTokenUsageBreakdown
        let modelContextWindow: Int64?

        enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
            case totalTokenUsage = "total_token_usage"
            case modelContextWindow = "model_context_window"
        }
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
