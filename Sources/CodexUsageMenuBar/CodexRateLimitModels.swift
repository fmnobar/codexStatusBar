import Foundation

struct CodexRateLimitWindow: Equatable {
    let usedPercent: Int
    let windowDurationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int {
        Self.clampedRemainingPercent(from: usedPercent)
    }

    static func clampedRemainingPercent(from usedPercent: Int) -> Int {
        min(max(100 - usedPercent, 0), 100)
    }
}

struct CodexRateLimitSnapshot: Equatable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

enum CodexUsageBucketKind: String, Codable, Equatable {
    case aggregate
    case model
}

struct CodexUsageBucket: Equatable, Identifiable {
    let id: String
    let name: String
    let kind: CodexUsageBucketKind
    let snapshot: CodexRateLimitSnapshot
}

struct CodexUsageSnapshot: Equatable {
    let displaySnapshot: CodexRateLimitSnapshot
    let buckets: [CodexUsageBucket]

    static func aggregateOnly(displaySnapshot: CodexRateLimitSnapshot) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            displaySnapshot: displaySnapshot,
            buckets: [
                CodexUsageBucket(
                    id: "codex",
                    name: "All models",
                    kind: .aggregate,
                    snapshot: displaySnapshot
                ),
            ]
        )
    }

    var bucketsForRecording: [CodexUsageBucket] {
        return [
            CodexUsageBucket(
                id: "codex",
                name: "All models",
                kind: .aggregate,
                snapshot: displaySnapshot
            ),
        ] + buckets.filter { $0.kind == .model }
    }
}

struct CodexTokenUsageBreakdown: Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
}

struct TokenCategoryTotals: Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
}

enum CodexModelIdentifier {
    static func normalized(_ value: String?) -> String? {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let trimmedValue = value?.trimmingCharacters(in: trimSet) ?? ""
        guard !trimmedValue.isEmpty else {
            return nil
        }

        let firstTokenScalars = trimmedValue.unicodeScalars.split { trimSet.contains($0) }.first
        guard let firstTokenScalars else {
            return nil
        }

        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard firstTokenScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return String(String.UnicodeScalarView(firstTokenScalars))
    }

    static func firstNormalized(_ values: [String?]) -> String? {
        values.lazy.compactMap(normalized).first
    }
}

struct CodexSafeSourceMetadataPayload: Decodable, Equatable {
    let sourceKind: String?
    let subagentParentThreadID: String?
    let subagentDepth: Int?
    let agentRole: String?
    let agentNickname: String?

