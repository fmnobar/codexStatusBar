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

    static let zero = TokenCategoryTotals(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )
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

struct CodexSafeMetadataValuePayload: Decodable, Equatable {
    let value: String?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self)
        {
            self.value = value
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? container.decodeIfPresent(String.self, forKey: .type))
            ?? (try? container.decodeIfPresent(String.self, forKey: .mode))
            ?? (try? container.decodeIfPresent(String.self, forKey: .value))
            ?? (try? container.decodeIfPresent(String.self, forKey: .name))
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case mode
        case value
        case name
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
        permissionProfile = Self.decodeFlexibleString(from: container, .permissionProfile, .permissionProfileSnake)
        realtimeActive = (try? container.decodeIfPresent(Bool.self, forKey: .realtimeActive))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .realtimeActiveSnake))
        truncationPolicy = Self.decodeFlexibleString(from: container, .truncationPolicy, .truncationPolicySnake)
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

    private static func decodeFlexibleString(
        from container: KeyedDecodingContainer<CodingKeys>,
        _ keys: CodingKeys...
    ) -> String? {
        keys.lazy.compactMap { key in
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }

            return (try? container.decodeIfPresent(CodexSafeMetadataValuePayload.self, forKey: key))?.value
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

struct CodexProfileTokenDailyBucket: Codable, Equatable, Identifiable {
    let date: String
    let tokens: Int64

    var id: String { date }
}

struct CodexProfileTokenUsageSnapshot: Codable, Equatable {
    let fetchedAt: Date
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSeconds: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let dailyBuckets: [CodexProfileTokenDailyBucket]

    init(
        fetchedAt: Date,
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        longestRunningTurnSeconds: Int64? = nil,
        currentStreakDays: Int64? = nil,
        longestStreakDays: Int64? = nil,
        dailyBuckets: [CodexProfileTokenDailyBucket]
    ) {
        self.fetchedAt = fetchedAt
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSeconds = longestRunningTurnSeconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.dailyBuckets = dailyBuckets
    }

    func bounded(to limit: Int) -> CodexProfileTokenUsageSnapshot {
        guard dailyBuckets.count > limit else {
            return self
        }

        return CodexProfileTokenUsageSnapshot(
            fetchedAt: fetchedAt,
            lifetimeTokens: lifetimeTokens,
            peakDailyTokens: peakDailyTokens,
            longestRunningTurnSeconds: longestRunningTurnSeconds,
            currentStreakDays: currentStreakDays,
            longestStreakDays: longestStreakDays,
            dailyBuckets: Array(dailyBuckets.sorted { $0.date < $1.date }.suffix(limit))
        )
    }
}

struct CodexResetCredit: Codable, Equatable, Identifiable {
    let title: String
    let resetType: String?
    let status: String
    let grantedAt: Date
    let expiresAt: Date
    let redeemedAt: Date?

    var id: String {
        [
            title,
            resetType ?? "",
            status,
            "\(Int64(grantedAt.timeIntervalSince1970))",
            "\(Int64(expiresAt.timeIntervalSince1970))",
        ].joined(separator: "|")
    }
}

struct CodexResetCreditSnapshot: Codable, Equatable {
    let fetchedAt: Date
    let availableCount: Int
    let credits: [CodexResetCredit]

    init(fetchedAt: Date, availableCount: Int, credits: [CodexResetCredit]) {
        self.fetchedAt = fetchedAt
        self.availableCount = max(availableCount, 0)
        self.credits = credits
            .filter { $0.status == CodexResetCreditsResponse.availableStatus }
            .sorted {
                if $0.expiresAt != $1.expiresAt {
                    return $0.expiresAt < $1.expiresAt
                }
                return $0.grantedAt < $1.grantedAt
            }
    }
}

struct CodexProfileTokenComparisonRow: Equatable, Identifiable {
    let id: String
    let title: String
    let profileTokens: Int64?
    let localCapturedTokens: Int64

    var deltaTokens: Int64? {
        profileTokens.map { localCapturedTokens - $0 }
    }

    var localToProfileRatio: Double? {
        guard let profileTokens, profileTokens > 0 else {
            return nil
        }

        return Double(localCapturedTokens) / Double(profileTokens)
    }
}

struct CodexProfileTokenComparisonSummary: Equatable {
    let generatedAt: Date
    let profileSnapshot: CodexProfileTokenUsageSnapshot?
    let localTotals: LocalTokenComparisonTotals
    let rows: [CodexProfileTokenComparisonRow]

    static func make(
        profileSnapshot: CodexProfileTokenUsageSnapshot?,
        localTotals: LocalTokenComparisonTotals,
        now: Date
    ) -> CodexProfileTokenComparisonSummary {
        let utcDay = Self.utcDayString(for: now)
        let utcMonthPrefix = String(utcDay.prefix(7)) + "-"
        let profileDayTokens = profileSnapshot?.dailyBuckets
            .filter { $0.date == utcDay }
            .reduce(Int64(0)) { $0 + $1.tokens }
        let profileMonthTokens = profileSnapshot?.dailyBuckets
            .filter { $0.date.hasPrefix(utcMonthPrefix) }
            .reduce(Int64(0)) { $0 + $1.tokens }

        return CodexProfileTokenComparisonSummary(
            generatedAt: now,
            profileSnapshot: profileSnapshot,
            localTotals: localTotals,
            rows: [
                CodexProfileTokenComparisonRow(
                    id: "all_time",
                    title: "All time",
                    profileTokens: profileSnapshot?.lifetimeTokens,
                    localCapturedTokens: localTotals.allTimeTokens
                ),
                CodexProfileTokenComparisonRow(
                    id: "utc_month",
                    title: "Current UTC month",
                    profileTokens: profileMonthTokens,
                    localCapturedTokens: localTotals.currentUTCMonthTokens
                ),
                CodexProfileTokenComparisonRow(
                    id: "utc_day",
                    title: "Current UTC day",
                    profileTokens: profileDayTokens,
                    localCapturedTokens: localTotals.currentUTCDayTokens
                ),
            ]
        )
    }

    private static func utcDayString(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }
}

struct LocalTokenComparisonTotals: Codable, Equatable {
    let generatedAt: Date
    let allTimeTokens: Int64
    let currentUTCMonthTokens: Int64
    let currentUTCDayTokens: Int64
}

struct CodexProfileTokenUsageResponse: Decodable {
    let stats: Stats?

    struct Stats: Decodable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
        let dailyUsageBuckets: [DailyUsageBucket]?

        enum CodingKeys: String, CodingKey {
            case lifetimeTokens = "lifetime_tokens"
            case peakDailyTokens = "peak_daily_tokens"
            case dailyUsageBuckets = "daily_usage_buckets"
        }
    }

    struct DailyUsageBucket: Decodable {
        let startDate: String?
        let tokens: Int64?

        enum CodingKeys: String, CodingKey {
            case startDate = "start_date"
            case tokens
        }

        func domainBucket() -> CodexProfileTokenDailyBucket? {
            guard let startDate = CodexTokenUsageDateSanitizer.safeUTCDateString(startDate),
                  let tokens
            else {
                return nil
            }

            return CodexProfileTokenDailyBucket(date: startDate, tokens: max(tokens, 0))
        }
    }

    func domainSnapshot(fetchedAt: Date) -> CodexProfileTokenUsageSnapshot {
        CodexProfileTokenUsageSnapshot(
            fetchedAt: fetchedAt,
            lifetimeTokens: stats?.lifetimeTokens.map { max($0, 0) },
            peakDailyTokens: stats?.peakDailyTokens.map { max($0, 0) },
            dailyBuckets: (stats?.dailyUsageBuckets ?? [])
                .compactMap { $0.domainBucket() }
                .sorted { $0.date < $1.date }
        )
    }
}

