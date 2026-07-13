import CryptoKit
import Darwin
import Foundation
import SQLite3

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum CodexGitRemoteSanitizer {
    static func sanitized(_ value: String?) -> String? {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let trimmed = value?.trimmingCharacters(in: trimSet) ?? ""
        guard !trimmed.isEmpty, trimmed.count <= 512,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !trimmed.contains(where: { $0.isWhitespace })
        else {
            return nil
        }

        if trimmed.contains("://") {
            guard var components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  ["https", "http", "ssh", "git", "file"].contains(scheme)
            else {
                return nil
            }
            guard scheme != "file" else {
                // Local file remotes reveal a private filesystem path and have no portable identity.
                return nil
            }
            guard components.host?.isEmpty == false,
                  !components.path.isEmpty,
                  components.path != "/",
                  components.path.unicodeScalars.allSatisfy({
                      !CharacterSet.whitespacesAndNewlines.contains($0)
                          && !CharacterSet.controlCharacters.contains($0)
                  })
            else {
                return nil
            }

            components.scheme = scheme
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string.flatMap { normalizedLength($0) }
        }

        // Git's SCP-style syntax is not a URL. Keep host:path while dropping the
        // optional user and any query/fragment payload that could carry secrets.
        let withoutSuffix = String(trimmed.prefix { $0 != "?" && $0 != "#" })
        guard let colon = withoutSuffix.firstIndex(of: ":"), colon != withoutSuffix.startIndex else {
            return nil
        }
        let authority = String(withoutSuffix[..<colon])
        let path = String(withoutSuffix[withoutSuffix.index(after: colon)...])
        let host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard !host.isEmpty,
              !path.isEmpty,
              !host.contains("/"),
              !path.hasPrefix("/"),
              !path.contains("\\")
        else {
            return nil
        }
        return normalizedLength("\(host):\(path)")
    }

    private static func normalizedLength(_ value: String) -> String? {
        value.isEmpty || value.count > 512 ? nil : value
    }
}

struct ImportedCodexTokenUsageSample: Equatable {
    let notification: CodexTokenUsageNotification
    let receivedAt: Date
    let context: TokenUsageContext?

    init(
        notification: CodexTokenUsageNotification,
        receivedAt: Date,
        context: TokenUsageContext? = nil
    ) {
        self.notification = notification
        self.receivedAt = receivedAt
        self.context = context?.hasAnyValue == true ? context : nil
    }
}

struct TokenUsageImportResult: Equatable, Sendable {
    let insertedCount: Int
    let duplicateCount: Int
    let repairedModelCount: Int
    let repairedContextCount: Int
    let repairedDimensionCount: Int

    init(
        insertedCount: Int,
        duplicateCount: Int,
        repairedModelCount: Int = 0,
        repairedContextCount: Int = 0,
        repairedDimensionCount: Int = 0
    ) {
        self.insertedCount = insertedCount
        self.duplicateCount = duplicateCount
        self.repairedModelCount = repairedModelCount
        self.repairedContextCount = repairedContextCount
        self.repairedDimensionCount = repairedDimensionCount
    }

    static let empty = TokenUsageImportResult(insertedCount: 0, duplicateCount: 0)

    var changedCount: Int {
        insertedCount + repairedModelCount + repairedContextCount + repairedDimensionCount
    }
}

enum CodexLiveTokenCaptureStatus: String, Equatable, Sendable {
    case neverChecked = "never_checked"
    case imported
    case noNewEvents = "no_new_events"
    case duplicateOnly = "duplicate_only"
    case repaired
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            "Not checked yet"
        case .imported:
            "Imported new tokens"
        case .noNewEvents:
            "Checked, no new token events"
        case .duplicateOnly:
            "Checked, duplicates only"
        case .repaired:
            "Checked, repaired context"
        case .failed:
            "Capture failed"
        }
    }

    var isSuccessfulCheck: Bool {
        switch self {
        case .imported, .noNewEvents, .duplicateOnly, .repaired:
            true
        case .neverChecked, .failed:
            false
        }
    }
}

struct CodexLiveTokenCaptureState: Equatable, Sendable {
    static let codexLogSourceKey = "codex-log"

    let sourceKey: String
    let lastCheckedAt: Date?
    let lastImportedEventAt: Date?
    let lastLogRowID: Int64
    let status: CodexLiveTokenCaptureStatus
    let result: TokenUsageImportResult
    let lastErrorText: String?

    init(
        sourceKey: String = Self.codexLogSourceKey,
        lastCheckedAt: Date? = nil,
        lastImportedEventAt: Date? = nil,
        lastLogRowID: Int64 = 0,
        status: CodexLiveTokenCaptureStatus = .neverChecked,
        result: TokenUsageImportResult = .empty,
        lastErrorText: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.lastCheckedAt = lastCheckedAt
        self.lastImportedEventAt = lastImportedEventAt
        self.lastLogRowID = max(lastLogRowID, 0)
        self.status = status
        self.result = result
        self.lastErrorText = lastErrorText
    }

    var hasSuccessfulCheck: Bool {
        status.isSuccessfulCheck && lastCheckedAt != nil && lastErrorText == nil
    }

    func hasSuccessfulCheck(containing date: Date, calendar: Calendar) -> Bool {
        guard let lastCheckedAt, hasSuccessfulCheck else {
            return false
        }

        return calendar.isDate(lastCheckedAt, inSameDayAs: date)
    }
}

struct CodexLiveTokenCaptureRunResult: Equatable, Sendable {
    let importResult: TokenUsageImportResult
    let maxLogRowID: Int64
    let lastImportedEventAt: Date?
}

enum CodexTurnPerformanceCaptureStatus: String, Equatable, Sendable {
    case neverChecked = "never_checked"
    case imported
    case noNewEvents = "no_new_events"
    case duplicateOnly = "duplicate_only"
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            "Not checked yet"
        case .imported:
            "Imported new events"
        case .noNewEvents:
            "Checked, no new events"
        case .duplicateOnly:
            "Checked, duplicates only"
        case .failed:
            "Capture failed"
        }
    }
}

struct CodexTurnPerformanceCaptureState: Equatable, Sendable {
    static let codexOtelLogSourceKey = "codex-otel-logs"

    let sourceKey: String
    let lastCheckedAt: Date?
    let lastImportedEventAt: Date?
    let lastLogRowID: Int64
    let status: CodexTurnPerformanceCaptureStatus
    let insertedCount: Int
    let duplicateCount: Int
    let lastErrorText: String?

    init(
        sourceKey: String = Self.codexOtelLogSourceKey,
        lastCheckedAt: Date? = nil,
        lastImportedEventAt: Date? = nil,
        lastLogRowID: Int64 = 0,
        status: CodexTurnPerformanceCaptureStatus = .neverChecked,
        insertedCount: Int = 0,
        duplicateCount: Int = 0,
        lastErrorText: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.lastCheckedAt = lastCheckedAt
        self.lastImportedEventAt = lastImportedEventAt
        self.lastLogRowID = max(lastLogRowID, 0)
        self.status = status
        self.insertedCount = insertedCount
        self.duplicateCount = duplicateCount
        self.lastErrorText = lastErrorText
    }
}

struct CodexTurnPerformanceImportResult: Equatable, Sendable {
    let insertedCount: Int
    let duplicateCount: Int
    let runtimeDimensionInsertedCount: Int

    init(insertedCount: Int, duplicateCount: Int, runtimeDimensionInsertedCount: Int = 0) {
        self.insertedCount = insertedCount
        self.duplicateCount = duplicateCount
        self.runtimeDimensionInsertedCount = runtimeDimensionInsertedCount
    }

    static let empty = CodexTurnPerformanceImportResult(
        insertedCount: 0,
        duplicateCount: 0,
        runtimeDimensionInsertedCount: 0
    )
}

struct CodexTurnPerformanceCaptureRunResult: Equatable, Sendable {
    let importResult: CodexTurnPerformanceImportResult
    let maxLogRowID: Int64
    let lastImportedEventAt: Date?
}

enum CodexSessionTaskTimingCaptureStatus: String, Equatable, Sendable {
    case neverChecked = "never_checked"
    case imported
    case updated
    case noNewEvents = "no_new_events"
    case duplicateOnly = "duplicate_only"
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            "Not checked yet"
        case .imported:
            "Imported new timing"
        case .updated:
            "Checked, updated timing"
        case .noNewEvents:
            "Checked, no new timing"
        case .duplicateOnly:
            "Checked, duplicates only"
        case .failed:
            "Capture failed"
        }
    }
}

struct CodexSessionTaskTimingCaptureState: Equatable, Sendable {
    static let sessionJSONLSourceKey = "codex-session-task-timing"

    let sourceKey: String
    let lastCheckedAt: Date?
    let lastImportedEventAt: Date?
    let status: CodexSessionTaskTimingCaptureStatus
    let filesDiscovered: Int
    let filesScanned: Int
    let filesSkippedUnchanged: Int
    let insertedCount: Int
    let updatedCount: Int
    let duplicateCount: Int
    let failedLinesSkipped: Int
    let lastErrorText: String?

    init(
        sourceKey: String = Self.sessionJSONLSourceKey,
        lastCheckedAt: Date? = nil,
        lastImportedEventAt: Date? = nil,
        status: CodexSessionTaskTimingCaptureStatus = .neverChecked,
        filesDiscovered: Int = 0,
        filesScanned: Int = 0,
        filesSkippedUnchanged: Int = 0,
        insertedCount: Int = 0,
        updatedCount: Int = 0,
        duplicateCount: Int = 0,
        failedLinesSkipped: Int = 0,
        lastErrorText: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.lastCheckedAt = lastCheckedAt
        self.lastImportedEventAt = lastImportedEventAt
        self.status = status
        self.filesDiscovered = max(filesDiscovered, 0)
        self.filesScanned = max(filesScanned, 0)
        self.filesSkippedUnchanged = max(filesSkippedUnchanged, 0)
        self.insertedCount = max(insertedCount, 0)
        self.updatedCount = max(updatedCount, 0)
        self.duplicateCount = max(duplicateCount, 0)
        self.failedLinesSkipped = max(failedLinesSkipped, 0)
        self.lastErrorText = lastErrorText
    }
}

enum CodexThreadCatalogCaptureStatus: String, Equatable, Sendable {
    case neverChecked = "never_checked"
    case imported
    case updated
    case noNewEvents = "no_new_events"
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            "Not checked yet"
        case .imported:
            "Imported thread metadata"
        case .updated:
            "Checked, updated metadata"
        case .noNewEvents:
            "Checked, no new metadata"
        case .failed:
            "Capture failed"
        }
    }
}

struct CodexThreadCatalogCaptureState: Equatable, Sendable {
    static let stateSQLiteSourceKey = "codex-state-thread-catalog"

    let sourceKey: String
    let lastCheckedAt: Date?
    let lastImportedThreadUpdatedAt: Date?
    let status: CodexThreadCatalogCaptureStatus
    let threadsInsertedCount: Int
    let threadsUpdatedCount: Int
    let spawnEdgesInsertedCount: Int
    let spawnEdgesUpdatedCount: Int
    let dynamicToolsInsertedCount: Int
    let dynamicToolsUpdatedCount: Int
    let staleRowsDeletedCount: Int
    let sourcePath: String?
    let lastErrorText: String?

    init(
        sourceKey: String = Self.stateSQLiteSourceKey,
        lastCheckedAt: Date? = nil,
        lastImportedThreadUpdatedAt: Date? = nil,
        status: CodexThreadCatalogCaptureStatus = .neverChecked,
        threadsInsertedCount: Int = 0,
        threadsUpdatedCount: Int = 0,
        spawnEdgesInsertedCount: Int = 0,
        spawnEdgesUpdatedCount: Int = 0,
        dynamicToolsInsertedCount: Int = 0,
        dynamicToolsUpdatedCount: Int = 0,
        staleRowsDeletedCount: Int = 0,
        sourcePath: String? = nil,
        lastErrorText: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.lastCheckedAt = lastCheckedAt
        self.lastImportedThreadUpdatedAt = lastImportedThreadUpdatedAt
        self.status = status
        self.threadsInsertedCount = max(threadsInsertedCount, 0)
        self.threadsUpdatedCount = max(threadsUpdatedCount, 0)
        self.spawnEdgesInsertedCount = max(spawnEdgesInsertedCount, 0)
        self.spawnEdgesUpdatedCount = max(spawnEdgesUpdatedCount, 0)
        self.dynamicToolsInsertedCount = max(dynamicToolsInsertedCount, 0)
        self.dynamicToolsUpdatedCount = max(dynamicToolsUpdatedCount, 0)
        self.staleRowsDeletedCount = max(staleRowsDeletedCount, 0)
        self.sourcePath = Self.normalizedPathPointer(sourcePath)
        self.lastErrorText = lastErrorText
    }

    var changedRowCount: Int {
        threadsInsertedCount
            + threadsUpdatedCount
            + spawnEdgesInsertedCount
            + spawnEdgesUpdatedCount
            + dynamicToolsInsertedCount
            + dynamicToolsUpdatedCount
            + staleRowsDeletedCount
    }

    static func normalizedPathPointer(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        guard !trimmedValue.isEmpty, trimmedValue.count <= 1_024 else {
            return nil
        }
        guard trimmedValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmedValue
    }
}

enum CodexModelCapabilitiesCaptureStatus: String, Equatable, Sendable {
    case neverChecked = "never_checked"
    case imported
    case updated
    case noNewEvents = "no_new_events"
    case noSource = "no_source"
    case malformed
    case noModels = "no_models"
    case failed

    var displayText: String {
        switch self {
        case .neverChecked:
            "Not checked yet"
        case .imported:
            "Imported model capabilities"
        case .updated:
            "Checked, updated capabilities"
        case .noNewEvents:
            "Checked, no model changes"
        case .noSource:
            "Models cache not found"
        case .malformed:
            "Models cache unreadable"
        case .noModels:
            "No models in cache"
        case .failed:
            "Capture failed"
        }
    }
}

struct CodexModelCapabilitiesCaptureState: Equatable, Sendable {
    static let modelsCacheSourceKey = "codex-model-capabilities"

    let sourceKey: String
    let lastCheckedAt: Date?
    let cacheFetchedAt: Date?
    let status: CodexModelCapabilitiesCaptureStatus
    let modelsInsertedCount: Int
    let modelsUpdatedCount: Int
    let childRowsInsertedCount: Int
    let staleRowsDeletedCount: Int
    let clientVersion: String?
    let sourcePath: String?
    let lastErrorText: String?

    init(
        sourceKey: String = Self.modelsCacheSourceKey,
        lastCheckedAt: Date? = nil,
        cacheFetchedAt: Date? = nil,
        status: CodexModelCapabilitiesCaptureStatus = .neverChecked,
        modelsInsertedCount: Int = 0,
        modelsUpdatedCount: Int = 0,
        childRowsInsertedCount: Int = 0,
        staleRowsDeletedCount: Int = 0,
        clientVersion: String? = nil,
        sourcePath: String? = nil,
        lastErrorText: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.lastCheckedAt = lastCheckedAt
        self.cacheFetchedAt = cacheFetchedAt
        self.status = status
        self.modelsInsertedCount = max(modelsInsertedCount, 0)
        self.modelsUpdatedCount = max(modelsUpdatedCount, 0)
        self.childRowsInsertedCount = max(childRowsInsertedCount, 0)
        self.staleRowsDeletedCount = max(staleRowsDeletedCount, 0)
        self.clientVersion = CodexTokenContextNormalizer.normalizedIdentifier(clientVersion)
        self.sourcePath = CodexThreadCatalogCaptureState.normalizedPathPointer(sourcePath)
        self.lastErrorText = lastErrorText
    }

    var changedRowCount: Int {
        modelsInsertedCount + modelsUpdatedCount + childRowsInsertedCount + staleRowsDeletedCount
    }
}

struct CodexModelCapabilitiesImportResult: Equatable, Sendable {
    let modelsInsertedCount: Int
    let modelsUpdatedCount: Int
    let childRowsInsertedCount: Int
    let staleRowsDeletedCount: Int
    let cacheFetchedAt: Date?
    let clientVersion: String?

    var changedRowCount: Int {
        modelsInsertedCount + modelsUpdatedCount + childRowsInsertedCount + staleRowsDeletedCount
    }
}

struct CodexModelCapabilitiesImportBatch: Equatable, Sendable {
    let models: [CodexModelCapability]
    let cacheFetchedAt: Date?
    let clientVersion: String?
}

struct CodexModelCapability: Equatable, Sendable {
    let slug: String
    let displayName: String?
    let visibility: String?
    let supportedInAPI: Bool?
    let priority: Int64?
    let contextWindow: Int64?
    let maxContextWindow: Int64?
    let effectiveContextWindowPercent: Int64?
    let defaultReasoningLevel: String?
    let supportsReasoningSummaries: Bool?
    let defaultReasoningSummary: String?
    let supportsVerbosity: Bool?
    let defaultVerbosity: String?
    let shellType: String?
    let applyPatchToolType: String?
    let webSearchToolType: String?
    let supportsParallelToolCalls: Bool?
    let supportsImageDetailOriginal: Bool?
    let supportsSearchTool: Bool?
    let truncationPolicyMode: String?
    let truncationPolicyLimit: Int64?
    let reasoningLevels: [CodexModelCapabilityReasoningLevel]
    let serviceTiers: [CodexModelCapabilityServiceTier]
    let speedTiers: [CodexModelCapabilitySpeedTier]
    let inputModalities: [CodexModelCapabilityInputModality]
    let toolIdentifiers: [CodexModelCapabilityToolIdentifier]

    init?(
        slug: String?,
        displayName: String?,
        visibility: String?,
        supportedInAPI: Bool?,
        priority: Int64?,
        contextWindow: Int64?,
        maxContextWindow: Int64?,
        effectiveContextWindowPercent: Int64?,
        defaultReasoningLevel: String?,
        supportsReasoningSummaries: Bool?,
        defaultReasoningSummary: String?,
        supportsVerbosity: Bool?,
        defaultVerbosity: String?,
        shellType: String?,
        applyPatchToolType: String?,
        webSearchToolType: String?,
        supportsParallelToolCalls: Bool?,
        supportsImageDetailOriginal: Bool?,
        supportsSearchTool: Bool?,
        truncationPolicyMode: String?,
        truncationPolicyLimit: Int64?,
        reasoningLevels: [CodexModelCapabilityReasoningLevel] = [],
        serviceTiers: [CodexModelCapabilityServiceTier] = [],
        speedTiers: [CodexModelCapabilitySpeedTier] = [],
        inputModalities: [CodexModelCapabilityInputModality] = [],
        toolIdentifiers: [CodexModelCapabilityToolIdentifier] = []
    ) {
        guard let slug = CodexModelIdentifier.normalized(slug) else {
            return nil
        }

        self.slug = slug
        self.displayName = CodexTokenContextNormalizer.normalizedDimensionValue(displayName)
        self.visibility = CodexTokenContextNormalizer.normalizedIdentifier(visibility)
        self.supportedInAPI = supportedInAPI
        self.priority = priority
        self.contextWindow = contextWindow.map { max($0, 0) }
        self.maxContextWindow = maxContextWindow.map { max($0, 0) }
        self.effectiveContextWindowPercent = effectiveContextWindowPercent.map { min(max($0, 0), 100) }
        self.defaultReasoningLevel = CodexTokenContextNormalizer.normalizedIdentifier(defaultReasoningLevel)
        self.supportsReasoningSummaries = supportsReasoningSummaries
        self.defaultReasoningSummary = CodexTokenContextNormalizer.normalizedIdentifier(defaultReasoningSummary)
        self.supportsVerbosity = supportsVerbosity
        self.defaultVerbosity = CodexTokenContextNormalizer.normalizedIdentifier(defaultVerbosity)
        self.shellType = CodexTokenContextNormalizer.normalizedIdentifier(shellType)
        self.applyPatchToolType = CodexTokenContextNormalizer.normalizedIdentifier(applyPatchToolType)
        self.webSearchToolType = CodexTokenContextNormalizer.normalizedIdentifier(webSearchToolType)
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsImageDetailOriginal = supportsImageDetailOriginal
        self.supportsSearchTool = supportsSearchTool
        self.truncationPolicyMode = CodexTokenContextNormalizer.normalizedIdentifier(truncationPolicyMode)
        self.truncationPolicyLimit = truncationPolicyLimit.map { max($0, 0) }
        self.reasoningLevels = reasoningLevels
        self.serviceTiers = serviceTiers
        self.speedTiers = speedTiers
        self.inputModalities = inputModalities
        self.toolIdentifiers = toolIdentifiers
    }
}

