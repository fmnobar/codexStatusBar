import Combine
import Foundation

enum CodexUsageDiagnosticsClassification: String, Codable, Equatable {
    case comparableCandidate
    case independentLikely
    case inconclusive
}

struct CodexUsageDiagnosticsSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let classification: CodexUsageDiagnosticsClassification
    let buckets: [CodexUsageDiagnosticsBucket]
    let summaries: [CodexUsageDiagnosticsWindowSummary]

    init(
        generatedAt: Date,
        buckets: [CodexUsageDiagnosticsBucket],
        summaries: [CodexUsageDiagnosticsWindowSummary]
    ) {
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.buckets = buckets
        self.summaries = summaries
        classification = Self.overallClassification(from: summaries)
    }

    private static func overallClassification(
        from summaries: [CodexUsageDiagnosticsWindowSummary]
    ) -> CodexUsageDiagnosticsClassification {
        if summaries.contains(where: { $0.classification == .independentLikely }) {
            return .independentLikely
        }

        if !summaries.isEmpty, summaries.allSatisfy({ $0.classification == .comparableCandidate }) {
            return .comparableCandidate
        }

        return .inconclusive
    }
}

struct CodexUsageDiagnosticsBucket: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let kind: CodexUsageBucketKind
    let planType: String?
    let primary: CodexUsageDiagnosticsWindow?
    let secondary: CodexUsageDiagnosticsWindow?
}

struct CodexUsageDiagnosticsWindow: Codable, Equatable {
    let usedPercent: Int
    let windowDurationMinutes: Int?
    let resetsAt: Date?
}

struct CodexUsageDiagnosticsWindowSummary: Codable, Equatable {
    let window: UsageLimitWindow
    let classification: CodexUsageDiagnosticsClassification
    let aggregateBucketID: String?
    let aggregateUsedPercent: Int?
    let modelBucketCount: Int
    let modelUsedPercentSum: Int?
    let durationsAligned: Bool
    let resetsAligned: Bool
    let modelValuesWithinAggregate: Bool
    let notes: [String]
}

struct CodexUsageDiagnosticsReview: Equatable {
    let captureCount: Int
    let classification: CodexUsageDiagnosticsClassification
    let summaries: [CodexUsageDiagnosticsReviewWindowSummary]
    let notes: [String]
}

struct CodexUsageDiagnosticsReviewWindowSummary: Equatable {
    let window: UsageLimitWindow
    let classification: CodexUsageDiagnosticsClassification
    let notes: [String]
}

enum CodexUsageDiagnosticsExporter {
    static func jsonData(for snapshot: CodexUsageDiagnosticsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }
}

enum CodexTokenPayloadAuditCategory: String, Codable, Equatable {
    case identifier
    case model
    case project
    case effort
    case source
    case runtimePolicy = "runtime_policy"
    case appSession = "app_session"
    case subagent
    case usageMode = "usage_mode"
}

enum CodexTokenPayloadAuditPresence: String, Codable, Equatable {
    case present
    case missing
    case unsupported
    case rejected
}

struct CodexTokenPayloadAuditField: Codable, Equatable, Identifiable {
    let keyPath: String
    let category: CodexTokenPayloadAuditCategory
    let presence: CodexTokenPayloadAuditPresence
    let valueKind: String?
    let sanitizedValue: String?
    let normalizedValue: String?
    let dimensionKey: TokenUsageDimensionKey?
    let dimensionValue: String?
    let notes: [String]

    var id: String { keyPath }
}

struct CodexTokenUsagePayloadAudit: Codable, Equatable {
    let schemaVersion: Int
    let capturedAt: Date
    let threadID: String?
    let turnID: String?
    let fields: [CodexTokenPayloadAuditField]

    init(
        capturedAt: Date,
        threadID: String?,
        turnID: String?,
        fields: [CodexTokenPayloadAuditField]
    ) {
        schemaVersion = 1
        self.capturedAt = capturedAt
        self.threadID = threadID
        self.turnID = turnID
        self.fields = fields
    }

    var hasModelMetadata: Bool {
        hasUsableField(in: .model)
    }

    var hasProjectMetadata: Bool {
        hasUsableField(in: .project)
    }

    var hasEffortMetadata: Bool {
        hasUsableField(in: .effort)
    }

    var hasSourceMetadata: Bool {
        hasUsableField(in: .source)
    }

    var hasRuntimePolicyMetadata: Bool {
        hasUsableField(in: .runtimePolicy)
    }

    var capturedFieldCount: Int {
        fields.filter { $0.presence == .present }.count
    }

    var rejectedFieldCount: Int {
        fields.filter { $0.presence == .rejected || $0.presence == .unsupported }.count
    }

    var interpretationText: String {
        let present = [
            hasModelMetadata ? "model" : nil,
            hasProjectMetadata ? "project" : nil,
            hasEffortMetadata ? "effort" : nil,
            hasSourceMetadata ? "source" : nil,
            hasRuntimePolicyMetadata ? "runtime policy" : nil,
        ].compactMap(\.self)

        guard !present.isEmpty else {
            return "Live token payloads have not exposed useful attribution metadata yet."
        }

        return "Live token payloads exposed: \(present.joined(separator: ", "))."
    }

    private func hasUsableField(in category: CodexTokenPayloadAuditCategory) -> Bool {
        fields.contains { field in
            field.category == category
                && field.presence == .present
                && (
                    field.normalizedValue?.isEmpty == false
                        || field.dimensionValue?.isEmpty == false
                )
        }
    }
}

enum CodexTokenPayloadAuditExporter {
    static func jsonData(for audit: CodexTokenUsagePayloadAudit) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(audit)
    }
}

enum CodexAppServerConnectionMode: String, Codable, Equatable {
    case unknown
    case webSocket = "web_socket"
    case standardIO = "standard_io"
}

enum CodexTokenPayloadAuditPersistenceStatus: String, Codable, Equatable {
    case notAttempted = "not_attempted"
    case succeeded
    case failed
}

enum CodexAppServerAuditDiagnosticEvent: Equatable {
    case connected(mode: CodexAppServerConnectionMode)
    case disconnected(errorText: String?)
    case inboundMethod(String)
    case rateLimitNotification
    case tokenUsageNotification
    case auditSanitizeAttempt(success: Bool)
    case auditPersistAttempt(success: Bool, errorText: String?)
    case receiveError(String)
}

struct CodexAppServerAuditDiagnostics: Codable, Equatable {
    let schemaVersion: Int
    var startedAt: Date
    var lastUpdatedAt: Date
    var connectionMode: CodexAppServerConnectionMode
    var isConnected: Bool
    var lastInboundMethod: String?
    var inboundNotificationCount: Int
    var rateLimitNotificationCount: Int
    var tokenUsageNotificationCount: Int
    var auditSanitizeAttemptCount: Int
    var auditSanitizeSuccessCount: Int
    var auditPersistAttemptCount: Int
    var auditPersistSuccessCount: Int
    var auditPersistFailureCount: Int
    var lastAuditPersistenceStatus: CodexTokenPayloadAuditPersistenceStatus
    var lastAuditPersistedAt: Date?
    var lastPersistenceError: String?
    var lastReceiveError: String?

    init(now: Date = Date()) {
        schemaVersion = 1
        startedAt = now
        lastUpdatedAt = now
        connectionMode = .unknown
        isConnected = false
        lastInboundMethod = nil
        inboundNotificationCount = 0
        rateLimitNotificationCount = 0
        tokenUsageNotificationCount = 0
        auditSanitizeAttemptCount = 0
        auditSanitizeSuccessCount = 0
        auditPersistAttemptCount = 0
        auditPersistSuccessCount = 0
        auditPersistFailureCount = 0
        lastAuditPersistenceStatus = .notAttempted
        lastAuditPersistedAt = nil
        lastPersistenceError = nil
        lastReceiveError = nil
    }

    var connectionStatusText: String {
        guard isConnected else {
            return connectionMode == .unknown ? "No connection yet" : "Disconnected"
        }

        switch connectionMode {
        case .webSocket:
            return "Connected via WebSocket"
        case .standardIO:
            return "Connected via stdio"
        case .unknown:
            return "Connected"
        }
    }

    var lastAuditStatusText: String {
        switch lastAuditPersistenceStatus {
        case .notAttempted:
            return "No audit write attempted"
        case .succeeded:
            return "Audit persisted"
        case .failed:
            return "Audit persist failed"
        }
    }

    var lastErrorText: String {
        lastPersistenceError ?? lastReceiveError ?? "None"
    }

