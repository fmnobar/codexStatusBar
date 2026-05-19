import Foundation
import SQLite3

protocol UsageHistoryRecording: Sendable {
    func record(snapshot: CodexUsageSnapshot, at date: Date) async
}

protocol TokenUsageRecording: Sendable {
    @discardableResult
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals?
    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals?
    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64?
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

    init(database: UsageHistoryDatabaseWorking) {
        self.database = database
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {
        await database.record(snapshot: snapshot, at: date)
    }
}

extension UsageHistoryRecorder: TokenUsageRecording {
    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        await database.record(tokenUsage: tokenUsage, at: date)
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        await database.todayTokenCategoryTotals(at: date, calendar: calendar)
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        await database.todayTotalTokens(at: date, calendar: calendar)
    }
}

extension UsageHistoryStore {
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
}

enum UsageHistoryStoreError: LocalizedError {
    case databaseOpenFailed(String)
    case databaseOperationFailed(String)
    case statementPreparationFailed(String)
    case databaseUnavailable
    case invalidBackup
    case fileOperationFailed(String)

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
        case .fileOperationFailed(let message):
            return "Usage history file operation failed: \(message)"
        }
    }
}

struct UsageHistoryDatabaseInfo: Equatable {
    let databaseURL: URL
    let totalByteSize: Int64
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

    init(
        sessionID: String? = nil,
        projectPath: String? = nil,
        effort: String? = nil,
        source: String? = nil
    ) {
        self.sessionID = CodexTokenContextNormalizer.normalizedIdentifier(sessionID)
        self.projectPath = CodexTokenContextNormalizer.normalizedProjectPath(projectPath)
        self.projectName = self.projectPath.flatMap(CodexTokenContextNormalizer.projectName)
        self.effort = CodexTokenContextNormalizer.normalizedIdentifier(effort)
        self.source = CodexTokenContextNormalizer.normalizedIdentifier(source)
    }

    var hasAnyValue: Bool {
        sessionID != nil
            || projectPath != nil
            || projectName != nil
            || effort != nil
            || source != nil
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
}

enum UsageHistoryRawRetention: Int, CaseIterable, Identifiable, Equatable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }

    var displayTitle: String {
        "\(rawValue) days"
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue * 24 * 60 * 60)
    }
}

enum UsageHistoryRawRetentionStore {
    static let defaultsKey = "UsageHistoryRawRetentionDays"
    static let defaultRetention: UsageHistoryRawRetention = .fourteenDays

    static func load(from defaults: UserDefaults = .standard) -> UsageHistoryRawRetention {
        let rawValue = defaults.integer(forKey: defaultsKey)
        return UsageHistoryRawRetention(rawValue: rawValue) ?? defaultRetention
    }

    static func save(_ retention: UsageHistoryRawRetention, to defaults: UserDefaults = .standard) {
        defaults.set(retention.rawValue, forKey: defaultsKey)
    }
}

final class UsageHistoryStore: @unchecked Sendable {
    static let didChangeNotification = Notification.Name("UsageHistoryStoreDidChange")
    static let defaultRawRetention: TimeInterval = 14 * 24 * 60 * 60
    static let consumptionAlgorithmMetadataKey = "usage_consumption_algorithm_version"
    static let currentConsumptionAlgorithmVersion = "5"
    static let seriesCatalogMetadataKey = "series_catalog_version"
    static let currentSeriesCatalogVersion = "2"
    static let tokenModelCleanupMetadataKey = "token_model_cleanup_version"
    static let currentTokenModelCleanupVersion = "1"
    static let tokenContextCleanupMetadataKey = "token_context_cleanup_version"
    static let currentTokenContextCleanupVersion = "1"
    static let currentSessionTokenContextImportVersion = "1"
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

    convenience init(
        databaseURL: URL,
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetention: TimeInterval = UsageHistoryStore.defaultRawRetention
    ) throws {
        try self.init(
            databaseURL: databaseURL,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetentionProvider: { rawRetention }
        )
    }

    convenience init(
        databaseURL: URL,
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = .autoupdatingCurrent,
        rawRetentionProvider: @escaping () -> TimeInterval
    ) throws {
        try self.init(
            databasePath: databaseURL.path,
            databaseURL: databaseURL,
            notificationCenter: notificationCenter,
            calendar: calendar,
            rawRetentionProvider: rawRetentionProvider
        )
    }

    private init(
        databasePath: String,
        databaseURL: URL?,
        notificationCenter: NotificationCenter,
        calendar: Calendar,
        rawRetentionProvider: @escaping () -> TimeInterval
    ) throws {
        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &openedDatabase, flags, nil) == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw UsageHistoryStoreError.databaseOpenFailed(message)
        }

        database = openedDatabase
        self.databaseURL = databaseURL
        self.notificationCenter = notificationCenter
        self.calendar = calendar
        self.rawRetentionProvider = rawRetentionProvider

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    static func applicationSupportStore(
        rawRetentionProvider: @escaping () -> TimeInterval = {
            UsageHistoryRawRetentionStore.load().timeInterval
        }
    ) throws -> UsageHistoryStore {
        let directoryURL = try applicationSupportDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try UsageHistoryStore(
            databaseURL: directoryURL.appendingPathComponent("usage-history.sqlite3"),
            rawRetentionProvider: rawRetentionProvider
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