struct CodexModelCapabilityReasoningLevel: Equatable, Sendable {
    let position: Int
    let effort: String

    init?(position: Int, effort: String?) {
        guard let effort = CodexTokenContextNormalizer.normalizedIdentifier(effort) else {
            return nil
        }
        self.position = max(position, 0)
        self.effort = effort
    }
}

struct CodexModelCapabilityServiceTier: Equatable, Sendable {
    let position: Int
    let tierID: String
    let tierName: String?

    init?(position: Int, tierID: String?, tierName: String?) {
        guard let tierID = CodexTokenContextNormalizer.normalizedIdentifier(tierID) else {
            return nil
        }
        self.position = max(position, 0)
        self.tierID = tierID
        self.tierName = CodexTokenContextNormalizer.normalizedDimensionValue(tierName)
    }
}

struct CodexModelCapabilitySpeedTier: Equatable, Sendable {
    let position: Int
    let tierID: String

    init?(position: Int, tierID: String?) {
        guard let tierID = CodexTokenContextNormalizer.normalizedIdentifier(tierID) else {
            return nil
        }
        self.position = max(position, 0)
        self.tierID = tierID
    }
}

struct CodexModelCapabilityInputModality: Equatable, Sendable {
    let position: Int
    let modality: String

    init?(position: Int, modality: String?) {
        guard let modality = CodexTokenContextNormalizer.normalizedIdentifier(modality) else {
            return nil
        }
        self.position = max(position, 0)
        self.modality = modality
    }
}

struct CodexModelCapabilityToolIdentifier: Equatable, Sendable {
    let position: Int
    let toolKind: String
    let toolValue: String

    init?(position: Int, toolKind: String?, toolValue: String?) {
        guard let toolKind = CodexTokenContextNormalizer.normalizedIdentifier(toolKind),
              let toolValue = CodexTokenContextNormalizer.normalizedIdentifier(toolValue)
        else {
            return nil
        }
        self.position = max(position, 0)
        self.toolKind = toolKind
        self.toolValue = toolValue
    }
}

struct DashboardModelCapabilityAnnotation: Equatable, Sendable {
    let modelSlug: String
    let compactText: String
    let detailText: String

    init?(_ capability: CodexModelCapability) {
        var badges: [String] = []
        var details: [String] = []

        if let contextWindow = capability.maxContextWindow ?? capability.contextWindow,
           contextWindow > 0
        {
            var contextText = "Ctx \(Self.compactCount(contextWindow))"
            if let effectivePercent = capability.effectiveContextWindowPercent,
               effectivePercent > 0,
               effectivePercent < 100
            {
                contextText += " @ \(effectivePercent)%"
            }
            badges.append(contextText)

            var detail = "Context \(Self.groupedCount(contextWindow))"
            if let context = capability.contextWindow,
               let maxContext = capability.maxContextWindow,
               context != maxContext
            {
                detail = "Context \(Self.groupedCount(context)) / max \(Self.groupedCount(maxContext))"
            }
            details.append(detail)
        }

        if let defaultReasoningLevel = capability.defaultReasoningLevel {
            badges.append("Reason \(defaultReasoningLevel)")
            details.append("Default reasoning \(defaultReasoningLevel)")
        } else if !capability.reasoningLevels.isEmpty {
            badges.append("Reason \(capability.reasoningLevels.count) levels")
        }
        if !capability.reasoningLevels.isEmpty {
            details.append(
                "Reasoning levels "
                    + capability.reasoningLevels
                        .sorted { $0.position < $1.position }
                        .map(\.effort)
                        .joined(separator: ", ")
            )
        }

        let modalityValues = Set(capability.inputModalities.map(\.modality))
        if modalityValues.contains("image") || capability.supportsImageDetailOriginal == true {
            badges.append("Image")
        }
        if !modalityValues.isEmpty {
            details.append("Input \(modalityValues.sorted().joined(separator: ", "))")
        }

        var tools: [String] = []
        if capability.supportsSearchTool == true || capability.webSearchToolType != nil {
            badges.append("Web")
            tools.append("web search")
        }
        if capability.shellType != nil || capability.toolIdentifiers.contains(where: { $0.toolKind == "shell_type" }) {
            badges.append("Shell")
            tools.append("shell")
        }
        if capability.applyPatchToolType != nil || capability.toolIdentifiers.contains(where: { $0.toolKind == "apply_patch_tool_type" }) {
            badges.append("Patch")
            tools.append("apply patch")
        }
        if capability.supportsParallelToolCalls == true {
            badges.append("Parallel")
            tools.append("parallel tools")
        }
        if !tools.isEmpty {
            details.append("Tools \(tools.joined(separator: ", "))")
        }

        if let serviceTier = capability.serviceTiers.sorted(by: { $0.position < $1.position }).first {
            let tierName = serviceTier.tierName ?? serviceTier.tierID
            badges.append("Tier \(Self.titleCase(tierName))")
            let allTiers = capability.serviceTiers
                .sorted { $0.position < $1.position }
                .map { $0.tierName ?? $0.tierID }
                .joined(separator: ", ")
            details.append("Service tiers \(allTiers)")
        }

        if !capability.speedTiers.isEmpty {
            details.append(
                "Speed tiers "
                    + capability.speedTiers
                        .sorted { $0.position < $1.position }
                        .map(\.tierID)
                        .joined(separator: ", ")
            )
        }

        if capability.supportedInAPI == false {
            badges.append("No API")
        }
        if let supportedInAPI = capability.supportedInAPI {
            details.append("API \(supportedInAPI ? "supported" : "not supported")")
        }
        if let visibility = capability.visibility {
            details.append("Visibility \(visibility)")
        }

        let compactBadges = Array(badges.prefix(4))
        guard !compactBadges.isEmpty || !details.isEmpty else {
            return nil
        }

        modelSlug = capability.slug
        compactText = compactBadges.isEmpty ? "Capabilities available" : compactBadges.joined(separator: " · ")
        detailText = ([capability.displayName ?? capability.slug] + details).joined(separator: "\n")
    }

    static func annotationsBySlug(
        from capabilities: [CodexModelCapability]
    ) -> [String: DashboardModelCapabilityAnnotation] {
        Dictionary(
            uniqueKeysWithValues: capabilities.compactMap { capability in
                guard let annotation = DashboardModelCapabilityAnnotation(capability) else {
                    return nil
                }
                return (capability.slug, annotation)
            }
        )
    }

    static func annotation(
        forModelValue modelValue: String?,
        capabilities: [CodexModelCapability]
    ) -> DashboardModelCapabilityAnnotation? {
        guard let slug = CodexModelIdentifier.normalized(modelValue) else {
            return nil
        }
        return annotationsBySlug(from: capabilities)[slug]
    }

    private static func compactCount(_ value: Int64) -> String {
        let absolute = abs(Double(value))
        if absolute >= 1_000_000 {
            let scaled = Double(value) / 1_000_000
            if scaled == scaled.rounded() {
                return "\(Int(scaled))M"
            }
            return String(format: "%.1fM", scaled)
        }
        if absolute >= 1_000 {
            let scaled = Double(value) / 1_000
            if scaled == scaled.rounded() {
                return "\(Int(scaled))k"
            }
            return String(format: "%.1fk", scaled)
        }
        return "\(value)"
    }

    private static func groupedCount(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func titleCase(_ value: String) -> String {
        value
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { part in
                guard let first = part.first else {
                    return ""
                }
                return first.uppercased() + part.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}

struct CodexThreadCatalogImportResult: Equatable, Sendable {
    let threadsInsertedCount: Int
    let threadsUpdatedCount: Int
    let spawnEdgesInsertedCount: Int
    let spawnEdgesUpdatedCount: Int
    let dynamicToolsInsertedCount: Int
    let dynamicToolsUpdatedCount: Int
    let staleRowsDeletedCount: Int
    let latestThreadUpdatedAt: Date?

    static let empty = CodexThreadCatalogImportResult(
        threadsInsertedCount: 0,
        threadsUpdatedCount: 0,
        spawnEdgesInsertedCount: 0,
        spawnEdgesUpdatedCount: 0,
        dynamicToolsInsertedCount: 0,
        dynamicToolsUpdatedCount: 0,
        staleRowsDeletedCount: 0,
        latestThreadUpdatedAt: nil
    )

    var changedRowCount: Int {
        threadsInsertedCount
            + threadsUpdatedCount
            + spawnEdgesInsertedCount
            + spawnEdgesUpdatedCount
            + dynamicToolsInsertedCount
            + dynamicToolsUpdatedCount
            + staleRowsDeletedCount
    }
}

struct CodexThreadCatalogImportBatch: Equatable, Sendable {
    let threads: [CodexThreadCatalogThread]
    let spawnEdges: [CodexThreadSpawnEdge]
    let dynamicTools: [CodexThreadDynamicTool]
    let pruneThreads: Bool
    let pruneSpawnEdges: Bool
    let pruneDynamicTools: Bool
}

struct CodexThreadCatalogThread: Equatable, Sendable {
    let threadID: String
    let rolloutPath: String?
    let createdAt: Date?
    let updatedAt: Date?
    let source: String?
    let modelProvider: String?
    let projectPath: String?
    let projectName: String?
    let sandboxPolicy: String?
    let approvalMode: String?
    let tokensUsed: Int64
    let hasUserEvent: Bool
    let archived: Bool
    let archivedAt: Date?
    let gitSHA: String?
    let gitBranch: String?
    let gitOriginURL: String?
    let cliVersion: String?
    let agentNickname: String?
    let agentRole: String?
    let agentPath: String?
    let memoryMode: String?
    let model: String?
    let reasoningEffort: String?
    let threadSource: String?

    init?(
        threadID: String?,
        rolloutPath: String?,
        createdAt: Date?,
        updatedAt: Date?,
        source: String?,
        modelProvider: String?,
        cwd: String?,
        sandboxPolicy: String?,
        approvalMode: String?,
        tokensUsed: Int64,
        hasUserEvent: Bool,
        archived: Bool,
        archivedAt: Date?,
        gitSHA: String?,
        gitBranch: String?,
        gitOriginURL: String?,
        cliVersion: String?,
        agentNickname: String?,
        agentRole: String?,
        agentPath: String?,
        memoryMode: String?,
        model: String?,
        reasoningEffort: String?,
        threadSource: String?
    ) {
        guard let threadID = CodexTokenContextNormalizer.normalizedIdentifier(threadID) else {
            return nil
        }

        self.threadID = threadID
        self.rolloutPath = CodexThreadCatalogCaptureState.normalizedPathPointer(rolloutPath)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = CodexTokenContextNormalizer.normalizedMetadataIdentifier(source)
        self.modelProvider = CodexTokenContextNormalizer.normalizedMetadataIdentifier(modelProvider)
        self.projectPath = CodexTokenContextNormalizer.normalizedProjectPath(cwd)
        self.projectName = self.projectPath.flatMap(CodexTokenContextNormalizer.projectName)
        self.sandboxPolicy = Self.normalizedSandboxPolicy(sandboxPolicy)
        self.approvalMode = CodexTokenContextNormalizer.normalizedMetadataIdentifier(approvalMode)
        self.tokensUsed = max(tokensUsed, 0)
        self.hasUserEvent = hasUserEvent
        self.archived = archived
        self.archivedAt = archivedAt
        self.gitSHA = Self.normalizedSHA(gitSHA)
        self.gitBranch = CodexTokenContextNormalizer.normalizedDimensionValue(gitBranch)
        self.gitOriginURL = CodexGitRemoteSanitizer.sanitized(gitOriginURL)
        self.cliVersion = CodexTokenContextNormalizer.normalizedMetadataIdentifier(cliVersion)
        self.agentNickname = CodexTokenContextNormalizer.normalizedMetadataDimensionValue(agentNickname)
        self.agentRole = CodexTokenContextNormalizer.normalizedMetadataIdentifier(agentRole)
        self.agentPath = CodexThreadCatalogCaptureState.normalizedPathPointer(agentPath)
        self.memoryMode = CodexTokenContextNormalizer.normalizedMetadataIdentifier(memoryMode)
        self.model = CodexModelIdentifier.normalized(model)
        self.reasoningEffort = CodexTokenContextNormalizer.normalizedMetadataIdentifier(reasoningEffort)
        self.threadSource = CodexTokenContextNormalizer.normalizedMetadataIdentifier(threadSource)
    }

    private static func normalizedSandboxPolicy(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if let data = trimmedValue.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any],
           let type = dictionary["type"] as? String
        {
            return CodexTokenContextNormalizer.normalizedIdentifier(type)
        }

        return CodexTokenContextNormalizer.normalizedIdentifier(trimmedValue)
    }

    private static func normalizedSHA(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        guard !trimmedValue.isEmpty, trimmedValue.count <= 64 else {
            return nil
        }
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard trimmedValue.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }
        return trimmedValue
    }

}

struct CodexThreadSpawnEdge: Equatable, Sendable {
    let parentThreadID: String
    let childThreadID: String
    let status: String?

    init?(parentThreadID: String?, childThreadID: String?, status: String?) {
        guard let parentThreadID = CodexTokenContextNormalizer.normalizedIdentifier(parentThreadID),
              let childThreadID = CodexTokenContextNormalizer.normalizedIdentifier(childThreadID)
        else {
            return nil
        }

        self.parentThreadID = parentThreadID
        self.childThreadID = childThreadID
        self.status = CodexTokenContextNormalizer.normalizedIdentifier(status)
    }
}

struct CodexThreadDynamicTool: Equatable, Sendable {
    let threadID: String
    let position: Int64
    let name: String
    let namespace: String?
    let deferLoading: Bool

    init?(threadID: String?, position: Int64, name: String?, namespace: String?, deferLoading: Bool) {
        guard let threadID = CodexTokenContextNormalizer.normalizedIdentifier(threadID),
              let name = CodexTokenContextNormalizer.normalizedDimensionValue(name)
        else {
            return nil
        }

        self.threadID = threadID
        self.position = max(position, 0)
        self.name = name
        self.namespace = CodexTokenContextNormalizer.normalizedIdentifier(namespace)
        self.deferLoading = deferLoading
    }
}

struct CodexThreadCatalogImporter {
    let stateDatabaseURL: URL
    let fileManager: FileManager

    init(
        stateDatabaseURL: URL = Self.defaultStateDatabaseURL(),
        fileManager: FileManager = .default
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.fileManager = fileManager
    }

    static func defaultStateDatabaseURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("state_5.sqlite")
    }

    func importThreadCatalog(into store: UsageHistoryStore) throws -> CodexThreadCatalogImportResult {
        guard fileManager.fileExists(atPath: stateDatabaseURL.path) else {
            throw UsageHistoryStoreError.fileOperationFailed("Codex state database not found.")
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw UsageHistoryStoreError.fileOperationFailed("Codex state database could not be opened.")
        }
        defer { sqlite3_close(database) }

        guard try Self.tableExists("threads", in: database) else {
            throw UsageHistoryStoreError.fileOperationFailed("Codex state database has no threads table.")
        }

        let threads = try Self.readThreads(from: database)
        let spawnEdges = (try? Self.readSpawnEdges(from: database)) ?? []
        let dynamicTools = (try? Self.readDynamicTools(from: database)) ?? []
        let batch = CodexThreadCatalogImportBatch(
            threads: threads,
            spawnEdges: spawnEdges,
            dynamicTools: dynamicTools,
            pruneThreads: true,
            pruneSpawnEdges: try Self.tableExists("thread_spawn_edges", in: database),
            pruneDynamicTools: try Self.tableExists("thread_dynamic_tools", in: database)
        )
        return try store.importCodexThreadCatalog(batch)
    }

    private static func readThreads(from database: OpaquePointer) throws -> [CodexThreadCatalogThread] {
        let columns = try tableColumns("threads", in: database)
        let createdExpression = timestampExpression(millisecondsColumn: "created_at_ms", secondsColumn: "created_at", columns: columns)
        let updatedExpression = timestampExpression(millisecondsColumn: "updated_at_ms", secondsColumn: "updated_at", columns: columns)
        let sql = """
        SELECT \(columnExpression("id", columns: columns)),
            \(columnExpression("rollout_path", columns: columns)),
            \(createdExpression),
            \(updatedExpression),
            \(columnExpression("source", columns: columns)),
            \(columnExpression("model_provider", columns: columns)),
            \(columnExpression("cwd", columns: columns)),
            \(columnExpression("sandbox_policy", columns: columns)),
            \(columnExpression("approval_mode", columns: columns)),
            \(columnExpression("tokens_used", columns: columns, fallback: "0")),
            \(columnExpression("has_user_event", columns: columns, fallback: "0")),
            \(columnExpression("archived", columns: columns, fallback: "0")),
            \(timestampExpression(millisecondsColumn: nil, secondsColumn: "archived_at", columns: columns)),
            \(columnExpression("git_sha", columns: columns)),
            \(columnExpression("git_branch", columns: columns)),
            \(columnExpression("git_origin_url", columns: columns)),
            \(columnExpression("cli_version", columns: columns)),
            \(columnExpression("agent_nickname", columns: columns)),
            \(columnExpression("agent_role", columns: columns)),
            \(columnExpression("agent_path", columns: columns)),
            \(columnExpression("memory_mode", columns: columns)),
            \(columnExpression("model", columns: columns)),
            \(columnExpression("reasoning_effort", columns: columns)),
            \(columnExpression("thread_source", columns: columns))
        FROM threads
        ORDER BY \(updatedExpression) ASC, \(columnExpression("id", columns: columns)) ASC
        """
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        var threads: [CodexThreadCatalogThread] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let thread = CodexThreadCatalogThread(
                    threadID: optionalText(statement, 0),
                    rolloutPath: optionalText(statement, 1),
                    createdAt: optionalDate(statement, 2),
                    updatedAt: optionalDate(statement, 3),
                    source: optionalText(statement, 4),
                    modelProvider: optionalText(statement, 5),
                    cwd: optionalText(statement, 6),
                    sandboxPolicy: optionalText(statement, 7),
                    approvalMode: optionalText(statement, 8),
                    tokensUsed: sqlite3_column_int64(statement, 9),
                    hasUserEvent: sqlite3_column_int(statement, 10) != 0,
                    archived: sqlite3_column_int(statement, 11) != 0,
                    archivedAt: optionalDate(statement, 12),
                    gitSHA: optionalText(statement, 13),
                    gitBranch: optionalText(statement, 14),
                    gitOriginURL: optionalText(statement, 15),
                    cliVersion: optionalText(statement, 16),
                    agentNickname: optionalText(statement, 17),
                    agentRole: optionalText(statement, 18),
                    agentPath: optionalText(statement, 19),
                    memoryMode: optionalText(statement, 20),
                    model: optionalText(statement, 21),
                    reasoningEffort: optionalText(statement, 22),
                    threadSource: optionalText(statement, 23)
                ) {
                    threads.append(thread)
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
        return threads
    }

    private static func readSpawnEdges(from database: OpaquePointer) throws -> [CodexThreadSpawnEdge] {
        guard try tableExists("thread_spawn_edges", in: database) else {
            return []
        }
        let columns = try tableColumns("thread_spawn_edges", in: database)
        let sql = """
        SELECT \(columnExpression("parent_thread_id", columns: columns)),
            \(columnExpression("child_thread_id", columns: columns)),
            \(columnExpression("status", columns: columns))
        FROM thread_spawn_edges
        ORDER BY \(columnExpression("parent_thread_id", columns: columns)),
            \(columnExpression("child_thread_id", columns: columns))
        """
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        var edges: [CodexThreadSpawnEdge] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let edge = CodexThreadSpawnEdge(
                    parentThreadID: optionalText(statement, 0),
                    childThreadID: optionalText(statement, 1),
                    status: optionalText(statement, 2)
                ) {
                    edges.append(edge)
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
        return edges
    }

    private static func readDynamicTools(from database: OpaquePointer) throws -> [CodexThreadDynamicTool] {
        guard try tableExists("thread_dynamic_tools", in: database) else {
            return []
        }
        let columns = try tableColumns("thread_dynamic_tools", in: database)
        let sql = """
        SELECT \(columnExpression("thread_id", columns: columns)),
            \(columnExpression("position", columns: columns, fallback: "0")),
            \(columnExpression("name", columns: columns)),
            \(columnExpression("namespace", columns: columns)),
            \(columnExpression("defer_loading", columns: columns, fallback: "0"))
        FROM thread_dynamic_tools
        ORDER BY \(columnExpression("thread_id", columns: columns)),
            \(columnExpression("position", columns: columns, fallback: "0"))
        """
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        var tools: [CodexThreadDynamicTool] = []
        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let tool = CodexThreadDynamicTool(
                    threadID: optionalText(statement, 0),
                    position: sqlite3_column_int64(statement, 1),
                    name: optionalText(statement, 2),
                    namespace: optionalText(statement, 3),
                    deferLoading: sqlite3_column_int(statement, 4) != 0
                ) {
                    tools.append(tool)
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
        return tools
    }

    private static func timestampExpression(
        millisecondsColumn: String?,
        secondsColumn: String?,
        columns: Set<String>
    ) -> String {
        let millisecondExpression = millisecondsColumn.flatMap { columns.contains($0) ? "(\($0) / 1000)" : nil }
        let secondExpression = secondsColumn.flatMap { columns.contains($0) ? $0 : nil }
        switch (millisecondExpression, secondExpression) {
        case let (milliseconds?, seconds?):
            return "COALESCE(\(milliseconds), \(seconds))"
        case let (milliseconds?, nil):
            return milliseconds
        case let (nil, seconds?):
            return seconds
        case (nil, nil):
            return "NULL"
        }
    }

    private static func columnExpression(
        _ column: String,
        columns: Set<String>,
        fallback: String = "NULL"
    ) -> String {
        columns.contains(column) ? column : fallback
    }

    private static func tableColumns(_ table: String, in database: OpaquePointer) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))", in: database)
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: text))
                }
            case SQLITE_DONE:
                return columns
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func tableExists(_ table: String, in database: OpaquePointer) throws -> Bool {
        let statement = try prepare(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) != 0
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private static func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index)
        else {
            return nil
        }
        return String(cString: text)
    }

    private static func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        let timestamp = sqlite3_column_int64(statement, index)
        guard timestamp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

