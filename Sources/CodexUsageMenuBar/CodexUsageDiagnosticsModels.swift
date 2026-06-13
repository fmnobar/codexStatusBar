import Combine
import Foundation
import SQLite3

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

enum CodexRemoteControlStatus: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
    case connecting
    case connected
    case disconnected
    case error
    case failed

    var displayText: String {
        switch self {
        case .enabled:
            return "Enabled"
        case .disabled:
            return "Disabled"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .error:
            return "Error"
        case .failed:
            return "Failed"
        }
    }

    var isWarning: Bool {
        switch self {
        case .error, .failed:
            return true
        case .enabled, .disabled, .connecting, .connected, .disconnected:
            return false
        }
    }
}

enum CodexRemoteControlHealthStatus: String, Codable, Equatable, Sendable {
    case neverChecked = "never_checked"
    case available
    case missingDatabase = "missing_database"
    case missingTable = "missing_table"
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            return "Not checked"
        case .available:
            return "Available"
        case .missingDatabase:
            return "No state database"
        case .missingTable:
            return "No enrollment table"
        case .failed:
            return "Failed"
        }
    }
}

struct CodexRemoteControlHealthSnapshot: Codable, Equatable, Sendable {
    let checkedAt: Date
    let status: CodexRemoteControlHealthStatus
    let enrollmentCount: Int?
    let latestEnrollmentUpdatedAt: Date?
    let errorText: String?

    init(
        checkedAt: Date,
        status: CodexRemoteControlHealthStatus,
        enrollmentCount: Int? = nil,
        latestEnrollmentUpdatedAt: Date? = nil,
        errorText: String? = nil
    ) {
        self.checkedAt = checkedAt
        self.status = status
        self.enrollmentCount = enrollmentCount
        self.latestEnrollmentUpdatedAt = latestEnrollmentUpdatedAt
        self.errorText = errorText
    }
}

struct CodexRemoteControlDiagnostics: Codable, Equatable, Sendable {
    var notificationCount: Int
    var lastStatus: CodexRemoteControlStatus?
    var lastStatusUpdatedAt: Date?
    var lastWarningText: String?
    var enrollmentStatus: CodexRemoteControlHealthStatus
    var enrollmentLastCheckedAt: Date?
    var enrollmentCount: Int?
    var enrollmentLatestUpdatedAt: Date?
    var enrollmentErrorText: String?

    init(
        notificationCount: Int = 0,
        lastStatus: CodexRemoteControlStatus? = nil,
        lastStatusUpdatedAt: Date? = nil,
        lastWarningText: String? = nil,
        enrollmentStatus: CodexRemoteControlHealthStatus = .neverChecked,
        enrollmentLastCheckedAt: Date? = nil,
        enrollmentCount: Int? = nil,
        enrollmentLatestUpdatedAt: Date? = nil,
        enrollmentErrorText: String? = nil
    ) {
        self.notificationCount = notificationCount
        self.lastStatus = lastStatus
        self.lastStatusUpdatedAt = lastStatusUpdatedAt
        self.lastWarningText = lastWarningText
        self.enrollmentStatus = enrollmentStatus
        self.enrollmentLastCheckedAt = enrollmentLastCheckedAt
        self.enrollmentCount = enrollmentCount
        self.enrollmentLatestUpdatedAt = enrollmentLatestUpdatedAt
        self.enrollmentErrorText = enrollmentErrorText
    }

    var lastErrorText: String {
        enrollmentErrorText ?? lastWarningText ?? "None"
    }

    var popoverWarningText: String? {
        if lastStatus?.isWarning == true {
            return "Codex remote control reported \(lastStatus?.displayText.lowercased() ?? "an error")."
        }

        if enrollmentStatus == .failed {
            return "Remote-control diagnostics could not be refreshed."
        }

        if enrollmentStatus == .missingTable, notificationCount > 0 {
            return "Remote-control enrollment metadata is unavailable."
        }

        return nil
    }
}

struct CodexAppServerNotificationAuditRecord: Codable, Equatable, Sendable {
    let method: String
    let isSupported: Bool
    let safeValues: [String: String]
    let presenceFlags: [String]
    let rejectedUnsafeFieldCount: Int
    let unsupportedShapeCount: Int

    init(
        method: String,
        isSupported: Bool,
        safeValues: [String: String] = [:],
        presenceFlags: [String] = [],
        rejectedUnsafeFieldCount: Int = 0,
        unsupportedShapeCount: Int = 0
    ) {
        self.method = method
        self.isSupported = isSupported
        self.safeValues = safeValues
        self.presenceFlags = Array(Set(presenceFlags)).sorted()
        self.rejectedUnsafeFieldCount = rejectedUnsafeFieldCount
        self.unsupportedShapeCount = unsupportedShapeCount
    }

    var summaryText: String {
        if !safeValues.isEmpty {
            return safeValues
                .sorted { lhs, rhs in lhs.key < rhs.key }
                .prefix(4)
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
        }

        if !presenceFlags.isEmpty {
            return "Presence: \(presenceFlags.prefix(4).joined(separator: ", "))"
        }

        return isSupported ? "Presence counted" : "Unsupported method counted"
    }
}

struct CodexAppServerNotificationAuditMethodSummary: Codable, Equatable, Identifiable, Sendable {
    let method: String
    var count: Int
    var supportedCount: Int
    var unsupportedCount: Int
    var rejectedUnsafeFieldCount: Int
    var unsupportedShapeCount: Int
    var lastSeenAt: Date?
    var lastSummary: String?
    var lastSafeValues: [String: String]
    var lastPresenceFlags: [String]

    var id: String { method }

    init(
        method: String,
        count: Int = 0,
        supportedCount: Int = 0,
        unsupportedCount: Int = 0,
        rejectedUnsafeFieldCount: Int = 0,
        unsupportedShapeCount: Int = 0,
        lastSeenAt: Date? = nil,
        lastSummary: String? = nil,
        lastSafeValues: [String: String] = [:],
        lastPresenceFlags: [String] = []
    ) {
        self.method = method
        self.count = count
        self.supportedCount = supportedCount
        self.unsupportedCount = unsupportedCount
        self.rejectedUnsafeFieldCount = rejectedUnsafeFieldCount
        self.unsupportedShapeCount = unsupportedShapeCount
        self.lastSeenAt = lastSeenAt
        self.lastSummary = lastSummary
        self.lastSafeValues = lastSafeValues
        self.lastPresenceFlags = lastPresenceFlags
    }
}

struct CodexAppServerNotificationAuditSummary: Codable, Equatable, Sendable {
    static let maxMethodSummaries = 40

    var totalCount: Int
    var supportedCount: Int
    var unsupportedCount: Int
    var rejectedUnsafeFieldCount: Int
    var unsupportedShapeCount: Int
    var lastMethod: String?
    var lastAuditedAt: Date?
    var methods: [CodexAppServerNotificationAuditMethodSummary]