    var dimensions: [TokenUsageDimension] {
        var dimensions: [TokenUsageDimension] = []
        if let dimension = TokenUsageDimension(.sourceKind, sourceKind) {
            dimensions.append(dimension)
        }
        if subagentParentThreadID != nil || subagentDepth != nil || agentRole != nil || agentNickname != nil {
            [
                TokenUsageDimension.boolean(.isSubagent, true),
                TokenUsageDimension(.subagentParentThreadID, subagentParentThreadID),
                TokenUsageDimension.integer(.subagentDepth, subagentDepth),
                TokenUsageDimension(.agentRole, agentRole),
                TokenUsageDimension(.agentNickname, agentNickname),
            ].compactMap(\.self).forEach { dimensions.append($0) }
        }
        return TokenUsageDimension.unique(dimensions)
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let sourceKind = try? container.decode(String.self)
        {
            self.sourceKind = sourceKind
            subagentParentThreadID = nil
            subagentDepth = nil
            agentRole = nil
            agentNickname = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let subagent = try? container.decode(SubagentPayload.self, forKey: .subagent)
        let threadSpawn = subagent?.threadSpawn
        sourceKind = threadSpawn == nil ? nil : "subagent"
        subagentParentThreadID = threadSpawn?.parentThreadID
        subagentDepth = threadSpawn?.depth
        agentRole = threadSpawn?.agentRole
        agentNickname = threadSpawn?.agentNickname
    }

    private enum CodingKeys: String, CodingKey {
        case subagent
    }

    private struct SubagentPayload: Decodable, Equatable {
        let threadSpawn: ThreadSpawnPayload?

        enum CodingKeys: String, CodingKey {
            case threadSpawn = "thread_spawn"
        }
    }

    private struct ThreadSpawnPayload: Decodable, Equatable {
        let parentThreadID: String?
        let depth: Int?
        let agentRole: String?
        let agentNickname: String?

        enum CodingKeys: String, CodingKey {
            case parentThreadID = "parent_thread_id"
            case depth
            case agentRole = "agent_role"
            case agentNickname = "agent_nickname"
        }
    }
}

struct CodexSandboxPolicyPayload: Decodable, Equatable {
    let type: String?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let type = try? container.decode(String.self)
        {
            self.type = type
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

struct CodexThreadTokenUsage: Equatable {
    let last: CodexTokenUsageBreakdown
    let total: CodexTokenUsageBreakdown
    let modelContextWindow: Int64?
}

struct CodexTokenUsageNotification: Equatable {
    let threadID: String
    let turnID: String
    let model: String?
    let tokenUsage: CodexThreadTokenUsage
    let dimensions: [TokenUsageDimension]

    init(
        threadID: String,
        turnID: String,
        model: String?,
        tokenUsage: CodexThreadTokenUsage,
        dimensions: [TokenUsageDimension] = []
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.model = model
        self.tokenUsage = tokenUsage
        self.dimensions = TokenUsageDimension.unique(dimensions)
    }
}

struct GetAuthStatusResponse: Decodable {
    let authMethod: String
    let authToken: String?
    let requiresOpenaiAuth: Bool
}

struct AccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshotPayload
    let rateLimitsByLimitId: [String: RateLimitSnapshotPayload]?

    func selectedSnapshot() -> CodexRateLimitSnapshot {
        if let codexSnapshot = rateLimitsByLimitId?["codex"] {
            return codexSnapshot.toDomainSnapshot()
        }

        return rateLimits.toDomainSnapshot()
    }

    func usageSnapshot(displaySnapshotOverride: CodexRateLimitSnapshot? = nil) -> CodexUsageSnapshot {
        let displaySnapshot = displaySnapshotOverride ?? selectedSnapshot()
        var buckets = usageBuckets()

        if buckets.isEmpty {
            buckets = CodexUsageSnapshot.aggregateOnly(displaySnapshot: displaySnapshot).buckets
        }

        return CodexUsageSnapshot(displaySnapshot: displaySnapshot, buckets: buckets)
    }

    func usageBuckets() -> [CodexUsageBucket] {
        guard let rateLimitsByLimitId, !rateLimitsByLimitId.isEmpty else {
            return [
                rateLimits.toUsageBucket(fallbackId: rateLimits.limitId ?? "codex"),
            ]
        }

        return rateLimitsByLimitId
            .map { key, payload in
                payload.toUsageBucket(fallbackId: key)
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .aggregate
                }

                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

struct AccountRateLimitsUpdatedNotificationPayload: Decodable {
    let rateLimits: RateLimitSnapshotPayload

    func selectedSnapshot() -> CodexRateLimitSnapshot? {
        guard rateLimits.isMainCodexBucket else {
            return nil
        }

        return rateLimits.toDomainSnapshot()
    }

    var isCodexRelated: Bool {
        rateLimits.limitId?.hasPrefix("codex") ?? true
    }
}

struct ThreadTokenUsageUpdatedNotificationPayload: Decodable {
    let threadId: String
    let turnId: String
    let tokenUsage: ThreadTokenUsagePayload
    let model: String?
    let slug: String?
    let modelSlug: String?
    let originator: String?
    let source: CodexSafeSourceMetadataPayload?
    let threadSource: String?
    let cliVersion: String?
    let modelProvider: String?
    let memoryMode: String?
    let approvalPolicy: String?
    let sandboxPolicy: CodexSandboxPolicyPayload?
    let permissionProfile: String?
    let realtimeActive: Bool?
    let truncationPolicy: String?
    let usageMode: String?
    let speedMode: String?
    let mode: String?

    var dimensions: [TokenUsageDimension] {
        TokenUsageDimension.unique(
            [
                TokenUsageDimension(.originator, originator),
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
            ].compactMap(\.self) + (source?.dimensions ?? []) + tokenUsage.dimensions
        )
    }

    func toDomainNotification() -> CodexTokenUsageNotification {
        CodexTokenUsageNotification(
            threadID: threadId,
            turnID: turnId,
            model: CodexModelIdentifier.firstNormalized([
                model,
                slug,
                modelSlug,
                tokenUsage.modelIdentifier,
            ]),
            tokenUsage: tokenUsage.toDomainUsage(),
            dimensions: dimensions
        )
    }

    enum CodingKeys: String, CodingKey {
        case threadId
        case threadIdSnake = "thread_id"
        case turnId
        case turnIdSnake = "turn_id"
        case tokenUsage
        case tokenUsageSnake = "token_usage"
        case model
        case slug
        case modelSlug
        case modelSlugSnake = "model_slug"
        case originator
        case source
        case threadSource
        case threadSourceSnake = "thread_source"
        case cliVersion
        case cliVersionSnake = "cli_version"
        case modelProvider
        case modelProviderSnake = "model_provider"
        case memoryMode
        case memoryModeSnake = "memory_mode"
        case approvalPolicy
        case approvalPolicySnake = "approval_policy"
        case sandboxPolicy
        case sandboxPolicySnake = "sandbox_policy"
        case permissionProfile
        case permissionProfileSnake = "permission_profile"
        case realtimeActive
        case realtimeActiveSnake = "realtime_active"
        case truncationPolicy
        case truncationPolicySnake = "truncation_policy"
        case usageMode
        case usageModeSnake = "usage_mode"
        case speedMode
        case speedModeSnake = "speed_mode"
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try Self.decodeRequiredString(from: container, .threadId, .threadIdSnake)
        turnId = try Self.decodeRequiredString(from: container, .turnId, .turnIdSnake)
        tokenUsage = try Self.decodeRequiredPayload(from: container, .tokenUsage, .tokenUsageSnake)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        slug = try? container.decodeIfPresent(String.self, forKey: .slug)
        modelSlug = Self.decodeString(from: container, .modelSlug, .modelSlugSnake)
        originator = Self.decodeString(from: container, .originator)
        source = try? container.decodeIfPresent(CodexSafeSourceMetadataPayload.self, forKey: .source)
        threadSource = Self.decodeString(from: container, .threadSource, .threadSourceSnake)
        cliVersion = Self.decodeString(from: container, .cliVersion, .cliVersionSnake)
        modelProvider = Self.decodeString(from: container, .modelProvider, .modelProviderSnake)
        memoryMode = Self.decodeString(from: container, .memoryMode, .memoryModeSnake)
        approvalPolicy = Self.decodeString(from: container, .approvalPolicy, .approvalPolicySnake)
        sandboxPolicy = (try? container.decodeIfPresent(CodexSandboxPolicyPayload.self, forKey: .sandboxPolicy))
            ?? (try? container.decodeIfPresent(CodexSandboxPolicyPayload.self, forKey: .sandboxPolicySnake))
        permissionProfile = Self.decodeString(from: container, .permissionProfile, .permissionProfileSnake)
        realtimeActive = (try? container.decodeIfPresent(Bool.self, forKey: .realtimeActive))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .realtimeActiveSnake))
        truncationPolicy = Self.decodeString(from: container, .truncationPolicy, .truncationPolicySnake)
        usageMode = Self.decodeString(from: container, .usageMode, .usageModeSnake)
        speedMode = Self.decodeString(from: container, .speedMode, .speedModeSnake)
        mode = Self.decodeString(from: container, .mode)
    }

    private static func decodeString(
        from container: KeyedDecodingContainer<CodingKeys>,
        _ keys: CodingKeys...
    ) -> String? {
        keys.lazy.compactMap { key in
            try? container.decodeIfPresent(String.self, forKey: key)
        }.first
    }

    private static func decodeRequiredString(
        from container: KeyedDecodingContainer<CodingKeys>,
        _ keys: CodingKeys...
    ) throws -> String {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }

        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing required token usage key.")
        )
    }

