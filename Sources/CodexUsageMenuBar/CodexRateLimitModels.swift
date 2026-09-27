import Foundation

enum UsageLimitWindow: String, CaseIterable, Codable, Identifiable, Equatable {
    case fiveHour
    case sevenDay

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .sevenDay:
            return "7d"
        }
    }
}

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

enum CodexRateLimitWindowKind: Equatable {
    case fiveHour
    case sevenDay

    init?(windowDurationMinutes: Int?) {
        switch windowDurationMinutes {
        case 300:
            self = .fiveHour
        case 10_080:
            self = .sevenDay
        default:
            return nil
        }
    }

    init(usageWindow: UsageLimitWindow) {
        switch usageWindow {
        case .fiveHour:
            self = .fiveHour
        case .sevenDay:
            self = .sevenDay
        }
    }

    var displayTitle: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .sevenDay:
            return "7d"
        }
    }
}

enum CodexRateLimitWindowSlot: Equatable {
    case primary
    case secondary

    var fallbackTitle: String {
        switch self {
        case .primary:
            return "Primary"
        case .secondary:
            return "Secondary"
        }
    }
}

struct CodexRateLimitWindowReference: Equatable {
    let slot: CodexRateLimitWindowSlot
    let window: CodexRateLimitWindow

    var kind: CodexRateLimitWindowKind? {
        CodexRateLimitWindowKind(windowDurationMinutes: window.windowDurationMinutes)
    }

    var sourceTitle: String {
        if let kind {
            return kind.displayTitle
        }

        if let duration = window.windowDurationMinutes, duration > 0 {
            return "\(duration)m"
        }

        return slot.fallbackTitle
    }
}

struct CodexRateLimitSnapshot: Equatable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?

    var windowReferences: [CodexRateLimitWindowReference] {
        [
            primary.map { CodexRateLimitWindowReference(slot: .primary, window: $0) },
            secondary.map { CodexRateLimitWindowReference(slot: .secondary, window: $0) },
        ].compactMap(\.self)
    }

    func windowReference(for kind: CodexRateLimitWindowKind) -> CodexRateLimitWindowReference? {
        windowReferences.first { $0.kind == kind }
    }

    func classifiedWindow(for kind: CodexRateLimitWindowKind) -> CodexRateLimitWindow? {
        windowReference(for: kind)?.window
    }

    func window(for usageWindow: UsageLimitWindow) -> CodexRateLimitWindow? {
        classifiedWindow(for: CodexRateLimitWindowKind(usageWindow: usageWindow))
    }
}

struct CodexUsageSnapshot: Equatable {
    let displaySnapshot: CodexRateLimitSnapshot

    static func aggregateOnly(displaySnapshot: CodexRateLimitSnapshot) -> CodexUsageSnapshot {
        CodexUsageSnapshot(displaySnapshot: displaySnapshot)
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
        .aggregateOnly(displaySnapshot: displaySnapshotOverride ?? selectedSnapshot())
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

    func selectedUsageSnapshot() -> CodexUsageSnapshot? {
        selectedSnapshot().map { CodexUsageSnapshot.aggregateOnly(displaySnapshot: $0) }
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
        let windowDurationMinutes: Int? = limitWindowSeconds.flatMap { seconds -> Int? in
            guard seconds.isMultiple(of: 60) else {
                return nil
            }

            return seconds / 60
        }

        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

enum CodexAppServerListenSupport {
    struct Capabilities: Equatable, Sendable {
        let supportsStandardIO: Bool
        let supportsWebSocket: Bool
        let explicitlyPrefersStandardIO: Bool

        var preferredTransport: Transport? {
            if supportsStandardIO, explicitlyPrefersStandardIO || !supportsWebSocket {
                return .standardIO
            }
            if supportsWebSocket {
                return .legacyWebSocket
            }
            if supportsStandardIO {
                return .standardIO
            }
            return nil
        }

        enum Transport: Equatable, Sendable {
            case standardIO
            case legacyWebSocket
        }
    }

    static func capabilities(helpText: String) -> Capabilities {
        Capabilities(
            supportsStandardIO: helpText.contains("stdio://") || helpText.contains("--stdio"),
            supportsWebSocket: helpText.contains("ws://"),
            // Newer CLIs expose an explicit stdio switch and should be owned over pipes.
            // Older CLIs only advertised listen URLs; retain their WebSocket path.
            explicitlyPrefersStandardIO: helpText.contains("--stdio")
        )
    }

    static func supportsWebSocket(helpText: String) -> Bool {
        capabilities(helpText: helpText).supportsWebSocket
    }
}