    init(
        totalCount: Int = 0,
        supportedCount: Int = 0,
        unsupportedCount: Int = 0,
        rejectedUnsafeFieldCount: Int = 0,
        unsupportedShapeCount: Int = 0,
        lastMethod: String? = nil,
        lastAuditedAt: Date? = nil,
        methods: [CodexAppServerNotificationAuditMethodSummary] = []
    ) {
        self.totalCount = totalCount
        self.supportedCount = supportedCount
        self.unsupportedCount = unsupportedCount
        self.rejectedUnsafeFieldCount = rejectedUnsafeFieldCount
        self.unsupportedShapeCount = unsupportedShapeCount
        self.lastMethod = lastMethod
        self.lastAuditedAt = lastAuditedAt
        self.methods = methods
    }

    mutating func record(_ record: CodexAppServerNotificationAuditRecord, at date: Date) {
        totalCount += 1
        if record.isSupported {
            supportedCount += 1
        } else {
            unsupportedCount += 1
        }
        rejectedUnsafeFieldCount += record.rejectedUnsafeFieldCount
        unsupportedShapeCount += record.unsupportedShapeCount
        lastMethod = record.method
        lastAuditedAt = date

        let index = methods.firstIndex { $0.method == record.method }
        var methodSummary = index.map { methods[$0] }
            ?? CodexAppServerNotificationAuditMethodSummary(method: record.method)
        methodSummary.count += 1
        if record.isSupported {
            methodSummary.supportedCount += 1
        } else {
            methodSummary.unsupportedCount += 1
        }
        methodSummary.rejectedUnsafeFieldCount += record.rejectedUnsafeFieldCount
        methodSummary.unsupportedShapeCount += record.unsupportedShapeCount
        methodSummary.lastSeenAt = date
        methodSummary.lastSummary = record.summaryText
        methodSummary.lastSafeValues = record.safeValues
        methodSummary.lastPresenceFlags = record.presenceFlags

        if let index {
            methods[index] = methodSummary
        } else {
            methods.append(methodSummary)
        }

        methods.sort { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return (lhs.lastSeenAt ?? .distantPast) > (rhs.lastSeenAt ?? .distantPast)
            }
            return lhs.method < rhs.method
        }

        if methods.count > Self.maxMethodSummaries {
            methods = Array(methods.prefix(Self.maxMethodSummaries))
        }
    }
}

enum CodexAppServerNotificationAuditSanitizer {
    private static let skippedMethods: Set<String> = [
        "account/rateLimits/updated",
        "remoteControl/status/changed",
        "thread/tokenUsage/updated",
    ]

    private static let supportedMethods: Set<String> = [
        "account/updated",
        "account/login/completed",
        "app/list/updated",
        "command/exec/outputDelta",
        "configWarning",
        "deprecationNotice",
        "error",
        "externalAgentConfig/import/completed",
        "fs/changed",
        "fuzzyFileSearch/sessionCompleted",
        "fuzzyFileSearch/sessionUpdated",
        "guardianWarning",
        "hook/completed",
        "hook/started",
        "item/agentMessage/delta",
        "item/autoApprovalReview/completed",
        "item/autoApprovalReview/started",
        "item/commandExecution/outputDelta",
        "item/commandExecution/terminalInteraction",
        "item/completed",
        "item/fileChange/outputDelta",
        "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress",
        "item/plan/delta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
        "item/started",
        "mcpServer/oauthLogin/completed",
        "mcpServer/startupStatus/updated",
        "model/rerouted",
        "model/verification",
        "process/exited",
        "process/outputDelta",
        "rawResponseItem/completed",
        "serverRequest/resolved",
        "skills/changed",
        "thread/archived",
        "thread/closed",
        "thread/compacted",
        "thread/goal/cleared",
        "thread/goal/updated",
        "thread/name/updated",
        "thread/realtime/closed",
        "thread/realtime/error",
        "thread/realtime/itemAdded",
        "thread/realtime/outputAudio/delta",
        "thread/realtime/sdp",
        "thread/realtime/started",
        "thread/realtime/transcript/delta",
        "thread/realtime/transcript/done",
        "thread/settings/updated",
        "thread/started",
        "thread/status/changed",
        "thread/unarchived",
        "turn/completed",
        "turn/diff/updated",
        "turn/moderationMetadata",
        "turn/plan/updated",
        "turn/started",
        "warning",
        "windows/worldWritableWarning",
        "windowsSandbox/setupCompleted",
    ]

    private static let unsafeKeyFragments = [
        "accountid",
        "account_id",
        "audio",
        "auth",
        "authorization",
        "body",
        "content",
        "cwd",
        "delta",
        "description",
        "details",
        "email",
        "environmentid",
        "environment_id",
        "error",
        "input",
        "instructions",
        "item",
        "items",
        "message",
        "objective",
        "output",
        "path",
        "payload",
        "preview",
        "prompt",
        "request",
        "response",
        "schema",
        "sdp",
        "serverid",
        "server_id",
        "summary",
        "text",
        "title",
        "token",
        "tool",
        "url",
        "userid",
        "user_id",
        "writableroots",
        "websocket",
    ]

    private static let knownModelProviders: Set<String> = [
        "openai",
    ]

    private static let knownThreadStatuses: Set<String> = [
        "active",
        "archived",
        "closed",
        "compacted",
        "created",
        "idle",
        "paused",
        "running",
        "unarchived",
    ]

    private static let knownSources: Set<String> = [
        "app-server",
        "cli",
        "codex",
        "config",
        "desktop",
        "extension",
        "hook",
        "server",
        "user",
        "vscode",
    ]

    private static let knownThreadSources: Set<String> = [
        "cli",
        "desktop",
        "vscode",
    ]

    private static let knownHookEvents: Set<String> = [
        "postCommand",
        "preCommand",
        "sessionStart",
        "turnComplete",
        "turnStart",
    ]

    private static let knownHookHandlerTypes: Set<String> = [
        "command",
        "shell",
    ]

    private static let knownHookExecutionModes: Set<String> = [
        "blocking",
        "parallel",
        "serial",
    ]

    private static let knownHookScopes: Set<String> = [
        "global",
        "project",
        "user",
        "workspace",
    ]

    private static let knownStatuses: Set<String> = [
        "approved",
        "cancelled",
        "completed",
        "denied",
        "error",
        "failed",
        "failure",
        "inProgress",
        "in_progress",
        "pending",
        "running",
        "skipped",
        "started",
        "success",
        "succeeded",
    ]

    private static let knownItemTypes: Set<String> = [
        "agentMessage",
        "autoApprovalReview",
        "commandExecution",
        "fileChange",
        "mcpToolCall",
        "message",
        "plan",
        "reasoning",
        "toolCall",
    ]

    private static let knownItemPhases: Set<String> = [
        "completed",
        "created",
        "delta",
        "failed",
        "started",
        "streaming",
    ]

    private static let knownReasoningEfforts: Set<String> = [
        "high",
        "low",
        "medium",
        "minimal",
        "none",
        "xhigh",
    ]

    private static let knownDecisionSources: Set<String> = [
        "auto",
        "guardian",
        "system",
        "user",
    ]

    private static let knownRiskLevels: Set<String> = [
        "critical",
        "high",
        "low",
        "medium",
        "none",
    ]

    private static let knownActionTypes: Set<String> = [
        "command",
        "fileChange",
        "mcpTool",
        "networkAccess",
        "openUrl",
        "tool",
    ]

    private static let knownProtocols: Set<String> = [
        "http",
        "https",
        "tcp",
        "udp",
        "ws",
        "wss",
    ]

    private static let knownStreams: Set<String> = [
        "stderr",
        "stdout",
    ]