    private static func decodeRequiredPayload(
        from container: KeyedDecodingContainer<CodingKeys>,
        _ keys: CodingKeys...
    ) throws -> ThreadTokenUsagePayload {
        for key in keys {
            if let value = try? container.decodeIfPresent(ThreadTokenUsagePayload.self, forKey: key) {
                return value
            }
        }

        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing required token usage payload.")
        )
    }
}

struct ThreadTokenUsagePayload: Decodable {
    let last: TokenUsageBreakdownPayload
    let total: TokenUsageBreakdownPayload
    let modelContextWindow: Int64?
    let model: String?
    let slug: String?
    let modelSlug: String?
    let info: TokenUsageModelInfoPayload?
    let usageMode: String?
    let speedMode: String?
    let mode: String?

    var dimensions: [TokenUsageDimension] {
        TokenUsageDimension.unique(
            [
                TokenUsageDimension(.usageMode, usageMode ?? speedMode ?? mode),
                TokenUsageDimension(.usageMode, info?.usageMode ?? info?.speedMode ?? info?.mode),
            ].compactMap(\.self)
        )
    }

    var modelIdentifier: String? {
        CodexModelIdentifier.firstNormalized([
            model,
            slug,
            modelSlug,
            info?.modelIdentifier,
        ])
    }

    func toDomainUsage() -> CodexThreadTokenUsage {
        CodexThreadTokenUsage(
            last: last.toDomainBreakdown(),
            total: total.toDomainBreakdown(),
            modelContextWindow: modelContextWindow
        )
    }

