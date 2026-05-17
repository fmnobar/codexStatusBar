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
        return firstTokenScalars.map { String(String.UnicodeScalarView($0)) }
    }

    static func firstNormalized(_ values: [String?]) -> String? {
        values.lazy.compactMap(normalized).first
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
            tokenUsage: tokenUsage.toDomainUsage()
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
}

struct TokenUsageModelInfoPayload: Decodable {
    let model: String?
    let slug: String?
    let modelSlug: String?

    var modelIdentifier: String? {
        CodexModelIdentifier.firstNormalized([model, slug, modelSlug])
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