    var interpretationText: String {
        if tokenUsageNotificationCount == 0 {
            return "No token usage notification has reached the status app yet."
        }

        if auditSanitizeSuccessCount == 0 {
            return "Token usage notifications arrived, but no sanitized audit sample was produced."
        }

        if lastAuditPersistenceStatus == .failed {
            return "Token usage notifications arrived and sanitized, but writing the audit file failed."
        }

        if auditPersistSuccessCount > 0 {
            return "Token usage notifications arrived, sanitized, and persisted."
        }

        return "Token usage notifications arrived and sanitized; audit persistence has not completed yet."
    }
}

@MainActor
final class CodexAppServerAuditDiagnosticsStore: ObservableObject {
    @Published private(set) var diagnostics: CodexAppServerAuditDiagnostics

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.now = now
        diagnostics = (try? Self.loadDiagnostics(from: fileURL)) ?? CodexAppServerAuditDiagnostics(now: now())
    }

    static func applicationSupportStore() -> CodexAppServerAuditDiagnosticsStore {
        let directoryURL = (try? UsageHistoryStore.applicationSupportDirectoryURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CodexStatusBar", isDirectory: true)
        return CodexAppServerAuditDiagnosticsStore(
            fileURL: directoryURL.appendingPathComponent("live-token-payload-audit-diagnostics.json")
        )
    }

    func record(_ event: CodexAppServerAuditDiagnosticEvent) {
        var updated = diagnostics
        let eventDate = now()
        updated.lastUpdatedAt = eventDate

        switch event {
        case .connected(let mode):
            updated.connectionMode = mode
            updated.isConnected = true
            updated.lastReceiveError = nil
        case .disconnected(let errorText):
            updated.isConnected = false
            if let errorText {
                updated.lastReceiveError = errorText
            }
        case .inboundMethod(let method):
            updated.lastInboundMethod = method
            updated.inboundNotificationCount += 1
        case .rateLimitNotification:
            updated.rateLimitNotificationCount += 1
        case .tokenUsageNotification:
            updated.tokenUsageNotificationCount += 1
        case .auditSanitizeAttempt(let success):
            updated.auditSanitizeAttemptCount += 1
            if success {
                updated.auditSanitizeSuccessCount += 1
            }
        case .auditPersistAttempt(let success, let errorText):
            updated.auditPersistAttemptCount += 1
            if success {
                updated.auditPersistSuccessCount += 1
                updated.lastAuditPersistenceStatus = .succeeded
                updated.lastAuditPersistedAt = eventDate
                updated.lastPersistenceError = nil
            } else {
                updated.auditPersistFailureCount += 1
                updated.lastAuditPersistenceStatus = .failed
                updated.lastPersistenceError = errorText
            }
        case .receiveError(let errorText):
            updated.lastReceiveError = errorText
        }

        diagnostics = updated
        persist(updated)
    }

    func clear() {
        diagnostics = CodexAppServerAuditDiagnostics(now: now())
        try? fileManager.removeItem(at: fileURL)
    }

    private func persist(_ diagnostics: CodexAppServerAuditDiagnostics) {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(diagnostics).write(to: fileURL, options: .atomic)
        } catch {
            // Diagnostics must never affect app-server handling.
        }
    }

    private static func loadDiagnostics(from fileURL: URL) throws -> CodexAppServerAuditDiagnostics {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexAppServerAuditDiagnostics.self, from: data)
    }
}

@MainActor
final class CodexTokenPayloadAuditStore: ObservableObject {
    @Published private(set) var latestAudit: CodexTokenUsagePayloadAudit?

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        latestAudit = try? Self.loadAudit(from: fileURL)
    }

    static func applicationSupportStore() -> CodexTokenPayloadAuditStore {
        let directoryURL = (try? UsageHistoryStore.applicationSupportDirectoryURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CodexStatusBar", isDirectory: true)
        return CodexTokenPayloadAuditStore(
            fileURL: directoryURL.appendingPathComponent("live-token-payload-audit.json")
        )
    }

    @discardableResult
    func record(_ audit: CodexTokenUsagePayloadAudit) -> Result<Void, Error> {
        latestAudit = audit
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CodexTokenPayloadAuditExporter.jsonData(for: audit).write(to: fileURL, options: .atomic)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func exportData() throws -> Data? {
        guard let latestAudit else {
            return nil
        }

        return try CodexTokenPayloadAuditExporter.jsonData(for: latestAudit)
    }

    func clear() {
        latestAudit = nil
        try? fileManager.removeItem(at: fileURL)
    }

    private static func loadAudit(from fileURL: URL) throws -> CodexTokenUsagePayloadAudit {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexTokenUsagePayloadAudit.self, from: data)
    }
}

enum CodexProfileTokenUsageSyncStatus: String, Codable, Equatable {
    case neverSynced = "never_synced"
    case succeeded
    case failed

    var displayText: String {
        switch self {
        case .neverSynced:
            return "Not synced"
        case .succeeded:
            return "Synced"
        case .failed:
            return "Failed"
        }
    }
}

struct CodexProfileTokenUsageState: Codable, Equatable {
    var snapshot: CodexProfileTokenUsageSnapshot?
    var status: CodexProfileTokenUsageSyncStatus
    var lastSyncedAt: Date?
    var lastErrorText: String?

    init(
        snapshot: CodexProfileTokenUsageSnapshot? = nil,
        status: CodexProfileTokenUsageSyncStatus = .neverSynced,
        lastSyncedAt: Date? = nil,
        lastErrorText: String? = nil
    ) {
        self.snapshot = snapshot
        self.status = status
        self.lastSyncedAt = lastSyncedAt
        self.lastErrorText = lastErrorText
    }

    func isStale(now: Date, staleAfter: TimeInterval) -> Bool {
        guard let lastSyncedAt else {
            return true
        }

        return now.timeIntervalSince(lastSyncedAt) >= staleAfter
    }
}

@MainActor
final class CodexProfileTokenUsageStore: ObservableObject {
    static let defaultDailyBucketLimit = 400
    static let defaultCacheDuration: TimeInterval = 6 * 60 * 60

    @Published private(set) var state: CodexProfileTokenUsageState

    private let fileURL: URL
    private let fileManager: FileManager
    private let dailyBucketLimit: Int

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        dailyBucketLimit: Int = CodexProfileTokenUsageStore.defaultDailyBucketLimit
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.dailyBucketLimit = dailyBucketLimit
        state = (try? Self.loadState(from: fileURL)) ?? CodexProfileTokenUsageState()
    }

    static func applicationSupportStore() -> CodexProfileTokenUsageStore {
        let directoryURL = (try? UsageHistoryStore.applicationSupportDirectoryURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CodexStatusBar", isDirectory: true)
        return CodexProfileTokenUsageStore(
            fileURL: directoryURL.appendingPathComponent("profile-token-usage.json")
        )
    }

    func recordSuccess(_ snapshot: CodexProfileTokenUsageSnapshot) {
        let boundedSnapshot = snapshot.bounded(to: dailyBucketLimit)
        state = CodexProfileTokenUsageState(
            snapshot: boundedSnapshot,
            status: .succeeded,
            lastSyncedAt: boundedSnapshot.fetchedAt,
            lastErrorText: nil
        )
        persist()
    }

    func recordFailure(_ errorText: String) {
        state = CodexProfileTokenUsageState(
            snapshot: state.snapshot,
            status: .failed,
            lastSyncedAt: state.lastSyncedAt,
            lastErrorText: errorText
        )
        persist()
    }

    func clear() {
        state = CodexProfileTokenUsageState()
        try? fileManager.removeItem(at: fileURL)
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            // Profile diagnostics must never affect menu-bar or dashboard behavior.
        }
    }

    private static func loadState(from fileURL: URL) throws -> CodexProfileTokenUsageState {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexProfileTokenUsageState.self, from: data)
    }
}

enum CodexSourceVersionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case appBundled = "app_bundled"
    case homebrew
    case usrLocal = "usr_local"
    case discoveredApp = "discovered_app"
    case path

    var displayTitle: String {
        switch self {
        case .appBundled:
            return "App-bundled"
        case .homebrew:
            return "Homebrew"
        case .usrLocal:
            return "/usr/local"
        case .discoveredApp:
            return "Codex.app"
        case .path:
            return "PATH"
        }
    }
}

struct CodexExecutableCandidate: Equatable, Sendable {
    let url: URL
    let kind: CodexSourceVersionKind
}