    private static let knownWindowsSandboxModes: Set<String> = [
        "copy",
        "off",
        "readonly",
        "readOnly",
        "workspace",
        "workspaceWrite",
    ]

    private static let knownRerouteReasons: Set<String> = [
        "capacity",
        "default",
        "fallback",
        "highRiskCyberActivity",
        "modelUnavailable",
        "policy",
    ]

    private static let knownAuthModes: Set<String> = [
        "api_key",
        "api-key",
        "chatgpt",
        "none",
        "openai",
    ]

    private static let knownPlanTypes: Set<String> = [
        "business",
        "enterprise",
        "free",
        "plus",
        "pro",
        "team",
    ]

    private static let knownApprovalPolicies: Set<String> = [
        "auto",
        "full-auto",
        "granular",
        "never",
        "on-failure",
        "on-request",
        "onFailure",
        "onRequest",
        "untrusted",
    ]

    private static let knownApprovalsReviewers: Set<String> = [
        "guardian_subagent",
        "none",
        "system",
        "user",
    ]

    private static let knownSandboxPolicies: Set<String> = [
        "danger-full-access",
        "danger_full_access",
        "read-only",
        "readOnly",
        "workspace-write",
        "workspaceWrite",
    ]

    private static let knownCollaborationModes: Set<String> = [
        "act",
        "agent",
        "chat",
        "plan",
    ]

    private static let knownGoalStatuses: Set<String> = [
        "active",
        "blocked",
        "completed",
        "done",
        "inProgress",
        "in_progress",
        "pending",
    ]

    private static let knownRealtimeRoles: Set<String> = [
        "assistant",
        "system",
        "user",
    ]