enum CodexModelCapabilitiesImporterError: LocalizedError {
    case sourceUnavailable
    case malformedJSON
    case noModels

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "Codex models cache not found."
        case .malformedJSON:
            "Codex models cache could not be read."
        case .noModels:
            "Codex models cache has no models."
        }
    }
}

struct CodexModelCapabilitiesImporter {
    let modelsCacheURL: URL
    let fileManager: FileManager

    init(
        modelsCacheURL: URL = Self.defaultModelsCacheURL(),
        fileManager: FileManager = .default
    ) {
        self.modelsCacheURL = modelsCacheURL
        self.fileManager = fileManager
    }

    static func defaultModelsCacheURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("models_cache.json")
    }

    func importModelCapabilities(into store: UsageHistoryStore) throws -> CodexModelCapabilitiesImportResult {
        guard fileManager.fileExists(atPath: modelsCacheURL.path) else {
            throw CodexModelCapabilitiesImporterError.sourceUnavailable
        }

        let data: Data
        do {
            data = try Data(contentsOf: modelsCacheURL)
        } catch {
            throw CodexModelCapabilitiesImporterError.malformedJSON
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawModels = root["models"] as? [[String: Any]]
        else {
            throw CodexModelCapabilitiesImporterError.malformedJSON
        }

        let models = rawModels.compactMap(Self.model(from:))
        guard !models.isEmpty else {
            throw CodexModelCapabilitiesImporterError.noModels
        }

        let batch = CodexModelCapabilitiesImportBatch(
            models: models,
            cacheFetchedAt: Self.date(from: root["fetched_at"]),
            clientVersion: Self.string(root["client_version"])
        )
        return try store.importCodexModelCapabilities(batch)
    }

    private static func model(from dictionary: [String: Any]) -> CodexModelCapability? {
        let truncationPolicy = dictionary["truncation_policy"] as? [String: Any]
        return CodexModelCapability(
            slug: string(dictionary["slug"]),
            displayName: string(dictionary["display_name"]),
            visibility: string(dictionary["visibility"]),
            supportedInAPI: bool(dictionary["supported_in_api"]),
            priority: int64(dictionary["priority"]),
            contextWindow: int64(dictionary["context_window"]),
            maxContextWindow: int64(dictionary["max_context_window"]),
            effectiveContextWindowPercent: int64(dictionary["effective_context_window_percent"]),
            defaultReasoningLevel: string(dictionary["default_reasoning_level"]),
            supportsReasoningSummaries: bool(dictionary["supports_reasoning_summaries"]),
            defaultReasoningSummary: string(dictionary["default_reasoning_summary"]),
            supportsVerbosity: bool(dictionary["support_verbosity"]),
            defaultVerbosity: string(dictionary["default_verbosity"]),
            shellType: string(dictionary["shell_type"]),
            applyPatchToolType: string(dictionary["apply_patch_tool_type"]),
            webSearchToolType: string(dictionary["web_search_tool_type"]),
            supportsParallelToolCalls: bool(dictionary["supports_parallel_tool_calls"]),
            supportsImageDetailOriginal: bool(dictionary["supports_image_detail_original"]),
            supportsSearchTool: bool(dictionary["supports_search_tool"]),
            truncationPolicyMode: string(truncationPolicy?["mode"]),
            truncationPolicyLimit: int64(truncationPolicy?["limit"]),
            reasoningLevels: reasoningLevels(from: dictionary["supported_reasoning_levels"]),
            serviceTiers: serviceTiers(from: dictionary["service_tiers"]),
            speedTiers: speedTiers(from: dictionary["additional_speed_tiers"]),
            inputModalities: inputModalities(from: dictionary["input_modalities"]),
            toolIdentifiers: toolIdentifiers(from: dictionary)
        )
    }

    private static func reasoningLevels(from value: Any?) -> [CodexModelCapabilityReasoningLevel] {
        guard let levels = value as? [[String: Any]] else {
            return []
        }
        return levels.enumerated().compactMap { offset, level in
            CodexModelCapabilityReasoningLevel(position: offset, effort: string(level["effort"]))
        }
    }

    private static func serviceTiers(from value: Any?) -> [CodexModelCapabilityServiceTier] {
        guard let tiers = value as? [[String: Any]] else {
            return []
        }
        return tiers.enumerated().compactMap { offset, tier in
            CodexModelCapabilityServiceTier(
                position: offset,
                tierID: string(tier["id"]),
                tierName: string(tier["name"])
            )
        }
    }

    private static func speedTiers(from value: Any?) -> [CodexModelCapabilitySpeedTier] {
        guard let tiers = value as? [Any] else {
            return []
        }
        return tiers.enumerated().compactMap { offset, tier in
            CodexModelCapabilitySpeedTier(position: offset, tierID: string(tier))
        }
    }

    private static func inputModalities(from value: Any?) -> [CodexModelCapabilityInputModality] {
        guard let modalities = value as? [Any] else {
            return []
        }
        return modalities.enumerated().compactMap { offset, modality in
            CodexModelCapabilityInputModality(position: offset, modality: string(modality))
        }
    }

    private static func toolIdentifiers(from dictionary: [String: Any]) -> [CodexModelCapabilityToolIdentifier] {
        var tools: [CodexModelCapabilityToolIdentifier] = []
        for (kind, key) in [
            ("shell_type", "shell_type"),
            ("apply_patch_tool_type", "apply_patch_tool_type"),
            ("web_search_tool_type", "web_search_tool_type"),
        ] {
            if let tool = CodexModelCapabilityToolIdentifier(
                position: tools.count,
                toolKind: kind,
                toolValue: string(dictionary[key])
            ) {
                tools.append(tool)
            }
        }

        if let experimentalTools = dictionary["experimental_supported_tools"] as? [Any] {
            for rawTool in experimentalTools {
                let value: String?
                if let dictionary = rawTool as? [String: Any] {
                    value = string(dictionary["name"]) ?? string(dictionary["id"]) ?? string(dictionary["type"])
                } else {
                    value = string(rawTool)
                }

                if let tool = CodexModelCapabilityToolIdentifier(
                    position: tools.count,
                    toolKind: "experimental_supported_tool",
                    toolValue: value
                ) {
                    tools.append(tool)
                }
            }
        }

        return tools
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        default:
            return nil
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        guard let rawValue = string(value) else {
            return nil
        }
        return CodexSessionTokenBackfillImporter.parseTimestamp(rawValue)
    }
}

enum CodexSessionTaskTimingImportFileStatus: String, Sendable {
    case imported
    case failed
}

struct CodexSessionTaskTimingImportFileRecord: Equatable, Sendable {
    let metadata: CodexSessionTokenImportFileMetadata
    let importedAt: Int64
    let status: CodexSessionTaskTimingImportFileStatus
    let timingVersion: String?
    let tailCursor: CodexSessionTokenTailCursor?

    init(
        metadata: CodexSessionTokenImportFileMetadata,
        importedAt: Int64,
        status: CodexSessionTaskTimingImportFileStatus,
        timingVersion: String? = UsageHistoryStore.currentSessionTaskTimingImportVersion,
        tailCursor: CodexSessionTokenTailCursor? = nil
    ) {
        self.metadata = metadata
        self.importedAt = importedAt
        self.status = status
        self.timingVersion = timingVersion
        self.tailCursor = tailCursor
    }
}

struct CodexSessionTaskTimingImportResult: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let duplicateCount: Int

    static let empty = CodexSessionTaskTimingImportResult(insertedCount: 0, updatedCount: 0, duplicateCount: 0)
}

struct CodexSessionTaskTimingSummary: Equatable, Sendable {
    let filesDiscovered: Int
    let filesScanned: Int
    let filesSkippedByBounds: Int
    let filesSkippedUnchanged: Int
    let insertedCount: Int
    let updatedCount: Int
    let duplicateCount: Int
    let failedLinesSkipped: Int
    let latestEventAt: Date?
}

struct CodexSessionTaskTimingEvent: Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let sourcePath: String?
    let startedAt: Date?
    let completedAt: Date?
    let durationMilliseconds: Int64?
    let timeToFirstTokenMilliseconds: Int64?
    let modelContextWindow: Int64?
    let collaborationModeKind: String?
    let model: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?
    let dimensionsJSON: String?
    let recordedAt: Date

    init?(
        sessionID: String?,
        turnID: String?,
        sourcePath: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        durationMilliseconds: Int64? = nil,
        timeToFirstTokenMilliseconds: Int64? = nil,
        modelContextWindow: Int64? = nil,
        collaborationModeKind: String? = nil,
        model: String? = nil,
        projectPath: String? = nil,
        effort: String? = nil,
        source: String? = nil,
        dimensions: [TokenUsageDimension] = [],
        dimensionsJSON: String? = nil,
        recordedAt: Date = Date()
    ) {
        guard let normalizedSessionID = CodexTokenContextNormalizer.normalizedIdentifier(sessionID),
              let normalizedTurnID = CodexTokenContextNormalizer.normalizedIdentifier(turnID)
        else {
            return nil
        }

        self.sessionID = normalizedSessionID
        self.turnID = normalizedTurnID
        self.sourcePath = sourcePath
        self.startedAt = startedAt
        self.completedAt = completedAt
        let computedDuration = Self.durationMilliseconds(startedAt: startedAt, completedAt: completedAt)
        self.durationMilliseconds = durationMilliseconds.map { max($0, 0) } ?? computedDuration
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds.map { max($0, 0) }
        self.modelContextWindow = modelContextWindow.map { max($0, 0) }
        self.collaborationModeKind = CodexTokenContextNormalizer.normalizedMetadataIdentifier(collaborationModeKind)
        self.model = CodexModelIdentifier.normalized(model)
        self.projectPath = CodexTokenContextNormalizer.normalizedProjectPath(projectPath)
        self.projectName = self.projectPath.flatMap(CodexTokenContextNormalizer.projectName)
        self.effort = CodexTokenContextNormalizer.normalizedMetadataIdentifier(effort)
        self.source = CodexTokenContextNormalizer.normalizedMetadataIdentifier(source)
        self.dimensionsJSON = dimensionsJSON ?? Self.dimensionsJSON(dimensions)
        self.recordedAt = recordedAt
    }

    var latestEventAt: Date? {
        [startedAt, completedAt].compactMap(\.self).max()
    }

    var eventTimestamp: Date {
        startedAt ?? completedAt ?? recordedAt
    }

    func merged(with incoming: CodexSessionTaskTimingEvent) -> CodexSessionTaskTimingEvent {
        CodexSessionTaskTimingEvent(
            sessionID: sessionID,
            turnID: turnID,
            sourcePath: incoming.sourcePath ?? sourcePath,
            startedAt: incoming.startedAt ?? startedAt,
            completedAt: incoming.completedAt ?? completedAt,
            durationMilliseconds: incoming.durationMilliseconds ?? durationMilliseconds,
            timeToFirstTokenMilliseconds: incoming.timeToFirstTokenMilliseconds ?? timeToFirstTokenMilliseconds,
            modelContextWindow: incoming.modelContextWindow ?? modelContextWindow,
            collaborationModeKind: incoming.collaborationModeKind ?? collaborationModeKind,
            model: incoming.model ?? model,
            projectPath: incoming.projectPath ?? projectPath,
            effort: incoming.effort ?? effort,
            source: incoming.source ?? source,
            dimensionsJSON: incoming.dimensionsJSON ?? dimensionsJSON,
            recordedAt: incoming.recordedAt
        )!
    }

    func hasSameStoredContent(as other: CodexSessionTaskTimingEvent) -> Bool {
        sessionID == other.sessionID
            && turnID == other.turnID
            && sourcePath == other.sourcePath
            && startedAt == other.startedAt
            && completedAt == other.completedAt
            && durationMilliseconds == other.durationMilliseconds
            && timeToFirstTokenMilliseconds == other.timeToFirstTokenMilliseconds
            && modelContextWindow == other.modelContextWindow
            && collaborationModeKind == other.collaborationModeKind
            && model == other.model
            && projectPath == other.projectPath
            && projectName == other.projectName
            && effort == other.effort
            && source == other.source
            && dimensionsJSON == other.dimensionsJSON
    }

    private static func durationMilliseconds(startedAt: Date?, completedAt: Date?) -> Int64? {
        guard let startedAt, let completedAt, completedAt >= startedAt else {
            return nil
        }

        return Int64((completedAt.timeIntervalSince(startedAt) * 1_000).rounded())
    }

    private static func dimensionsJSON(_ dimensions: [TokenUsageDimension]) -> String? {
        let unique = TokenUsageDimension.unique(dimensions)
            .sorted { left, right in
                left.key.rawValue == right.key.rawValue
                    ? left.value < right.value
                    : left.key.rawValue < right.key.rawValue
            }
        guard !unique.isEmpty else {
            return nil
        }

        let rows = unique.map { ["key": $0.key.rawValue, "value": $0.value] }
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return text
    }
}

struct CodexTurnPerformanceEvent: Equatable, Sendable {
    let sourceKey: String
    let sourceRowID: Int64
    let target: String
    let eventTimestamp: Date
    let eventName: String?
    let eventKind: String?
    let durationMilliseconds: Int64?
    let success: Bool?
    let errorSummary: String?
    let threadID: String?
    let turnID: String?
    let model: String?
    let sessionID: String?
    let projectPath: String?
    let projectName: String?
    let effort: String?
    let source: String?
    let originator: String?
    let appVersion: String?
    let terminalType: String?
    let transport: String?
    let wireAPI: String?
    let apiPath: String?
    let runtimeDimensions: [CodexOtelRuntimeDimension]
    let recordedAt: Date

    init(
        sourceKey: String,
        sourceRowID: Int64,
        target: String,
        eventTimestamp: Date,
        eventName: String?,
        eventKind: String?,
        durationMilliseconds: Int64?,
        success: Bool?,
        errorSummary: String?,
        threadID: String?,
        turnID: String?,
        model: String?,
        sessionID: String?,
        projectPath: String?,
        effort: String?,
        source: String?,
        originator: String?,
        appVersion: String?,
        terminalType: String?,
        transport: String?,
        wireAPI: String?,
        apiPath: String?,
        runtimeDimensions: [CodexOtelRuntimeDimension] = [],
        recordedAt: Date = Date()
    ) {
        self.sourceKey = sourceKey
        self.sourceRowID = max(sourceRowID, 0)
        self.target = CodexTokenContextNormalizer.normalizedMetadataIdentifier(target) ?? "unknown"
        self.eventTimestamp = eventTimestamp
        self.eventName = CodexTokenContextNormalizer.normalizedMetadataDimensionValue(eventName)
        self.eventKind = CodexTokenContextNormalizer.normalizedMetadataDimensionValue(eventKind)
        self.durationMilliseconds = durationMilliseconds.map { max($0, 0) }
        self.success = success
        self.errorSummary = CodexTokenContextNormalizer.normalizedMetadataIdentifier(errorSummary)
        self.threadID = CodexTokenContextNormalizer.normalizedIdentifier(threadID)
        self.turnID = CodexTokenContextNormalizer.normalizedIdentifier(turnID)
        self.model = CodexModelIdentifier.normalized(model)
        self.sessionID = CodexTokenContextNormalizer.normalizedIdentifier(sessionID)
        self.projectPath = CodexTokenContextNormalizer.normalizedProjectPath(projectPath)
        self.projectName = self.projectPath.flatMap(CodexTokenContextNormalizer.projectName)
        self.effort = CodexTokenContextNormalizer.normalizedMetadataIdentifier(effort)
        self.source = CodexTokenContextNormalizer.normalizedMetadataIdentifier(source)
        self.originator = CodexTokenContextNormalizer.normalizedMetadataIdentifier(originator)
        self.appVersion = CodexTokenContextNormalizer.normalizedMetadataIdentifier(appVersion)
        self.terminalType = CodexTokenContextNormalizer.normalizedMetadataIdentifier(terminalType)
        self.transport = CodexTokenContextNormalizer.normalizedMetadataIdentifier(transport)
        self.wireAPI = CodexTokenContextNormalizer.normalizedMetadataIdentifier(wireAPI)
        self.apiPath = Self.normalizedAPIPath(apiPath)
        self.runtimeDimensions = CodexOtelRuntimeDimension.unique(runtimeDimensions)
        self.recordedAt = recordedAt
    }

    var hasSafePayload: Bool {
        eventName != nil
            || eventKind != nil
            || durationMilliseconds != nil
            || success != nil
            || errorSummary != nil
            || threadID != nil
            || turnID != nil
            || model != nil
            || projectPath != nil
            || effort != nil
            || source != nil
            || originator != nil
            || appVersion != nil
            || terminalType != nil
            || transport != nil
            || wireAPI != nil
            || apiPath != nil
            || !runtimeDimensions.isEmpty
    }

    private static func normalizedAPIPath(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        guard !trimmedValue.isEmpty, trimmedValue.count <= 120 else {
            return nil
        }

        let allowedCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-/"
        )
        guard trimmedValue.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return trimmedValue
    }
}

enum CodexOtelRuntimeDimensionKey: String, CaseIterable, Codable, Sendable {
    case authMode = "auth_mode"
    case turnHasMetadataHeader = "turn_has_metadata_header"
    case websocketWarmup = "websocket_warmup"
    case requestReasoningEffort = "request_reasoning_effort"
    case requestItemCountBucket = "request_item_count_bucket"
    case connectionRetryCountBucket = "connection_retry_count_bucket"
    case toolOutputSizeBucket = "tool_output_size_bucket"

    var displayTitle: String {
        switch self {
        case .authMode:
            return "Auth mode"
        case .turnHasMetadataHeader:
            return "Metadata header"
        case .websocketWarmup:
            return "WebSocket warmup"
        case .requestReasoningEffort:
            return "Request effort"
        case .requestItemCountBucket:
            return "Request items"
        case .connectionRetryCountBucket:
            return "Connection retries"
        case .toolOutputSizeBucket:
            return "Tool output size"
        }
    }
}