enum CodexExecutableCandidateProvider {
    static func candidates(fileManager: FileManager = .default) -> [CodexExecutableCandidate] {
        var candidates: [CodexExecutableCandidate] = [
            CodexExecutableCandidate(
                url: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
                kind: .appBundled
            ),
            CodexExecutableCandidate(
                url: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                kind: .homebrew
            ),
            CodexExecutableCandidate(
                url: URL(fileURLWithPath: "/usr/local/bin/codex"),
                kind: .usrLocal
            ),
        ]

        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if let appBundleURLs = try? fileManager.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let discoveredCandidates = appBundleURLs
                .filter { $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.hasPrefix("Codex") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map {
                    CodexExecutableCandidate(
                        url: $0.appending(path: "Contents/Resources/codex", directoryHint: .notDirectory),
                        kind: .discoveredApp
                    )
                }

            candidates.append(contentsOf: discoveredCandidates)
        }

        return deduplicated(candidates)
    }

    static func pathCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CodexExecutableCandidate] {
        guard let path = environment["PATH"] else {
            return []
        }

        return path
            .split(separator: ":")
            .map { pathComponent in
                CodexExecutableCandidate(
                    url: URL(fileURLWithPath: String(pathComponent)).appendingPathComponent("codex"),
                    kind: .path
                )
            }
    }

    static func executableURLs(fileManager: FileManager = .default) -> [URL] {
        candidates(fileManager: fileManager).map(\.url)
    }

    private static func deduplicated(_ candidates: [CodexExecutableCandidate]) -> [CodexExecutableCandidate] {
        var deduplicated: [CodexExecutableCandidate] = []
        var seenPaths = Set<String>()

        for candidate in candidates where seenPaths.insert(candidate.url.path).inserted {
            deduplicated.append(candidate)
        }

        return deduplicated
    }
}

struct CodexSourceVersionSignal: Codable, Equatable, Identifiable, Sendable {
    let kind: CodexSourceVersionKind
    let executablePath: String
    let version: String?
    let fileModifiedAt: Date?
    let errorText: String?

    var id: String {
        "\(kind.rawValue):\(executablePath)"
    }

    var displayVersionText: String {
        version ?? "Unavailable"
    }
}

enum CodexSourceHealthStatus: String, Codable, Equatable, Sendable {
    case neverChecked = "never_checked"
    case healthy
    case stale
    case mismatch
    case missing
    case malformed
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            return "Not checked"
        case .healthy:
            return "Healthy"
        case .stale:
            return "Stale metadata"
        case .mismatch:
            return "Version mismatch"
        case .missing:
            return "Missing source"
        case .malformed:
            return "Malformed metadata"
        case .failed:
            return "Failed"
        }
    }

    var shouldShowPopoverWarning: Bool {
        switch self {
        case .neverChecked, .healthy:
            return false
        case .stale, .mismatch, .missing, .malformed, .failed:
            return true
        }
    }
}

struct CodexSourceHealthSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let checkedAt: Date
    let status: CodexSourceHealthStatus
    let activeExecutablePath: String?
    let versionSignals: [CodexSourceVersionSignal]
    let modelsCachePath: String?
    let modelsCacheClientVersion: String?
    let modelsCacheFetchedAt: Date?
    let modelsCacheModelCount: Int?
    let modelsCacheErrorText: String?
    let versionMetadataPath: String?
    let versionMetadataLatestVersion: String?
    let versionMetadataLastCheckedAt: Date?
    let versionMetadataErrorText: String?
    let warnings: [String]
    let errorText: String?

    init(
        checkedAt: Date,
        status: CodexSourceHealthStatus,
        activeExecutablePath: String?,
        versionSignals: [CodexSourceVersionSignal],
        modelsCachePath: String?,
        modelsCacheClientVersion: String?,
        modelsCacheFetchedAt: Date?,
        modelsCacheModelCount: Int?,
        modelsCacheErrorText: String?,
        versionMetadataPath: String?,
        versionMetadataLatestVersion: String?,
        versionMetadataLastCheckedAt: Date?,
        versionMetadataErrorText: String?,
        warnings: [String],
        errorText: String?
    ) {
        schemaVersion = 1
        self.checkedAt = checkedAt
        self.status = status
        self.activeExecutablePath = activeExecutablePath
        self.versionSignals = versionSignals
        self.modelsCachePath = modelsCachePath
        self.modelsCacheClientVersion = modelsCacheClientVersion
        self.modelsCacheFetchedAt = modelsCacheFetchedAt
        self.modelsCacheModelCount = modelsCacheModelCount
        self.modelsCacheErrorText = modelsCacheErrorText
        self.versionMetadataPath = versionMetadataPath
        self.versionMetadataLatestVersion = versionMetadataLatestVersion
        self.versionMetadataLastCheckedAt = versionMetadataLastCheckedAt
        self.versionMetadataErrorText = versionMetadataErrorText
        self.warnings = warnings
        self.errorText = errorText
    }

    var activeSignal: CodexSourceVersionSignal? {
        guard let activeExecutablePath else {
            return nil
        }

        return versionSignals.first { $0.executablePath == activeExecutablePath && $0.version != nil }
    }

    var appBundledSignal: CodexSourceVersionSignal? {
        versionSignals.first { $0.kind == .appBundled }
    }

    var homebrewSignal: CodexSourceVersionSignal? {
        versionSignals.first { $0.kind == .homebrew }
    }

    var popoverWarningText: String? {
        guard status.shouldShowPopoverWarning else {
            return nil
        }

        switch status {
        case .mismatch:
            return "Codex versions differ across local sources."
        case .stale:
            return "Codex update metadata looks stale."
        case .missing:
            return "Codex executable source is missing."
        case .malformed:
            return "Codex version metadata could not be read."
        case .failed:
            return errorText ?? "Codex source health check failed."
        case .neverChecked, .healthy:
            return nil
        }
    }
}

struct CodexSourceHealthState: Codable, Equatable, Sendable {
    var snapshot: CodexSourceHealthSnapshot?
    var status: CodexSourceHealthStatus
    var lastCheckedAt: Date?
    var lastErrorText: String?

    init(
        snapshot: CodexSourceHealthSnapshot? = nil,
        status: CodexSourceHealthStatus = .neverChecked,
        lastCheckedAt: Date? = nil,
        lastErrorText: String? = nil
    ) {
        self.snapshot = snapshot
        self.status = status
        self.lastCheckedAt = lastCheckedAt
        self.lastErrorText = lastErrorText
    }

    var popoverWarningText: String? {
        snapshot?.popoverWarningText
            ?? (status.shouldShowPopoverWarning ? (lastErrorText ?? status.displayText) : nil)
    }

    func isStale(now: Date, staleAfter: TimeInterval) -> Bool {
        guard let lastCheckedAt else {
            return true
        }

        return now.timeIntervalSince(lastCheckedAt) >= staleAfter
    }
}

@MainActor
protocol CodexSourceHealthReading {
    func sourceHealthSnapshot(now: Date) async throws -> CodexSourceHealthSnapshot
}

@MainActor
protocol CodexSourceVersionCommandRunning {
    func versionOutput(for executableURL: URL, timeout: TimeInterval) async throws -> String
}

enum CodexSourceHealthDefaults {
    static let cacheDuration: TimeInterval = 6 * 60 * 60
    static let metadataStalenessInterval: TimeInterval = 7 * 24 * 60 * 60
}

enum CodexSourceHealthReaderError: LocalizedError, Equatable {
    case versionCommandTimedOut
    case versionCommandFailed
    case versionOutputMalformed

    var errorDescription: String? {
        switch self {
        case .versionCommandTimedOut:
            return "Version command timed out."
        case .versionCommandFailed:
            return "Version command failed."
        case .versionOutputMalformed:
            return "Version output was malformed."
        }
    }
}