    static func audit(method rawMethod: String, params: Any?) -> CodexAppServerNotificationAuditRecord? {
        guard let method = normalizedMethod(rawMethod), !skippedMethods.contains(method) else {
            return nil
        }

        let rejectedUnsafeFieldCount = rejectedUnsafeFieldCount(in: params)
        guard supportedMethods.contains(method) else {
            return CodexAppServerNotificationAuditRecord(
                method: method,
                isSupported: false,
                rejectedUnsafeFieldCount: rejectedUnsafeFieldCount,
                unsupportedShapeCount: params == nil ? 0 : 1
            )
        }

        guard let object = params as? [String: Any] else {
            return CodexAppServerNotificationAuditRecord(
                method: method,
                isSupported: true,
                rejectedUnsafeFieldCount: rejectedUnsafeFieldCount,
                unsupportedShapeCount: 1
            )
        }

        var safeValues: [String: String] = [:]
        var presenceFlags: [String] = []
        var unsupportedShapeCount = 0

        func markPresence(_ key: String, when value: Any?) {
            if let value, !(value is NSNull) {
                presenceFlags.append(key)
            }
        }

        switch method {
        case "thread/started":
            if let thread = object["thread"] as? [String: Any] {
                markPresence("threadId", when: thread["id"])
                addThreadSummary(thread, to: &safeValues)
            } else {
                unsupportedShapeCount += 1
            }
        case "thread/archived", "thread/unarchived", "thread/closed", "thread/goal/cleared", "thread/compacted":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
        case "thread/name/updated":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["threadName"], key: "hasThreadName", to: &safeValues)
        case "thread/status/changed":
            markPresence("threadId", when: object["threadId"])
            if let statusObject = object["status"] as? [String: Any] {
                addKnownIdentifier(statusObject["type"], key: "status", allowedValues: knownThreadStatuses, to: &safeValues)
                if let activeFlags = statusObject["activeFlags"] as? [Any] {
                    safeValues["activeFlagCount"] = "\(activeFlags.count)"
                }
            } else {
                unsupportedShapeCount += 1
            }
        case "skills/changed", "externalAgentConfig/import/completed":
            break
        case "turn/started", "turn/completed":
            markPresence("threadId", when: object["threadId"])
            if let turn = object["turn"] as? [String: Any] {
                markPresence("turnId", when: turn["id"])
                addKnownIdentifier(turn["status"], key: "turnStatus", allowedValues: knownStatuses, to: &safeValues)
                if let items = turn["items"] as? [Any] {
                    safeValues["itemCount"] = "\(items.count)"
                }
                addPresenceValue(turn["durationMs"], key: "hasDuration", to: &safeValues)
                addPresenceValue(turn["startedAt"], key: "hasStartedAt", to: &safeValues)
                addPresenceValue(turn["completedAt"], key: "hasCompletedAt", to: &safeValues)
                addPresenceValue(turn["error"], key: "hasError", to: &safeValues)
            } else {
                unsupportedShapeCount += 1
            }
        case "error":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            addBoolean(object["willRetry"], key: "willRetry", to: &safeValues)
            addPresenceValue(object["error"], key: "hasError", to: &safeValues)
            if let error = object["error"] as? [String: Any] {
                addPresenceValue(error["codexErrorInfo"], key: "hasCodexErrorInfo", to: &safeValues)
                addPresenceValue(error["additionalDetails"], key: "hasAdditionalDetails", to: &safeValues)
            }
        case "hook/started", "hook/completed":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            if let run = object["run"] as? [String: Any] {
                addHookRunSummary(run, to: &safeValues)
            } else {
                unsupportedShapeCount += 1
            }
        case "turn/diff/updated":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            addPresenceValue(object["diff"], key: "hasDiff", to: &safeValues)
        case "turn/plan/updated":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            addPresenceValue(object["explanation"], key: "hasExplanation", to: &safeValues)
            addPlanSummary(object["plan"], to: &safeValues)
        case "turn/moderationMetadata":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            addPresenceValue(object["metadata"], key: "hasMetadata", to: &safeValues)
            addObjectCount(object["metadata"], key: "metadataFieldCount", to: &safeValues)
        case "item/started", "item/completed":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            addPresenceValue(object["startedAtMs"], key: "hasStartedAt", to: &safeValues)
            addPresenceValue(object["completedAtMs"], key: "hasCompletedAt", to: &safeValues)
            if let item = object["item"] as? [String: Any] {
                markPresence("itemId", when: item["id"])
                addItemSummary(item, to: &safeValues)
            } else {
                unsupportedShapeCount += 1
            }
        case "rawResponseItem/completed":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            if let item = object["item"] as? [String: Any] {
                addItemSummary(item, to: &safeValues)
            } else {
                unsupportedShapeCount += 1
            }
        case "item/autoApprovalReview/started", "item/autoApprovalReview/completed":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            markPresence("reviewId", when: object["reviewId"])
            markPresence("targetItemId", when: object["targetItemId"])
            addPresenceValue(object["startedAtMs"], key: "hasStartedAt", to: &safeValues)
            addPresenceValue(object["completedAtMs"], key: "hasCompletedAt", to: &safeValues)
            addKnownIdentifier(object["decisionSource"], key: "decisionSource", allowedValues: knownDecisionSources, to: &safeValues)
            addApprovalReviewSummary(object["review"], to: &safeValues)
            addApprovalActionSummary(object["action"], to: &safeValues)
        case "item/agentMessage/delta", "item/plan/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            markPresence("itemId", when: object["itemId"])
            addPresenceValue(object["delta"], key: "hasDelta", to: &safeValues)
            addPresenceValue(object["summaryIndex"], key: "hasSummaryIndex", to: &safeValues)
            addPresenceValue(object["contentIndex"], key: "hasContentIndex", to: &safeValues)
        case "item/reasoning/summaryPartAdded":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            markPresence("itemId", when: object["itemId"])
            addPresenceValue(object["summaryIndex"], key: "hasSummaryIndex", to: &safeValues)
        case "command/exec/outputDelta":
            markPresence("processId", when: object["processId"])
            addKnownIdentifier(object["stream"], key: "stream", allowedValues: knownStreams, to: &safeValues)
            addBoolean(object["capReached"], key: "capReached", to: &safeValues)
            addPresenceValue(object["deltaBase64"], key: "hasOutputDelta", to: &safeValues)
        case "process/outputDelta":
            markPresence("processHandle", when: object["processHandle"])
            addKnownIdentifier(object["stream"], key: "stream", allowedValues: knownStreams, to: &safeValues)
            addBoolean(object["capReached"], key: "capReached", to: &safeValues)
            addPresenceValue(object["deltaBase64"], key: "hasOutputDelta", to: &safeValues)
        case "process/exited":
            markPresence("processHandle", when: object["processHandle"])
            addPresenceValue(object["exitCode"], key: "hasExitCode", to: &safeValues)
            addBoolean(object["stdoutCapReached"], key: "stdoutCapReached", to: &safeValues)
            addBoolean(object["stderrCapReached"], key: "stderrCapReached", to: &safeValues)
            addPresenceValue(object["stdout"], key: "hasStdout", to: &safeValues)
            addPresenceValue(object["stderr"], key: "hasStderr", to: &safeValues)
        case "item/commandExecution/terminalInteraction":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            markPresence("itemId", when: object["itemId"])
            markPresence("processId", when: object["processId"])
            addPresenceValue(object["stdin"], key: "hasInput", to: &safeValues)
        case "item/fileChange/patchUpdated":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            markPresence("itemId", when: object["itemId"])
            addPatchChangeSummary(object["changes"], to: &safeValues)
        case "serverRequest/resolved":
            markPresence("threadId", when: object["threadId"])
            markPresence("requestId", when: object["requestId"])
        case "item/mcpToolCall/progress":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            markPresence("itemId", when: object["itemId"])
            addPresenceValue(object["message"], key: "hasMessage", to: &safeValues)
        case "mcpServer/oauthLogin/completed":
            addPresenceValue(object["name"], key: "hasName", to: &safeValues)
            addBoolean(object["success"], key: "success", to: &safeValues)
            addPresenceValue(object["error"], key: "hasError", to: &safeValues)
        case "mcpServer/startupStatus/updated":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["name"], key: "hasName", to: &safeValues)
            addKnownIdentifier(object["status"], key: "status", allowedValues: knownStatuses, to: &safeValues)
            addPresenceValue(object["error"], key: "hasError", to: &safeValues)
        case "app/list/updated":
            addArrayCount(object["data"], key: "appCount", to: &safeValues)
            addAccessibleAppCount(object["data"], to: &safeValues)
        case "fs/changed":
            markPresence("watchId", when: object["watchId"])
            addArrayCount(object["changedPaths"], key: "changedPathCount", to: &safeValues)
        case "fuzzyFileSearch/sessionUpdated":
            markPresence("sessionId", when: object["sessionId"])
            addPresenceValue(object["query"], key: "hasQuery", to: &safeValues)
            addArrayCount(object["files"], key: "fileCount", to: &safeValues)
        case "fuzzyFileSearch/sessionCompleted":
            markPresence("sessionId", when: object["sessionId"])
        case "windows/worldWritableWarning":
            addArrayCount(object["samplePaths"], key: "samplePathCount", to: &safeValues)
            addCountValue(object["extraCount"], key: "extraPathCount", to: &safeValues)
            addBoolean(object["failedScan"], key: "failedScan", to: &safeValues)
        case "windowsSandbox/setupCompleted":
            addKnownIdentifier(object["mode"], key: "mode", allowedValues: knownWindowsSandboxModes, to: &safeValues)
            addBoolean(object["success"], key: "success", to: &safeValues)
            addPresenceValue(object["error"], key: "hasError", to: &safeValues)
        case "account/login/completed":
            markPresence("loginId", when: object["loginId"])
            addBoolean(object["success"], key: "success", to: &safeValues)
            addPresenceValue(object["error"], key: "hasError", to: &safeValues)
        case "model/rerouted":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            addModel(object["fromModel"], key: "fromModel", to: &safeValues)
            addModel(object["toModel"], key: "toModel", to: &safeValues)
            addKnownIdentifier(object["reason"], key: "reason", allowedValues: knownRerouteReasons, to: &safeValues)
        case "account/updated":
            addKnownIdentifier(object["authMode"], key: "authMode", allowedValues: knownAuthModes, to: &safeValues)
            addKnownIdentifier(object["planType"], key: "planType", allowedValues: knownPlanTypes, to: &safeValues)
        case "thread/settings/updated":
            markPresence("threadId", when: object["threadId"])
            if let settings = object["threadSettings"] as? [String: Any] {
                addModel(settings["model"], key: "model", to: &safeValues)
                addKnownIdentifierOrPresence(settings["modelProvider"], key: "modelProvider", presenceKey: "hasModelProvider", allowedValues: knownModelProviders, to: &safeValues)
                addKnownIdentifier(settings["effort"], key: "effort", allowedValues: knownReasoningEfforts, to: &safeValues)
                addKnownEnumLike(settings["approvalPolicy"], key: "approvalPolicy", allowedValues: knownApprovalPolicies, to: &safeValues)
                addKnownEnumLike(settings["approvalsReviewer"], key: "approvalsReviewer", allowedValues: knownApprovalsReviewers, to: &safeValues)
                addKnownEnumLike(settings["sandboxPolicy"], key: "sandboxPolicy", allowedValues: knownSandboxPolicies, to: &safeValues)
                if let collaborationMode = settings["collaborationMode"] as? [String: Any] {
                    addKnownEnumLike(collaborationMode["mode"], key: "collaborationMode", allowedValues: knownCollaborationModes, to: &safeValues)
                }
                addPresenceValue(settings["cwd"], key: "hasCwd", to: &safeValues)
                addPresenceValue(settings["serviceTier"], key: "hasServiceTier", to: &safeValues)
                addPresenceValue(settings["activePermissionProfile"], key: "hasPermissionProfile", to: &safeValues)
                addPresenceValue(settings["summary"], key: "hasReasoningSummary", to: &safeValues)
                addPresenceValue(settings["personality"], key: "hasPersonality", to: &safeValues)
            } else {
                unsupportedShapeCount += 1
            }
        case "thread/goal/updated":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            if let goal = object["goal"] as? [String: Any] {
                addKnownIdentifier(goal["status"], key: "goalStatus", allowedValues: knownGoalStatuses, to: &safeValues)
                addPresenceValue(goal["tokenBudget"], key: "hasTokenBudget", to: &safeValues)
            } else {
                unsupportedShapeCount += 1
            }
        case "thread/realtime/started":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["version"], key: "hasVersion", to: &safeValues)
            addPresenceValue(object["realtimeSessionId"], key: "hasRealtimeSession", to: &safeValues)
        case "thread/realtime/closed":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["reason"], key: "hasReason", to: &safeValues)
        case "thread/realtime/error":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["message"], key: "hasMessage", to: &safeValues)
        case "thread/realtime/itemAdded":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["item"], key: "hasItem", to: &safeValues)
        case "thread/realtime/transcript/delta", "thread/realtime/transcript/done":
            markPresence("threadId", when: object["threadId"])
            addKnownIdentifier(object["role"], key: "role", allowedValues: knownRealtimeRoles, to: &safeValues)
            addPresenceValue(object["delta"], key: "hasDelta", to: &safeValues)
            addPresenceValue(object["text"], key: "hasText", to: &safeValues)
        case "thread/realtime/outputAudio/delta":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["audio"], key: "hasAudio", to: &safeValues)
        case "thread/realtime/sdp":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["sdp"], key: "hasSdp", to: &safeValues)
        case "warning", "guardianWarning":
            markPresence("threadId", when: object["threadId"])
            addPresenceValue(object["message"], key: "hasMessage", to: &safeValues)
        case "configWarning":
            addPresenceValue(object["summary"], key: "hasSummary", to: &safeValues)
            addPresenceValue(object["details"], key: "hasDetails", to: &safeValues)
            addPresenceValue(object["path"], key: "hasPath", to: &safeValues)
            addPresenceValue(object["range"], key: "hasRange", to: &safeValues)
        case "deprecationNotice":
            addPresenceValue(object["summary"], key: "hasSummary", to: &safeValues)
            addPresenceValue(object["details"], key: "hasDetails", to: &safeValues)
        case "model/verification":
            markPresence("threadId", when: object["threadId"])
            markPresence("turnId", when: object["turnId"])
            if let verifications = object["verifications"] as? [Any] {
                safeValues["verificationCount"] = "\(verifications.count)"
            }
        default:
            unsupportedShapeCount += 1
        }

        return CodexAppServerNotificationAuditRecord(
            method: method,
            isSupported: true,
            safeValues: safeValues,
            presenceFlags: presenceFlags,
            rejectedUnsafeFieldCount: rejectedUnsafeFieldCount,
            unsupportedShapeCount: unsupportedShapeCount
        )
    }

    private static func normalizedMethod(_ value: String) -> String? {
        guard value.count <= 120,
              !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
                      .contains(scalar)
              })
        else {
            return nil
        }

        return value
    }

    private static func addThreadSummary(_ thread: [String: Any], to safeValues: inout [String: String]) {
        addKnownIdentifier(thread["status"], key: "threadStatus", allowedValues: knownThreadStatuses, to: &safeValues)
        addKnownIdentifierOrPresence(thread["modelProvider"], key: "modelProvider", presenceKey: "hasModelProvider", allowedValues: knownModelProviders, to: &safeValues)
        addKnownIdentifier(thread["source"], key: "source", allowedValues: knownSources, to: &safeValues)
        addKnownIdentifier(thread["threadSource"], key: "threadSource", allowedValues: knownThreadSources, to: &safeValues)
        addBoolean(thread["ephemeral"], key: "isEphemeral", to: &safeValues)
        addPresenceValue(thread["parentThreadId"], key: "hasParentThread", to: &safeValues)
        addPresenceValue(thread["forkedFromId"], key: "hasForkSource", to: &safeValues)
        addPresenceValue(thread["sessionId"], key: "hasSession", to: &safeValues)
        addPresenceValue(thread["preview"], key: "hasPreview", to: &safeValues)
        addPresenceValue(thread["name"], key: "hasThreadName", to: &safeValues)
        addPresenceValue(thread["agentNickname"], key: "hasAgentNickname", to: &safeValues)
        addPresenceValue(thread["agentRole"], key: "hasAgentRole", to: &safeValues)
        addPresenceValue(thread["createdAt"], key: "hasCreatedAt", to: &safeValues)
        addPresenceValue(thread["updatedAt"], key: "hasUpdatedAt", to: &safeValues)
        addPresenceValue(thread["path"], key: "hasPath", to: &safeValues)
        addPresenceValue(thread["cwd"], key: "hasCwd", to: &safeValues)
        addPresenceValue(thread["gitInfo"], key: "hasGitInfo", to: &safeValues)
        addArrayCount(thread["turns"], key: "turnCount", to: &safeValues)
    }

    private static func addHookRunSummary(_ run: [String: Any], to safeValues: inout [String: String]) {
        addKnownIdentifier(run["eventName"], key: "hookEvent", allowedValues: knownHookEvents, to: &safeValues)
        addKnownIdentifier(run["handlerType"], key: "hookHandlerType", allowedValues: knownHookHandlerTypes, to: &safeValues)
        addKnownIdentifier(run["executionMode"], key: "hookExecutionMode", allowedValues: knownHookExecutionModes, to: &safeValues)
        addKnownIdentifier(run["scope"], key: "hookScope", allowedValues: knownHookScopes, to: &safeValues)
        addKnownIdentifier(run["source"], key: "hookSource", allowedValues: knownSources, to: &safeValues)
        addKnownIdentifier(run["status"], key: "hookStatus", allowedValues: knownStatuses, to: &safeValues)
        addArrayCount(run["entries"], key: "hookEntryCount", to: &safeValues)
        addPresenceValue(run["sourcePath"], key: "hasSourcePath", to: &safeValues)
        addPresenceValue(run["statusMessage"], key: "hasStatusMessage", to: &safeValues)
        addPresenceValue(run["startedAt"], key: "hasStartedAt", to: &safeValues)
        addPresenceValue(run["completedAt"], key: "hasCompletedAt", to: &safeValues)
        addPresenceValue(run["durationMs"], key: "hasDuration", to: &safeValues)
    }

    private static func addPlanSummary(_ value: Any?, to safeValues: inout [String: String]) {
        guard let plan = value as? [[String: Any]] else {
            addArrayCount(value, key: "planStepCount", to: &safeValues)
            return
        }

        safeValues["planStepCount"] = "\(plan.count)"
        for step in plan {
            guard let status = normalizedString(from: step["status"]) else {
                continue
            }

            switch status {
            case "pending":
                incrementCount("pendingStepCount", in: &safeValues)
            case "inProgress", "in_progress":
                incrementCount("inProgressStepCount", in: &safeValues)
            case "completed":
                incrementCount("completedStepCount", in: &safeValues)
            default:
                break
            }
        }
    }

    private static func addItemSummary(_ item: [String: Any], to safeValues: inout [String: String]) {
        addKnownIdentifier(item["type"], key: "itemType", allowedValues: knownItemTypes, to: &safeValues)
        addKnownIdentifier(item["status"], key: "itemStatus", allowedValues: knownStatuses, to: &safeValues)
        addKnownIdentifier(item["phase"], key: "itemPhase", allowedValues: knownItemPhases, to: &safeValues)
        addKnownIdentifier(item["source"], key: "itemSource", allowedValues: knownSources, to: &safeValues)
        addKnownIdentifier(item["kind"], key: "itemKind", allowedValues: knownItemTypes, to: &safeValues)
        addBoolean(item["success"], key: "success", to: &safeValues)
        addModel(item["model"], key: "model", to: &safeValues)
        addKnownIdentifier(item["reasoningEffort"], key: "reasoningEffort", allowedValues: knownReasoningEfforts, to: &safeValues)
        addArrayCount(item["content"], key: "contentCount", to: &safeValues)
        addArrayCount(item["summary"], key: "summaryCount", to: &safeValues)
        addArrayCount(item["changes"], key: "changeCount", to: &safeValues)
        addArrayCount(item["commandActions"], key: "commandActionCount", to: &safeValues)
        addArrayCount(item["contentItems"], key: "contentItemCount", to: &safeValues)
        addArrayCount(item["receiverThreadIds"], key: "receiverThreadCount", to: &safeValues)
        addObjectCount(item["agentsStates"], key: "agentStateCount", to: &safeValues)
        addPresenceValue(item["durationMs"], key: "hasDuration", to: &safeValues)
        addPresenceValue(item["exitCode"], key: "hasExitCode", to: &safeValues)
        addPresenceValue(item["arguments"], key: "hasArguments", to: &safeValues)
        addPresenceValue(item["result"], key: "hasResult", to: &safeValues)
        addPresenceValue(item["error"], key: "hasError", to: &safeValues)
        addPresenceValue(item["prompt"], key: "hasPrompt", to: &safeValues)
        addPresenceValue(item["query"], key: "hasQuery", to: &safeValues)
        addPresenceValue(item["path"], key: "hasPath", to: &safeValues)
        addPresenceValue(item["savedPath"], key: "hasSavedPath", to: &safeValues)
        addPresenceValue(item["review"], key: "hasReview", to: &safeValues)
        addPresenceValue(item["aggregatedOutput"], key: "hasAggregatedOutput", to: &safeValues)
    }

    private static func addApprovalReviewSummary(_ value: Any?, to safeValues: inout [String: String]) {
        guard let review = value as? [String: Any] else {
            addPresenceValue(value, key: "hasReview", to: &safeValues)
            return
        }

        addKnownIdentifier(review["status"], key: "reviewStatus", allowedValues: knownStatuses, to: &safeValues)
        addKnownIdentifier(review["riskLevel"], key: "riskLevel", allowedValues: knownRiskLevels, to: &safeValues)
        addPresenceValue(review["userAuthorization"], key: "hasUserAuthorization", to: &safeValues)
        addPresenceValue(review["rationale"], key: "hasRationale", to: &safeValues)
    }

    private static func addApprovalActionSummary(_ value: Any?, to safeValues: inout [String: String]) {
        guard let action = value as? [String: Any] else {
            addPresenceValue(value, key: "hasAction", to: &safeValues)
            return
        }

        addKnownIdentifier(action["type"], key: "actionType", allowedValues: knownActionTypes, to: &safeValues)
        addKnownIdentifier(action["source"], key: "actionSource", allowedValues: knownSources, to: &safeValues)
        addKnownIdentifier(action["protocol"], key: "protocol", allowedValues: knownProtocols, to: &safeValues)
        addArrayCount(action["argv"], key: "argvCount", to: &safeValues)
        addArrayCount(action["files"], key: "fileCount", to: &safeValues)
        addPresenceValue(action["cwd"], key: "hasCwd", to: &safeValues)
        addPresenceValue(action["command"], key: "hasCommand", to: &safeValues)
        addPresenceValue(action["program"], key: "hasProgram", to: &safeValues)
        addPresenceValue(action["target"], key: "hasTarget", to: &safeValues)
        addPresenceValue(action["host"], key: "hasHost", to: &safeValues)
        addPresenceValue(action["port"], key: "hasPort", to: &safeValues)
        addPresenceValue(action["server"], key: "hasServer", to: &safeValues)
        addPresenceValue(action["toolName"], key: "hasToolName", to: &safeValues)
        addPresenceValue(action["connectorId"], key: "hasConnectorId", to: &safeValues)
        addPresenceValue(action["connectorName"], key: "hasConnectorName", to: &safeValues)
        addPresenceValue(action["toolTitle"], key: "hasToolTitle", to: &safeValues)
        addPresenceValue(action["reason"], key: "hasReason", to: &safeValues)
        addPresenceValue(action["permissions"], key: "hasPermissions", to: &safeValues)
    }

    private static func addPatchChangeSummary(_ value: Any?, to safeValues: inout [String: String]) {
        guard let changes = value as? [[String: Any]] else {
            addArrayCount(value, key: "changeCount", to: &safeValues)
            return
        }

        safeValues["changeCount"] = "\(changes.count)"
        for change in changes {
            guard let kind = normalizedString(from: change["kind"]) else {
                continue
            }

            switch kind {
            case "add", "added":
                incrementCount("addedChangeCount", in: &safeValues)
            case "delete", "deleted", "remove", "removed":
                incrementCount("deletedChangeCount", in: &safeValues)
            case "update", "updated", "modify", "modified":
                incrementCount("updatedChangeCount", in: &safeValues)
            default:
                break
            }
        }
    }

    private static func addAccessibleAppCount(_ value: Any?, to safeValues: inout [String: String]) {
        guard let apps = value as? [[String: Any]] else {
            return
        }

        let count = apps.filter { app in
            if let isAccessible = app["isAccessible"] as? Bool {
                return isAccessible
            }
            return false
        }.count
        safeValues["accessibleAppCount"] = "\(count)"
    }

    private static func addModel(_ value: Any?, key: String, to safeValues: inout [String: String]) {
        guard let stringValue = value as? String,
              let normalized = CodexModelIdentifier.normalized(stringValue)
        else {
            return
        }

        safeValues[key] = normalized
    }

    private static func addDimension(_ value: Any?, key: String, to safeValues: inout [String: String]) {
        guard let stringValue = value as? String,
              let normalized = CodexTokenContextNormalizer.normalizedDimensionValue(stringValue)
        else {
            return
        }

        safeValues[key] = normalized
    }

    private static func addKnownIdentifier(
        _ value: Any?,
        key: String,
        allowedValues: Set<String>,
        to safeValues: inout [String: String]
    ) {
        guard let stringValue = value as? String,
              let normalized = CodexTokenContextNormalizer.normalizedIdentifier(stringValue),
              isKnownIdentifier(normalized, in: allowedValues)
        else {
            return
        }

        safeValues[key] = normalized
    }

    private static func addKnownIdentifierOrPresence(
        _ value: Any?,
        key: String,
        presenceKey: String,
        allowedValues: Set<String>,
        to safeValues: inout [String: String]
    ) {
        guard let value, !(value is NSNull) else {
            return
        }

        addKnownIdentifier(value, key: key, allowedValues: allowedValues, to: &safeValues)
        if safeValues[key] == nil {
            safeValues[presenceKey] = "true"
        }
    }

    private static func addKnownEnumLike(
        _ value: Any?,
        key: String,
        allowedValues: Set<String>,
        to safeValues: inout [String: String]
    ) {
        if let stringValue = value as? String,
           let normalized = CodexTokenContextNormalizer.normalizedIdentifier(stringValue),
           isKnownIdentifier(normalized, in: allowedValues)
        {
            safeValues[key] = normalized
            return
        }

        guard let object = value as? [String: Any] else {
            return
        }

        if let typeValue = object["type"] as? String,
           let normalized = CodexTokenContextNormalizer.normalizedIdentifier(typeValue),
           isKnownIdentifier(normalized, in: allowedValues)
        {
            safeValues[key] = normalized
            return
        }

        if object["granular"] is [String: Any],
           allowedValues.contains("granular")
        {
            safeValues[key] = "granular"
        }
    }

    private static func isKnownIdentifier(_ value: String, in allowedValues: Set<String>) -> Bool {
        allowedValues.contains(value) || allowedValues.contains(value.lowercased())
    }

    private static func addPresenceValue(_ value: Any?, key: String, to safeValues: inout [String: String]) {
        guard let value, !(value is NSNull) else {
            return
        }

        safeValues[key] = "true"
    }

    private static func addArrayCount(_ value: Any?, key: String, to safeValues: inout [String: String]) {
        guard let array = value as? [Any] else {
            return
        }

        safeValues[key] = "\(array.count)"
    }

    private static func addObjectCount(_ value: Any?, key: String, to safeValues: inout [String: String]) {
        guard let object = value as? [String: Any] else {
            return
        }

        safeValues[key] = "\(object.count)"
    }

    private static func addBoolean(_ value: Any?, key: String, to safeValues: inout [String: String]) {
        guard let boolValue = value as? Bool else {
            return
        }

        safeValues[key] = boolValue ? "true" : "false"
    }

    private static func addCountValue(_ value: Any?, key: String, to safeValues: inout [String: String]) {
        guard let count = integerValue(from: value) else {
            return
        }

        safeValues[key] = "\(max(count, 0))"
    }

    private static func incrementCount(_ key: String, in safeValues: inout [String: String]) {
        let currentValue = Int(safeValues[key] ?? "0") ?? 0
        safeValues[key] = "\(currentValue + 1)"
    }

    private static func normalizedString(from value: Any?) -> String? {
        guard let stringValue = value as? String,
              let normalized = CodexTokenContextNormalizer.normalizedIdentifier(stringValue)
        else {
            return nil
        }

        return normalized
    }

    private static func integerValue(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }

        guard let numberValue = value as? NSNumber,
              !(value is Bool)
        else {
            return nil
        }

        return numberValue.intValue
    }

    private static func rejectedUnsafeFieldCount(in value: Any?) -> Int {
        guard let value else {
            return 0
        }

        if let object = value as? [String: Any] {
            return object.reduce(0) { partialResult, pair in
                let rejectedKeyCount = isUnsafeKey(pair.key) ? 1 : 0
                return partialResult + rejectedKeyCount + rejectedUnsafeFieldCount(in: pair.value)
            }
        }

        if let array = value as? [Any] {
            return array.reduce(0) { $0 + rejectedUnsafeFieldCount(in: $1) }
        }

        return 0
    }

    private static func isUnsafeKey(_ key: String) -> Bool {
        let normalizedKey = key
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return unsafeKeyFragments.contains { normalizedKey.contains($0) }
    }
}