struct CodexOtelRuntimeDimension: Hashable, Equatable, Sendable {
    let key: CodexOtelRuntimeDimensionKey
    let value: String

    init?(_ key: CodexOtelRuntimeDimensionKey, _ rawValue: String?) {
        guard let rawValue else {
            return nil
        }

        let normalizedValue: String?
        switch key {
        case .turnHasMetadataHeader:
            normalizedValue = Self.normalizedBool(rawValue)
        case .requestItemCountBucket, .connectionRetryCountBucket:
            normalizedValue = Self.countBucket(rawValue)
        case .toolOutputSizeBucket:
            normalizedValue = Self.sizeBucket(rawValue)
        default:
            normalizedValue = Self.normalizedSafeIdentifier(rawValue)
        }

        guard let normalizedValue,
              !CodexTokenContextNormalizer.isPrivacySensitiveIdentifier(normalizedValue) else {
            return nil
        }

        self.key = key
        self.value = normalizedValue
    }

    init?(storedKey key: CodexOtelRuntimeDimensionKey, storedValue: String?) {
        guard let storedValue else {
            return nil
        }

        let normalizedValue: String?
        switch key {
        case .turnHasMetadataHeader:
            normalizedValue = Self.normalizedBool(storedValue)
        case .requestItemCountBucket, .connectionRetryCountBucket:
            normalizedValue = Self.normalizedStoredCountBucket(storedValue) ?? Self.countBucket(storedValue)
        case .toolOutputSizeBucket:
            normalizedValue = Self.normalizedStoredSizeBucket(storedValue) ?? Self.sizeBucket(storedValue)
        default:
            normalizedValue = Self.normalizedSafeIdentifier(storedValue)
        }

        guard let normalizedValue,
              !CodexTokenContextNormalizer.isPrivacySensitiveIdentifier(normalizedValue) else {
            return nil
        }

        self.key = key
        self.value = normalizedValue
    }

    static func boolean(_ key: CodexOtelRuntimeDimensionKey, _ rawValue: String?) -> CodexOtelRuntimeDimension? {
        guard let normalized = normalizedBool(rawValue) else {
            return nil
        }

        return CodexOtelRuntimeDimension(key, normalized)
    }

    static func unique(_ dimensions: [CodexOtelRuntimeDimension]) -> [CodexOtelRuntimeDimension] {
        Array(Set(dimensions)).sorted { lhs, rhs in
            if lhs.key.rawValue != rhs.key.rawValue {
                return lhs.key.rawValue < rhs.key.rawValue
            }

            return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
        }
    }

    private static func normalizedBool(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).lowercased(),
              !value.isEmpty
        else {
            return nil
        }

        if ["true", "yes", "1", "enabled", "present"].contains(value) {
            return "true"
        }
        if ["false", "no", "0", "disabled", "absent"].contains(value) {
            return "false"
        }
        return nil
    }

    private static func countBucket(_ rawValue: String?) -> String? {
        guard let value = integerValue(rawValue), value >= 0 else {
            return nil
        }

        switch value {
        case 0:
            return "0"
        case 1:
            return "1"
        case 2...5:
            return "2-5"
        case 6...20:
            return "6-20"
        case 21...100:
            return "21-100"
        default:
            return "101+"
        }
    }

    private static func normalizedStoredCountBucket(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        let allowedValues = Set(["0", "1", "2-5", "6-20", "21-100", "101+"])
        return allowedValues.contains(value) ? value : nil
    }

    private static func sizeBucket(_ rawValue: String?) -> String? {
        guard let value = integerValue(rawValue), value >= 0 else {
            return nil
        }

        switch value {
        case 0:
            return "0"
        case 1..<1_024:
            return "1-1k"
        case 1_024..<10_240:
            return "1k-10k"
        case 10_240..<102_400:
            return "10k-100k"
        case 102_400..<1_048_576:
            return "100k-1m"
        default:
            return "1m+"
        }
    }

    private static func normalizedStoredSizeBucket(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        let allowedValues = Set(["0", "1-1k", "1k-10k", "10k-100k", "100k-1m", "1m+"])
        return allowedValues.contains(value) ? value : nil
    }

    private static func integerValue(_ rawValue: String?) -> Int64? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        guard !value.isEmpty else {
            return nil
        }

        return Int64(value)
    }

    private static func normalizedSafeIdentifier(_ rawValue: String?) -> String? {
        let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        guard !trimmedValue.isEmpty, trimmedValue.count <= 80 else {
            return nil
        }

        let lowercased = trimmedValue.lowercased()
        let unsafeNeedles = [
            "prompt",
            "message",
            "summary",
            "tool",
            "request",
            "response",
            "authorization",
            "auth_token",
            "account_id",
            "user_id",
            "user.email",
            "email",
            "schema",
            "title",
            "preview",
            "description",
            "http://",
            "https://",
            "/users/",
        ]
        guard !unsafeNeedles.contains(where: { lowercased.contains($0) }) else {
            return nil
        }

        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard trimmedValue.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return trimmedValue.lowercased()
    }
}

struct CodexOtelRuntimeDimensionCatalogEntry: Equatable, Sendable {
    let key: CodexOtelRuntimeDimensionKey
    let value: String
    let firstSeenAt: Date
    let lastSeenAt: Date
}

struct CodexOtelRuntimeDimensionSummary: Equatable, Sendable {
    let rowCount: Int
    let distinctKeyCount: Int
    let latestSeenAt: Date?

    static let empty = CodexOtelRuntimeDimensionSummary(
        rowCount: 0,
        distinctKeyCount: 0,
        latestSeenAt: nil
    )
}

struct CodexSessionTokenBackfillRequest: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case recent
        case allHistory
    }

    static let defaultRecentDayCount = 30

    let mode: Mode
    let since: Date?
    let forceRescan: Bool
    let maximumFileSize: Int64?

    static func recent(
        now: Date = Date(),
        days: Int = Self.defaultRecentDayCount,
        forceRescan: Bool = false,
        maximumFileSize: Int64? = nil
    ) -> CodexSessionTokenBackfillRequest {
        CodexSessionTokenBackfillRequest(
            mode: .recent,
            since: Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now) ?? now,
            forceRescan: forceRescan,
            maximumFileSize: maximumFileSize
        )
    }

    static func allHistory(
        forceRescan: Bool = false,
        maximumFileSize: Int64? = nil
    ) -> CodexSessionTokenBackfillRequest {
        CodexSessionTokenBackfillRequest(
            mode: .allHistory,
            since: nil,
            forceRescan: forceRescan,
            maximumFileSize: maximumFileSize
        )
    }

    var displayTitle: String {
        switch mode {
        case .recent:
            "Recent sessions"
        case .allHistory:
            "All history"
        }
    }
}

enum CodexSessionTokenImportFileStatus: String, Sendable {
    case imported
    case failed
}

struct CodexSessionTokenImportFileMetadata: Equatable, Sendable {
    let path: String
    let fileSize: Int64
    let modifiedAt: Int64
}

struct CodexSessionTokenTailCursor: Equatable, Sendable {
    let byteOffset: Int64
    let nextLineNumber: Int?
    let filePrefixHash: String?
    let stateJSON: String?

    init(
        byteOffset: Int64,
        nextLineNumber: Int? = nil,
        filePrefixHash: String? = nil,
        stateJSON: String? = nil
    ) {
        self.byteOffset = max(byteOffset, 0)
        self.nextLineNumber = nextLineNumber.flatMap { $0 > 0 ? $0 : nil }
        self.filePrefixHash = filePrefixHash
        self.stateJSON = stateJSON
    }
}

struct CodexSessionTokenImportFileRecord: Equatable, Sendable {
    let metadata: CodexSessionTokenImportFileMetadata
    let importedAt: Int64
    let status: CodexSessionTokenImportFileStatus
    let contextVersion: String?
    let tailCursor: CodexSessionTokenTailCursor?

    init(
        metadata: CodexSessionTokenImportFileMetadata,
        importedAt: Int64,
        status: CodexSessionTokenImportFileStatus,
        contextVersion: String? = UsageHistoryStore.currentSessionTokenContextImportVersion,
        tailCursor: CodexSessionTokenTailCursor? = nil
    ) {
        self.metadata = metadata
        self.importedAt = importedAt
        self.status = status
        self.contextVersion = contextVersion
        self.tailCursor = tailCursor
    }
}

struct CodexSessionTokenBackfillSummary: Equatable, Sendable {
    let request: CodexSessionTokenBackfillRequest
    let filesDiscovered: Int
    let filesScanned: Int
    let filesSkippedByBounds: Int
    let filesSkippedUnchanged: Int
    let tokenEventsImported: Int
    let duplicateEventsSkipped: Int
    let modelEventsRepaired: Int
    let contextEventsRepaired: Int
    let dimensionEventsRepaired: Int
    let failedLinesSkipped: Int
    let elapsedTime: TimeInterval

    init(
        request: CodexSessionTokenBackfillRequest = .allHistory(),
        filesDiscovered: Int? = nil,
        filesScanned: Int,
        filesSkippedByBounds: Int = 0,
        filesSkippedUnchanged: Int = 0,
        tokenEventsImported: Int,
        duplicateEventsSkipped: Int,
        modelEventsRepaired: Int = 0,
        contextEventsRepaired: Int = 0,
        dimensionEventsRepaired: Int = 0,
        failedLinesSkipped: Int,
        elapsedTime: TimeInterval = 0
    ) {
        self.request = request
        self.filesDiscovered = filesDiscovered ?? filesScanned
        self.filesScanned = filesScanned
        self.filesSkippedByBounds = filesSkippedByBounds
        self.filesSkippedUnchanged = filesSkippedUnchanged
        self.tokenEventsImported = tokenEventsImported
        self.duplicateEventsSkipped = duplicateEventsSkipped
        self.modelEventsRepaired = modelEventsRepaired
        self.contextEventsRepaired = contextEventsRepaired
        self.dimensionEventsRepaired = dimensionEventsRepaired
        self.failedLinesSkipped = failedLinesSkipped
        self.elapsedTime = elapsedTime
    }

    var statusMessage: String {
        if filesDiscovered == 0 {
            return "No Codex session files found."
        }

        var parts = [
            "\(request.displayTitle): scanned \(filesScanned) of \(filesDiscovered) files.",
            "Imported \(tokenEventsImported) token events.",
        ]

        if filesSkippedByBounds > 0 {
            parts.append("\(filesSkippedByBounds) outside this import scope.")
        }

        if filesSkippedUnchanged > 0 {
            parts.append("\(filesSkippedUnchanged) unchanged files skipped.")
        }

        if duplicateEventsSkipped > 0 {
            parts.append("\(duplicateEventsSkipped) duplicates skipped.")
        }

        if modelEventsRepaired > 0 {
            parts.append("\(modelEventsRepaired) model labels repaired.")
        }

        if contextEventsRepaired > 0 {
            parts.append("\(contextEventsRepaired) context rows repaired.")
        }

        if dimensionEventsRepaired > 0 {
            parts.append("\(dimensionEventsRepaired) dimension rows repaired.")
        }

        if failedLinesSkipped > 0 {
            parts.append("\(failedLinesSkipped) unreadable lines skipped.")
        }

        parts.append(String(format: "%.1fs elapsed.", elapsedTime))
        return parts.joined(separator: " ")
    }
}

struct CodexSessionTaskTimingImporter: @unchecked Sendable {
    let sourceDirectories: [URL]
    let fileManager: FileManager
    let maximumSessionFileSize: Int64
    let readWindowSize: Int64