struct ProcessCodexSourceVersionCommandRunner: CodexSourceVersionCommandRunning {
    func versionOutput(for executableURL: URL, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(
                        returning: try Self.versionOutputSynchronously(
                            for: executableURL,
                            timeout: timeout
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func versionOutputSynchronously(
        for executableURL: URL,
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            throw CodexSourceHealthReaderError.versionCommandFailed
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            throw CodexSourceHealthReaderError.versionCommandTimedOut
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw CodexSourceHealthReaderError.versionCommandFailed
        }

        return String(decoding: output, as: UTF8.self)
    }
}

struct CodexSourceHealthReader: CodexSourceHealthReading {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let environment: [String: String]
    private let commandRunner: CodexSourceVersionCommandRunning
    private let commandTimeout: TimeInterval
    private let metadataStalenessInterval: TimeInterval
    private let executableCandidatesOverride: [CodexExecutableCandidate]?
    private let pathCandidatesOverride: [CodexExecutableCandidate]?

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: CodexSourceVersionCommandRunning = ProcessCodexSourceVersionCommandRunner(),
        commandTimeout: TimeInterval = 2,
        metadataStalenessInterval: TimeInterval = CodexSourceHealthDefaults.metadataStalenessInterval,
        executableCandidates: [CodexExecutableCandidate]? = nil,
        pathCandidates: [CodexExecutableCandidate]? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.commandRunner = commandRunner
        self.commandTimeout = commandTimeout
        self.metadataStalenessInterval = metadataStalenessInterval
        self.executableCandidatesOverride = executableCandidates
        self.pathCandidatesOverride = pathCandidates
    }

    func sourceHealthSnapshot(now: Date = Date()) async throws -> CodexSourceHealthSnapshot {
        let fixedCandidates = executableCandidatesOverride ?? CodexExecutableCandidateProvider.candidates(fileManager: fileManager)
        let pathCandidates = pathCandidatesOverride ?? CodexExecutableCandidateProvider.pathCandidates(environment: environment)
        let activeCandidate = (fixedCandidates + pathCandidates).first {
            fileManager.isExecutableFile(atPath: $0.url.path)
        }

        var signals: [CodexSourceVersionSignal] = []
        for candidate in fixedCandidates {
            signals.append(await versionSignal(for: candidate))
        }

        if let activeCandidate,
           !signals.contains(where: { $0.executablePath == activeCandidate.url.path })
        {
            signals.append(await versionSignal(for: activeCandidate))
        }

        let modelsCache = readModelsCacheMetadata()
        let versionMetadata = readVersionMetadata()
        let warnings = warnings(
            now: now,
            activeCandidate: activeCandidate,
            signals: signals,
            modelsCache: modelsCache,
            versionMetadata: versionMetadata
        )
        let status = status(
            activeCandidate: activeCandidate,
            signals: signals,
            modelsCache: modelsCache,
            versionMetadata: versionMetadata,
            warnings: warnings
        )

        return CodexSourceHealthSnapshot(
            checkedAt: now,
            status: status,
            activeExecutablePath: activeCandidate?.url.path,
            versionSignals: signals,
            modelsCachePath: modelsCache.path,
            modelsCacheClientVersion: modelsCache.clientVersion,
            modelsCacheFetchedAt: modelsCache.fetchedAt,
            modelsCacheModelCount: modelsCache.modelCount,
            modelsCacheErrorText: modelsCache.errorText,
            versionMetadataPath: versionMetadata.path,
            versionMetadataLatestVersion: versionMetadata.latestVersion,
            versionMetadataLastCheckedAt: versionMetadata.lastCheckedAt,
            versionMetadataErrorText: versionMetadata.errorText,
            warnings: warnings,
            errorText: nil
        )
    }

    private func versionSignal(for candidate: CodexExecutableCandidate) async -> CodexSourceVersionSignal {
        let modifiedAt = (try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard fileManager.isExecutableFile(atPath: candidate.url.path) else {
            return CodexSourceVersionSignal(
                kind: candidate.kind,
                executablePath: candidate.url.path,
                version: nil,
                fileModifiedAt: modifiedAt,
                errorText: "Missing or not executable."
            )
        }

        do {
            let output = try await commandRunner.versionOutput(for: candidate.url, timeout: commandTimeout)
            guard let version = Self.parseVersion(from: output) else {
                return CodexSourceVersionSignal(
                    kind: candidate.kind,
                    executablePath: candidate.url.path,
                    version: nil,
                    fileModifiedAt: modifiedAt,
                    errorText: CodexSourceHealthReaderError.versionOutputMalformed.localizedDescription
                )
            }

            return CodexSourceVersionSignal(
                kind: candidate.kind,
                executablePath: candidate.url.path,
                version: version,
                fileModifiedAt: modifiedAt,
                errorText: nil
            )
        } catch let error as CodexSourceHealthReaderError {
            return CodexSourceVersionSignal(
                kind: candidate.kind,
                executablePath: candidate.url.path,
                version: nil,
                fileModifiedAt: modifiedAt,
                errorText: error.localizedDescription
            )
        } catch {
            return CodexSourceVersionSignal(
                kind: candidate.kind,
                executablePath: candidate.url.path,
                version: nil,
                fileModifiedAt: modifiedAt,
                errorText: CodexSourceHealthReaderError.versionCommandFailed.localizedDescription
            )
        }
    }

    private struct ModelsCacheMetadata {
        let path: String
        let clientVersion: String?
        let fetchedAt: Date?
        let modelCount: Int?
        let errorText: String?
    }

    private struct VersionMetadata {
        let path: String
        let latestVersion: String?
        let lastCheckedAt: Date?
        let errorText: String?
    }

    private func readModelsCacheMetadata() -> ModelsCacheMetadata {
        let fileURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("models_cache.json")
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ModelsCacheMetadata(path: fileURL.path, clientVersion: nil, fetchedAt: nil, modelCount: nil, errorText: "Missing.")
        }

        do {
            let data = try Data(contentsOf: fileURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ModelsCacheMetadata(path: fileURL.path, clientVersion: nil, fetchedAt: nil, modelCount: nil, errorText: "Malformed JSON.")
            }

            let clientVersion = root["client_version"] as? String
            let fetchedAt = (root["fetched_at"] as? String).flatMap(Self.isoDate)
            let modelCount = (root["models"] as? [[String: Any]])?.count
            return ModelsCacheMetadata(path: fileURL.path, clientVersion: clientVersion, fetchedAt: fetchedAt, modelCount: modelCount, errorText: nil)
        } catch {
            return ModelsCacheMetadata(path: fileURL.path, clientVersion: nil, fetchedAt: nil, modelCount: nil, errorText: "Malformed JSON.")
        }
    }

    private func readVersionMetadata() -> VersionMetadata {
        let fileURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("version.json")
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return VersionMetadata(path: fileURL.path, latestVersion: nil, lastCheckedAt: nil, errorText: "Missing.")
        }

        do {
            let data = try Data(contentsOf: fileURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return VersionMetadata(path: fileURL.path, latestVersion: nil, lastCheckedAt: nil, errorText: "Malformed JSON.")
            }

            let latestVersion = root["latest_version"] as? String
            let lastCheckedAt = (root["last_checked_at"] as? String).flatMap(Self.isoDate)
            return VersionMetadata(path: fileURL.path, latestVersion: latestVersion, lastCheckedAt: lastCheckedAt, errorText: nil)
        } catch {
            return VersionMetadata(path: fileURL.path, latestVersion: nil, lastCheckedAt: nil, errorText: "Malformed JSON.")
        }
    }

    private func warnings(
        now: Date,
        activeCandidate: CodexExecutableCandidate?,
        signals: [CodexSourceVersionSignal],
        modelsCache: ModelsCacheMetadata,
        versionMetadata: VersionMetadata
    ) -> [String] {
        var warnings: [String] = []

        if activeCandidate == nil {
            warnings.append("No executable Codex source was found.")
        }

        let versionPairs = versionPairs(signals: signals, modelsCache: modelsCache, versionMetadata: versionMetadata)
        let distinctVersions = Set(versionPairs.map(\.version))
        if distinctVersions.count > 1 {
            let sourceList = versionPairs.map { "\($0.label) \($0.version)" }.joined(separator: ", ")
            warnings.append("Codex version signals differ: \(sourceList).")
        }

        if isStale(modelsCache.fetchedAt, now: now) {
            warnings.append("models_cache.json has not been fetched recently.")
        }

        if isStale(versionMetadata.lastCheckedAt, now: now) {
            warnings.append("version.json update metadata is stale.")
        }

        if modelsCache.errorText == "Malformed JSON." || versionMetadata.errorText == "Malformed JSON." {
            warnings.append("One or more Codex metadata files are malformed.")
        }

        return warnings
    }

    private func status(
        activeCandidate: CodexExecutableCandidate?,
        signals: [CodexSourceVersionSignal],
        modelsCache: ModelsCacheMetadata,
        versionMetadata: VersionMetadata,
        warnings: [String]
    ) -> CodexSourceHealthStatus {
        if activeCandidate == nil {
            return .missing
        }

        if let activeCandidate,
           signals.contains(where: { $0.executablePath == activeCandidate.url.path && $0.version == nil })
        {
            return .failed
        }

        if modelsCache.errorText == "Malformed JSON." || versionMetadata.errorText == "Malformed JSON." {
            return .malformed
        }

        if Set(versionPairs(signals: signals, modelsCache: modelsCache, versionMetadata: versionMetadata).map(\.version)).count > 1 {
            return .mismatch
        }

        if warnings.contains(where: { $0.contains("stale") || $0.contains("not been fetched recently") }) {
            return .stale
        }

        return .healthy
    }