enum CodexAppServerAuditDiagnosticEvent: Equatable {
    case connected(mode: CodexAppServerConnectionMode)
    case disconnected(errorText: String?)
    case inboundMethod(String)
    case rateLimitNotification
    case tokenUsageNotification
    case notificationAudit(CodexAppServerNotificationAuditRecord)
    case remoteControlNotification(status: CodexRemoteControlStatus?, warningText: String?)
    case remoteControlHealth(CodexRemoteControlHealthSnapshot)
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
    var remoteControl: CodexRemoteControlDiagnostics?
    var notificationAudit: CodexAppServerNotificationAuditSummary

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
        remoteControl = nil
        notificationAudit = CodexAppServerNotificationAuditSummary()
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case startedAt
        case lastUpdatedAt
        case connectionMode
        case isConnected
        case lastInboundMethod
        case inboundNotificationCount
        case rateLimitNotificationCount
        case tokenUsageNotificationCount
        case auditSanitizeAttemptCount
        case auditSanitizeSuccessCount
        case auditPersistAttemptCount
        case auditPersistSuccessCount
        case auditPersistFailureCount
        case lastAuditPersistenceStatus
        case lastAuditPersistedAt
        case lastPersistenceError
        case lastReceiveError
        case remoteControl
        case notificationAudit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let now = Date()
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? now
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt) ?? startedAt
        connectionMode = try container.decodeIfPresent(CodexAppServerConnectionMode.self, forKey: .connectionMode) ?? .unknown
        isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
        lastInboundMethod = try container.decodeIfPresent(String.self, forKey: .lastInboundMethod)
        inboundNotificationCount = try container.decodeIfPresent(Int.self, forKey: .inboundNotificationCount) ?? 0
        rateLimitNotificationCount = try container.decodeIfPresent(Int.self, forKey: .rateLimitNotificationCount) ?? 0
        tokenUsageNotificationCount = try container.decodeIfPresent(Int.self, forKey: .tokenUsageNotificationCount) ?? 0
        auditSanitizeAttemptCount = try container.decodeIfPresent(Int.self, forKey: .auditSanitizeAttemptCount) ?? 0
        auditSanitizeSuccessCount = try container.decodeIfPresent(Int.self, forKey: .auditSanitizeSuccessCount) ?? 0
        auditPersistAttemptCount = try container.decodeIfPresent(Int.self, forKey: .auditPersistAttemptCount) ?? 0
        auditPersistSuccessCount = try container.decodeIfPresent(Int.self, forKey: .auditPersistSuccessCount) ?? 0
        auditPersistFailureCount = try container.decodeIfPresent(Int.self, forKey: .auditPersistFailureCount) ?? 0
        lastAuditPersistenceStatus = try container.decodeIfPresent(CodexTokenPayloadAuditPersistenceStatus.self, forKey: .lastAuditPersistenceStatus) ?? .notAttempted
        lastAuditPersistedAt = try container.decodeIfPresent(Date.self, forKey: .lastAuditPersistedAt)
        lastPersistenceError = try container.decodeIfPresent(String.self, forKey: .lastPersistenceError)
        lastReceiveError = try container.decodeIfPresent(String.self, forKey: .lastReceiveError)
        remoteControl = try container.decodeIfPresent(CodexRemoteControlDiagnostics.self, forKey: .remoteControl)
        notificationAudit = try container.decodeIfPresent(
            CodexAppServerNotificationAuditSummary.self,
            forKey: .notificationAudit
        ) ?? CodexAppServerNotificationAuditSummary()
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

    var remoteControlDiagnostics: CodexRemoteControlDiagnostics {
        remoteControl ?? CodexRemoteControlDiagnostics()
    }

    var remoteControlPopoverWarningText: String? {
        if !isConnected, connectionMode != .unknown {
            return "Codex app-server is disconnected."
        }

        return remoteControlDiagnostics.popoverWarningText
    }

    var notificationAuditLastMethodText: String {
        notificationAudit.lastMethod ?? "--"
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
        case .notificationAudit(let record):
            updated.notificationAudit.record(record, at: eventDate)
        case .remoteControlNotification(let status, let warningText):
            var remoteControl = updated.remoteControlDiagnostics
            remoteControl.notificationCount += 1
            remoteControl.lastStatusUpdatedAt = eventDate
            remoteControl.lastWarningText = warningText
            if let status {
                remoteControl.lastStatus = status
            }
            updated.remoteControl = remoteControl
        case .remoteControlHealth(let snapshot):
            var remoteControl = updated.remoteControlDiagnostics
            remoteControl.enrollmentStatus = snapshot.status
            remoteControl.enrollmentLastCheckedAt = snapshot.checkedAt
            remoteControl.enrollmentCount = snapshot.enrollmentCount
            remoteControl.enrollmentLatestUpdatedAt = snapshot.latestEnrollmentUpdatedAt
            remoteControl.enrollmentErrorText = snapshot.errorText
            updated.remoteControl = remoteControl
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

    @discardableResult
    func refreshRemoteControlHealth(
        reader: CodexRemoteControlHealthReading = CodexRemoteControlHealthReader(),
        now: Date? = nil
    ) async -> CodexAppServerAuditDiagnostics {
        let snapshot: CodexRemoteControlHealthSnapshot
        do {
            snapshot = try await reader.remoteControlHealthSnapshot(now: now ?? self.now())
        } catch {
            snapshot = CodexRemoteControlHealthSnapshot(
                checkedAt: now ?? self.now(),
                status: .failed,
                errorText: "Remote-control health could not be refreshed."
            )
        }

        record(.remoteControlHealth(snapshot))
        return diagnostics
    }

    func clearRemoteControlDiagnostics() {
        var updated = diagnostics
        updated.lastUpdatedAt = now()
        updated.remoteControl = nil
        diagnostics = updated
        persist(updated)
    }

    func clearNotificationAudit() {
        var updated = diagnostics
        updated.lastUpdatedAt = now()
        updated.notificationAudit = CodexAppServerNotificationAuditSummary()
        diagnostics = updated
        persist(updated)
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
        case .neverChecked, .healthy, .stale, .mismatch:
            return false
        case .missing, .malformed, .failed:
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

@MainActor
protocol CodexRemoteControlHealthReading {
    func remoteControlHealthSnapshot(now: Date) async throws -> CodexRemoteControlHealthSnapshot
}

struct CodexRemoteControlHealthReader: CodexRemoteControlHealthReading {
    private let stateDatabaseURL: URL
    private let fileManager: FileManager

    init(
        stateDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("state_5.sqlite"),
        fileManager: FileManager = .default
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.fileManager = fileManager
    }

    func remoteControlHealthSnapshot(now: Date = Date()) async throws -> CodexRemoteControlHealthSnapshot {
        guard fileManager.fileExists(atPath: stateDatabaseURL.path) else {
            return CodexRemoteControlHealthSnapshot(checkedAt: now, status: .missingDatabase)
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "State database could not be opened."
            if let database {
                sqlite3_close(database)
            }
            return CodexRemoteControlHealthSnapshot(
                checkedAt: now,
                status: .failed,
                errorText: Self.safeErrorText(message)
            )
        }
        defer { sqlite3_close(database) }

        guard tableExists(database: database, name: "remote_control_enrollments") else {
            return CodexRemoteControlHealthSnapshot(checkedAt: now, status: .missingTable)
        }

        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*), MAX(updated_at) FROM remote_control_enrollments"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return CodexRemoteControlHealthSnapshot(
                checkedAt: now,
                status: .failed,
                errorText: "Remote-control enrollment query could not be prepared."
            )
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return CodexRemoteControlHealthSnapshot(
                checkedAt: now,
                status: .failed,
                errorText: "Remote-control enrollment query failed."
            )
        }

        let count = Int(sqlite3_column_int64(statement, 0))
        let latestUpdatedAt: Date? = if sqlite3_column_type(statement, 1) == SQLITE_NULL {
            nil
        } else {
            Self.date(fromSQLiteTimestamp: sqlite3_column_int64(statement, 1))
        }

        return CodexRemoteControlHealthSnapshot(
            checkedAt: now,
            status: .available,
            enrollmentCount: count,
            latestEnrollmentUpdatedAt: latestUpdatedAt
        )
    }

    private func tableExists(database: OpaquePointer, name: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return false
        }

        return sqlite3_column_int(statement, 0) != 0
    }

    private static func date(fromSQLiteTimestamp timestamp: Int64) -> Date {
        if timestamp > 4_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
        }

        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private static func safeErrorText(_ message: String) -> String {
        message.isEmpty ? "State database could not be read." : "State database could not be read."
    }
}

