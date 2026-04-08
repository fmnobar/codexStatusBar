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