    /// Zero means there is no whole-file cutoff. Reads remain bounded by the streaming reader's
    /// chunk and per-line limits, so a large session file is not rejected merely for growing.
    static let defaultMaximumSessionFileSize: Int64 = 0
    static let defaultReadWindowSize: Int64 = (64 * 1_024 * 1_024) - (2 * 64 * 1_024)
    private static let taskStartedLineNeedle = Data(#""task_started""#.utf8)
    private static let taskCompleteLineNeedle = Data(#""task_complete""#.utf8)
    private static let turnContextLineNeedle = Data(#""turn_context""#.utf8)
    private static let sessionMetaLineNeedle = Data(#""session_meta""#.utf8)

    init(
        sourceDirectories: [URL] = Self.defaultSourceDirectories(),
        fileManager: FileManager = .default,
        maximumSessionFileSize: Int64 = Self.defaultMaximumSessionFileSize,
        readWindowSize: Int64 = Self.defaultReadWindowSize
    ) {
        self.sourceDirectories = sourceDirectories
        self.fileManager = fileManager
        self.maximumSessionFileSize = max(maximumSessionFileSize, 0)
        self.readWindowSize = min(max(readWindowSize, 1), Self.defaultReadWindowSize)
    }

    static func defaultSourceDirectories(fileManager: FileManager = .default) -> [URL] {
        [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true),
        ]
    }

    func importTaskTiming(
        into store: UsageHistoryStore,
        now: Date,
        recentDayCount: Int = CodexSessionTokenBackfillRequest.defaultRecentDayCount,
        forceRescan: Bool = false
    ) throws -> CodexSessionTaskTimingSummary {
        let since = Calendar(identifier: .gregorian).date(byAdding: .day, value: -recentDayCount, to: now) ?? now
        let discoveredFiles = sessionFileCandidates()
        var filesSkippedByBounds = 0
        var filesSkippedUnchanged = 0
        var failedLinesSkipped = 0
        var insertedCount = 0
        var updatedCount = 0
        var duplicateCount = 0
        var latestEventAt: Date?

        let sessionFiles = discoveredFiles.filter { candidate in
            guard shouldInclude(candidate: candidate, since: since) else {
                filesSkippedByBounds += 1
                return false
            }

            guard maximumSessionFileSize == 0 || candidate.metadata.fileSize <= maximumSessionFileSize else {
                filesSkippedByBounds += 1
                return false
            }

            guard !shouldSkipUnchanged(candidate.metadata, store: store, forceRescan: forceRescan) else {
                filesSkippedUnchanged += 1
                return false
            }

            return true
        }

        for candidate in sessionFiles {
            let storedRecord = try? store.codexSessionTaskTimingImportFileRecord(path: candidate.metadata.path)
            let priorRecord: CodexSessionTaskTimingImportFileRecord?
            if !forceRescan,
               storedRecord?.timingVersion == UsageHistoryStore.currentSessionTaskTimingImportVersion
            {
                priorRecord = storedRecord
            } else {
                priorRecord = nil
            }
            let fileResult = parseSessionFileWindow(
                candidate.url,
                metadata: candidate.metadata,
                priorRecord: priorRecord
            )
            failedLinesSkipped += fileResult.failedLinesSkipped
            let importResult = try store.importSessionTaskTimingEvents(fileResult.events)
            insertedCount += importResult.insertedCount
            updatedCount += importResult.updatedCount
            duplicateCount += importResult.duplicateCount
            latestEventAt = Self.latestDate(latestEventAt, fileResult.events.compactMap(\.latestEventAt).max())
            try store.recordCodexSessionTaskTimingImportFile(
                candidate.metadata,
                importedAt: Int64(Date().timeIntervalSince1970),
                status: fileResult.readSucceeded ? .imported : .failed,
                tailCursor: fileResult.tailCursor
            )
        }

        return CodexSessionTaskTimingSummary(
            filesDiscovered: discoveredFiles.count,
            filesScanned: sessionFiles.count,
            filesSkippedByBounds: filesSkippedByBounds,
            filesSkippedUnchanged: filesSkippedUnchanged,
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            duplicateCount: duplicateCount,
            failedLinesSkipped: failedLinesSkipped,
            latestEventAt: latestEventAt
        )
    }

    private struct SessionFileCandidate {
        let url: URL
        let metadata: CodexSessionTokenImportFileMetadata
        let sessionDate: Date?
    }

    private func sessionFileCandidates() -> [SessionFileCandidate] {
        sourceDirectories.flatMap { directoryURL -> [URL] in
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
        .compactMap { fileURL in
            guard let metadata = fileMetadata(for: fileURL) else {
                return nil
            }
            return SessionFileCandidate(
                url: fileURL,
                metadata: metadata,
                sessionDate: CodexSessionTokenBackfillImporter.sessionDate(from: fileURL)
            )
        }
        .sorted { $0.metadata.path.localizedStandardCompare($1.metadata.path) == .orderedAscending }
    }

    private func fileMetadata(for fileURL: URL) -> CodexSessionTokenImportFileMetadata? {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CodexSessionTokenImportFileMetadata(
            path: fileURL.path,
            fileSize: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate.map { Int64($0.timeIntervalSince1970) } ?? 0
        )
    }

    private func shouldInclude(candidate: SessionFileCandidate, since: Date) -> Bool {
        if let sessionDate = candidate.sessionDate {
            return sessionDate >= since
        }

        return Date(timeIntervalSince1970: TimeInterval(candidate.metadata.modifiedAt)) >= since
    }

    private func shouldSkipUnchanged(
        _ metadata: CodexSessionTokenImportFileMetadata,
        store: UsageHistoryStore,
        forceRescan: Bool
    ) -> Bool {
        guard !forceRescan,
              let record = try? store.codexSessionTaskTimingImportFileRecord(path: metadata.path)
        else {
            return false
        }

        guard record.status == .imported
            && record.metadata.fileSize == metadata.fileSize
            && record.metadata.modifiedAt == metadata.modifiedAt
            && record.timingVersion == UsageHistoryStore.currentSessionTaskTimingImportVersion
            && (record.tailCursor?.byteOffset ?? metadata.fileSize) >= metadata.fileSize
        else {
            return false
        }
        guard let tailCursor = record.tailCursor,
              let storedHash = tailCursor.filePrefixHash
        else {
            return false
        }
        return CodexSessionTokenBackfillImporter.filePrefixMatches(
            storedHash,
            fileURL: URL(fileURLWithPath: metadata.path),
            through: tailCursor.byteOffset
        )
    }

    private static func latestDate(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case let (left?, right?):
            return max(left, right)
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    private struct TailParseResult {
        let events: [CodexSessionTaskTimingEvent]
        let failedLinesSkipped: Int
        let readSucceeded: Bool
        let tailCursor: CodexSessionTokenTailCursor
    }

    private func parseSessionFileWindow(
        _ fileURL: URL,
        metadata: CodexSessionTokenImportFileMetadata,
        priorRecord: CodexSessionTaskTimingImportFileRecord?
    ) -> TailParseResult {
        let priorCursor = priorRecord?.tailCursor
        let canResume: Bool
        if let priorCursor, let storedHash = priorCursor.filePrefixHash {
            canResume = CodexSessionTokenBackfillImporter.filePrefixMatches(
                storedHash,
                fileURL: fileURL,
                through: priorCursor.byteOffset
            ) && priorCursor.byteOffset <= metadata.fileSize
        } else {
            canResume = false
        }
        let startOffset = canResume ? (priorCursor?.byteOffset ?? 0) : 0
        let restoredState = canResume
            ? CodexSessionTokenTailState.decode(priorCursor?.stateJSON)
            : nil
        var nextLineNumber = canResume ? priorCursor?.nextLineNumber : 1
        let window: CodexSessionTokenBackfillImporter.SessionWindow
        do {
            window = try CodexSessionTokenBackfillImporter.readSessionWindow(
                fileURL,
                startOffset: startOffset,
                maximumBytes: readWindowSize,
                alignToNextLine: false
            )
        } catch {
            return TailParseResult(
                events: [],
                failedLinesSkipped: 1,
                readSucceeded: false,
                tailCursor: CodexSessionTokenTailCursor(
                    byteOffset: startOffset,
                    nextLineNumber: nextLineNumber,
                    filePrefixHash: CodexSessionTokenBackfillImporter.filePrefixHash(
                        fileURL,
                        through: startOffset
                    ),
                    stateJSON: restoredState?.encodedJSON
                )
            )
        }
        let decoder = JSONDecoder()
        let sessionID = CodexSessionTokenBackfillImporter.sessionIdentifier(for: fileURL)
        var currentContext = CodexSessionTokenContextTracker(
            sessionID: sessionID,
            restoredState: restoredState
        )
        var currentModel = restoredState?.currentModel
        var eventsByTurnID: [String: CodexSessionTaskTimingEvent] = [:]
        var failedLinesSkipped = window.discardedLineCount
        var cursorOffset = window.offset
        var searchStart = window.data.startIndex

        while let newline = window.data[searchStart...].firstIndex(of: 0x0A) {
            var line = window.data[searchStart..<newline]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            let nextIndex = window.data.index(after: newline)
            cursorOffset = window.offset + Int64(nextIndex - window.data.startIndex)
            searchStart = nextIndex
            if let lineNumber = nextLineNumber {
                nextLineNumber = lineNumber + 1
            }
            guard !line.isEmpty else {
                continue
            }
            let lineData = Data(line)
            guard Self.shouldDecodeSessionLine(lineData) else {
                continue
            }

            do {
                let line = try decoder.decode(CodexSessionTokenBackfillLine.self, from: lineData)
                if line.isSessionMetadata {
                    currentContext.applyMetadata(from: line.payload)
                }
                if line.isTurnContext {
                    currentContext.applyTurnContext(from: line.payload)
                }
                if line.payload?.hasModelMetadata == true {
                    currentModel = line.payload?.modelIdentifier
                }

                guard let event = Self.timingEvent(
                    from: line,
                    sourcePath: fileURL.path,
                    fallbackSessionID: sessionID,
                    currentContext: currentContext,
                    currentModel: currentModel
                ) else {
                    continue
                }

                eventsByTurnID[event.turnID] = eventsByTurnID[event.turnID]?.merged(with: event) ?? event
            } catch {
                failedLinesSkipped += 1
            }
        }

        if let lineNumber = nextLineNumber, window.discardedLineCount > 0 {
            nextLineNumber = lineNumber + window.discardedLineCount
        }
        let state = currentContext.tailState(currentModel: currentModel)
        let consumedSuffixCount = cursorOffset - startOffset
        let consumedSuffix: Data? = if window.offset == startOffset,
                                       consumedSuffixCount >= 0,
                                       consumedSuffixCount <= Int64(window.data.count)
        {
            Data(window.data.prefix(Int(consumedSuffixCount)))
        } else {
            nil
        }
        return TailParseResult(
            events: eventsByTurnID.values.sorted {
                ($0.startedAt ?? $0.completedAt ?? .distantPast) < ($1.startedAt ?? $1.completedAt ?? .distantPast)
            },
            failedLinesSkipped: failedLinesSkipped,
            readSucceeded: true,
            tailCursor: CodexSessionTokenTailCursor(
                byteOffset: cursorOffset,
                nextLineNumber: nextLineNumber,
                filePrefixHash: CodexSessionTokenBackfillImporter.extendedFilePrefixHash(
                    priorCursor?.filePrefixHash,
                    fileURL: fileURL,
                    from: canResume ? startOffset : 0,
                    through: cursorOffset,
                    consumedSuffix: consumedSuffix,
                    streamedSegmentLength: window.streamedSegmentLength,
                    streamedSegmentDigest: window.streamedSegmentDigest
                ),
                stateJSON: state.encodedJSON
            )
        )
    }

    private static func timingEvent(
        from line: CodexSessionTokenBackfillLine,
        sourcePath: String,
        fallbackSessionID: String,
        currentContext: CodexSessionTokenContextTracker,
        currentModel: String?
    ) -> CodexSessionTaskTimingEvent? {
        guard let payload = line.payload,
              payload.isTaskStarted || payload.isTaskComplete,
              let turnID = payload.turnID
        else {
            return nil
        }

        let lineTimestamp = CodexSessionTokenBackfillImporter.parseTimestamp(line.timestamp)
        let startedAt = payload.isTaskStarted ? (payload.startedAtDate ?? lineTimestamp) : nil
        let completedAt = payload.isTaskComplete ? (payload.completedAtDate ?? lineTimestamp) : nil
        let context = currentContext.context

        return CodexSessionTaskTimingEvent(
            sessionID: context?.sessionID ?? fallbackSessionID,
            turnID: turnID,
            sourcePath: sourcePath,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: payload.durationMilliseconds,
            timeToFirstTokenMilliseconds: payload.timeToFirstTokenMilliseconds,
            modelContextWindow: payload.modelContextWindow,
            collaborationModeKind: payload.collaborationModeKind,
            model: payload.modelIdentifier ?? currentModel,
            projectPath: context?.projectPath,
            effort: context?.effort,
            source: context?.source,
            dimensions: context?.dimensions ?? []
        )
    }

    private static func shouldDecodeSessionLine(_ lineData: Data) -> Bool {
        lineData.range(of: taskStartedLineNeedle) != nil
            || lineData.range(of: taskCompleteLineNeedle) != nil
            || lineData.range(of: turnContextLineNeedle) != nil
            || lineData.range(of: sessionMetaLineNeedle) != nil
    }

}

struct CodexLogTokenUsageImporter {
    let logsDatabaseURL: URL
    let incrementalContextLookbackRowCount: Int64

    init(
        logsDatabaseURL: URL = Self.defaultLogsDatabaseURL(),
        incrementalContextLookbackRowCount: Int64 = 500
    ) {
        self.logsDatabaseURL = logsDatabaseURL
        self.incrementalContextLookbackRowCount = max(incrementalContextLookbackRowCount, 0)
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
            AND (
                (
                    feedback_log_body LIKE '%event.name="codex.sse_event"%'
                    AND feedback_log_body LIKE '%event.kind=response.completed%'
                )
                OR (
                    (feedback_log_body LIKE '%conversation.id=%' OR feedback_log_body LIKE '%thread_id=%')
                    AND (
                        feedback_log_body LIKE '%cwd=%'
                        OR feedback_log_body LIKE '%model=%'
                        OR feedback_log_body LIKE '%slug=%'
                        OR feedback_log_body LIKE '%reasoning_effort=%'
                        OR feedback_log_body LIKE '%approval_policy=%'
                        OR feedback_log_body LIKE '%sandbox_type=%'
                        OR feedback_log_body LIKE '%sandbox_policy.type=%'
                        OR feedback_log_body LIKE '%permission_profile=%'
                        OR feedback_log_body LIKE '%truncation_policy=%'
                        OR feedback_log_body LIKE '%originator=%'
                        OR feedback_log_body LIKE '%cli_version=%'
                        OR feedback_log_body LIKE '%app.version=%'
                        OR feedback_log_body LIKE '%model_provider=%'
                        OR feedback_log_body LIKE '%usage_mode=%'
                        OR feedback_log_body LIKE '%speed_mode=%'
                        OR feedback_log_body LIKE '%mode=%'
                    )
                )
            )
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
        var contextsByConversationID: [String: CodexLogTokenContextTracker] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bodyPointer = sqlite3_column_text(statement, 2) else {
                continue
            }

            let body = String(cString: bodyPointer)
            let metadata = CodexLogMetadataExtractor(body: body)
            if let conversationID = metadata.conversationID, metadata.hasCarriableMetadata {
                var tracker = contextsByConversationID[conversationID] ?? CodexLogTokenContextTracker(sessionID: conversationID)
                tracker.apply(metadata)
                contextsByConversationID[conversationID] = tracker
            }

            guard metadata.isResponseCompleted,
                  let sample = Self.sample(
                      logID: sqlite3_column_int64(statement, 0),
                      fallbackTimestamp: sqlite3_column_int64(statement, 1),
                      metadata: metadata,
                      carriedContext: metadata.conversationID.flatMap { contextsByConversationID[$0] }
                  )
            else {
                continue
            }
            samples.append(sample)
        }

        return try store.importTokenUsageSamples(samples)
    }

    func importTokenHistory(
        into store: UsageHistoryStore,
        afterLogRowID: Int64,
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> CodexLiveTokenCaptureRunResult {
        guard FileManager.default.fileExists(atPath: logsDatabaseURL.path) else {
            throw UsageHistoryStoreError.fileOperationFailed("Codex log database not found.")
        }
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            throw UsageHistoryStoreError.fileOperationFailed("Current day could not be resolved.")
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(logsDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw UsageHistoryStoreError.fileOperationFailed("Codex log database could not be opened.")
        }
        defer { sqlite3_close(database) }

        let latestLogRowID = try Self.maxLogRowID(
            in: database,
            startTimestamp: interval.start.timeIntervalSince1970Int,
            endTimestamp: interval.end.timeIntervalSince1970Int
        )
        let contextFloorLogRowID = incrementalContextFloorLogRowID(
            afterLogRowID: afterLogRowID,
            latestLogRowID: latestLogRowID
        )

        let sql = """
        SELECT id, ts, feedback_log_body
        FROM logs
        WHERE id > ?
            AND ts >= ? AND ts < ?
            AND (
                (
                    (feedback_log_body LIKE '%conversation.id=%' OR feedback_log_body LIKE '%thread_id=%')
                    AND (
                        feedback_log_body LIKE '%cwd=%'
                        OR feedback_log_body LIKE '%model=%'
                        OR feedback_log_body LIKE '%slug=%'
                        OR feedback_log_body LIKE '%reasoning_effort=%'
                        OR feedback_log_body LIKE '%approval_policy=%'
                        OR feedback_log_body LIKE '%sandbox_type=%'
                        OR feedback_log_body LIKE '%sandbox_policy.type=%'
                        OR feedback_log_body LIKE '%permission_profile=%'
                        OR feedback_log_body LIKE '%truncation_policy=%'
                        OR feedback_log_body LIKE '%originator=%'
                        OR feedback_log_body LIKE '%cli_version=%'
                        OR feedback_log_body LIKE '%app.version=%'
                        OR feedback_log_body LIKE '%model_provider=%'
                        OR feedback_log_body LIKE '%usage_mode=%'
                        OR feedback_log_body LIKE '%speed_mode=%'
                        OR feedback_log_body LIKE '%mode=%'
                    )
                )
                OR (
                    feedback_log_body LIKE '%event.name="codex.sse_event"%'
                    AND feedback_log_body LIKE '%event.kind=response.completed%'
                )
            )
        ORDER BY ts ASC, id ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, contextFloorLogRowID)
        sqlite3_bind_int64(statement, 2, interval.start.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 3, interval.end.timeIntervalSince1970Int)

        var samples: [ImportedCodexTokenUsageSample] = []
        var contextsByConversationID: [String: CodexLogTokenContextTracker] = [:]
        var maxLogRowID = max(max(afterLogRowID, 0), latestLogRowID)
        var lastImportedEventAt: Date?

        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let logRowID = sqlite3_column_int64(statement, 0)
                maxLogRowID = max(maxLogRowID, logRowID)
                guard let bodyPointer = sqlite3_column_text(statement, 2) else {
                    continue
                }

                let body = String(cString: bodyPointer)
                let metadata = CodexLogMetadataExtractor(body: body)
                if let conversationID = metadata.conversationID, metadata.hasCarriableMetadata {
                    var tracker = contextsByConversationID[conversationID] ?? CodexLogTokenContextTracker(sessionID: conversationID)
                    tracker.apply(metadata)
                    contextsByConversationID[conversationID] = tracker
                }

                guard logRowID > afterLogRowID,
                      metadata.isResponseCompleted,
                      let sample = Self.sample(
                          logID: logRowID,
                          fallbackTimestamp: sqlite3_column_int64(statement, 1),
                          metadata: metadata,
                          carriedContext: metadata.conversationID.flatMap { contextsByConversationID[$0] }
                      )
                else {
                    continue
                }

                samples.append(sample)
                if let existing = lastImportedEventAt {
                    lastImportedEventAt = max(existing, sample.receivedAt)
                } else {
                    lastImportedEventAt = sample.receivedAt
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }

        let importResult = try store.importTokenUsageSamples(samples)
        return CodexLiveTokenCaptureRunResult(
            importResult: importResult,
            maxLogRowID: maxLogRowID,
            lastImportedEventAt: lastImportedEventAt
        )
    }

    private func incrementalContextFloorLogRowID(afterLogRowID: Int64, latestLogRowID: Int64) -> Int64 {
        let normalizedAfterLogRowID = max(afterLogRowID, 0)
        guard normalizedAfterLogRowID > 0 else {
            return max(latestLogRowID - incrementalContextLookbackRowCount, 0)
        }

        return max(normalizedAfterLogRowID - incrementalContextLookbackRowCount, 0)
    }

    private static func maxLogRowID(
        in database: OpaquePointer,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> Int64 {
        let sql = """
        SELECT COALESCE(MAX(id), 0)
        FROM logs
        WHERE ts >= ? AND ts < ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int64(statement, 0)
        case SQLITE_DONE:
            return 0
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func sample(
        logID _: Int64,
        fallbackTimestamp: Int64,
        metadata: CodexLogMetadataExtractor,
        carriedContext: CodexLogTokenContextTracker?
    ) -> ImportedCodexTokenUsageSample? {
        guard
            let inputTokens = metadata.intValue(for: "input_token_count"),
            let outputTokens = metadata.intValue(for: "output_token_count"),
            let cachedInputTokens = metadata.intValue(for: "cached_token_count"),
            let reasoningOutputTokens = metadata.intValue(for: "reasoning_token_count")
        else {
            return nil
        }

        let totalTokens = metadata.intValue(for: "tool_token_count") ?? (inputTokens + outputTokens)
        let timestampText = metadata.value(for: "event.timestamp")
        let receivedAt = timestampText.flatMap(CodexSessionTokenBackfillImporter.parseTimestamp)
            ?? Date(timeIntervalSince1970: TimeInterval(fallbackTimestamp))
        let conversationID = metadata.conversationID ?? "unknown-conversation"
        let legacyModelID = CodexModelIdentifier.firstNormalized([
            metadata.value(for: "slug"),
            metadata.value(for: "model"),
        ])
        let model = metadata.model ?? carriedContext?.model
        let carriedDimensions = carriedContext?.dimensionsList ?? []
        let explicitMetadataDimensions = metadata.explicitDimensions
        let hasExplicitSourceKind = metadata.source != nil
            || carriedContext?.source != nil
            || explicitMetadataDimensions.contains { $0.key == .sourceKind }
            || carriedDimensions.contains { $0.key == .sourceKind && $0.value != "codex-log" }
        let metadataDimensions = hasExplicitSourceKind
            ? explicitMetadataDimensions
            : metadata.dimensions
        let context = TokenUsageContext(
            sessionID: conversationID,
            projectPath: metadata.projectPath ?? carriedContext?.projectPath,
            effort: metadata.effort ?? carriedContext?.effort,
            source: metadata.source ?? carriedContext?.source ?? "codex-log",
            dimensions: carriedDimensions + metadataDimensions
        )
        let eventID = [
            timestampText ?? "\(fallbackTimestamp)",
            "\(inputTokens)",
            "\(cachedInputTokens)",
            "\(outputTokens)",
            "\(reasoningOutputTokens)",
            legacyModelID ?? "unknown-model",
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

        return ImportedCodexTokenUsageSample(notification: notification, receivedAt: receivedAt, context: context)
    }
}

struct CodexOtelTurnPerformanceImporter {
    static let defaultMaximumBodyCharacters = 256 * 1024

    let logsDatabaseURL: URL
    let maximumRowsPerRun: Int?
    let maximumBodyCharacters: Int

    init(
        logsDatabaseURL: URL = CodexLogTokenUsageImporter.defaultLogsDatabaseURL(),
        maximumRowsPerRun: Int? = nil,
        maximumBodyCharacters: Int = CodexOtelTurnPerformanceImporter.defaultMaximumBodyCharacters
    ) {
        self.logsDatabaseURL = logsDatabaseURL
        self.maximumRowsPerRun = maximumRowsPerRun
        self.maximumBodyCharacters = maximumBodyCharacters
    }

    func importTurnPerformanceEvents(
        into store: UsageHistoryStore,
        afterLogRowID: Int64,
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> CodexTurnPerformanceCaptureRunResult {
        guard FileManager.default.fileExists(atPath: logsDatabaseURL.path) else {
            throw UsageHistoryStoreError.fileOperationFailed("Codex log database not found.")
        }
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            throw UsageHistoryStoreError.fileOperationFailed("Current day could not be resolved.")
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(logsDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw UsageHistoryStoreError.fileOperationFailed("Codex log database could not be opened.")
        }
        defer { sqlite3_close(database) }

        let latestLogRowID = try Self.maxLogRowID(
            in: database,
            startTimestamp: interval.start.timeIntervalSince1970Int,
            endTimestamp: interval.end.timeIntervalSince1970Int
        )

        let sql = """
        SELECT id, ts, target, body_prefix
        FROM (
            SELECT id, ts, target, substr(feedback_log_body, 1, ?) AS body_prefix
            FROM logs
            WHERE id > ?
                AND ts >= ? AND ts < ?
                AND target IN (
                    'codex_otel.trace_safe',
                    'codex_otel.log_only',
                    'codex_api::endpoint::responses_websocket',
                    'codex_api::sse::responses'
                )
        )
        WHERE (
                body_prefix LIKE '%event.name=%'
                OR body_prefix LIKE '%duration_ms=%'
                OR body_prefix LIKE '%duration_ms":%'
                OR body_prefix LIKE '%success=%'
                OR body_prefix LIKE '%transport=%'
                OR body_prefix LIKE '%wire_api=%'
                OR body_prefix LIKE '%api.path=%'
                OR body_prefix LIKE '%codex.turn.reasoning_effort=%'
                OR body_prefix LIKE '%reasoning_effort=%'
                OR body_prefix LIKE '%auth_mode%'
                OR body_prefix LIKE '%has_metadata_header%'
                OR body_prefix LIKE '%websocket.warmup%'
                OR body_prefix LIKE '%codex.request.reasoning_effort%'
                OR body_prefix LIKE '%request.reasoning_effort%'
                OR body_prefix LIKE '%tool_output%'
                OR body_prefix LIKE '%tool.output.size%'
                OR body_prefix LIKE '%model=%'
                OR body_prefix LIKE '%slug=%'
                OR body_prefix LIKE '%cwd=%'
            )
        ORDER BY id ASC
        LIMIT ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(max(maximumBodyCharacters, 1)))
        sqlite3_bind_int64(statement, 2, max(afterLogRowID, 0))
        sqlite3_bind_int64(statement, 3, interval.start.timeIntervalSince1970Int)
        sqlite3_bind_int64(statement, 4, interval.end.timeIntervalSince1970Int)
        sqlite3_bind_int(statement, 5, Int32(max(maximumRowsPerRun ?? Int(Int32.max), 1)))

        var events: [CodexTurnPerformanceEvent] = []
        var maxLogRowID = max(afterLogRowID, 0)
        var rowCount = 0
        var lastImportedEventAt: Date?

        rowLoop:
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let logRowID = sqlite3_column_int64(statement, 0)
                rowCount += 1
                maxLogRowID = max(maxLogRowID, logRowID)
                guard let targetPointer = sqlite3_column_text(statement, 2),
                      let bodyPointer = sqlite3_column_text(statement, 3)
                else {
                    continue
                }

                let target = String(cString: targetPointer)
                let body = String(cString: bodyPointer)
                let metadata = CodexOtelMetadataExtractor(
                    sourceKey: CodexTurnPerformanceCaptureState.codexOtelLogSourceKey,
                    sourceRowID: logRowID,
                    target: target,
                    fallbackTimestamp: sqlite3_column_int64(statement, 1),
                    body: body
                )
                guard let event = metadata.event(), event.hasSafePayload else {
                    continue
                }

                events.append(event)
                if let existing = lastImportedEventAt {
                    lastImportedEventAt = max(existing, event.eventTimestamp)
                } else {
                    lastImportedEventAt = event.eventTimestamp
                }
            case SQLITE_DONE:
                break rowLoop
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }

        if maximumRowsPerRun == nil || rowCount < max(maximumRowsPerRun ?? 0, 1) {
            maxLogRowID = max(maxLogRowID, latestLogRowID)
        }

        let importResult = try store.importTurnPerformanceEvents(events)
        return CodexTurnPerformanceCaptureRunResult(
            importResult: importResult,
            maxLogRowID: maxLogRowID,
            lastImportedEventAt: lastImportedEventAt
        )
    }

    private static func maxLogRowID(
        in database: OpaquePointer,
        startTimestamp: Int64,
        endTimestamp: Int64
    ) throws -> Int64 {
        let sql = """
        SELECT COALESCE(MAX(id), 0)
        FROM logs
        WHERE ts >= ? AND ts < ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, startTimestamp)
        sqlite3_bind_int64(statement, 2, endTimestamp)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int64(statement, 0)
        case SQLITE_DONE:
            return 0
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }
}

private struct CodexOtelMetadataExtractor {
    let sourceKey: String
    let sourceRowID: Int64
    let target: String
    let fallbackTimestamp: Int64
    let body: String

    func event() -> CodexTurnPerformanceEvent? {
        let metadata = CodexLogMetadataExtractor(body: body)
        let eventTimestamp = firstTimestamp(for: [
            "event.timestamp",
            "timestamp",
            "time",
        ]) ?? Date(timeIntervalSince1970: TimeInterval(fallbackTimestamp))
        let eventName = firstValue(for: [
            "event.name",
            "name",
        ])
        let eventKind = firstValue(for: [
            "event.kind",
            "kind",
            "codex.event.kind",
        ])
        let threadID = metadata.conversationID ?? normalizedIdentifier(firstValue(for: [
            "thread_id",
            "thread.id",
            "threadId",
            "conversation_id",
        ]))
        let turnID = normalizedIdentifier(firstValue(for: [
            "turn.id",
            "turn_id",
            "turnId",
            "codex.turn.id",
        ]))

        return CodexTurnPerformanceEvent(
            sourceKey: sourceKey,
            sourceRowID: sourceRowID,
            target: target,
            eventTimestamp: eventTimestamp,
            eventName: eventName,
            eventKind: eventKind,
            durationMilliseconds: firstDurationMilliseconds(for: [
                "duration_ms",
                "duration.milliseconds",
                "duration_millis",
                "duration",
            ]),
            success: firstBool(for: [
                "success",
                "ok",
                "succeeded",
            ]),
            errorSummary: errorSummary,
            threadID: threadID,
            turnID: turnID,
            model: metadata.model,
            sessionID: threadID,
            projectPath: metadata.projectPath,
            effort: metadata.effort ?? requestReasoningEffort,
            source: metadata.source,
            originator: firstIdentifier(for: [
                "originator",
                "codex.originator",
                "codex.session.originator",
            ]),
            appVersion: firstIdentifier(for: [
                "app.version",
                "app_version",
                "cli_version",
                "codex.cli_version",
            ]),
            terminalType: firstIdentifier(for: [
                "terminal.type",
                "terminal_type",
            ]),
            transport: firstIdentifier(for: [
                "transport",
                "codex.transport",
            ]),
            wireAPI: firstIdentifier(for: [
                "wire_api",
                "wire.api",
            ]),
            apiPath: firstValue(for: [
                "api.path",
                "api_path",
                "path",
            ]),
            runtimeDimensions: runtimeDimensions
        )
    }

    private var requestReasoningEffort: String? {
        CodexOtelRuntimeDimension(
            .requestReasoningEffort,
            firstValue(for: [
                "codex.request.reasoning_effort",
                "request.reasoning_effort",
                "request_reasoning_effort",
            ])
        )?.value
    }

    private var runtimeDimensions: [CodexOtelRuntimeDimension] {
        CodexOtelRuntimeDimension.unique(
            [
                CodexOtelRuntimeDimension(.authMode, firstValue(for: [
                    "auth_mode",
                    "auth.mode",
                    "codex.auth_mode",
                    "codex.request.auth_mode",
                ])),
                CodexOtelRuntimeDimension.boolean(.turnHasMetadataHeader, firstValue(for: [
                    "turn.has_metadata_header",
                    "codex.turn.has_metadata_header",
                    "has_metadata_header",
                ])),
                CodexOtelRuntimeDimension(.websocketWarmup, firstValue(for: [
                    "websocket.warmup",
                    "websocket_warmup",
                    "codex.websocket.warmup",
                ])),
                CodexOtelRuntimeDimension(.requestReasoningEffort, firstValue(for: [
                    "codex.request.reasoning_effort",
                    "request.reasoning_effort",
                    "request_reasoning_effort",
                ])),
                CodexOtelRuntimeDimension(.requestItemCountBucket, firstValue(for: [
                    "request.item_count",
                    "request.items_count",
                    "request_item_count",
                    "codex.request.item_count",
                    "codex.request.items_count",
                ])),
                CodexOtelRuntimeDimension(.connectionRetryCountBucket, firstValue(for: [
                    "connection.retry_count",
                    "connection_retry_count",
                    "websocket.retry_count",
                    "websocket.reconnect_count",
                    "request.retry_count",
                ])),
                CodexOtelRuntimeDimension(.toolOutputSizeBucket, firstValue(for: [
                    "tool_output_size",
                    "tool_output_size_bytes",
                    "tool_output_bytes",
                    "tool.output.size",
                    "tool.output.size_bytes",
                    "codex.tool_output_size",
                ])),
            ].compactMap(\.self)
        )
    }

    private var errorSummary: String? {
        guard let value = firstRawValue(for: [
            "error.summary",
            "error.kind",
            "error.code",
            "error.message",
        ]) else {
            return nil
        }

        let lowercased = value.lowercased()
        if lowercased.contains("timeout") {
            return "timeout"
        }
        if lowercased.contains("disconnect") || lowercased.contains("connection") {
            return "connection"
        }
        if lowercased.contains("rate") || lowercased.contains("limit") {
            return "rate_limit"
        }
        if lowercased.contains("cancel") {
            return "cancelled"
        }

        return normalizedIdentifier(value) ?? "error"
    }

    private func firstTimestamp(for keys: [String]) -> Date? {
        for key in keys {
            if let timestamp = value(for: key).flatMap(CodexSessionTokenBackfillImporter.parseTimestamp) {
                return timestamp
            }
        }

        return nil
    }

    private func firstIdentifier(for keys: [String]) -> String? {
        normalizedIdentifier(firstValue(for: keys))
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        CodexTokenContextNormalizer.normalizedIdentifier(value)
    }

    private func firstDurationMilliseconds(for keys: [String]) -> Int64? {
        for key in keys {
            guard let value = value(for: key) else {
                continue
            }
            if let intValue = Int64(value) {
                return intValue
            }
            if let doubleValue = Double(value) {
                return Int64((doubleValue * 1000).rounded())
            }
        }

        return nil
    }

    private func firstBool(for keys: [String]) -> Bool? {
        for key in keys {
            guard let value = value(for: key)?.lowercased() else {
                continue
            }
            if ["true", "yes", "1", "ok", "success"].contains(value) {
                return true
            }
            if ["false", "no", "0", "failed", "error"].contains(value) {
                return false
            }
        }

        if let status = firstValue(for: ["status", "otel.status_code"])?.lowercased() {
            if ["ok", "success", "unset"].contains(status) {
                return true
            }
            if ["error", "failed"].contains(status) {
                return false
            }
        }

        return nil
    }

    private func firstValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = value(for: key) {
                return value
            }
        }

        return nil
    }

    private func value(for key: String) -> String? {
        rawValue(for: key, rejectSensitiveValues: true)
    }

    private func firstRawValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = rawValue(for: key, rejectSensitiveValues: false) {
                return value
            }
        }

        return nil
    }

    private func rawValue(for key: String, rejectSensitiveValues: Bool) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?<![A-Za-z0-9_.-])[\"']?\(escapedKey)[\"']?\\s*[:=]\\s*(?:\"([^\"\\r\\n]*)\"|'([^'\\r\\n]*)'|([^\\s,;\\}\\]\\)]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = regex.firstMatch(in: body, range: range) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            guard match.range(at: index).location != NSNotFound,
                  let valueRange = Range(match.range(at: index), in: body)
            else {
                continue
            }

            let value = String(body[valueRange])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !value.isEmpty,
                  !rejectSensitiveValues
                    || (!value.lowercased().contains("user.email")
                        && !value.lowercased().contains("user.account_id")
                        && !value.lowercased().contains("authorization"))
            else {
                return nil
            }
            return value
        }

        return nil
    }
}

private struct CodexLogMetadataExtractor {
    let body: String
    private let bodyValues: [String: String]
    private let contextValues: [String: String]