    private func versionPairs(
        signals: [CodexSourceVersionSignal],
        modelsCache: ModelsCacheMetadata,
        versionMetadata: VersionMetadata
    ) -> [(label: String, version: String)] {
        var pairs: [(String, String)] = signals.compactMap { signal in
            guard let version = signal.version else {
                return nil
            }
            return (signal.kind.displayTitle, version)
        }

        if let clientVersion = modelsCache.clientVersion.flatMap(Self.parseVersion(from:)) {
            pairs.append(("models cache", clientVersion))
        }

        if let latestVersion = versionMetadata.latestVersion.flatMap(Self.parseVersion(from:)) {
            pairs.append(("version.json", latestVersion))
        }

        return pairs
    }

    private func isStale(_ date: Date?, now: Date) -> Bool {
        guard let date else {
            return false
        }

        return now.timeIntervalSince(date) >= metadataStalenessInterval
    }

    static func parseVersion(from output: String) -> String? {
        let pattern = #"\d+(?:\.[0-9A-Za-z-]+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let versionRange = Range(match.range, in: output)
        else {
            return nil
        }

        return String(output[versionRange])
    }

    private static func isoDate(from string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        return ISO8601DateFormatter().date(from: string)
    }
}

@MainActor
final class CodexSourceHealthStore: ObservableObject {
    static let defaultCacheDuration = CodexSourceHealthDefaults.cacheDuration
    static let defaultMetadataStalenessInterval = CodexSourceHealthDefaults.metadataStalenessInterval

    @Published private(set) var state: CodexSourceHealthState

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        state = (try? Self.loadState(from: fileURL)) ?? CodexSourceHealthState()
    }

    static let shared = CodexSourceHealthStore.applicationSupportStore()

    static func applicationSupportStore() -> CodexSourceHealthStore {
        let directoryURL = (try? UsageHistoryStore.applicationSupportDirectoryURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CodexStatusBar", isDirectory: true)
        return CodexSourceHealthStore(
            fileURL: directoryURL.appendingPathComponent("codex-source-health.json")
        )
    }

    @discardableResult
    func refresh(
        reader: CodexSourceHealthReading = CodexSourceHealthReader(),
        now: Date = Date()
    ) async -> CodexSourceHealthState {
        do {
            let snapshot = try await reader.sourceHealthSnapshot(now: now)
            state = CodexSourceHealthState(
                snapshot: snapshot,
                status: snapshot.status,
                lastCheckedAt: snapshot.checkedAt,
                lastErrorText: snapshot.errorText
            )
            persist()
        } catch {
            state = CodexSourceHealthState(
                snapshot: state.snapshot,
                status: .failed,
                lastCheckedAt: now,
                lastErrorText: "Codex source health could not be refreshed."
            )
            persist()
        }

        return state
    }

    @discardableResult
    func refreshIfStale(
        reader: CodexSourceHealthReading = CodexSourceHealthReader(),
        now: Date = Date(),
        staleAfter: TimeInterval = defaultCacheDuration
    ) async -> CodexSourceHealthState {
        guard state.isStale(now: now, staleAfter: staleAfter) else {
            return state
        }

        return await refresh(reader: reader, now: now)
    }

    func clear() {
        state = CodexSourceHealthState()
        try? fileManager.removeItem(at: fileURL)
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            // Version/source diagnostics must never affect the menu or dashboards.
        }
    }

    private static func loadState(from fileURL: URL) throws -> CodexSourceHealthState {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexSourceHealthState.self, from: data)
    }
}

enum CodexTokenPayloadAuditor {
    private struct FieldSpec {
        let keyPath: String
        let paths: [[String]]
        let category: CodexTokenPayloadAuditCategory
        let normalizer: FieldNormalizer

        init(
            _ keyPath: String,
            paths: [[String]]? = nil,
            category: CodexTokenPayloadAuditCategory,
            normalizer: FieldNormalizer
        ) {
            self.keyPath = keyPath
            self.paths = paths ?? [keyPath.split(separator: ".").map(String.init)]
            self.category = category
            self.normalizer = normalizer
        }
    }

    private enum FieldNormalizer {
        case identifier
        case model
        case projectPath
        case source
        case dimension(TokenUsageDimensionKey)
        case mode
        case booleanDimension(TokenUsageDimensionKey)
        case integerDimension(TokenUsageDimensionKey)
        case flexibleDimension(TokenUsageDimensionKey)
        case objectSummary
    }