struct CodexAccountTokenUsageResponse: Decodable {
    let summary: CodexAccountTokenUsageSummary?
    let dailyUsageBuckets: [CodexAccountTokenUsageDailyBucket]?

    func domainSnapshot(fetchedAt: Date) -> CodexProfileTokenUsageSnapshot {
        CodexProfileTokenUsageSnapshot(
            fetchedAt: fetchedAt,
            lifetimeTokens: summary?.lifetimeTokens.map { max($0, 0) },
            peakDailyTokens: summary?.peakDailyTokens.map { max($0, 0) },
            longestRunningTurnSeconds: summary?.longestRunningTurnSec.map { max($0, 0) },
            currentStreakDays: summary?.currentStreakDays.map { max($0, 0) },
            longestStreakDays: summary?.longestStreakDays.map { max($0, 0) },
            dailyBuckets: (dailyUsageBuckets ?? [])
                .compactMap { $0.domainBucket() }
                .sorted { $0.date < $1.date }
        )
    }
}

struct CodexResetCreditsResponse: Decodable {
    static let availableStatus = "available"

    let availableCount: Int?
    let credits: [Credit]?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }

    struct Credit: Decodable {
        let title: String?
        let resetType: String?
        let status: String?
        let grantedAt: String?
        let expiresAt: String?
        let redeemedAt: String?

        enum CodingKeys: String, CodingKey {
            case title
            case resetType = "reset_type"
            case status
            case grantedAt = "granted_at"
            case expiresAt = "expires_at"
            case redeemedAt = "redeemed_at"
        }

        func domainCredit() -> CodexResetCredit? {
            guard let status = CodexResetCreditSanitizer.safeIdentifier(status),
                  status == CodexResetCreditsResponse.availableStatus,
                  let grantedAt = CodexResetCreditSanitizer.safeDate(grantedAt),
                  let expiresAt = CodexResetCreditSanitizer.safeDate(expiresAt)
            else {
                return nil
            }

            return CodexResetCredit(
                title: CodexResetCreditSanitizer.safeDisplayTitle(title),
                resetType: CodexResetCreditSanitizer.safeIdentifier(resetType),
                status: status,
                grantedAt: grantedAt,
                expiresAt: expiresAt,
                redeemedAt: CodexResetCreditSanitizer.safeDate(redeemedAt)
            )
        }
    }

    func domainSnapshot(fetchedAt: Date) -> CodexResetCreditSnapshot {
        let availableCredits = (credits ?? []).compactMap { $0.domainCredit() }
        return CodexResetCreditSnapshot(
            fetchedAt: fetchedAt,
            availableCount: availableCount ?? availableCredits.count,
            credits: availableCredits
        )
    }
}