    init(body: String) {
        self.body = body
        let bodyValues = CodexLogMetadataExtractor.keyValuePairs(in: body)
        self.bodyValues = bodyValues

        let contextBody = CodexLogMetadataExtractor.contextLookupBody(for: body)
        if contextBody == body {
            self.contextValues = bodyValues
        } else {
            self.contextValues = CodexLogMetadataExtractor.keyValuePairs(in: contextBody)
        }
    }

    var isResponseCompleted: Bool {
        body.contains("event.kind=response.completed")
    }

    var conversationID: String? {
        CodexTokenContextNormalizer.normalizedIdentifier(
            firstValue(for: [
                "conversation.id",
                "thread_id",
                "thread.id",
                "threadId",
            ])
        )
    }

    var model: String? {
        CodexModelIdentifier.firstNormalized([
            contextValue(for: "slug"),
            contextValue(for: "model"),
            contextValue(for: "model_slug"),
            contextValue(for: "modelSlug"),
            contextValue(for: "codex.turn.slug"),
            contextValue(for: "codex.turn.model"),
            contextValue(for: "codex.turn.model_slug"),
            contextValue(for: "codex.model"),
        ])
    }

    var projectPath: String? {
        firstContextValue(for: [
            "cwd",
            "project_path",
            "codex.cwd",
            "codex.project.cwd",
            "codex.session.cwd",
            "codex.turn.cwd",
        ])
    }

    var effort: String? {
        firstContextValue(for: [
            "model_reasoning_effort",
            "reasoning_effort",
            "collaboration_mode.settings.reasoning_effort",
            "codex.reasoning_effort",
            "codex.turn.reasoning_effort",
        ])
    }

    var source: String? {
        firstContextValue(for: [
            "source",
            "codex.source",
            "codex.session.source",
            "codex.turn.source",
        ])
    }

    var dimensions: [TokenUsageDimension] {
        dimensions(includeProvenanceDefault: true)
    }

    var explicitDimensions: [TokenUsageDimension] {
        dimensions(includeProvenanceDefault: false)
    }

    var hasCarriableMetadata: Bool {
        model != nil
            || projectPath != nil
            || effort != nil
            || source != nil
            || !explicitDimensions.isEmpty
    }

    func dimensions(includeProvenanceDefault: Bool) -> [TokenUsageDimension] {
        TokenUsageDimension.unique(
            [
                TokenUsageDimension(.originator, firstContextValue(for: [
                    "originator",
                    "codex.originator",
                    "codex.session.originator",
                ])),
                TokenUsageDimension(.sourceKind, source ?? firstContextValue(for: [
                    "source_kind",
                    "codex.source_kind",
                    "codex.session.source_kind",
                    "codex.turn.source_kind",
                ]) ?? (includeProvenanceDefault ? "codex-log" : nil)),
                TokenUsageDimension(.threadSource, firstContextValue(for: [
                    "thread_source",
                    "codex.thread_source",
                    "codex.session.thread_source",
                ])),
                TokenUsageDimension(.cliVersion, firstContextValue(for: [
                    "cli_version",
                    "app.version",
                    "app_version",
                    "codex.cli_version",
                    "codex.session.cli_version",
                ])),
                TokenUsageDimension(.modelProvider, firstContextValue(for: [
                    "model_provider",
                    "codex.model_provider",
                    "codex.turn.model_provider",
                ])),
                TokenUsageDimension(.memoryMode, firstContextValue(for: [
                    "memory_mode",
                    "codex.memory_mode",
                    "codex.turn.memory_mode",
                ])),
                TokenUsageDimension(.approvalPolicy, firstContextValue(for: [
                    "approval_policy",
                    "codex.approval_policy",
                    "codex.turn.approval_policy",
                ])),
                TokenUsageDimension(.sandboxType, firstContextValue(for: [
                    "sandbox_type",
                    "sandbox_policy.type",
                    "codex.sandbox_type",
                    "codex.turn.sandbox_type",
                    "codex.turn.sandbox_policy.type",
                ])),
                TokenUsageDimension(.permissionProfile, firstContextValue(for: [
                    "permission_profile",
                    "permission_profile.type",
                    "codex.permission_profile",
                    "codex.turn.permission_profile",
                    "codex.turn.permission_profile.type",
                ])),
                TokenUsageDimension(.realtimeActive, firstContextValue(for: [
                    "realtime_active",
                    "codex.realtime_active",
                    "codex.turn.realtime_active",
                ])),
                TokenUsageDimension(.truncationPolicy, firstContextValue(for: [
                    "truncation_policy",
                    "truncation_policy.mode",
                    "codex.truncation_policy",
                    "codex.turn.truncation_policy",
                    "codex.turn.truncation_policy.mode",
                ])),
                TokenUsageDimension(.usageMode, firstContextValue(for: [
                    "usage_mode",
                    "speed_mode",
                    "mode",
                    "codex.usage_mode",
                    "codex.turn.usage_mode",
                    "codex.turn.speed_mode",
                    "codex.turn.mode",
                ])),
            ].compactMap(\.self)
        )
    }

    func intValue(for key: String) -> Int64? {
        value(for: key).flatMap(Int64.init)
    }

    func value(for key: String) -> String? {
        bodyValues[key]
    }

    private func contextValue(for key: String) -> String? {
        contextValues[key]
    }

    private func firstValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = value(for: key) {
                return value
            }
        }