    private static let fieldSpecs: [FieldSpec] = [
        FieldSpec("threadId", paths: [["threadId"], ["thread_id"]], category: .identifier, normalizer: .identifier),
        FieldSpec("turnId", paths: [["turnId"], ["turn_id"]], category: .identifier, normalizer: .identifier),

        FieldSpec("model", category: .model, normalizer: .model),
        FieldSpec("slug", category: .model, normalizer: .model),
        FieldSpec("modelSlug", paths: [["modelSlug"], ["model_slug"]], category: .model, normalizer: .model),
        FieldSpec("tokenUsage.model", paths: [["tokenUsage", "model"], ["token_usage", "model"]], category: .model, normalizer: .model),
        FieldSpec("tokenUsage.slug", paths: [["tokenUsage", "slug"], ["token_usage", "slug"]], category: .model, normalizer: .model),
        FieldSpec("tokenUsage.modelSlug", paths: [["tokenUsage", "modelSlug"], ["token_usage", "modelSlug"], ["tokenUsage", "model_slug"], ["token_usage", "model_slug"]], category: .model, normalizer: .model),
        FieldSpec("tokenUsage.info.model", paths: [["tokenUsage", "info", "model"], ["token_usage", "info", "model"]], category: .model, normalizer: .model),
        FieldSpec("tokenUsage.info.slug", paths: [["tokenUsage", "info", "slug"], ["token_usage", "info", "slug"]], category: .model, normalizer: .model),
        FieldSpec("tokenUsage.info.modelSlug", paths: [["tokenUsage", "info", "modelSlug"], ["token_usage", "info", "modelSlug"], ["tokenUsage", "info", "model_slug"], ["token_usage", "info", "model_slug"]], category: .model, normalizer: .model),

        FieldSpec("cwd", category: .project, normalizer: .projectPath),
        FieldSpec("projectPath", paths: [["projectPath"], ["project_path"]], category: .project, normalizer: .projectPath),
        FieldSpec("projectName", paths: [["projectName"], ["project_name"]], category: .project, normalizer: .identifier),
        FieldSpec("tokenUsage.info.cwd", paths: [["tokenUsage", "info", "cwd"], ["token_usage", "info", "cwd"]], category: .project, normalizer: .projectPath),
        FieldSpec("tokenUsage.info.projectPath", paths: [["tokenUsage", "info", "projectPath"], ["token_usage", "info", "project_path"]], category: .project, normalizer: .projectPath),
        FieldSpec("tokenUsage.info.projectName", paths: [["tokenUsage", "info", "projectName"], ["token_usage", "info", "project_name"]], category: .project, normalizer: .identifier),

        FieldSpec("effort", category: .effort, normalizer: .identifier),
        FieldSpec("reasoningEffort", paths: [["reasoningEffort"], ["reasoning_effort"]], category: .effort, normalizer: .identifier),
        FieldSpec("collaborationMode.settings.reasoningEffort", paths: [["collaborationMode", "settings", "reasoningEffort"], ["collaboration_mode", "settings", "reasoning_effort"]], category: .effort, normalizer: .identifier),
        FieldSpec("tokenUsage.info.effort", paths: [["tokenUsage", "info", "effort"], ["token_usage", "info", "effort"]], category: .effort, normalizer: .identifier),
        FieldSpec("tokenUsage.info.reasoningEffort", paths: [["tokenUsage", "info", "reasoningEffort"], ["token_usage", "info", "reasoning_effort"]], category: .effort, normalizer: .identifier),

        FieldSpec("source", category: .source, normalizer: .source),
        FieldSpec("sourceKind", paths: [["sourceKind"], ["source_kind"]], category: .source, normalizer: .dimension(.sourceKind)),
        FieldSpec("originator", category: .source, normalizer: .dimension(.originator)),
        FieldSpec("threadSource", paths: [["threadSource"], ["thread_source"]], category: .source, normalizer: .dimension(.threadSource)),
        FieldSpec("tokenUsage.info.source", paths: [["tokenUsage", "info", "source"], ["token_usage", "info", "source"]], category: .source, normalizer: .source),
        FieldSpec("tokenUsage.info.sourceKind", paths: [["tokenUsage", "info", "sourceKind"], ["token_usage", "info", "source_kind"]], category: .source, normalizer: .dimension(.sourceKind)),
        FieldSpec("tokenUsage.info.originator", paths: [["tokenUsage", "info", "originator"], ["token_usage", "info", "originator"]], category: .source, normalizer: .dimension(.originator)),
        FieldSpec("tokenUsage.info.threadSource", paths: [["tokenUsage", "info", "threadSource"], ["token_usage", "info", "thread_source"]], category: .source, normalizer: .dimension(.threadSource)),

        FieldSpec("cliVersion", paths: [["cliVersion"], ["cli_version"]], category: .appSession, normalizer: .dimension(.cliVersion)),
        FieldSpec("modelProvider", paths: [["modelProvider"], ["model_provider"]], category: .appSession, normalizer: .dimension(.modelProvider)),
        FieldSpec("memoryMode", paths: [["memoryMode"], ["memory_mode"]], category: .appSession, normalizer: .dimension(.memoryMode)),
        FieldSpec("tokenUsage.info.cliVersion", paths: [["tokenUsage", "info", "cliVersion"], ["token_usage", "info", "cli_version"]], category: .appSession, normalizer: .dimension(.cliVersion)),
        FieldSpec("tokenUsage.info.modelProvider", paths: [["tokenUsage", "info", "modelProvider"], ["token_usage", "info", "model_provider"]], category: .appSession, normalizer: .dimension(.modelProvider)),
        FieldSpec("tokenUsage.info.memoryMode", paths: [["tokenUsage", "info", "memoryMode"], ["token_usage", "info", "memory_mode"]], category: .appSession, normalizer: .dimension(.memoryMode)),

        FieldSpec("approvalPolicy", paths: [["approvalPolicy"], ["approval_policy"]], category: .runtimePolicy, normalizer: .flexibleDimension(.approvalPolicy)),
        FieldSpec("sandboxPolicy", paths: [["sandboxPolicy"], ["sandbox_policy"]], category: .runtimePolicy, normalizer: .flexibleDimension(.sandboxType)),
        FieldSpec("sandboxPolicy.type", paths: [["sandboxPolicy", "type"], ["sandbox_policy", "type"]], category: .runtimePolicy, normalizer: .dimension(.sandboxType)),
        FieldSpec("permissionProfile", paths: [["permissionProfile"], ["permission_profile"]], category: .runtimePolicy, normalizer: .flexibleDimension(.permissionProfile)),
        FieldSpec("truncationPolicy", paths: [["truncationPolicy"], ["truncation_policy"]], category: .runtimePolicy, normalizer: .flexibleDimension(.truncationPolicy)),
        FieldSpec("realtimeActive", paths: [["realtimeActive"], ["realtime_active"]], category: .runtimePolicy, normalizer: .booleanDimension(.realtimeActive)),
        FieldSpec("tokenUsage.info.approvalPolicy", paths: [["tokenUsage", "info", "approvalPolicy"], ["token_usage", "info", "approval_policy"]], category: .runtimePolicy, normalizer: .flexibleDimension(.approvalPolicy)),
        FieldSpec("tokenUsage.info.sandboxPolicy", paths: [["tokenUsage", "info", "sandboxPolicy"], ["token_usage", "info", "sandbox_policy"]], category: .runtimePolicy, normalizer: .flexibleDimension(.sandboxType)),
        FieldSpec("tokenUsage.info.sandboxPolicy.type", paths: [["tokenUsage", "info", "sandboxPolicy", "type"], ["token_usage", "info", "sandbox_policy", "type"]], category: .runtimePolicy, normalizer: .dimension(.sandboxType)),
        FieldSpec("tokenUsage.info.permissionProfile", paths: [["tokenUsage", "info", "permissionProfile"], ["token_usage", "info", "permission_profile"]], category: .runtimePolicy, normalizer: .flexibleDimension(.permissionProfile)),
        FieldSpec("tokenUsage.info.truncationPolicy", paths: [["tokenUsage", "info", "truncationPolicy"], ["token_usage", "info", "truncation_policy"]], category: .runtimePolicy, normalizer: .flexibleDimension(.truncationPolicy)),
        FieldSpec("tokenUsage.info.realtimeActive", paths: [["tokenUsage", "info", "realtimeActive"], ["token_usage", "info", "realtime_active"]], category: .runtimePolicy, normalizer: .booleanDimension(.realtimeActive)),

        FieldSpec("usageMode", paths: [["usageMode"], ["usage_mode"]], category: .usageMode, normalizer: .mode),
        FieldSpec("speedMode", paths: [["speedMode"], ["speed_mode"]], category: .usageMode, normalizer: .mode),
        FieldSpec("mode", category: .usageMode, normalizer: .mode),
        FieldSpec("tokenUsage.usageMode", paths: [["tokenUsage", "usageMode"], ["token_usage", "usage_mode"]], category: .usageMode, normalizer: .mode),
        FieldSpec("tokenUsage.speedMode", paths: [["tokenUsage", "speedMode"], ["token_usage", "speed_mode"]], category: .usageMode, normalizer: .mode),
        FieldSpec("tokenUsage.mode", paths: [["tokenUsage", "mode"], ["token_usage", "mode"]], category: .usageMode, normalizer: .mode),
        FieldSpec("tokenUsage.info.usageMode", paths: [["tokenUsage", "info", "usageMode"], ["token_usage", "info", "usage_mode"]], category: .usageMode, normalizer: .mode),
        FieldSpec("tokenUsage.info.speedMode", paths: [["tokenUsage", "info", "speedMode"], ["token_usage", "info", "speed_mode"]], category: .usageMode, normalizer: .mode),
        FieldSpec("tokenUsage.info.mode", paths: [["tokenUsage", "info", "mode"], ["token_usage", "info", "mode"]], category: .usageMode, normalizer: .mode),

        FieldSpec("source.subagent.thread_spawn.parent_thread_id", category: .subagent, normalizer: .dimension(.subagentParentThreadID)),
        FieldSpec("source.subagent.thread_spawn.depth", category: .subagent, normalizer: .integerDimension(.subagentDepth)),
        FieldSpec("source.subagent.thread_spawn.agent_role", category: .subagent, normalizer: .dimension(.agentRole)),
        FieldSpec("source.subagent.thread_spawn.agent_nickname", category: .subagent, normalizer: .dimension(.agentNickname)),
    ]

    static func audit(params: Any, capturedAt: Date = Date()) -> CodexTokenUsagePayloadAudit? {
        guard let object = params as? [String: Any] else {
            return nil
        }

        let fields = fieldSpecs.map { field(in: object, spec: $0) }
        let threadID = normalizedString(at: [["threadId"], ["thread_id"]], in: object)
        let turnID = normalizedString(at: [["turnId"], ["turn_id"]], in: object)
        return CodexTokenUsagePayloadAudit(
            capturedAt: capturedAt,
            threadID: threadID,
            turnID: turnID,
            fields: fields
        )
    }

    private static func field(in object: [String: Any], spec: FieldSpec) -> CodexTokenPayloadAuditField {
        guard let rawValue = value(at: spec.paths, in: object) else {
            return CodexTokenPayloadAuditField(
                keyPath: spec.keyPath,
                category: spec.category,
                presence: .missing,
                valueKind: nil,
                sanitizedValue: nil,
                normalizedValue: nil,
                dimensionKey: nil,
                dimensionValue: nil,
                notes: []
            )
        }

        let result = normalize(rawValue, with: spec.normalizer)
        return CodexTokenPayloadAuditField(
            keyPath: spec.keyPath,
            category: spec.category,
            presence: result.presence,
            valueKind: valueKind(rawValue),
            sanitizedValue: result.sanitizedValue,
            normalizedValue: result.normalizedValue,
            dimensionKey: result.dimension?.key,
            dimensionValue: result.dimension?.value,
            notes: result.notes
        )
    }

    private struct NormalizationResult {
        let presence: CodexTokenPayloadAuditPresence
        let sanitizedValue: String?
        let normalizedValue: String?
        let dimension: TokenUsageDimension?
        let notes: [String]
    }

