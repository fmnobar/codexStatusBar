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
}

struct AccountRateLimitsUpdatedNotificationPayload: Decodable {
    let rateLimits: RateLimitSnapshotPayload

    func selectedSnapshot() -> CodexRateLimitSnapshot? {
        guard rateLimits.isMainCodexBucket else {
            return nil
        }

        return rateLimits.toDomainSnapshot()
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