enum CodexResetCreditSanitizer {
    static func safeDisplayTitle(_ value: String?) -> String {
        guard let value else {
            return "Usage reset"
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Usage reset"
        }

        let lowercased = trimmed.lowercased()
        guard !lowercased.contains("http://"),
              !lowercased.contains("https://"),
              !lowercased.contains("@")
        else {
            return "Usage reset"
        }

        let scalars = trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else {
            return "Usage reset"
        }

        if sanitized.count > 64 {
            return String(sanitized.prefix(61)) + "..."
        }

        return sanitized
    }

    static func safeIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }

        return trimmed.lowercased()
    }

    static func safeDate(_ value: String?) -> Date? {
        guard let value, value.count <= 40 else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct CodexAccountTokenUsageSummary: Decodable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
}

struct CodexAccountTokenUsageDailyBucket: Decodable {
    let startDate: String?
    let tokens: Int64?

    func domainBucket() -> CodexProfileTokenDailyBucket? {
        guard let startDate = CodexTokenUsageDateSanitizer.safeUTCDateString(startDate),
              let tokens
        else {
            return nil
        }

        return CodexProfileTokenDailyBucket(date: startDate, tokens: max(tokens, 0))
    }
}

enum CodexTokenUsageDateSanitizer {
    static func safeUTCDateString(_ value: String?) -> String? {
        guard let value, value.count == 10 else {
            return nil
        }

        let scalars = Array(value.unicodeScalars)
        guard scalars.indices.contains(9),
              scalars[4] == "-",
              scalars[7] == "-"
        else {
            return nil
        }

        let digitIndices = [0, 1, 2, 3, 5, 6, 8, 9]
        guard digitIndices.allSatisfy({ CharacterSet.decimalDigits.contains(scalars[$0]) }) else {
            return nil
        }

        return value
    }
}