    private static func normalize(_ rawValue: Any, with normalizer: FieldNormalizer) -> NormalizationResult {
        switch normalizer {
        case .identifier:
            return normalizedScalar(rawValue) { CodexTokenContextNormalizer.normalizedIdentifier($0) }
        case .model:
            return normalizedScalar(rawValue) { CodexModelIdentifier.normalized($0) }
        case .projectPath:
            return normalizedScalar(rawValue) { CodexTokenContextNormalizer.normalizedProjectPath($0) }
        case .source:
            if let object = rawValue as? [String: Any] {
                let hasSubagent = object["subagent"] is [String: Any]
                return NormalizationResult(
                    presence: hasSubagent ? .present : .unsupported,
                    sanitizedValue: nil,
                    normalizedValue: hasSubagent ? "subagent" : nil,
                    dimension: hasSubagent ? TokenUsageDimension(.sourceKind, "subagent") : nil,
                    notes: hasSubagent ? ["Object source captured through source.subagent.* fields."] : ["Object source shape has no allowlisted attribution fields."]
                )
            }
            return normalizedDimension(rawValue, key: .sourceKind)
        case .dimension(let key):
            return normalizedDimension(rawValue, key: key)
        case .mode:
            let stringValue = scalarString(rawValue)
            let dimension = TokenUsageDimension(.usageMode, stringValue)
            return resultForScalar(
                rawValue: rawValue,
                sanitizedValue: stringValue,
                normalizedValue: dimension?.value,
                dimension: dimension
            )
        case .booleanDimension(let key):
            guard let boolValue = rawValue as? Bool else {
                return NormalizationResult(
                    presence: .unsupported,
                    sanitizedValue: nil,
                    normalizedValue: nil,
                    dimension: nil,
                    notes: ["Expected a boolean value."]
                )
            }
            let dimension = TokenUsageDimension.boolean(key, boolValue)
            return NormalizationResult(
                presence: dimension == nil ? .rejected : .present,
                sanitizedValue: boolValue ? "true" : "false",
                normalizedValue: dimension?.value,
                dimension: dimension,
                notes: dimension == nil ? ["Value rejected by safe normalizer."] : []
            )
        case .integerDimension(let key):
            guard let intValue = rawValue as? Int else {
                return NormalizationResult(
                    presence: .unsupported,
                    sanitizedValue: nil,
                    normalizedValue: nil,
                    dimension: nil,
                    notes: ["Expected an integer value."]
                )
            }
            let dimension = TokenUsageDimension.integer(key, intValue)
            return NormalizationResult(
                presence: dimension == nil ? .rejected : .present,
                sanitizedValue: "\(intValue)",
                normalizedValue: dimension?.value,
                dimension: dimension,
                notes: dimension == nil ? ["Value rejected by safe normalizer."] : []
            )
        case .flexibleDimension(let key):
            let extractedValue = flexibleString(rawValue)
            return normalizedDimension(extractedValue as Any, key: key)
        case .objectSummary:
            return NormalizationResult(
                presence: .unsupported,
                sanitizedValue: nil,
                normalizedValue: nil,
                dimension: nil,
                notes: ["Object shape is only audited through allowlisted child fields."]
            )
        }
    }

    private static func normalizedDimension(_ rawValue: Any, key: TokenUsageDimensionKey) -> NormalizationResult {
        let stringValue = scalarString(rawValue)
        let dimension = TokenUsageDimension(key, stringValue)
        return resultForScalar(
            rawValue: rawValue,
            sanitizedValue: stringValue,
            normalizedValue: dimension?.value,
            dimension: dimension
        )
    }

    private static func normalizedScalar(
        _ rawValue: Any,
        normalize: (String?) -> String?
    ) -> NormalizationResult {
        let stringValue = scalarString(rawValue)
        return resultForScalar(
            rawValue: rawValue,
            sanitizedValue: stringValue,
            normalizedValue: normalize(stringValue),
            dimension: nil
        )
    }

    private static func resultForScalar(
        rawValue: Any,
        sanitizedValue: String?,
        normalizedValue: String?,
        dimension: TokenUsageDimension?
    ) -> NormalizationResult {
        guard sanitizedValue != nil else {
            return NormalizationResult(
                presence: .unsupported,
                sanitizedValue: nil,
                normalizedValue: nil,
                dimension: nil,
                notes: ["Expected a scalar safe value."]
            )
        }

        guard normalizedValue != nil || dimension != nil else {
            return NormalizationResult(
                presence: .rejected,
                sanitizedValue: nil,
                normalizedValue: nil,
                dimension: nil,
                notes: ["Value rejected by safe normalizer."]
            )
        }

        return NormalizationResult(
            presence: .present,
            sanitizedValue: sanitizedValue,
            normalizedValue: normalizedValue,
            dimension: dimension,
            notes: []
        )
    }

    private static func scalarString(_ rawValue: Any) -> String? {
        switch rawValue {
        case let string as String:
            return string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return "\(int)"
        case let int64 as Int64:
            return "\(int64)"
        case let double as Double where double.isFinite:
            return double.rounded() == double ? "\(Int64(double))" : "\(double)"
        default:
            return nil
        }
    }

    private static func flexibleString(_ rawValue: Any) -> String? {
        if let scalar = scalarString(rawValue) {
            return scalar
        }

        guard let object = rawValue as? [String: Any] else {
            return nil
        }

        return ["type", "mode", "value", "name"].lazy.compactMap { key in
            scalarString(object[key] as Any)
        }.first
    }

    private static func normalizedString(at paths: [[String]], in object: [String: Any]) -> String? {
        value(at: paths, in: object)
            .flatMap(scalarString)
            .flatMap(CodexTokenContextNormalizer.normalizedIdentifier)
    }

    private static func value(at paths: [[String]], in object: [String: Any]) -> Any? {
        for path in paths {
            var current: Any = object
            var found = true
            for component in path {
                guard let dictionary = current as? [String: Any],
                      let next = dictionary[component]
                else {
                    found = false
                    break
                }
                current = next
            }

            if found {
                return current
            }
        }

        return nil
    }

    private static func valueKind(_ rawValue: Any) -> String {
        switch rawValue {
        case is String:
            return "string"
        case is Bool:
            return "boolean"
        case is Int, is Int64, is Double:
            return "number"
        case is [String: Any]:
            return "object"
        case is [Any]:
            return "array"
        case is NSNull:
            return "null"
        default:
            return "unknown"
        }
    }
}

enum CodexUsageDiagnosticsReviewer {
    private static let minimumCaptureCount = 3
    private static let movementTolerance = 1

    static func review(_ snapshots: [CodexUsageDiagnosticsSnapshot]) -> CodexUsageDiagnosticsReview {
        let sortedSnapshots = snapshots.sorted { $0.generatedAt < $1.generatedAt }
        let summaries = UsageLimitWindow.allCases.map { window in
            review(window: window, snapshots: sortedSnapshots)
        }
        let classification = CodexUsageDiagnosticsSnapshot.overallClassification(from: summaries)
        let notes = if sortedSnapshots.count < minimumCaptureCount {
            ["At least 3 diagnostics captures are required before changing chart semantics."]
        } else {
            summaries.flatMap(\.notes)
        }

        return CodexUsageDiagnosticsReview(
            captureCount: sortedSnapshots.count,
            classification: classification,
            summaries: summaries,
            notes: notes
        )
    }

    private static func review(
        window: UsageLimitWindow,
        snapshots: [CodexUsageDiagnosticsSnapshot]
    ) -> CodexUsageDiagnosticsReviewWindowSummary {
        guard snapshots.count >= minimumCaptureCount else {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .inconclusive,
                notes: ["At least 3 diagnostics captures are required for \(window.displayTitle)."]
            )
        }

        let observations = snapshots.compactMap { snapshot in
            observation(in: snapshot, window: window)
        }