    enum CodingKeys: String, CodingKey {
        case last
        case total
        case modelContextWindow
        case modelContextWindowSnake = "model_context_window"
        case model
        case slug
        case modelSlug
        case modelSlugSnake = "model_slug"
        case info
        case usageMode
        case usageModeSnake = "usage_mode"
        case speedMode
        case speedModeSnake = "speed_mode"
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        last = try container.decode(TokenUsageBreakdownPayload.self, forKey: .last)
        total = try container.decode(TokenUsageBreakdownPayload.self, forKey: .total)
        modelContextWindow = (try? container.decodeIfPresent(Int64.self, forKey: .modelContextWindow))
            ?? (try? container.decodeIfPresent(Int64.self, forKey: .modelContextWindowSnake))
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        slug = try? container.decodeIfPresent(String.self, forKey: .slug)
        modelSlug = (try? container.decodeIfPresent(String.self, forKey: .modelSlug))
            ?? (try? container.decodeIfPresent(String.self, forKey: .modelSlugSnake))
        info = try? container.decodeIfPresent(TokenUsageModelInfoPayload.self, forKey: .info)
        usageMode = (try? container.decodeIfPresent(String.self, forKey: .usageMode))
            ?? (try? container.decodeIfPresent(String.self, forKey: .usageModeSnake))
        speedMode = (try? container.decodeIfPresent(String.self, forKey: .speedMode))
            ?? (try? container.decodeIfPresent(String.self, forKey: .speedModeSnake))
        mode = try? container.decodeIfPresent(String.self, forKey: .mode)
    }
}

struct TokenUsageModelInfoPayload: Decodable {
    let model: String?
    let slug: String?
    let modelSlug: String?
    let usageMode: String?
    let speedMode: String?
    let mode: String?

    var modelIdentifier: String? {
        CodexModelIdentifier.firstNormalized([model, slug, modelSlug])
    }

    enum CodingKeys: String, CodingKey {
        case model
        case slug
        case modelSlug
        case modelSlugSnake = "model_slug"
        case usageMode
        case usageModeSnake = "usage_mode"
        case speedMode
        case speedModeSnake = "speed_mode"
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        slug = try? container.decodeIfPresent(String.self, forKey: .slug)
        modelSlug = (try? container.decodeIfPresent(String.self, forKey: .modelSlug))
            ?? (try? container.decodeIfPresent(String.self, forKey: .modelSlugSnake))
        usageMode = (try? container.decodeIfPresent(String.self, forKey: .usageMode))
            ?? (try? container.decodeIfPresent(String.self, forKey: .usageModeSnake))
        speedMode = (try? container.decodeIfPresent(String.self, forKey: .speedMode))
            ?? (try? container.decodeIfPresent(String.self, forKey: .speedModeSnake))
        mode = try? container.decodeIfPresent(String.self, forKey: .mode)
    }
}

struct TokenUsageBreakdownPayload: Decodable {
    let cachedInputTokens: Int64
    let inputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

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

struct RateLimitSnapshotPayload: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindowPayload?
    let secondary: RateLimitWindowPayload?
    let planType: String?

    var isMainCodexBucket: Bool {
        limitId == nil || limitId == "codex"
    }

    func toDomainSnapshot() -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            primary: primary?.toDomainWindow(),
            secondary: secondary?.toDomainWindow()
        )
    }

    func toUsageBucket(fallbackId: String) -> CodexUsageBucket {
        let resolvedId = limitId ?? fallbackId
        let kind: CodexUsageBucketKind = isMainCodexBucket ? .aggregate : .model
        let resolvedName = if kind == .aggregate {
            "All models"
        } else {
            limitName ?? resolvedId
        }

        return CodexUsageBucket(
            id: resolvedId,
            name: resolvedName,
            kind: kind,
            snapshot: toDomainSnapshot()
        )
    }
}

struct RateLimitWindowPayload: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int64?

    func toDomainWindow() -> CodexRateLimitWindow {
        CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMins,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

struct WhamUsageResponse: Decodable {
    let rateLimit: WhamRateLimitPayload?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    func selectedSnapshot() -> CodexRateLimitSnapshot? {
        rateLimit?.toDomainSnapshot()
    }

    func selectedUsageSnapshot() -> CodexUsageSnapshot? {
        selectedSnapshot().map { CodexUsageSnapshot.aggregateOnly(displaySnapshot: $0) }
    }
}

struct WhamRateLimitPayload: Decodable {
    let primaryWindow: WhamRateLimitWindowPayload?
    let secondaryWindow: WhamRateLimitWindowPayload?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    func toDomainSnapshot() -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            primary: primaryWindow?.toDomainWindow(),
            secondary: secondaryWindow?.toDomainWindow()
        )
    }
}

struct WhamRateLimitWindowPayload: Decodable {
    let usedPercent: Int
    let limitWindowSeconds: Int?
    let resetAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    func toDomainWindow() -> CodexRateLimitWindow {
        CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: limitWindowSeconds.map { $0 / 60 },
            resetsAt: resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

enum CodexAppServerListenSupport {
    static func supportsWebSocket(helpText: String) -> Bool {
        helpText.contains("ws://")
    }
}