        return nil
    }

    private func firstContextValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = contextValue(for: key) {
                return value
            }
        }

        return nil
    }

    private static func contextLookupBody(for body: String) -> String {
        guard !body.contains("event.kind=response.completed"),
              let eventNameRange = body.range(of: " event.name=") ?? body.range(of: "event.name=")
        else {
            return body
        }

        return String(body[..<eventNameRange.lowerBound])
    }

    private static func keyValuePairs(in searchBody: String) -> [String: String] {
        var values: [String: String] = [:]
        var cursor = searchBody.startIndex

        while cursor < searchBody.endIndex {
            guard isIdentifierCharacter(searchBody[cursor]) else {
                cursor = searchBody.index(after: cursor)
                continue
            }

            if cursor > searchBody.startIndex {
                let previousIndex = searchBody.index(before: cursor)
                guard !isIdentifierCharacter(searchBody[previousIndex]) else {
                    cursor = searchBody.index(after: cursor)
                    continue
                }
            }

            let keyStart = cursor
            var keyEnd = cursor
            while keyEnd < searchBody.endIndex, isIdentifierCharacter(searchBody[keyEnd]) {
                keyEnd = searchBody.index(after: keyEnd)
            }
            var valueCursor = keyEnd
            while valueCursor < searchBody.endIndex, searchBody[valueCursor].isWhitespace {
                valueCursor = searchBody.index(after: valueCursor)
            }
            guard valueCursor < searchBody.endIndex, searchBody[valueCursor] == "=" else {
                cursor = keyEnd
                continue
            }
            valueCursor = searchBody.index(after: valueCursor)

            while valueCursor < searchBody.endIndex, searchBody[valueCursor].isWhitespace {
                valueCursor = searchBody.index(after: valueCursor)
            }
            guard valueCursor < searchBody.endIndex else {
                cursor = keyEnd
                continue
            }

            let valueStart: String.Index
            let valueEnd: String.Index
            if searchBody[valueCursor] == "\"" || searchBody[valueCursor] == "'" {
                let quote = searchBody[valueCursor]
                valueStart = searchBody.index(after: valueCursor)
                var end = valueStart
                while end < searchBody.endIndex, searchBody[end] != quote, !searchBody[end].isNewline {
                    end = searchBody.index(after: end)
                }
                valueEnd = end
                cursor = end < searchBody.endIndex ? searchBody.index(after: end) : end
            } else {
                valueStart = valueCursor
                var end = valueCursor
                while end < searchBody.endIndex, !isUnquotedValueTerminator(searchBody[end]) {
                    end = searchBody.index(after: end)
                }
                valueEnd = end
                cursor = end
            }

            let key = String(searchBody[keyStart..<keyEnd])
            let value = String(searchBody[valueStart..<valueEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !value.isEmpty {
                values[key, default: value] = values[key] ?? value
            }
        }

        return values
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "." || character == "-"
    }

    private static func isUnquotedValueTerminator(_ character: Character) -> Bool {
        character.isWhitespace || character == "," || character == ";" || character == "}" || character == "]" || character == ")"
    }
}

private struct CodexLogTokenContextTracker {
    var model: String?
    var sessionID: String?
    var projectPath: String?
    var effort: String?
    var source: String?
    var dimensions: [TokenUsageDimensionKey: TokenUsageDimension] = [:]

    init(sessionID: String?) {
        self.sessionID = CodexTokenContextNormalizer.normalizedIdentifier(sessionID)
    }

    mutating func apply(_ metadata: CodexLogMetadataExtractor) {
        if let conversationID = metadata.conversationID {
            sessionID = conversationID
        }
        if let model = metadata.model {
            self.model = model
        }
        if let projectPath = metadata.projectPath {
            self.projectPath = projectPath
        }
        if let effort = metadata.effort {
            self.effort = effort
        }
        if let source = metadata.source {
            self.source = source
        }
        for dimension in metadata.explicitDimensions {
            dimensions[dimension.key] = dimension
        }
    }

    var dimensionsList: [TokenUsageDimension] {
        Array(dimensions.values)
    }
}

protocol CodexSessionTokenBackfillImporting: Sendable {
    func importTokenHistory(
        into store: UsageHistoryStore,
        request: CodexSessionTokenBackfillRequest
    ) throws -> CodexSessionTokenBackfillSummary
}

extension CodexSessionTokenBackfillImporting {
    func importTokenHistory(into store: UsageHistoryStore) throws -> CodexSessionTokenBackfillSummary {
        try importTokenHistory(into: store, request: .allHistory())
    }
}

enum CodexSessionImportReadKind: Equatable, Sendable {
    case parserWindow(Int64)
    case fullFingerprintChunk(Int)
    case suffixFingerprintChunk(Int)
    case boundaryFingerprintChunk(Int)
    case oversizedDiscardChunk(Int)
}

struct CodexSessionTokenBackfillImporter: CodexSessionTokenBackfillImporting, @unchecked Sendable {
    let sourceDirectories: [URL]
    let fileManager: FileManager
    let readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)?
    let afterWindowCheckpoint: (@Sendable (Int) throws -> Void)?
    private static let tokenCountLineNeedle = Data(#""token_count""#.utf8)
    private static let turnContextLineNeedle = Data(#""turn_context""#.utf8)
    private static let sessionMetaLineNeedle = Data(#""session_meta""#.utf8)
    static let maximumReadWindowSize: Int64 = 64 * 1_024 * 1_024
    static let fingerprintBoundarySize = 64 * 1_024
    static let maximumParserReadSize = maximumReadWindowSize - (2 * Int64(fingerprintBoundarySize))

    init(
        sourceDirectories: [URL] = Self.defaultSourceDirectories(),
        fileManager: FileManager = .default,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)? = nil,
        afterWindowCheckpoint: (@Sendable (Int) throws -> Void)? = nil
    ) {
        self.sourceDirectories = sourceDirectories
        self.fileManager = fileManager
        self.readObserver = readObserver
        self.afterWindowCheckpoint = afterWindowCheckpoint
    }

    static func defaultSourceDirectories(fileManager: FileManager = .default) -> [URL] {
        let codexDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return [
            codexDirectory.appendingPathComponent("sessions", isDirectory: true),
            codexDirectory.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    static func defaultActiveSourceDirectories(fileManager: FileManager = .default) -> [URL] {
        let codexDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return [
            codexDirectory.appendingPathComponent("sessions", isDirectory: true),
        ]
    }

    func importTokenHistory(
        into store: UsageHistoryStore,
        request: CodexSessionTokenBackfillRequest
    ) throws -> CodexSessionTokenBackfillSummary {
        let startedAt = Date()
        let discoveredFiles = sessionFileCandidates(request: request)
        var filesSkippedByBounds = 0
        var filesSkippedUnchanged = 0
        var failedLinesSkipped = 0
        var tokenEventsImported = 0
        var duplicateEventsSkipped = 0
        var modelEventsRepaired = 0
        var contextEventsRepaired = 0
        var dimensionEventsRepaired = 0

        let sessionFiles = discoveredFiles.filter { candidate in
            guard shouldInclude(candidate: candidate, request: request) else {
                filesSkippedByBounds += 1
                return false
            }

            guard !shouldSkipUnchanged(candidate.metadata, store: store, request: request) else {
                filesSkippedUnchanged += 1
                return false
            }

            return true
        }

        for candidate in sessionFiles {
            let storedRecord = try? store.codexSessionTokenImportFileRecord(path: candidate.metadata.path)
            var priorRecord: CodexSessionTokenImportFileRecord?
            if !request.forceRescan,
               storedRecord?.contextVersion == UsageHistoryStore.currentSessionTokenContextImportVersion
            {
                priorRecord = storedRecord
            } else {
                priorRecord = nil
            }
            var windowCount = 0
            repeat {
                let previousOffset = priorRecord?.tailCursor?.byteOffset ?? 0
                let fileResult = parseSessionFileWindow(
                    candidate.url,
                    metadata: candidate.metadata,
                    priorRecord: priorRecord,
                    maximumBytes: request.maximumFileSize
                )
                failedLinesSkipped += fileResult.failedLinesSkipped
                let importResult = try store.importTokenUsageSamples(fileResult.samples)
                tokenEventsImported += importResult.insertedCount
                duplicateEventsSkipped += importResult.duplicateCount
                modelEventsRepaired += importResult.repairedModelCount
                contextEventsRepaired += importResult.repairedContextCount
                dimensionEventsRepaired += importResult.repairedDimensionCount

                try store.recordCodexSessionTokenImportFile(
                    candidate.metadata,
                    importedAt: Int64(Date().timeIntervalSince1970),
                    status: fileResult.readSucceeded ? .imported : .failed,
                    tailCursor: fileResult.tailCursor
                )
                windowCount += 1
                try afterWindowCheckpoint?(windowCount)

                let shouldContinueAllHistory = request.mode == .allHistory
                    && request.maximumFileSize == nil
                    && fileResult.readSucceeded
                    && fileResult.tailCursor.byteOffset < candidate.metadata.fileSize
                    && fileResult.tailCursor.byteOffset > previousOffset
                guard shouldContinueAllHistory else {
                    break
                }
                priorRecord = CodexSessionTokenImportFileRecord(
                    metadata: candidate.metadata,
                    importedAt: Int64(Date().timeIntervalSince1970),
                    status: .imported,
                    tailCursor: fileResult.tailCursor
                )
            } while true
        }

        return CodexSessionTokenBackfillSummary(
            request: request,
            filesDiscovered: discoveredFiles.count,
            filesScanned: sessionFiles.count,
            filesSkippedByBounds: filesSkippedByBounds,
            filesSkippedUnchanged: filesSkippedUnchanged,
            tokenEventsImported: tokenEventsImported,
            duplicateEventsSkipped: duplicateEventsSkipped,
            modelEventsRepaired: modelEventsRepaired,
            contextEventsRepaired: contextEventsRepaired,
            dimensionEventsRepaired: dimensionEventsRepaired,
            failedLinesSkipped: failedLinesSkipped,
            elapsedTime: Date().timeIntervalSince(startedAt)
        )
    }

    private struct SessionFileCandidate {
        let url: URL
        let metadata: CodexSessionTokenImportFileMetadata
        let sessionDate: Date?
    }

    private func sessionFileCandidates(request: CodexSessionTokenBackfillRequest) -> [SessionFileCandidate] {
        return sourceDirectories.flatMap { directoryURL -> [URL] in
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                return []
            }
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return enumerator.compactMap { item -> URL? in
                guard let fileURL = item as? URL else {
                    return nil
                }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    if let since = request.since,
                       Self.dateDirectoryIsEntirelyBefore(
                           fileURL,
                           root: directoryURL,
                           since: since
                       )
                    {
                        enumerator.skipDescendants()
                    }
                    return nil
                }
                guard fileURL.pathExtension == "jsonl" else {
                    return nil
                }
                return values?.isRegularFile == true ? fileURL : nil
            }
        }
        .compactMap { fileURL in
            guard let metadata = fileMetadata(for: fileURL) else {
                return nil
            }

            return SessionFileCandidate(
                url: fileURL,
                metadata: metadata,
                sessionDate: Self.sessionDate(from: fileURL)
            )
        }
        .sorted { $0.metadata.path.localizedStandardCompare($1.metadata.path) == .orderedAscending }
    }

    private static func dateDirectoryIsEntirelyBefore(
        _ directoryURL: URL,
        root: URL,
        since: Date
    ) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = directoryURL.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count else {
            return false
        }
        let relative = Array(components.dropFirst(rootComponents.count))
        guard (1...3).contains(relative.count),
              relative.allSatisfy({ Int($0) != nil }),
              let year = Int(relative[0])
        else {
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.timeZone = calendar.timeZone
        dateComponents.year = year
        let component: Calendar.Component
        if relative.count >= 2, let month = Int(relative[1]) {
            dateComponents.month = month
            if relative.count == 3, let day = Int(relative[2]) {
                dateComponents.day = day
                component = .day
            } else {
                dateComponents.day = 1
                component = .month
            }
        } else {
            dateComponents.month = 1
            dateComponents.day = 1
            component = .year
        }
        guard let start = calendar.date(from: dateComponents),
              let end = calendar.date(byAdding: component, value: 1, to: start)
        else {
            return false
        }
        return end <= since
    }

    private func fileMetadata(for fileURL: URL) -> CodexSessionTokenImportFileMetadata? {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CodexSessionTokenImportFileMetadata(
            path: fileURL.path,
            fileSize: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate.map { Int64($0.timeIntervalSince1970) } ?? 0
        )
    }

    private func shouldInclude(
        candidate: SessionFileCandidate,
        request: CodexSessionTokenBackfillRequest
    ) -> Bool {
        guard let since = request.since else {
            return true
        }

        if let sessionDate = candidate.sessionDate {
            return sessionDate >= since
        }

        let modifiedAt = Date(timeIntervalSince1970: TimeInterval(candidate.metadata.modifiedAt))
        return modifiedAt >= since
    }

    private func shouldSkipUnchanged(
        _ metadata: CodexSessionTokenImportFileMetadata,
        store: UsageHistoryStore,
        request: CodexSessionTokenBackfillRequest
    ) -> Bool {
        guard !request.forceRescan,
              let record = try? store.codexSessionTokenImportFileRecord(path: metadata.path)
        else {
            return false
        }

        guard record.status == .imported
            && record.metadata.fileSize == metadata.fileSize
            && record.metadata.modifiedAt == metadata.modifiedAt
            && record.contextVersion == UsageHistoryStore.currentSessionTokenContextImportVersion
            && (record.tailCursor?.byteOffset ?? metadata.fileSize) >= metadata.fileSize
        else {
            return false
        }
        guard let tailCursor = record.tailCursor,
              let storedHash = tailCursor.filePrefixHash
        else {
            return false
        }
        return Self.filePrefixMatches(
            storedHash,
            fileURL: URL(fileURLWithPath: metadata.path),
            through: tailCursor.byteOffset,
            readObserver: readObserver
        )
    }

    private struct TailParseResult {
        let samples: [ImportedCodexTokenUsageSample]
        let failedLinesSkipped: Int
        let readSucceeded: Bool
        let tailCursor: CodexSessionTokenTailCursor
    }

    private func parseSessionFileWindow(
        _ fileURL: URL,
        metadata: CodexSessionTokenImportFileMetadata,
        priorRecord: CodexSessionTokenImportFileRecord?,
        maximumBytes: Int64?
    ) -> TailParseResult {
        let priorCursor = priorRecord?.tailCursor
        let canResume: Bool
        if let priorCursor, let storedHash = priorCursor.filePrefixHash {
            canResume = Self.filePrefixMatches(
                storedHash,
                fileURL: fileURL,
                through: priorCursor.byteOffset,
                readObserver: readObserver
            )
                && priorCursor.byteOffset <= metadata.fileSize
        } else {
            canResume = false
        }

        let requestedByteLimit = max(maximumBytes ?? Self.maximumReadWindowSize, 1)
        let readByteLimit = min(requestedByteLimit, Self.maximumParserReadSize)
        var startOffset = canResume ? (priorCursor?.byteOffset ?? 0) : 0
        var nextLineNumber = canResume ? priorCursor?.nextLineNumber : 1
        var restoredState = canResume
            ? CodexSessionTokenTailState.decode(priorCursor?.stateJSON)
            : nil
        var alignToNextLine = false

        if !canResume, maximumBytes != nil, metadata.fileSize > requestedByteLimit {
            startOffset = metadata.fileSize - requestedByteLimit
            nextLineNumber = nil
            restoredState = nil
            alignToNextLine = true
        }

        let window: SessionWindow
        do {
            readObserver?(.parserWindow(readByteLimit))
            window = try Self.readSessionWindow(
                fileURL,
                startOffset: startOffset,
                maximumBytes: readByteLimit,
                alignToNextLine: alignToNextLine,
                readObserver: readObserver
            )
        } catch {
            return TailParseResult(
                samples: [],
                failedLinesSkipped: 1,
                readSucceeded: false,
                tailCursor: CodexSessionTokenTailCursor(
                    byteOffset: startOffset,
                    nextLineNumber: nextLineNumber,
                    filePrefixHash: Self.filePrefixHash(
                        fileURL,
                        through: startOffset,
                        readObserver: readObserver
                    ),
                    stateJSON: restoredState?.encodedJSON
                )
            )
        }

        let decoder = JSONDecoder()
        let sessionID = Self.sessionIdentifier(for: fileURL)
        var currentContext = CodexSessionTokenContextTracker(
            sessionID: sessionID,
            restoredState: restoredState
        )
        var currentModel = restoredState?.currentModel
        var samples: [ImportedCodexTokenUsageSample] = []
        var failedLinesSkipped = window.discardedLineCount
        var cursorOffset = window.offset
        var searchStart = window.data.startIndex

        while let newline = window.data[searchStart...].firstIndex(of: 0x0A) {
            let lineOffset = cursorOffset
            var line = window.data[searchStart..<newline]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            let nextIndex = window.data.index(after: newline)
            cursorOffset = window.offset + Int64(nextIndex - window.data.startIndex)
            searchStart = nextIndex

            defer {
                if let lineNumber = nextLineNumber {
                    nextLineNumber = lineNumber + 1
                }
            }
            guard !line.isEmpty else {
                continue
            }
            let lineData = Data(line)
            guard Self.shouldDecodeSessionLine(lineData) else {
                continue
            }

            do {
                let decodedLine = try decoder.decode(CodexSessionTokenBackfillLine.self, from: lineData)
                if decodedLine.isSessionMetadata {
                    currentContext.applyMetadata(from: decodedLine.payload)
                }
                if decodedLine.isTurnContext {
                    currentContext.applyTurnContext(from: decodedLine.payload)
                }
                if decodedLine.payload?.hasModelMetadata == true {
                    currentModel = decodedLine.payload?.modelIdentifier
                }

                guard let payload = decodedLine.payload,
                      payload.type == "token_count",
                      let info = payload.info
                else {
                    continue
                }
                guard let receivedAt = Self.parseTimestamp(decodedLine.timestamp) else {
                    failedLinesSkipped += 1
                    continue
                }

                let tokenUsage = CodexThreadTokenUsage(
                    last: info.lastTokenUsage.toDomainBreakdown(),
                    total: info.totalTokenUsage.toDomainBreakdown(),
                    modelContextWindow: info.modelContextWindow
                )
                let turnID = nextLineNumber.map { "line:\($0)" } ?? "byte:\(lineOffset)"
                samples.append(
                    ImportedCodexTokenUsageSample(
                        notification: CodexTokenUsageNotification(
                            threadID: sessionID,
                            turnID: turnID,
                            model: info.hasModelMetadata ? info.modelIdentifier : currentModel,
                            tokenUsage: tokenUsage
                        ),
                        receivedAt: receivedAt,
                        context: currentContext.context(adding: info.dimensions)
                    )
                )
            } catch {
                failedLinesSkipped += 1
            }
        }

        let state = currentContext.tailState(currentModel: currentModel)
        if let lineNumber = nextLineNumber, window.discardedLineCount > 0 {
            nextLineNumber = lineNumber + window.discardedLineCount
        }
        let fingerprintStart = canResume ? startOffset : window.offset
        let consumedSuffixCount = cursorOffset - fingerprintStart
        let consumedSuffix: Data? = if window.offset == fingerprintStart,
                                       consumedSuffixCount >= 0,
                                       consumedSuffixCount <= Int64(window.data.count)
        {
            Data(window.data.prefix(Int(consumedSuffixCount)))
        } else {
            nil
        }
        return TailParseResult(
            samples: samples,
            failedLinesSkipped: failedLinesSkipped,
            readSucceeded: true,
            tailCursor: CodexSessionTokenTailCursor(
                byteOffset: cursorOffset,
                nextLineNumber: nextLineNumber,
                filePrefixHash: Self.extendedFilePrefixHash(
                    priorCursor?.filePrefixHash,
                    fileURL: fileURL,
                    from: fingerprintStart,
                    through: cursorOffset,
                    consumedSuffix: consumedSuffix,
                    streamedSegmentLength: window.streamedSegmentLength,
                    streamedSegmentDigest: window.streamedSegmentDigest,
                    readObserver: readObserver
                ),
                stateJSON: state.encodedJSON
            )
        )
    }

    fileprivate struct SessionWindow {
        let data: Data
        let offset: Int64
        let discardedLineCount: Int
        let streamedSegmentLength: Int64?
        let streamedSegmentDigest: Data?

        init(
            data: Data,
            offset: Int64,
            discardedLineCount: Int,
            streamedSegmentLength: Int64? = nil,
            streamedSegmentDigest: Data? = nil
        ) {
            self.data = data
            self.offset = offset
            self.discardedLineCount = discardedLineCount
            self.streamedSegmentLength = streamedSegmentLength
            self.streamedSegmentDigest = streamedSegmentDigest
        }
    }

    fileprivate static func readSessionWindow(
        _ fileURL: URL,
        startOffset: Int64,
        maximumBytes: Int64,
        alignToNextLine: Bool,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)? = nil
    ) throws -> SessionWindow {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let normalizedStartOffset = max(startOffset, 0)
        var startsAtLineBoundary = normalizedStartOffset == 0
        if alignToNextLine, normalizedStartOffset > 0 {
            try handle.seek(toOffset: UInt64(normalizedStartOffset - 1))
            startsAtLineBoundary = try handle.read(upToCount: 1)?.first == 0x0A
        }
        try handle.seek(toOffset: UInt64(normalizedStartOffset))

        let count = Int(min(maximumBytes, Int64(Int.max)))
        var data = try handle.read(upToCount: count) ?? Data()
        var actualOffset = normalizedStartOffset
        if alignToNextLine, actualOffset > 0, !startsAtLineBoundary {
            guard let newline = data.firstIndex(of: 0x0A) else {
                guard data.count == count,
                      let offsetAfterNewline = try Self.offsetAfterNextNewline(
                          in: handle,
                          startingAt: actualOffset + Int64(data.count)
                      )
                else {
                    // The tail is an incomplete line. Leave the cursor before it so an append can
                    // complete the record without persisting partial bytes.
                    return SessionWindow(data: Data(), offset: actualOffset, discardedLineCount: 0)
                }
                // This prefix was intentionally omitted by a bounded tail read, so it is not a
                // parser failure even when finding its newline requires more than one chunk.
                return SessionWindow(data: Data(), offset: offsetAfterNewline, discardedLineCount: 0)
            }
            let alignedStart = data.index(after: newline)
            actualOffset += Int64(alignedStart - data.startIndex)
            data.removeSubrange(data.startIndex..<alignedStart)
        }

        if !alignToNextLine,
           data.count == count,
           data.firstIndex(of: 0x0A) == nil,
           let discarded = try Self.discardOversizedLine(
               in: handle,
               initialData: data,
               startingAt: actualOffset,
               readObserver: readObserver
           )
        {
            // A record larger than the bounded window cannot be decoded safely. Consume it in
            // fixed-size chunks through exactly one newline, count one failure, and let the next
            // import window resume at the following record.
            return SessionWindow(
                data: Data(),
                offset: discarded.offsetAfterNewline,
                discardedLineCount: 1,
                streamedSegmentLength: discarded.length,
                streamedSegmentDigest: discarded.digest
            )
        }

        return SessionWindow(data: data, offset: actualOffset, discardedLineCount: 0)
    }

    private static func offsetAfterNextNewline(
        in handle: FileHandle,
        startingAt startOffset: Int64
    ) throws -> Int64? {
        let chunkSize = 64 * 1_024
        var chunkOffset = startOffset
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else {
                return nil
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                return chunkOffset + Int64(newline - chunk.startIndex) + 1
            }
            chunkOffset += Int64(chunk.count)
        }
    }

    private struct StreamedDiscardResult {
        let offsetAfterNewline: Int64
        let length: Int64
        let digest: Data
    }

    private static func discardOversizedLine(
        in handle: FileHandle,
        initialData: Data,
        startingAt startOffset: Int64,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)?
    ) throws -> StreamedDiscardResult? {
        var hasher = SHA256()
        hasher.update(data: initialData)
        var length = Int64(initialData.count)
        let chunkSize = 64 * 1_024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else {
                return nil
            }
            readObserver?(.oversizedDiscardChunk(chunk.count))
            if let newline = chunk.firstIndex(of: 0x0A) {
                let consumed = Data(chunk[...newline])
                hasher.update(data: consumed)
                length += Int64(consumed.count)
                return StreamedDiscardResult(
                    offsetAfterNewline: startOffset + length,
                    length: length,
                    digest: Data(hasher.finalize())
                )
            }
            hasher.update(data: chunk)
            length += Int64(chunk.count)
        }
    }

    /// Fingerprints consumed JSONL ranges as SHA-256 segments. Normal append-only growth extends
    /// the fingerprint from bytes already held by the parser, so a 64 MiB window is read only once.
    /// Same-size rewrites and inode replacement verify every persisted segment before resuming.
    fileprivate static func filePrefixHash(
        _ fileURL: URL,
        through byteOffset: Int64,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)? = nil
    ) -> String? {
        filePrefixFingerprint(
            fileURL,
            coverageStart: 0,
            through: byteOffset,
            readObserver: readObserver
        )?.encoded
    }

    fileprivate static func filePrefixMatches(
        _ storedHash: String,
        fileURL: URL,
        through byteOffset: Int64,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)? = nil
    ) -> Bool {
        guard let stored = FilePrefixFingerprint(encoded: storedHash),
              stored.byteCount == max(byteOffset, 0),
              let currentIdentity = fileIdentity(for: fileURL)
        else {
            return false
        }
        if stored.identity == currentIdentity {
            return true
        }
        // Identity changes cannot prove append-only growth: a same-inode file may have been
        // truncated, rewritten, and regrown between scans. Revalidate every consumed segment
        // before trusting its cursor. Reads stay chunk-bounded even though correctness requires
        // O(consumed-prefix) I/O when the file identity changed.
        guard let current = filePrefixFingerprint(
            fileURL,
            matchingLayoutOf: stored,
            readObserver: readObserver
        ) else {
            return false
        }
        return stored.hasSameContent(as: current)
    }

    fileprivate static func extendedFilePrefixHash(
        _ storedHash: String?,
        fileURL: URL,
        from startOffset: Int64,
        through endOffset: Int64,
        consumedSuffix: Data? = nil,
        streamedSegmentLength: Int64? = nil,
        streamedSegmentDigest: Data? = nil,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)? = nil
    ) -> String? {
        guard endOffset >= startOffset,
              let identityBefore = fileIdentity(for: fileURL)
        else {
            return filePrefixHash(fileURL, through: endOffset, readObserver: readObserver)
        }
        let stored = storedHash.flatMap(FilePrefixFingerprint.init(encoded:))
        let coverageStart: Int64
        var segments: [FilePrefixFingerprint.Segment]
        if let stored, stored.byteCount == startOffset {
            coverageStart = stored.coverageStart
            segments = stored.segments
        } else if storedHash == nil {
            coverageStart = startOffset
            segments = []
        } else {
            return filePrefixHash(fileURL, through: endOffset, readObserver: readObserver)
        }
        if let consumedSuffix,
           Int64(consumedSuffix.count) == endOffset - startOffset,
           !consumedSuffix.isEmpty
        {
            segments.append(.init(length: Int64(consumedSuffix.count), digest: sha256(consumedSuffix)))
        } else if let streamedSegmentLength,
                  let streamedSegmentDigest,
                  streamedSegmentLength == endOffset - startOffset,
                  streamedSegmentDigest.count == 32,
                  streamedSegmentLength > 0
        {
            segments.append(.init(length: streamedSegmentLength, digest: streamedSegmentDigest))
        } else if endOffset != startOffset {
            return filePrefixHash(fileURL, through: endOffset, readObserver: readObserver)
        }
        guard segments.reduce(Int64(0), { $0 + $1.length }) == endOffset - coverageStart,
              let boundaryDigest = fingerprintBoundaryDigest(
                  fileURL,
                  coverageStart: coverageStart,
                  through: endOffset,
                  readObserver: readObserver
              ),
              let identityAfter = fileIdentity(for: fileURL),
              identityAfter == identityBefore
        else {
            return nil
        }
        return FilePrefixFingerprint(
            coverageStart: coverageStart,
            byteCount: endOffset,
            segments: segments,
            boundaryDigest: boundaryDigest,
            identity: identityAfter
        ).encoded
    }

    private static let prefixFingerprintReadChunkSize = 1_024 * 1_024

    private struct SessionFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let fileSize: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        var encodedFields: [String] {
            [
                String(device), String(inode), String(fileSize),
                String(modificationSeconds), String(modificationNanoseconds),
                String(changeSeconds), String(changeNanoseconds),
            ]
        }
    }

    private struct FilePrefixFingerprint {
        struct Segment: Equatable {
            let length: Int64
            let digest: Data

            var encoded: String { "\(length).\(digest.hexString)" }

            init(length: Int64, digest: Data) {
                self.length = length
                self.digest = digest
            }

            init?(encoded: Substring) {
                guard let separator = encoded.firstIndex(of: "."),
                      let length = Int64(encoded[..<separator]), length > 0,
                      let digest = Data(hexString: String(encoded[encoded.index(after: separator)...])),
                      digest.count == 32
                else {
                    return nil
                }
                self.init(length: length, digest: digest)
            }
        }

        let coverageStart: Int64
        let byteCount: Int64
        let segments: [Segment]
        let boundaryDigest: Data
        let identity: SessionFileIdentity

        init(
            coverageStart: Int64,
            byteCount: Int64,
            segments: [Segment],
            boundaryDigest: Data,
            identity: SessionFileIdentity
        ) {
            self.coverageStart = coverageStart
            self.byteCount = byteCount
            self.segments = segments
            self.boundaryDigest = boundaryDigest
            self.identity = identity
        }

        init?(encoded: String) {
            let fields = encoded.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 12,
                  fields[0] == "v4",
                  let coverageStart = Int64(fields[1]), coverageStart >= 0,
                  let byteCount = Int64(fields[2]), byteCount >= coverageStart,
                  let segments = Self.decodeSegments(fields[3]),
                  segments.reduce(Int64(0), { $0 + $1.length }) == byteCount - coverageStart,
                  let boundaryDigest = Data(hexString: String(fields[4])), boundaryDigest.count == 32,
                  let device = UInt64(fields[5]),
                  let inode = UInt64(fields[6]),
                  let fileSize = Int64(fields[7]),
                  let modificationSeconds = Int64(fields[8]),
                  let modificationNanoseconds = Int64(fields[9]),
                  let changeSeconds = Int64(fields[10]),
                  let changeNanoseconds = Int64(fields[11])
            else {
                return nil
            }
            self.init(
                coverageStart: coverageStart,
                byteCount: byteCount,
                segments: segments,
                boundaryDigest: boundaryDigest,
                identity: SessionFileIdentity(
                    device: device,
                    inode: inode,
                    fileSize: fileSize,
                    modificationSeconds: modificationSeconds,
                    modificationNanoseconds: modificationNanoseconds,
                    changeSeconds: changeSeconds,
                    changeNanoseconds: changeNanoseconds
                )
            )
        }

        var encoded: String {
            ([
                "v4", String(coverageStart), String(byteCount),
                segments.map(\.encoded).joined(separator: ","), boundaryDigest.hexString,
            ] + identity.encodedFields)
                .joined(separator: ":")
        }

        func hasSameContent(as other: FilePrefixFingerprint) -> Bool {
            coverageStart == other.coverageStart
                && byteCount == other.byteCount
                && segments == other.segments
        }

        private static func decodeSegments(_ value: Substring) -> [Segment]? {
            if value.isEmpty {
                return []
            }
            let segments = value.split(separator: ",").compactMap(Segment.init(encoded:))
            return segments.count == value.split(separator: ",").count ? segments : nil
        }
    }

    private static func filePrefixFingerprint(
        _ fileURL: URL,
        coverageStart: Int64,
        through byteOffset: Int64,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)?
    ) -> FilePrefixFingerprint? {
        let length = max(byteOffset - coverageStart, 0)
        var segmentLengths: [Int64] = []
        var remaining = length
        while remaining > 0 {
            let count = min(remaining, maximumReadWindowSize)
            segmentLengths.append(count)
            remaining -= count
        }
        return filePrefixFingerprint(
            fileURL,
            coverageStart: coverageStart,
            through: byteOffset,
            segmentLengths: segmentLengths,
            readObserver: readObserver
        )
    }

    private static func filePrefixFingerprint(
        _ fileURL: URL,
        matchingLayoutOf stored: FilePrefixFingerprint,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)?
    ) -> FilePrefixFingerprint? {
        filePrefixFingerprint(
            fileURL,
            coverageStart: stored.coverageStart,
            through: stored.byteCount,
            segmentLengths: stored.segments.map(\.length),
            readObserver: readObserver
        )
    }

    private static func filePrefixFingerprint(
        _ fileURL: URL,
        coverageStart: Int64,
        through byteOffset: Int64,
        segmentLengths: [Int64],
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)?
    ) -> FilePrefixFingerprint? {
        guard let identityBefore = fileIdentity(for: fileURL),
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(coverageStart))) != nil else {
            return nil
        }
        var segments: [FilePrefixFingerprint.Segment] = []
        for length in segmentLengths {
            var hasher = SHA256()
            var remaining = length
            while remaining > 0 {
                let count = Int(min(remaining, Int64(prefixFingerprintReadChunkSize)))
                guard let chunk = try? readExactly(count, from: handle), chunk.count == count else {
                    return nil
                }
                readObserver?(.fullFingerprintChunk(chunk.count))
                hasher.update(data: chunk)
                remaining -= Int64(count)
            }
            segments.append(.init(length: length, digest: Data(hasher.finalize())))
        }
        guard segmentLengths.reduce(Int64(0), +) == byteOffset - coverageStart,
              let boundaryDigest = fingerprintBoundaryDigest(
                  in: handle,
                  coverageStart: coverageStart,
                  through: byteOffset,
                  readObserver: readObserver
              ),
              let identityAfter = fileIdentity(for: fileURL), identityAfter == identityBefore
        else {
            return nil
        }
        return FilePrefixFingerprint(
            coverageStart: coverageStart,
            byteCount: byteOffset,
            segments: segments,
            boundaryDigest: boundaryDigest,
            identity: identityAfter
        )
    }

    private static func fingerprintBoundaryDigest(
        _ fileURL: URL,
        coverageStart: Int64,
        through byteOffset: Int64,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)?
    ) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        return fingerprintBoundaryDigest(
            in: handle,
            coverageStart: coverageStart,
            through: byteOffset,
            readObserver: readObserver
        )
    }

    private static func fingerprintBoundaryDigest(
        in handle: FileHandle,
        coverageStart: Int64,
        through byteOffset: Int64,
        readObserver: (@Sendable (CodexSessionImportReadKind) -> Void)?
    ) -> Data? {
        let coveredLength = max(byteOffset - coverageStart, 0)
        let count = Int(min(coveredLength, Int64(fingerprintBoundarySize)))
        let start = byteOffset - Int64(count)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let data = try? readExactly(count, from: handle),
              data.count == count
        else {
            return nil
        }
        if !data.isEmpty {
            readObserver?(.boundaryFingerprintChunk(data.count))
        }
        return sha256(data)
    }

    private static func fileIdentity(for fileURL: URL) -> SessionFileIdentity? {
        var information = stat()
        guard lstat(fileURL.path, &information) == 0 else {
            return nil
        }
        return SessionFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            fileSize: Int64(information.st_size),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            changeSeconds: Int64(information.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try handle.read(upToCount: count - result.count) ?? Data()
            guard !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        return result
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func shouldDecodeSessionLine(_ lineData: Data) -> Bool {
        lineData.range(of: tokenCountLineNeedle) != nil
            || lineData.range(of: turnContextLineNeedle) != nil
            || lineData.range(of: sessionMetaLineNeedle) != nil
    }

    static func sessionDate(from fileURL: URL) -> Date? {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let pattern = #"rollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
              match.numberOfRanges == 7
        else {
            return nil
        }

        let parts = (1..<7).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: name) else {
                return nil
            }
            return String(name[range])
        }

        guard parts.count == 6 else {
            return nil
        }

        return parseTimestamp("\(parts[0])-\(parts[1])-\(parts[2])T\(parts[3]):\(parts[4]):\(parts[5])Z")
    }

    static func sessionIdentifier(for fileURL: URL) -> String {
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

    var isSessionMetadata: Bool {
        type == "session_meta"
    }

    var isTurnContext: Bool {
        type == "turn_context" || payload?.type == "turn_context"
    }

    struct Payload: Decodable {
        let type: String?
        let id: String?
        let cwd: String?
        let source: CodexSafeSourceMetadataPayload?
        let effort: String?
        let originator: String?
        let cliVersion: String?
        let modelProvider: String?
        let memoryMode: String?
        let threadSource: String?
        let approvalPolicy: String?
        let sandboxPolicy: CodexSandboxPolicyPayload?
        let permissionProfile: String?
        let realtimeActive: Bool?
        let truncationPolicy: String?
        let usageMode: String?
        let speedMode: String?
        let mode: String?
        let collaborationMode: CollaborationMode?
        let turnID: String?
        let startedAt: Int64?
        let completedAt: Int64?
        let durationMilliseconds: Int64?
        let timeToFirstTokenMilliseconds: Int64?
        let modelContextWindow: Int64?
        let collaborationModeKind: String?
        let info: Info?
        let model: String?
        let slug: String?
        let modelSlug: String?

        var modelIdentifier: String? {
            CodexModelIdentifier.firstNormalized([model, slug, modelSlug])
        }

        var safeSessionID: String? {
            CodexTokenContextNormalizer.normalizedMetadataIdentifier(id)
        }

        var safeProjectPath: String? {
            CodexTokenContextNormalizer.normalizedProjectPath(cwd)
        }

        var safeEffort: String? {
            CodexTokenContextNormalizer.normalizedMetadataIdentifier(
                effort ?? collaborationMode?.settings?.reasoningEffort
            )
        }

        var safeSource: String? {
            CodexTokenContextNormalizer.normalizedMetadataIdentifier(
                source?.dimensions.first { $0.key == .sourceKind }?.value
            )
        }

        var hasModelMetadata: Bool {
            model != nil || slug != nil || modelSlug != nil
        }

        var isTaskStarted: Bool {
            type == "task_started"
        }

        var isTaskComplete: Bool {
            type == "task_complete"
        }

        var startedAtDate: Date? {
            Self.date(fromEpoch: startedAt)
        }

        var completedAtDate: Date? {
            Self.date(fromEpoch: completedAt)
        }

        var dimensions: [TokenUsageDimension] {
            TokenUsageDimension.unique(
                [
                    TokenUsageDimension(.originator, originator),
                    TokenUsageDimension(.sourceKind, safeSource),
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
                    TokenUsageDimension(.usageMode, info?.usageMode ?? info?.speedMode ?? info?.mode),
                ].compactMap(\.self)
                    + (source?.dimensions ?? [])
                    + (info?.dimensions ?? [])
            )
        }

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case cwd
            case source
            case effort
            case originator
            case cliVersion = "cli_version"
            case modelProvider = "model_provider"
            case memoryMode = "memory_mode"
            case threadSource = "thread_source"
            case approvalPolicy = "approval_policy"
            case sandboxPolicy = "sandbox_policy"
            case permissionProfile = "permission_profile"
            case realtimeActive = "realtime_active"
            case truncationPolicy = "truncation_policy"
            case usageMode = "usage_mode"
            case speedMode = "speed_mode"
            case mode
            case collaborationMode = "collaboration_mode"
            case turnID = "turn_id"
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case durationMilliseconds = "duration_ms"
            case timeToFirstTokenMilliseconds = "time_to_first_token_ms"
            case modelContextWindow = "model_context_window"
            case collaborationModeKind = "collaboration_mode_kind"
            case info
            case model
            case slug
            case modelSlug
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
            source = try? container.decodeIfPresent(CodexSafeSourceMetadataPayload.self, forKey: .source)
            effort = try? container.decodeIfPresent(String.self, forKey: .effort)
            originator = try? container.decodeIfPresent(String.self, forKey: .originator)
            cliVersion = try? container.decodeIfPresent(String.self, forKey: .cliVersion)
            modelProvider = try? container.decodeIfPresent(String.self, forKey: .modelProvider)
            memoryMode = try? container.decodeIfPresent(String.self, forKey: .memoryMode)
            threadSource = try? container.decodeIfPresent(String.self, forKey: .threadSource)
            approvalPolicy = try? container.decodeIfPresent(String.self, forKey: .approvalPolicy)
            sandboxPolicy = try? container.decodeIfPresent(CodexSandboxPolicyPayload.self, forKey: .sandboxPolicy)
            permissionProfile = Self.decodeFlexibleString(from: container, .permissionProfile)
            realtimeActive = try? container.decodeIfPresent(Bool.self, forKey: .realtimeActive)
            truncationPolicy = Self.decodeFlexibleString(from: container, .truncationPolicy)
            usageMode = try? container.decodeIfPresent(String.self, forKey: .usageMode)
            speedMode = try? container.decodeIfPresent(String.self, forKey: .speedMode)
            mode = try? container.decodeIfPresent(String.self, forKey: .mode)
            collaborationMode = try? container.decode(CollaborationMode.self, forKey: .collaborationMode)
            turnID = try? container.decodeIfPresent(String.self, forKey: .turnID)
            startedAt = Self.decodeFlexibleInt64(from: container, .startedAt)
            completedAt = Self.decodeFlexibleInt64(from: container, .completedAt)
            durationMilliseconds = Self.decodeFlexibleInt64(from: container, .durationMilliseconds)
            timeToFirstTokenMilliseconds = Self.decodeFlexibleInt64(from: container, .timeToFirstTokenMilliseconds)
            modelContextWindow = Self.decodeFlexibleInt64(from: container, .modelContextWindow)
            collaborationModeKind = try? container.decodeIfPresent(String.self, forKey: .collaborationModeKind)
            info = try? container.decode(Info.self, forKey: .info)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            slug = try container.decodeIfPresent(String.self, forKey: .slug)
            modelSlug = try container.decodeIfPresent(String.self, forKey: .modelSlug)
        }

        private static func decodeFlexibleString(
            from container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }

            return (try? container.decodeIfPresent(CodexSafeMetadataValuePayload.self, forKey: key))?.value
        }

        private static func decodeFlexibleInt64(
            from container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> Int64? {
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int64(value.rounded())
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int64(value)
            }
            return nil
        }

        private static func date(fromEpoch rawValue: Int64?) -> Date? {
            guard let rawValue, rawValue > 0 else {
                return nil
            }

            if rawValue > 10_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(rawValue) / 1_000)
            }
            return Date(timeIntervalSince1970: TimeInterval(rawValue))
        }
    }

    struct Info: Decodable {
        let lastTokenUsage: SessionTokenUsageBreakdown
        let totalTokenUsage: SessionTokenUsageBreakdown
        let modelContextWindow: Int64?
        let model: String?
        let slug: String?
        let modelSlug: String?
        let usageMode: String?
        let speedMode: String?
        let mode: String?

        var modelIdentifier: String? {
            CodexModelIdentifier.firstNormalized([model, slug, modelSlug])
        }

        var dimensions: [TokenUsageDimension] {
            TokenUsageDimension.unique(
                [
                    TokenUsageDimension(.usageMode, usageMode ?? speedMode ?? mode),
                ].compactMap(\.self)
            )
        }

        var hasModelMetadata: Bool {
            model != nil || slug != nil || modelSlug != nil
        }

        enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
            case totalTokenUsage = "total_token_usage"
            case modelContextWindow = "model_context_window"
            case model
            case slug
            case modelSlug
            case usageMode = "usage_mode"
            case speedMode = "speed_mode"
            case mode
        }
    }

    struct CollaborationMode: Decodable {
        let settings: Settings?

        struct Settings: Decodable {
            let reasoningEffort: String?

            enum CodingKeys: String, CodingKey {
                case reasoningEffort = "reasoning_effort"
            }
        }
    }
}