enum CodexProfileTokenUsageFetchError: LocalizedError, Equatable {
    case unauthorized
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Codex Profile token usage is not authorized."
        case .unexpectedStatusCode:
            return "Codex Profile token usage returned an unexpected response."
        }
    }
}

enum CodexResetCreditFetchError: LocalizedError, Equatable {
    case unauthorized
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Codex reset credits are not authorized."
        case .unexpectedStatusCode:
            return "Codex reset credits returned an unexpected response."
        }
    }
}

struct CodexProfileTokenUsageHTTPClient {
    typealias ResponseLoader = (URLRequest) async throws -> (Data, URLResponse)
    typealias AuthTokenProvider = @MainActor (Bool) async throws -> String?

    let endpoint: URL
    let responseLoader: ResponseLoader
    let now: () -> Date

    init(
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!,
        responseLoader: @escaping ResponseLoader = { request in
            try await URLSession.shared.data(for: request)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.endpoint = endpoint
        self.responseLoader = responseLoader
        self.now = now
    }

    @MainActor
    func fetch(authTokenProvider: AuthTokenProvider) async throws -> CodexProfileTokenUsageSnapshot {
        do {
            return try await fetch(refreshToken: false, authTokenProvider: authTokenProvider)
        } catch CodexProfileTokenUsageFetchError.unauthorized {
            return try await fetch(refreshToken: true, authTokenProvider: authTokenProvider)
        }
    }

    @MainActor
    private func fetch(
        refreshToken: Bool,
        authTokenProvider: AuthTokenProvider
    ) async throws -> CodexProfileTokenUsageSnapshot {
        guard let authToken = try await authTokenProvider(refreshToken), !authToken.isEmpty else {
            throw CodexClientError.authTokenUnavailable
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexStatusBar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await responseLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexClientError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return try JSONDecoder()
                .decode(CodexProfileTokenUsageResponse.self, from: data)
                .domainSnapshot(fetchedAt: now())
        case 401:
            throw CodexProfileTokenUsageFetchError.unauthorized
        default:
            throw CodexProfileTokenUsageFetchError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }
}

struct CodexResetCreditHTTPClient {
    typealias ResponseLoader = (URLRequest) async throws -> (Data, URLResponse)
    typealias AuthTokenProvider = @MainActor (Bool) async throws -> String?

    let endpoint: URL
    let responseLoader: ResponseLoader
    let now: () -> Date

    init(
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
        responseLoader: @escaping ResponseLoader = { request in
            try await URLSession.shared.data(for: request)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.endpoint = endpoint
        self.responseLoader = responseLoader
        self.now = now
    }

    @MainActor
    func fetch(authTokenProvider: AuthTokenProvider) async throws -> CodexResetCreditSnapshot {
        do {
            return try await fetch(refreshToken: false, authTokenProvider: authTokenProvider)
        } catch CodexResetCreditFetchError.unauthorized {
            return try await fetch(refreshToken: true, authTokenProvider: authTokenProvider)
        }
    }

    @MainActor
    private func fetch(
        refreshToken: Bool,
        authTokenProvider: AuthTokenProvider
    ) async throws -> CodexResetCreditSnapshot {
        guard let authToken = try await authTokenProvider(refreshToken), !authToken.isEmpty else {
            throw CodexClientError.authTokenUnavailable
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexStatusBar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await responseLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexClientError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return try JSONDecoder()
                .decode(CodexResetCreditsResponse.self, from: data)
                .domainSnapshot(fetchedAt: now())
        case 401:
            throw CodexResetCreditFetchError.unauthorized
        default:
            throw CodexResetCreditFetchError.unexpectedStatusCode(httpResponse.statusCode)
        }
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