enum CodexRemoteControlStatusSanitizer {
    private static let unsafeKeys: Set<String> = [
        "account_id", "accountid", "auth", "authorization", "body", "environment_id",
        "environmentid", "message", "payload", "prompt", "request", "server_id", "serverid",
        "token", "tool", "url", "websocket_url", "websocketurl",
    ]

    static func sanitize(params: Any?) -> (status: CodexRemoteControlStatus?, warningText: String?) {
        guard let params else {
            return (nil, nil)
        }

        guard let status = status(in: params, depth: 0) else {
            return (nil, "Remote-control status payload did not contain a supported status value.")
        }

        let warningText = status.isWarning ? "Remote control reported \(status.displayText.lowercased())." : nil
        return (status, warningText)
    }

    private static func status(in value: Any, depth: Int) -> CodexRemoteControlStatus? {
        guard depth <= 4 else {
            return nil
        }

        if let string = value as? String {
            return normalizedStatus(from: string)
        }

        if let dictionary = value as? [String: Any] {
            var candidates: [CodexRemoteControlStatus] = []
            for (key, nestedValue) in dictionary {
                let normalizedKey = normalizedKey(key)
                guard !unsafeKeys.contains(normalizedKey) else {
                    continue
                }

                if let boolValue = nestedValue as? Bool,
                   let status = status(from: boolValue, key: normalizedKey)
                {
                    candidates.append(status)
                    continue
                }

                if isStatusKey(normalizedKey), let status = status(in: nestedValue, depth: depth + 1) {
                    candidates.append(status)
                    continue
                }

                if let status = status(in: nestedValue, depth: depth + 1) {
                    candidates.append(status)
                }
            }

            return prioritized(candidates)
        }

        if let array = value as? [Any] {
            return prioritized(array.compactMap { status(in: $0, depth: depth + 1) })
        }

        return nil
    }