private struct CodexSessionTokenContextTracker {
    var sessionID: String?
    var projectPath: String?
    var effort: String?
    var source: String?
    var dimensions: [TokenUsageDimensionKey: TokenUsageDimension] = [:]

    init(sessionID: String?) {
        self.sessionID = CodexTokenContextNormalizer.normalizedMetadataIdentifier(sessionID)
    }

    init(sessionID: String?, restoredState: CodexSessionTokenTailState?) {
        self.init(sessionID: restoredState?.sessionID ?? sessionID)
        projectPath = CodexTokenContextNormalizer.normalizedProjectPath(restoredState?.projectPath)
        effort = CodexTokenContextNormalizer.normalizedMetadataIdentifier(restoredState?.effort)
        source = CodexTokenContextNormalizer.normalizedMetadataIdentifier(restoredState?.source)
        for (rawKey, rawValue) in restoredState?.dimensions ?? [:] {
            guard let key = TokenUsageDimensionKey(rawValue: rawKey),
                  let dimension = TokenUsageDimension(key, rawValue)
            else {
                continue
            }
            dimensions[key] = dimension
        }
    }

    mutating func applyMetadata(from payload: CodexSessionTokenBackfillLine.Payload?) {
        guard let payload else {
            return
        }

        if let sessionID = payload.safeSessionID {
            self.sessionID = sessionID
        }
        if let projectPath = payload.safeProjectPath {
            self.projectPath = projectPath
        }
        if let source = payload.safeSource {
            self.source = source
        }
        if let effort = payload.safeEffort {
            self.effort = effort
        }
        applyDimensions(payload.dimensions)
    }

    mutating func applyTurnContext(from payload: CodexSessionTokenBackfillLine.Payload?) {
        guard let payload else {
            return
        }

        if let projectPath = payload.safeProjectPath {
            self.projectPath = projectPath
        }
        if let effort = payload.safeEffort {
            self.effort = effort
        }
        if let source = payload.safeSource {
            self.source = source
        }
        applyDimensions(payload.dimensions)
    }

    mutating func applyDimensions(_ newDimensions: [TokenUsageDimension]) {
        for dimension in newDimensions {
            dimensions[dimension.key] = dimension
        }
    }

    var context: TokenUsageContext? {
        context(adding: [])
    }

    func context(adding additionalDimensions: [TokenUsageDimension]) -> TokenUsageContext? {
        let context = TokenUsageContext(
            sessionID: sessionID,
            projectPath: projectPath,
            effort: effort,
            source: source,
            dimensions: Array(dimensions.values) + additionalDimensions
        )
        return context.hasAnyValue ? context : nil
    }

    func tailState(currentModel: String?) -> CodexSessionTokenTailState {
        CodexSessionTokenTailState(
            sessionID: CodexTokenContextNormalizer.normalizedMetadataIdentifier(sessionID),
            projectPath: projectPath,
            effort: CodexTokenContextNormalizer.normalizedMetadataIdentifier(effort),
            source: CodexTokenContextNormalizer.normalizedMetadataIdentifier(source),
            dimensions: Dictionary(uniqueKeysWithValues: dimensions.values.map { ($0.key.rawValue, $0.value) }),
            currentModel: CodexModelIdentifier.normalized(currentModel)
        )
    }
}

private struct CodexSessionTokenTailState: Codable {
    let sessionID: String?
    let projectPath: String?
    let effort: String?
    let source: String?
    let dimensions: [String: String]
    let currentModel: String?

    static func decode(_ json: String?) -> CodexSessionTokenTailState? {
        guard let data = json?.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CodexSessionTokenTailState.self, from: data)
    }

    var encodedJSON: String? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