        guard observations.count == snapshots.count else {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .inconclusive,
                notes: ["One or more captures are missing aggregate or model data for \(window.displayTitle)."]
            )
        }

        if observations.contains(where: { !$0.durationsAligned }) {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .independentLikely,
                notes: ["One or more \(window.displayTitle) captures have model durations that differ from aggregate."]
            )
        }

        if observations.contains(where: { !$0.resetsAligned }) {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .independentLikely,
                notes: ["One or more \(window.displayTitle) captures have model resets that differ from aggregate."]
            )
        }

        if observations.contains(where: { !$0.modelValuesWithinAggregate }) {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .independentLikely,
                notes: ["One or more \(window.displayTitle) captures have model percentages outside the aggregate value."]
            )
        }

        var movingDeltas: [(aggregateDelta: Int, modelDelta: Int)] = []
        for (current, previous) in zip(observations.dropFirst(), observations) {
            let aggregateDelta = current.aggregateUsedPercent - previous.aggregateUsedPercent
            let modelDelta = current.modelUsedPercentSum - previous.modelUsedPercentSum

            guard aggregateDelta != 0 || modelDelta != 0 else {
                continue
            }

            movingDeltas.append((aggregateDelta: aggregateDelta, modelDelta: modelDelta))
        }

        guard !movingDeltas.isEmpty else {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .inconclusive,
                notes: ["The \(window.displayTitle) captures do not include enough percentage movement."]
            )
        }

        guard movingDeltas.allSatisfy({ abs($0.aggregateDelta - $0.modelDelta) <= movementTolerance }) else {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .independentLikely,
                notes: ["The \(window.displayTitle) model deltas do not consistently explain aggregate deltas."]
            )
        }

        return CodexUsageDiagnosticsReviewWindowSummary(
            window: window,
            classification: .comparableCandidate,
            notes: ["The \(window.displayTitle) model deltas consistently explain aggregate deltas."]
        )
    }

    private static func observation(
        in snapshot: CodexUsageDiagnosticsSnapshot,
        window: UsageLimitWindow
    ) -> WindowObservation? {
        guard let summary = snapshot.summaries.first(where: { $0.window == window }),
              let aggregateUsedPercent = summary.aggregateUsedPercent,
              let modelUsedPercentSum = summary.modelUsedPercentSum,
              summary.modelBucketCount > 0
        else {
            return nil
        }

        return WindowObservation(
            aggregateUsedPercent: aggregateUsedPercent,
            modelUsedPercentSum: modelUsedPercentSum,
            durationsAligned: summary.durationsAligned,
            resetsAligned: summary.resetsAligned,
            modelValuesWithinAggregate: summary.modelValuesWithinAggregate
        )
    }

    private struct WindowObservation {
        let aggregateUsedPercent: Int
        let modelUsedPercentSum: Int
        let durationsAligned: Bool
        let resetsAligned: Bool
        let modelValuesWithinAggregate: Bool
    }
}

extension AccountRateLimitsResponse {
    func diagnosticsSnapshot(generatedAt: Date) -> CodexUsageDiagnosticsSnapshot {
        let buckets = diagnosticsBuckets()
        let summaries = UsageLimitWindow.allCases.map { window in
            CodexUsageDiagnosticsClassifier.summary(for: window, buckets: buckets)
        }

        return CodexUsageDiagnosticsSnapshot(
            generatedAt: generatedAt,
            buckets: buckets,
            summaries: summaries
        )
    }

    private func diagnosticsBuckets() -> [CodexUsageDiagnosticsBucket] {
        if let rateLimitsByLimitId, !rateLimitsByLimitId.isEmpty {
            return rateLimitsByLimitId
                .map { key, payload in
                    payload.toDiagnosticsBucket(fallbackId: key)
                }
                .sortedByDiagnosticsOrder()
        }

        return [
            rateLimits.toDiagnosticsBucket(fallbackId: rateLimits.limitId ?? "codex"),
        ]
    }
}

private extension CodexUsageDiagnosticsSnapshot {
    static func overallClassification(
        from summaries: [CodexUsageDiagnosticsReviewWindowSummary]
    ) -> CodexUsageDiagnosticsClassification {
        if summaries.contains(where: { $0.classification == .independentLikely }) {
            return .independentLikely
        }

        if !summaries.isEmpty, summaries.allSatisfy({ $0.classification == .comparableCandidate }) {
            return .comparableCandidate
        }

        return .inconclusive
    }
}

private enum CodexUsageDiagnosticsClassifier {
    private static let resetAlignmentTolerance: TimeInterval = 60

    static func summary(
        for window: UsageLimitWindow,
        buckets: [CodexUsageDiagnosticsBucket]
    ) -> CodexUsageDiagnosticsWindowSummary {
        let aggregateBucket = buckets.first { $0.kind == .aggregate }
        let modelBuckets = buckets.filter { $0.kind == .model }
        let aggregateWindow = aggregateBucket?.window(for: window)
        let modelWindows = modelBuckets.compactMap { bucket -> CodexUsageDiagnosticsWindow? in
            bucket.window(for: window)
        }
        let modelUsedPercentSum = modelWindows.isEmpty ? nil : modelWindows.reduce(0) { $0 + $1.usedPercent }

        guard let aggregateWindow else {
            return CodexUsageDiagnosticsWindowSummary(
                window: window,
                classification: .inconclusive,
                aggregateBucketID: nil,
                aggregateUsedPercent: nil,
                modelBucketCount: modelWindows.count,
                modelUsedPercentSum: modelUsedPercentSum,
                durationsAligned: false,
                resetsAligned: false,
                modelValuesWithinAggregate: false,
                notes: ["No aggregate bucket was available for this window."]
            )
        }

        guard !modelWindows.isEmpty else {
            return CodexUsageDiagnosticsWindowSummary(
                window: window,
                classification: .inconclusive,
                aggregateBucketID: aggregateBucket?.id,
                aggregateUsedPercent: aggregateWindow.usedPercent,
                modelBucketCount: 0,
                modelUsedPercentSum: nil,
                durationsAligned: true,
                resetsAligned: true,
                modelValuesWithinAggregate: true,
                notes: ["No model buckets were available for this window."]
            )
        }

        let durationsAligned = modelWindows.allSatisfy {
            $0.windowDurationMinutes == aggregateWindow.windowDurationMinutes
        }
        let resetsAligned = modelWindows.allSatisfy {
            resetDatesAreAligned(aggregateWindow.resetsAt, $0.resetsAt)
        }
        let modelValuesWithinAggregate = modelWindows.allSatisfy {
            $0.usedPercent <= aggregateWindow.usedPercent
        } && (modelUsedPercentSum ?? 0) <= aggregateWindow.usedPercent

        let classification: CodexUsageDiagnosticsClassification
        var notes: [String] = []

        if !durationsAligned {
            notes.append("One or more model buckets use a different window duration than the aggregate bucket.")
        }

        if !resetsAligned {
            notes.append("One or more model buckets reset at a different time than the aggregate bucket.")
        }

        if !modelValuesWithinAggregate {
            notes.append("Model bucket percentages do not fit within the aggregate used percentage.")
        }

        if durationsAligned && resetsAligned && modelValuesWithinAggregate {
            classification = .comparableCandidate
            notes.append("Model buckets align with the aggregate bucket for this single captured sample.")
        } else {
            classification = .independentLikely
        }

        return CodexUsageDiagnosticsWindowSummary(
            window: window,
            classification: classification,
            aggregateBucketID: aggregateBucket?.id,
            aggregateUsedPercent: aggregateWindow.usedPercent,
            modelBucketCount: modelWindows.count,
            modelUsedPercentSum: modelUsedPercentSum,
            durationsAligned: durationsAligned,
            resetsAligned: resetsAligned,
            modelValuesWithinAggregate: modelValuesWithinAggregate,
            notes: notes
        )
    }

    private static func resetDatesAreAligned(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.some(let lhs), .some(let rhs)):
            return abs(lhs.timeIntervalSince(rhs)) <= resetAlignmentTolerance
        default:
            return false
        }
    }
}

private extension RateLimitSnapshotPayload {
    func toDiagnosticsBucket(fallbackId: String) -> CodexUsageDiagnosticsBucket {
        let resolvedId = limitId ?? fallbackId
        let kind: CodexUsageBucketKind = isMainCodexBucket ? .aggregate : .model
        let resolvedName = if kind == .aggregate {
            "All models"
        } else {
            limitName ?? resolvedId
        }

        return CodexUsageDiagnosticsBucket(
            id: resolvedId,
            name: resolvedName,
            kind: kind,
            planType: planType,
            primary: primary?.toDiagnosticsWindow(),
            secondary: secondary?.toDiagnosticsWindow()
        )
    }
}

private extension RateLimitWindowPayload {
    func toDiagnosticsWindow() -> CodexUsageDiagnosticsWindow {
        CodexUsageDiagnosticsWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMins,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private extension CodexUsageDiagnosticsBucket {
    func window(for usageWindow: UsageLimitWindow) -> CodexUsageDiagnosticsWindow? {
        switch usageWindow {
        case .fiveHour:
            return primary
        case .sevenDay:
            return secondary
        }
    }
}

private extension Array where Element == CodexUsageDiagnosticsBucket {
    func sortedByDiagnosticsOrder() -> [CodexUsageDiagnosticsBucket] {
        sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .aggregate
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