    private static func status(from value: Bool, key: String) -> CodexRemoteControlStatus? {
        switch key {
        case "enabled", "isenabled":
            return value ? .enabled : .disabled
        case "connected", "isconnected", "active", "isactive":
            return value ? .connected : .disconnected
        default:
            return nil
        }
    }

    private static func normalizedStatus(from value: String) -> CodexRemoteControlStatus? {
        let normalized = normalizedKey(value)
        switch normalized {
        case "enabled", "on":
            return .enabled
        case "disabled", "off":
            return .disabled
        case "connecting", "pending":
            return .connecting
        case "connected", "ready", "online":
            return .connected
        case "disconnected", "offline":
            return .disconnected
        case "error", "errored":
            return .error
        case "failed", "failure":
            return .failed
        default:
            return nil
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func isStatusKey(_ key: String) -> Bool {
        key == "status"
            || key == "state"
            || key == "connectionstatus"
            || key == "remotecontrolstatus"
            || key == "remotecontrolstate"
    }

    private static func prioritized(_ statuses: [CodexRemoteControlStatus]) -> CodexRemoteControlStatus? {
        for candidate in [CodexRemoteControlStatus.failed, .error, .connecting, .connected, .enabled, .disconnected, .disabled] {
            if statuses.contains(candidate) {
                return candidate
            }
        }

        return nil
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
