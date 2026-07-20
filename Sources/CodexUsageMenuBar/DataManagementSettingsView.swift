import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTabSelection: String {
    case data
    case updates
}

enum SettingsTabSelectionStore {
    static let key = "Settings.selectedTab"

    static func select(_ tab: SettingsTabSelection, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: key)
    }

    static func selectedTab(from rawValue: String) -> SettingsTabSelection {
        SettingsTabSelection(rawValue: rawValue) ?? .data
    }
}

@MainActor
private final class UnavailableCodexProfileTokenUsageClient: CodexProfileTokenUsageFetching {
    func profileTokenUsageSnapshot() async throws -> CodexProfileTokenUsageSnapshot {
        throw CodexClientError.authTokenUnavailable
    }
}

@MainActor
final class DataManagementSettingsViewModel: ObservableObject {
    @Published private(set) var databasePathText = "Unavailable"
    @Published private(set) var databaseSizeText = "--"
    @Published private(set) var storageLimitText = "Storage unavailable"
    @Published private(set) var maintenanceStatusText = "Maintenance not run yet"
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isImportingTokenHistory = false
    @Published private(set) var tokenImportSummaryText: String?
    @Published private(set) var projectEntries: [TokenProjectCatalogEntry] = []
    @Published private(set) var tokenPayloadAudit: CodexTokenUsagePayloadAudit?
    @Published private(set) var tokenPayloadAuditDiagnostics: CodexAppServerAuditDiagnostics
    @Published private(set) var localTokenCaptureState = CodexLiveTokenCaptureState()
    @Published private(set) var turnPerformanceCaptureState = CodexTurnPerformanceCaptureState()
    @Published private(set) var turnPerformanceRuntimeDimensionSummary = CodexOtelRuntimeDimensionSummary.empty
    @Published private(set) var sessionTaskTimingCaptureState = CodexSessionTaskTimingCaptureState()
    @Published private(set) var threadCatalogCaptureState = CodexThreadCatalogCaptureState()
    @Published private(set) var modelCapabilitiesCaptureState = CodexModelCapabilitiesCaptureState()
    @Published private(set) var localSourceCoverageSnapshot = CodexLocalSourceCoverageSnapshot.empty
    @Published private(set) var performanceInstrumentationSummary: AppPerformanceInstrumentationSummary
    @Published private(set) var profileTokenUsageState: CodexProfileTokenUsageState
    @Published private(set) var profileTokenComparisonSummary: CodexProfileTokenComparisonSummary?
    @Published private(set) var isRefreshingProfileTokens = false
    @Published private(set) var codexSourceHealthState: CodexSourceHealthState
    @Published private(set) var isRefreshingCodexSourceHealth = false
    @Published private(set) var isRefreshingRemoteControlHealth = false
    @Published private(set) var isOptimizingStorage = false

    private let database: UsageHistoryDatabaseWorking
    private let defaults: UserDefaults
    private let byteFormatter: ByteCountFormatter
    private let tokenBackfillImporter: CodexSessionTokenBackfillImporting
    private let tokenPayloadAuditStore: CodexTokenPayloadAuditStore
    private let tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore
    private let performanceInstrumentationStore: AppPerformanceInstrumentationStore
    private let profileTokenUsageStore: CodexProfileTokenUsageStore
    private let profileTokenClient: CodexProfileTokenUsageFetching
    private let codexSourceHealthStore: CodexSourceHealthStore
    private let codexSourceHealthReader: CodexSourceHealthReading
    private let remoteControlHealthReader: CodexRemoteControlHealthReading
    private let localSourceCoverageProbe: CodexLocalSourceCoverageProbing
    private let autoRefreshProfileTokens: Bool
    private let now: () -> Date
    private var databaseInfo: UsageHistoryDatabaseInfo?
    private var localSourceStoredMetrics = CodexLocalSourceStoredMetrics.empty
    private var localSourceProbeSnapshot = CodexLocalSourceProbeSnapshot.notChecked
    private var tokenPayloadAuditCancellable: AnyCancellable?
    private var tokenPayloadAuditDiagnosticsCancellable: AnyCancellable?
    private var performanceInstrumentationCancellable: AnyCancellable?
    private var performanceInstrumentationErrorCancellable: AnyCancellable?
    private var codexSourceHealthCancellable: AnyCancellable?

    init(
        database: UsageHistoryDatabaseWorking,
        defaults: UserDefaults = .standard,
        byteFormatter: ByteCountFormatter = ByteCountFormatter(),
        tokenBackfillImporter: CodexSessionTokenBackfillImporting = CodexSessionTokenBackfillImporter(),
        tokenPayloadAuditStore: CodexTokenPayloadAuditStore = .applicationSupportStore(),
        tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore = .applicationSupportStore(),
        performanceInstrumentationStore: AppPerformanceInstrumentationStore = .shared,
        profileTokenUsageStore: CodexProfileTokenUsageStore = .applicationSupportStore(),
        profileTokenClient: CodexProfileTokenUsageFetching = UnavailableCodexProfileTokenUsageClient(),
        codexSourceHealthStore: CodexSourceHealthStore = .shared,
        codexSourceHealthReader: CodexSourceHealthReading = CodexSourceHealthReader(),
        remoteControlHealthReader: CodexRemoteControlHealthReading = CodexRemoteControlHealthReader(),
        localSourceCoverageProbe: CodexLocalSourceCoverageProbing = CodexLocalSourceCoverageProbe(),
        autoRefreshProfileTokens: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.database = database
        self.defaults = defaults
        self.byteFormatter = byteFormatter
        self.tokenBackfillImporter = tokenBackfillImporter
        self.tokenPayloadAuditStore = tokenPayloadAuditStore
        self.tokenPayloadAuditDiagnosticsStore = tokenPayloadAuditDiagnosticsStore
        self.performanceInstrumentationStore = performanceInstrumentationStore
        self.profileTokenUsageStore = profileTokenUsageStore
        self.profileTokenClient = profileTokenClient
        self.codexSourceHealthStore = codexSourceHealthStore
        self.codexSourceHealthReader = codexSourceHealthReader
        self.remoteControlHealthReader = remoteControlHealthReader
        self.localSourceCoverageProbe = localSourceCoverageProbe
        self.autoRefreshProfileTokens = autoRefreshProfileTokens
        self.now = now
        tokenPayloadAudit = tokenPayloadAuditStore.latestAudit
        tokenPayloadAuditDiagnostics = tokenPayloadAuditDiagnosticsStore.diagnostics
        performanceInstrumentationSummary = performanceInstrumentationStore.summary()
        profileTokenUsageState = profileTokenUsageStore.state
        codexSourceHealthState = codexSourceHealthStore.state
        tokenPayloadAuditCancellable = tokenPayloadAuditStore.$latestAudit.sink { [weak self] audit in
            self?.tokenPayloadAudit = audit
        }
        tokenPayloadAuditDiagnosticsCancellable = tokenPayloadAuditDiagnosticsStore.$diagnostics.sink { [weak self] diagnostics in
            self?.tokenPayloadAuditDiagnostics = diagnostics
            self?.rebuildLocalSourceCoverageSnapshot()
        }
        performanceInstrumentationCancellable = performanceInstrumentationStore.$events.sink { [weak self] _ in
            self?.refreshPerformanceInstrumentationSummary()
        }
        performanceInstrumentationErrorCancellable = performanceInstrumentationStore.$lastErrorText.sink { [weak self] _ in
            self?.refreshPerformanceInstrumentationSummary()
        }
        codexSourceHealthCancellable = codexSourceHealthStore.$state.sink { [weak self] state in
            self?.codexSourceHealthState = state
        }
    }

    convenience init(
        store: UsageHistoryStore,
        defaults: UserDefaults = .standard,
        byteFormatter: ByteCountFormatter = ByteCountFormatter(),
        tokenBackfillImporter: CodexSessionTokenBackfillImporting = CodexSessionTokenBackfillImporter(),
        tokenPayloadAuditStore: CodexTokenPayloadAuditStore = .applicationSupportStore(),
        tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore = .applicationSupportStore(),
        performanceInstrumentationStore: AppPerformanceInstrumentationStore = .shared,
        profileTokenUsageStore: CodexProfileTokenUsageStore = .applicationSupportStore(),
        profileTokenClient: CodexProfileTokenUsageFetching = UnavailableCodexProfileTokenUsageClient(),
        codexSourceHealthStore: CodexSourceHealthStore = .shared,
        codexSourceHealthReader: CodexSourceHealthReading = CodexSourceHealthReader(),
        remoteControlHealthReader: CodexRemoteControlHealthReading = CodexRemoteControlHealthReader(),
        localSourceCoverageProbe: CodexLocalSourceCoverageProbing = CodexLocalSourceCoverageProbe(),
        autoRefreshProfileTokens: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        let testSafeWorker = UsageHistoryDatabaseWorker(
            store: store,
            turnPerformanceImporter: { store, _, _, _ in
                (try? store.codexTurnPerformanceCaptureState()) ?? CodexTurnPerformanceCaptureState()
            },
            sessionTaskTimingImporter: { store, _, _, _ in
                (try? store.codexSessionTaskTimingCaptureState()) ?? CodexSessionTaskTimingCaptureState()
            },
            threadCatalogImporter: { store, _, _, _ in
                (try? store.codexThreadCatalogCaptureState()) ?? CodexThreadCatalogCaptureState()
            },
            modelCapabilitiesImporter: { store, _, _, _ in
                (try? store.codexModelCapabilitiesCaptureState()) ?? CodexModelCapabilitiesCaptureState()
            }
        )
        self.init(
            database: testSafeWorker,
            defaults: defaults,
            byteFormatter: byteFormatter,
            tokenBackfillImporter: tokenBackfillImporter,
            tokenPayloadAuditStore: tokenPayloadAuditStore,
            tokenPayloadAuditDiagnosticsStore: tokenPayloadAuditDiagnosticsStore,
            performanceInstrumentationStore: performanceInstrumentationStore,
            profileTokenUsageStore: profileTokenUsageStore,
            profileTokenClient: profileTokenClient,
            codexSourceHealthStore: codexSourceHealthStore,
            codexSourceHealthReader: codexSourceHealthReader,
            remoteControlHealthReader: remoteControlHealthReader,
            localSourceCoverageProbe: localSourceCoverageProbe,
            autoRefreshProfileTokens: autoRefreshProfileTokens,
            now: now
        )
    }

    var databaseURL: URL? {
        databaseInfo?.databaseURL
    }

    var canRevealDatabase: Bool {
        databaseURL != nil
    }

    var canExportTokenPayloadAudit: Bool {
        tokenPayloadAudit != nil
    }

    var canExportPerformanceDiagnostics: Bool {
        performanceInstrumentationSummary.eventCount > 0
    }

    var canExportCodexSourceHealth: Bool {
        codexSourceHealthState.snapshot != nil
    }

    var tokenPayloadAuditCapturedAtText: String {
        guard let capturedAt = tokenPayloadAudit?.capturedAt else {
            return "No capture yet"
        }

        return Self.auditDateFormatter.string(from: capturedAt)
    }

    var tokenPayloadAuditDiagnosticsUpdatedAtText: String {
        Self.auditDateFormatter.string(from: tokenPayloadAuditDiagnostics.lastUpdatedAt)
    }

    var tokenPayloadAuditDiagnosticsConnectionText: String {
        tokenPayloadAuditDiagnostics.connectionStatusText
    }

    var tokenPayloadAuditDiagnosticsLastMethodText: String {
        tokenPayloadAuditDiagnostics.lastInboundMethod ?? "--"
    }

    var tokenPayloadAuditDiagnosticsLastAuditStatusText: String {
        tokenPayloadAuditDiagnostics.lastAuditStatusText
    }

    var tokenPayloadAuditDiagnosticsLastErrorText: String {
        tokenPayloadAuditDiagnostics.lastErrorText
    }

    var remoteControlNotificationCountText: String {
        "\(tokenPayloadAuditDiagnostics.remoteControlDiagnostics.notificationCount)"
    }

    var remoteControlStatusText: String {
        tokenPayloadAuditDiagnostics.remoteControlDiagnostics.lastStatus?.displayText ?? "No notification yet"
    }

    var remoteControlLastStatusUpdateText: String {
        guard let lastStatusUpdatedAt = tokenPayloadAuditDiagnostics.remoteControlDiagnostics.lastStatusUpdatedAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: lastStatusUpdatedAt)
    }

    var remoteControlEnrollmentHealthText: String {
        tokenPayloadAuditDiagnostics.remoteControlDiagnostics.enrollmentStatus.displayText
    }

    var remoteControlEnrollmentLastCheckedText: String {
        guard let enrollmentLastCheckedAt = tokenPayloadAuditDiagnostics.remoteControlDiagnostics.enrollmentLastCheckedAt else {
            return "Not checked yet"
        }

        return Self.auditDateFormatter.string(from: enrollmentLastCheckedAt)
    }

    var remoteControlEnrollmentCountText: String {
        tokenPayloadAuditDiagnostics.remoteControlDiagnostics.enrollmentCount.map(String.init) ?? "--"
    }

    var remoteControlEnrollmentLatestUpdateText: String {
        guard let enrollmentLatestUpdatedAt = tokenPayloadAuditDiagnostics.remoteControlDiagnostics.enrollmentLatestUpdatedAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: enrollmentLatestUpdatedAt)
    }

    var remoteControlLastErrorText: String {
        tokenPayloadAuditDiagnostics.remoteControlDiagnostics.lastErrorText
    }

    var notificationAuditTotalText: String {
        "\(tokenPayloadAuditDiagnostics.notificationAudit.totalCount)"
    }

    var notificationAuditSupportedText: String {
        "\(tokenPayloadAuditDiagnostics.notificationAudit.supportedCount)"
    }

    var notificationAuditUnsupportedText: String {
        "\(tokenPayloadAuditDiagnostics.notificationAudit.unsupportedCount)"
    }

    var notificationAuditRejectedText: String {
        "\(tokenPayloadAuditDiagnostics.notificationAudit.rejectedUnsafeFieldCount)"
    }

    var notificationAuditUnsupportedShapeText: String {
        "\(tokenPayloadAuditDiagnostics.notificationAudit.unsupportedShapeCount)"
    }

    var notificationAuditLastMethodText: String {
        tokenPayloadAuditDiagnostics.notificationAuditLastMethodText
    }

    var notificationAuditLastUpdatedText: String {
        guard let lastAuditedAt = tokenPayloadAuditDiagnostics.notificationAudit.lastAuditedAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: lastAuditedAt)
    }

    var notificationAuditRows: [CodexAppServerNotificationAuditMethodSummary] {
        Array(tokenPayloadAuditDiagnostics.notificationAudit.methods.prefix(8))
    }

    var localSourceCoverageRows: [CodexLocalSourceCoverageRow] {
        localSourceCoverageSnapshot.rows
    }

    var localSourceCoverageHeadlineText: String {
        localSourceCoverageSnapshot.headlineText
    }

    var localSourceCoverageUpdatedText: String {
        guard !localSourceCoverageSnapshot.rows.isEmpty else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: localSourceCoverageSnapshot.generatedAt)
    }

    func localSourceCoverageDateText(_ date: Date?) -> String {
        guard let date else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: date)
    }

    var localTokenCaptureLastCheckedText: String {
        guard let lastCheckedAt = localTokenCaptureState.lastCheckedAt else {
            return "Not checked yet"
        }

        return Self.auditDateFormatter.string(from: lastCheckedAt)
    }

    var localTokenCaptureLastEventText: String {
        guard let lastImportedEventAt = localTokenCaptureState.lastImportedEventAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: lastImportedEventAt)
    }

    var localTokenCaptureResultText: String {
        let result = localTokenCaptureState.result
        return "\(result.insertedCount) imported, \(result.duplicateCount) duplicate, \(result.repairedModelCount + result.repairedContextCount + result.repairedDimensionCount) repaired"
    }

    var localTokenCaptureLastErrorText: String {
        localTokenCaptureState.lastErrorText ?? "None"
    }

    var turnPerformanceCaptureLastCheckedText: String {
        guard let lastCheckedAt = turnPerformanceCaptureState.lastCheckedAt else {
            return "Not checked yet"
        }

        return Self.auditDateFormatter.string(from: lastCheckedAt)
    }

    var turnPerformanceCaptureLastEventText: String {
        guard let lastImportedEventAt = turnPerformanceCaptureState.lastImportedEventAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: lastImportedEventAt)
    }

    var turnPerformanceCaptureResultText: String {
        "\(turnPerformanceCaptureState.insertedCount) imported, \(turnPerformanceCaptureState.duplicateCount) duplicate"
    }

    var turnPerformanceCaptureLastErrorText: String {
        turnPerformanceCaptureState.lastErrorText ?? "None"
    }

    var turnPerformanceRuntimeDimensionRowCountText: String {
        "\(turnPerformanceRuntimeDimensionSummary.rowCount)"
    }

    var turnPerformanceRuntimeDimensionKeyCountText: String {
        "\(turnPerformanceRuntimeDimensionSummary.distinctKeyCount)"
    }

    var turnPerformanceRuntimeDimensionLatestSeenText: String {
        guard let latestSeenAt = turnPerformanceRuntimeDimensionSummary.latestSeenAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: latestSeenAt)
    }

    var sessionTaskTimingCaptureLastCheckedText: String {
        guard let lastCheckedAt = sessionTaskTimingCaptureState.lastCheckedAt else {
            return "Not checked yet"
        }

        return Self.auditDateFormatter.string(from: lastCheckedAt)
    }

    var sessionTaskTimingCaptureLastEventText: String {
        guard let lastImportedEventAt = sessionTaskTimingCaptureState.lastImportedEventAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: lastImportedEventAt)
    }

    var sessionTaskTimingCaptureFilesText: String {
        "\(sessionTaskTimingCaptureState.filesScanned) scanned, \(sessionTaskTimingCaptureState.filesSkippedUnchanged) skipped"
    }

    var sessionTaskTimingCaptureResultText: String {
        "\(sessionTaskTimingCaptureState.insertedCount) imported, \(sessionTaskTimingCaptureState.updatedCount) updated, \(sessionTaskTimingCaptureState.duplicateCount) duplicate, \(sessionTaskTimingCaptureState.failedLinesSkipped) failed lines"
    }

    var sessionTaskTimingCaptureLastErrorText: String {
        sessionTaskTimingCaptureState.lastErrorText ?? "None"
    }

    var threadCatalogCaptureLastCheckedText: String {
        guard let lastCheckedAt = threadCatalogCaptureState.lastCheckedAt else {
            return "Not checked yet"
        }

        return Self.auditDateFormatter.string(from: lastCheckedAt)
    }

    var threadCatalogCaptureLatestThreadText: String {
        guard let lastImportedThreadUpdatedAt = threadCatalogCaptureState.lastImportedThreadUpdatedAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: lastImportedThreadUpdatedAt)
    }

    var threadCatalogCaptureThreadsText: String {
        "\(threadCatalogCaptureState.threadsInsertedCount) imported, \(threadCatalogCaptureState.threadsUpdatedCount) updated"
    }

    var threadCatalogCaptureRelationshipsText: String {
        "\(threadCatalogCaptureState.spawnEdgesInsertedCount + threadCatalogCaptureState.dynamicToolsInsertedCount) imported, \(threadCatalogCaptureState.spawnEdgesUpdatedCount + threadCatalogCaptureState.dynamicToolsUpdatedCount) updated, \(threadCatalogCaptureState.staleRowsDeletedCount) stale"
    }

    var threadCatalogCaptureLastErrorText: String {
        threadCatalogCaptureState.lastErrorText ?? "None"
    }

    var modelCapabilitiesCaptureLastCheckedText: String {
        guard let lastCheckedAt = modelCapabilitiesCaptureState.lastCheckedAt else {
            return "Not checked yet"
        }

        return Self.auditDateFormatter.string(from: lastCheckedAt)
    }

    var modelCapabilitiesCaptureFetchedText: String {
        guard let cacheFetchedAt = modelCapabilitiesCaptureState.cacheFetchedAt else {
            return "--"
        }

        return Self.auditDateFormatter.string(from: cacheFetchedAt)
    }

    var modelCapabilitiesCaptureModelsText: String {
        "\(modelCapabilitiesCaptureState.modelsInsertedCount) imported, \(modelCapabilitiesCaptureState.modelsUpdatedCount) updated"
    }

    var modelCapabilitiesCaptureDetailsText: String {
        "\(modelCapabilitiesCaptureState.childRowsInsertedCount) details imported, \(modelCapabilitiesCaptureState.staleRowsDeletedCount) stale"
    }

    var modelCapabilitiesCaptureClientVersionText: String {
        modelCapabilitiesCaptureState.clientVersion ?? "--"
    }

    var modelCapabilitiesCaptureLastErrorText: String {
        modelCapabilitiesCaptureState.lastErrorText ?? "None"
    }

    var performanceDiagnosticsEventCountText: String {
        "\(performanceInstrumentationSummary.eventCount)"
    }

    var performanceDiagnosticsLastEventText: String {
        guard let event = performanceInstrumentationSummary.lastEvent else {
            return "No events yet"
        }

        return "\(event.displayTitle) · \(Self.durationText(milliseconds: event.durationMilliseconds))"
    }

    var performanceDiagnosticsSlowestEventText: String {
        guard let event = performanceInstrumentationSummary.slowestEvent else {
            return "--"
        }

        return "\(event.displayTitle) · \(Self.durationText(milliseconds: event.durationMilliseconds))"
    }

    var performanceDiagnosticsLastErrorText: String {
        performanceInstrumentationSummary.lastErrorText ?? "None"
    }

    var profileTokenStatusText: String {
        profileTokenUsageState.status.displayText
    }

    var profileTokenLastSyncText: String {
        guard let lastSyncedAt = profileTokenUsageState.lastSyncedAt else {
            return "Not synced yet"
        }

        return Self.auditDateFormatter.string(from: lastSyncedAt)
    }

    var profileTokenLastErrorText: String {
        profileTokenUsageState.lastErrorText ?? "None"
    }

    var profileTokenPeakDailyText: String {
        tokenCountText(profileTokenUsageState.snapshot?.peakDailyTokens)
    }

    var profileTokenLifetimeText: String {
        tokenCountText(profileTokenUsageState.snapshot?.lifetimeTokens)
    }

    var profileTokenLongestTurnText: String {
        durationSecondsText(profileTokenUsageState.snapshot?.longestRunningTurnSeconds)
    }

    var profileTokenCurrentStreakText: String {
        dayCountText(profileTokenUsageState.snapshot?.currentStreakDays)
    }

    var profileTokenLongestStreakText: String {
        dayCountText(profileTokenUsageState.snapshot?.longestStreakDays)
    }

    var profileTokenBucketCountText: String {
        guard let snapshot = profileTokenUsageState.snapshot else {
            return "--"
        }

        return "\(snapshot.dailyBuckets.count)"
    }

    var profileTokenComparisonRows: [CodexProfileTokenComparisonRow] {
        profileTokenComparisonSummary?.rows ?? []
    }

    var codexSourceHealthStatusText: String {
        codexSourceHealthState.status.displayText
    }

    var codexSourceHealthLastCheckedText: String {
        guard let lastCheckedAt = codexSourceHealthState.lastCheckedAt else {
            return "Not checked yet"
        }

        return Self.auditDateFormatter.string(from: lastCheckedAt)
    }

    var codexSourceHealthActiveExecutableText: String {
        codexSourceHealthState.snapshot?.activeExecutablePath ?? "--"
    }

    var codexSourceHealthActiveVersionText: String {
        codexSourceHealthState.snapshot?.activeSignal?.displayVersionText ?? "--"
    }

    var codexSourceHealthAppBundledVersionText: String {
        codexSourceHealthState.snapshot?.appBundledSignal?.displayVersionText ?? "--"
    }

    var codexSourceHealthHomebrewVersionText: String {
        codexSourceHealthState.snapshot?.homebrewSignal?.displayVersionText ?? "--"
    }

    var codexSourceHealthModelsCacheText: String {
        guard let snapshot = codexSourceHealthState.snapshot else {
            return "--"
        }

        let version = snapshot.modelsCacheClientVersion ?? "unavailable"
        let count = snapshot.modelsCacheModelCount.map { "\($0) models" } ?? "unknown models"
        let fetched = snapshot.modelsCacheFetchedAt.map(Self.auditDateFormatter.string(from:)) ?? "unknown fetch time"
        return "\(version) · \(count) · \(fetched)"
    }

    var codexSourceHealthVersionMetadataText: String {
        guard let snapshot = codexSourceHealthState.snapshot else {
            return "--"
        }

        let checked = snapshot.versionMetadataLastCheckedAt.map(Self.auditDateFormatter.string(from:)) ?? "unknown check time"
        return "\(snapshot.versionMetadataStateText) · \(checked)"
    }

    var codexSourceHealthDismissedUpdateText: String {
        guard let snapshot = codexSourceHealthState.snapshot else {
            return "--"
        }

        guard let dismissedVersion = snapshot.versionMetadataDismissedVersion else {
            return "None"
        }

        if snapshot.versionMetadataDismissesLatestVersion {
            return "\(dismissedVersion) acknowledged"
        }

        return dismissedVersion
    }

    var codexSourceHealthExportSafeSnapshot: CodexSourceHealthSnapshot? {
        codexSourceHealthState.snapshot?.redactedForDiagnostics
    }

    var codexSourceHealthLastErrorText: String {
        codexSourceHealthState.lastErrorText
            ?? codexSourceHealthState.snapshot?.errorText
            ?? codexSourceHealthState.snapshot?.modelsCacheErrorText
            ?? codexSourceHealthState.snapshot?.versionMetadataErrorText
            ?? "None"
    }

    var codexSourceHealthWarnings: [String] {
        codexSourceHealthState.snapshot?.warnings ?? []
    }

    func tokenCountText(_ count: Int64?) -> String {
        guard let count else {
            return "--"
        }

        return Self.tokenCountFormatter.string(from: NSNumber(value: max(count, 0))) ?? "\(max(count, 0))"
    }

    func profileTokenDeltaText(for row: CodexProfileTokenComparisonRow) -> String {
        guard let delta = row.deltaTokens else {
            return "--"
        }

        let sign = delta > 0 ? "+" : ""
        let magnitude = Self.tokenCountFormatter.string(from: NSNumber(value: abs(delta))) ?? "\(abs(delta))"
        let ratioText: String
        if let ratio = row.localToProfileRatio {
            ratioText = String(format: " · %.0f%%", ratio * 100)
        } else {
            ratioText = ""
        }

        return "\(sign)\(delta < 0 ? "-" : "")\(magnitude)\(ratioText)"
    }

    func refreshDatabaseInfo() async {
        do {
            let info = try await database.databaseInfo()
            databaseInfo = info
            databasePathText = info.databaseURL.path
            databaseSizeText = byteFormatter.string(fromByteCount: info.totalByteSize)
            storageLimitText = "Storage: \(databaseSizeText) (\(byteFormatter.string(fromByteCount: info.hardMaximumByteSize)) maximum)"
            maintenanceStatusText = Self.maintenanceText(info.maintenanceState)
        } catch {
            databaseInfo = nil
            databasePathText = "Unavailable"
            databaseSizeText = "--"
            storageLimitText = "Storage unavailable"
            maintenanceStatusText = "Maintenance unavailable"
        }
    }

    func refreshProjectEntries() async {
        do {
            projectEntries = try await database.tokenProjectCatalogEntries()
        } catch {
            projectEntries = []
        }
    }

    func refreshLocalTokenCaptureState() async {
        localTokenCaptureState = await database.liveTokenCaptureState()
    }

    func refreshTurnPerformanceCaptureState() async {
        turnPerformanceCaptureState = await database.captureTurnPerformanceIfNeeded(
            at: Date(),
            calendar: .autoupdatingCurrent,
            force: false
        )
        turnPerformanceRuntimeDimensionSummary = await database.turnPerformanceRuntimeDimensionSummary()
    }

    func refreshSessionTaskTimingCaptureState() async {
        sessionTaskTimingCaptureState = await database.captureSessionTaskTimingIfNeeded(
            at: Date(),
            calendar: .autoupdatingCurrent,
            force: false
        )
    }

    func refreshThreadCatalogCaptureState() async {
        threadCatalogCaptureState = await database.captureThreadCatalogIfNeeded(
            at: Date(),
            calendar: .autoupdatingCurrent,
            force: false
        )
    }

    func refreshModelCapabilitiesCaptureState() async {
        modelCapabilitiesCaptureState = await database.captureModelCapabilitiesIfNeeded(
            at: Date(),
            calendar: .autoupdatingCurrent,
            force: false
        )
    }

    func refreshLocalSourceCoverageSnapshot() async {
        do {
            localSourceStoredMetrics = try await database.localSourceStoredMetrics()
        } catch {
            localSourceStoredMetrics = .empty
        }
        localSourceProbeSnapshot = await localSourceCoverageProbe.probeSnapshot(now: now())
        rebuildLocalSourceCoverageSnapshot()
    }

    private func rebuildLocalSourceCoverageSnapshot() {
        localSourceCoverageSnapshot = CodexLocalSourceCoverageSnapshot.make(
            localTokenCaptureState: localTokenCaptureState,
            turnPerformanceCaptureState: turnPerformanceCaptureState,
            turnPerformanceRuntimeDimensionSummary: turnPerformanceRuntimeDimensionSummary,
            sessionTaskTimingCaptureState: sessionTaskTimingCaptureState,
            threadCatalogCaptureState: threadCatalogCaptureState,
            modelCapabilitiesCaptureState: modelCapabilitiesCaptureState,
            tokenPayloadAuditDiagnostics: tokenPayloadAuditDiagnostics,
            storedMetrics: localSourceStoredMetrics,
            sourceProbes: localSourceProbeSnapshot,
            now: now()
        )
    }

    func refreshPerformanceInstrumentationSummary() {
        performanceInstrumentationSummary = performanceInstrumentationStore.summary()
    }

    func refreshProfileTokenComparison(autoRefreshIfStale: Bool = true) async {
        profileTokenUsageState = profileTokenUsageStore.state
        await refreshProfileTokenComparisonSummary()

        guard autoRefreshIfStale,
              autoRefreshProfileTokens,
              !isRefreshingProfileTokens,
              profileTokenUsageState.isStale(now: now(), staleAfter: CodexProfileTokenUsageStore.defaultCacheDuration)
        else {
            return
        }

        await refreshProfileTokens()
    }

    func refreshProfileTokens() async {
        guard !isRefreshingProfileTokens else {
            return
        }

        isRefreshingProfileTokens = true
        defer {
            isRefreshingProfileTokens = false
        }

        do {
            let snapshot = try await profileTokenClient.profileTokenUsageSnapshot()
            profileTokenUsageStore.recordSuccess(snapshot)
            profileTokenUsageState = profileTokenUsageStore.state
            statusMessage = "Codex account tokens refreshed."
            errorMessage = nil
        } catch CodexClientError.authTokenUnavailable {
            profileTokenUsageStore.recordFailure("Codex auth is unavailable.")
            profileTokenUsageState = profileTokenUsageStore.state
            statusMessage = nil
            errorMessage = "Codex account tokens could not be refreshed because Codex auth is unavailable."
        } catch {
            profileTokenUsageStore.recordFailure("Codex account tokens could not be refreshed.")
            profileTokenUsageState = profileTokenUsageStore.state
            statusMessage = nil
            errorMessage = "Codex account tokens could not be refreshed."
        }

        await refreshProfileTokenComparisonSummary()
    }

    func refreshCodexSourceHealth(showStatus: Bool = true) async {
        guard !isRefreshingCodexSourceHealth else {
            return
        }

        isRefreshingCodexSourceHealth = true
        let refreshedState = await codexSourceHealthStore.refresh(
            reader: codexSourceHealthReader,
            now: now()
        )
        codexSourceHealthState = refreshedState
        isRefreshingCodexSourceHealth = false

        if showStatus {
            if refreshedState.status == .failed {
                statusMessage = nil
                errorMessage = "Codex version and source health could not be refreshed."
            } else {
                statusMessage = "Codex version and source health refreshed."
                errorMessage = nil
            }
        }
    }

    func refreshCodexSourceHealthIfStale() async {
        guard codexSourceHealthState.isStale(
            now: now(),
            staleAfter: CodexSourceHealthStore.defaultCacheDuration
        ) else {
            return
        }

        await refreshCodexSourceHealth(showStatus: false)
    }

    private func refreshProfileTokenComparisonSummary() async {
        do {
            let currentDate = now()
            let localTotals = try await database.localTokenComparisonTotals(now: currentDate)
            profileTokenComparisonSummary = CodexProfileTokenComparisonSummary.make(
                profileSnapshot: profileTokenUsageState.snapshot,
                localTotals: localTotals,
                now: currentDate
            )
        } catch {
            profileTokenComparisonSummary = nil
        }
    }

    func refreshData() async {
        await refreshDatabaseInfo()
        await refreshLocalTokenCaptureState()
        await refreshProfileTokenComparison()
        await refreshCodexSourceHealthIfStale()
    }

    func refreshAdvancedData() async {
        await refreshProjectEntries()
        turnPerformanceCaptureState = await database.turnPerformanceCaptureState()
        turnPerformanceRuntimeDimensionSummary = await database.turnPerformanceRuntimeDimensionSummary()
        sessionTaskTimingCaptureState = await database.sessionTaskTimingCaptureState()
        threadCatalogCaptureState = await database.threadCatalogCaptureState()
        modelCapabilitiesCaptureState = await database.modelCapabilitiesCaptureState()
        if tokenPayloadAuditDiagnostics.remoteControlDiagnostics.enrollmentStatus == .neverChecked {
            await refreshRemoteControlHealth()
        }
        await refreshLocalSourceCoverageSnapshot()
        refreshPerformanceInstrumentationSummary()
    }

    func revealDatabaseInFinder() {
        guard let databaseURL else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
    }

    func exportBackup(to destinationURL: URL) async {
        do {
            try await database.exportBackup(to: destinationURL)
            statusMessage = "Backup exported."
            errorMessage = nil
            await refreshDatabaseInfo()
        } catch {
            statusMessage = nil
            errorMessage = "Backup could not be exported."
        }
    }

    func importBackup(from sourceURL: URL) async {
        do {
            try await database.importBackup(from: sourceURL)
            statusMessage = "Backup imported."
            errorMessage = nil
            await refreshData()
        } catch {
            statusMessage = nil
            errorMessage = "Backup could not be imported."
        }
    }

    func clearAnalyticsData() async {
        do {
            try await database.clearAnalyticsData()
            statusMessage = "Detailed analytics data cleared."
            errorMessage = nil
            tokenImportSummaryText = nil
            projectEntries = []
            await refreshData()
        } catch {
            statusMessage = nil
            errorMessage = "Analytics data could not be cleared. Your core history is unchanged."
        }
    }

    func optimizeStorage() async {
        guard !isOptimizingStorage else { return }
        isOptimizingStorage = true
        defer { isOptimizingStorage = false }
        do {
            let result = try await database.optimizeStorage(reason: .manual)
            statusMessage = result.performed
                ? "Storage optimized; \(byteFormatter.string(fromByteCount: result.reclaimedByteSize)) reclaimed."
                : "Storage is already compact."
            errorMessage = nil
            await refreshDatabaseInfo()
        } catch {
            statusMessage = nil
            errorMessage = "Storage optimization did not run. Your data is unchanged."
            await refreshDatabaseInfo()
        }
    }

    func renameProject(_ entry: TokenProjectCatalogEntry, displayName: String) async {
        do {
            try await database.updateTokenProjectDisplayName(
                projectPath: entry.projectPath,
                displayName: displayName
            )
            statusMessage = "Project name updated."
            errorMessage = nil
            await refreshProjectEntries()
        } catch UsageHistoryStoreError.invalidProjectDisplayName {
            statusMessage = nil
            errorMessage = UsageHistoryStoreError.invalidProjectDisplayName.localizedDescription
        } catch {
            statusMessage = nil
            errorMessage = "Project name could not be updated."
        }
    }

    func resetProjectName(_ entry: TokenProjectCatalogEntry) async {
        do {
            try await database.updateTokenProjectDisplayName(
                projectPath: entry.projectPath,
                displayName: nil
            )
            statusMessage = "Project name reset."
            errorMessage = nil
            await refreshProjectEntries()
        } catch {
            statusMessage = nil
            errorMessage = "Project name could not be reset."
        }
    }

    func exportTokenPayloadAudit(to destinationURL: URL) {
        do {
            guard let data = try tokenPayloadAuditStore.exportData() else {
                statusMessage = nil
                errorMessage = "No live token payload audit has been captured yet."
                return
            }

            try data.write(to: destinationURL, options: .atomic)
            statusMessage = "Payload audit exported."
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = "Payload audit could not be exported."
        }
    }

    func clearTokenPayloadAudit() {
        tokenPayloadAuditStore.clear()
        statusMessage = "Payload audit cleared."
        errorMessage = nil
    }

    func clearTokenPayloadAuditDiagnostics() {
        tokenPayloadAuditDiagnosticsStore.clear()
        statusMessage = "Capture diagnostics cleared."
        errorMessage = nil
        tokenPayloadAuditDiagnostics = tokenPayloadAuditDiagnosticsStore.diagnostics
        rebuildLocalSourceCoverageSnapshot()
    }

    func refreshRemoteControlHealth() async {
        guard !isRefreshingRemoteControlHealth else {
            return
        }

        isRefreshingRemoteControlHealth = true
        let diagnostics = await tokenPayloadAuditDiagnosticsStore.refreshRemoteControlHealth(
            reader: remoteControlHealthReader,
            now: now()
        )
        tokenPayloadAuditDiagnostics = diagnostics
        isRefreshingRemoteControlHealth = false

        if diagnostics.remoteControlDiagnostics.enrollmentStatus == .failed {
            statusMessage = nil
            errorMessage = "Remote-control health could not be refreshed."
        } else {
            statusMessage = "Remote-control health refreshed."
            errorMessage = nil
        }
        rebuildLocalSourceCoverageSnapshot()
    }

    func clearRemoteControlDiagnostics() {
        tokenPayloadAuditDiagnosticsStore.clearRemoteControlDiagnostics()
        tokenPayloadAuditDiagnostics = tokenPayloadAuditDiagnosticsStore.diagnostics
        statusMessage = "Remote-control diagnostics cleared."
        errorMessage = nil
        rebuildLocalSourceCoverageSnapshot()
    }

    func clearNotificationAudit() {
        tokenPayloadAuditDiagnosticsStore.clearNotificationAudit()
        tokenPayloadAuditDiagnostics = tokenPayloadAuditDiagnosticsStore.diagnostics
        statusMessage = "Notification audit cleared."
        errorMessage = nil
        rebuildLocalSourceCoverageSnapshot()
    }

    func exportPerformanceDiagnostics(to destinationURL: URL) {
        do {
            guard let data = try performanceInstrumentationStore.exportData() else {
                statusMessage = nil
                errorMessage = "No performance diagnostics have been captured yet."
                return
            }

            try data.write(to: destinationURL, options: .atomic)
            statusMessage = "Performance diagnostics exported."
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = "Performance diagnostics could not be exported."
        }
    }

    func exportCodexSourceHealth(to destinationURL: URL) {
        do {
            guard let data = try codexSourceHealthStore.exportRedactedData() else {
                statusMessage = nil
                errorMessage = "No Codex version and source health has been captured yet."
                return
            }

            try data.write(to: destinationURL, options: .atomic)
            statusMessage = "Codex version and source health exported."
            errorMessage = nil
        } catch {
            statusMessage = nil
            errorMessage = "Codex version and source health could not be exported."
        }
    }

    func clearPerformanceDiagnostics() {
        performanceInstrumentationStore.clear()
        refreshPerformanceInstrumentationSummary()
        statusMessage = "Performance diagnostics cleared."
        errorMessage = nil
    }

    func importTokenHistoryFromCodexSessions() {
        importRecentTokenHistoryFromCodexSessions()
    }

    func importRecentTokenHistoryFromCodexSessions(now: Date = Date()) {
        importTokenHistoryFromCodexSessions(request: .recent(now: now, days: 7))
    }

    func buildHistoricalArchive(
        at destinationURL: URL,
        replaceExisting: Bool
    ) async -> HistoricalTokenArchiveDescriptor? {
        guard !isImportingTokenHistory else { return nil }
        isImportingTokenHistory = true
        statusMessage = nil
        errorMessage = nil
        tokenImportSummaryText = nil
        defer { isImportingTokenHistory = false }
        do {
            let result = try await database.buildHistoricalTokenArchive(
                importer: tokenBackfillImporter,
                destinationURL: destinationURL,
                replaceExisting: replaceExisting
            )
            tokenImportSummaryText = result.summary.statusMessage
            statusMessage = "Historical archive built."
            return result.descriptor
        } catch {
            errorMessage = "Historical archive could not be built. Existing data is unchanged."
            return nil
        }
    }

    private func importTokenHistoryFromCodexSessions(request: CodexSessionTokenBackfillRequest) {
        guard !isImportingTokenHistory else {
            return
        }

        isImportingTokenHistory = true
        statusMessage = nil
        errorMessage = nil
        tokenImportSummaryText = nil

        let database = database
        let tokenBackfillImporter = tokenBackfillImporter
        Task { [weak self] in
            let result: Result<CodexSessionTokenBackfillSummary, Error>
            do {
                result = .success(try await database.importTokenHistory(importer: tokenBackfillImporter, request: request))
            } catch {
                result = .failure(error)
            }
            self?.finishTokenHistoryImport(result)
        }
    }

    private func finishTokenHistoryImport(_ result: Result<CodexSessionTokenBackfillSummary, Error>) {
        isImportingTokenHistory = false

        switch result {
        case .success(let summary):
            tokenImportSummaryText = summary.statusMessage
            Task {
                await refreshData()
            }
        case .failure:
            tokenImportSummaryText = nil
            errorMessage = "Token history could not be imported."
        }
    }

    private static let auditDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static func maintenanceText(_ state: StorageMaintenanceState) -> String {
        switch state.stage {
        case .idle:
            if let lastSuccessAt = state.lastSuccessAt {
                return "Last maintained \(auditDateFormatter.string(from: lastSuccessAt))"
            }
            return "Maintenance scheduled automatically"
        case .rawToHourly, .hourlyToDaily, .pruning, .backfilling:
            return "Maintenance in progress"
        case .checkpointing, .optimizing, .validating, .replacing, .reopening:
            return "Optimizing storage"
        case .failed:
            return "Maintenance will retry automatically"
        }
    }

    private static let tokenCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static func durationText(milliseconds: Double) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.1fs", milliseconds / 1_000)
        }

        return "\(Int(milliseconds.rounded()))ms"
    }

    private func durationSecondsText(_ seconds: Int64?) -> String {
        guard let seconds else {
            return "--"
        }

        let clampedSeconds = max(seconds, 0)
        if clampedSeconds < 60 {
            return "\(clampedSeconds)s"
        }

        let minutes = clampedSeconds / 60
        let remainingSeconds = clampedSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(remainingSeconds)s"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }

    private func dayCountText(_ days: Int64?) -> String {
        guard let days else {
            return "--"
        }

        let clampedDays = max(days, 0)
        return clampedDays == 1 ? "1 day" : "\(clampedDays) days"
    }
}

#if DEBUG
enum StorageSettingsFixtureState: String, CaseIterable, Identifiable, Sendable {
    case lightweight
    case detailedAnalytics
    case migrating
    case overBudgetPaused
    case insufficientSpace
    case archiveOpen
    case empty
    case failure

    var id: String { rawValue }

    var presentation: StorageSettingsFixturePresentation {
        switch self {
        case .lightweight:
            StorageSettingsFixturePresentation(
                detailedAnalyticsEnabled: false,
                storageText: "Storage: 18 MB (250 MB maximum)",
                maintenanceText: "Last maintained today at 9:41 AM",
                detailText: "Lightweight keeps rate limits and token totals current with minimal local storage."
            )
        case .detailedAnalytics:
            StorageSettingsFixturePresentation(
                detailedAnalyticsEnabled: true,
                storageText: "Storage: 82 MB (500 MB maximum)",
                maintenanceText: "Last maintained today at 9:41 AM",
                detailText: "Detailed Analytics records model, project, session, and performance breakdowns."
            )
        case .migrating:
            StorageSettingsFixturePresentation(
                detailedAnalyticsEnabled: false,
                storageText: "Storage: 146 MB (250 MB maximum)",
                maintenanceText: "Migrating retained history · batch 12",
                detailText: "Collection continues in Lightweight while retained history is compacted."
            )
        case .overBudgetPaused:
            StorageSettingsFixturePresentation(
                detailedAnalyticsEnabled: true,
                storageText: "Storage: 503 MB (500 MB maximum)",
                maintenanceText: "Detailed collection paused · maintenance will retry automatically",
                detailText: "Rate limits and lightweight token totals remain current."
            )
        case .insufficientSpace:
            StorageSettingsFixturePresentation(
                detailedAnalyticsEnabled: false,
                storageText: "Storage: 228 MB (250 MB maximum)",
                maintenanceText: "Optimization needs 310 MB free; 190 MB is available",
                detailText: "Existing data is safe. Free space, then choose Optimize Now."
            )
        case .archiveOpen:
            StorageSettingsFixturePresentation(
                detailedAnalyticsEnabled: false,
                storageText: "Storage: 21 MB (250 MB maximum)",
                maintenanceText: "Last maintained yesterday at 6:18 PM",
                detailText: "Historical archives remain readable independently.",
                archiveName: "codex-token-history-2026",
                archiveSizeText: "640 MB"
            )
        case .empty:
            StorageSettingsFixturePresentation(
                detailedAnalyticsEnabled: false,
                storageText: "Storage: 1.2 MB (250 MB maximum)",
                maintenanceText: "Maintenance scheduled automatically",
                detailText: "No detailed analytics have been collected."
            )
        case .failure:
            StorageSettingsFixturePresentation(
                detailedAnalyticsEnabled: false,
                storageText: "Storage: 94 MB (250 MB maximum)",
                maintenanceText: "Maintenance could not finish · current data is safe",
                detailText: "Retry Optimize Now. Automatic collection remains lightweight."
            )
        }
    }
}

struct StorageSettingsFixturePresentation: Equatable, Sendable {
    let detailedAnalyticsEnabled: Bool
    let storageText: String
    let maintenanceText: String
    let detailText: String
    var archiveName: String?
    var archiveSizeText: String?

    init(
        detailedAnalyticsEnabled: Bool,
        storageText: String,
        maintenanceText: String,
        detailText: String,
        archiveName: String? = nil,
        archiveSizeText: String? = nil
    ) {
        self.detailedAnalyticsEnabled = detailedAnalyticsEnabled
        self.storageText = storageText
        self.maintenanceText = maintenanceText
        self.detailText = detailText
        self.archiveName = archiveName
        self.archiveSizeText = archiveSizeText
    }
}

/// Deterministic, non-shipping renderer for native storage-state inspection. It deliberately
/// models presentation only and never creates, grows, corrupts, or replaces a real database.
struct StorageSettingsFixtureView: View {
    let state: StorageSettingsFixtureState

    var body: some View {
        let presentation = state.presentation
        Form {
            Section("Collection") {
                Toggle("Detailed Analytics", isOn: .constant(presentation.detailedAnalyticsEnabled))
                    .accessibilityLabel("Detailed Analytics")
                Text(presentation.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Storage") {
                Text(presentation.storageText)
                    .monospacedDigit()
                    .accessibilityLabel("Operational storage usage")
                    .accessibilityValue(presentation.storageText)
                Text(presentation.maintenanceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Storage maintenance status")
                    .accessibilityValue(presentation.maintenanceText)
                HStack {
                    Button("Optimize Now") {}
                    Button("Export Backup...") {}
                    Spacer()
                    Button("Clear Analytics Data...", role: .destructive) {}
                }
            }
            Section("Retention") {
                Text("Raw details: 72 hours · Hourly: 90 days · Daily: one year")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let archiveName = presentation.archiveName,
               let archiveSizeText = presentation.archiveSizeText
            {
                Section("Historical Archive") {
                    LabeledContent("Open archive", value: archiveName)
                    LabeledContent("Archive size", value: archiveSizeText)
                    HStack {
                        Button("Export Archive...") {}
                        Button("Close Archive") {}
                        Spacer()
                        Button("Delete Archive...", role: .destructive) {}
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 760, height: 700)
    }
}
#endif

struct DataManagementSettingsView: View {
    @StateObject private var viewModel: DataManagementSettingsViewModel
    @ObservedObject private var updateMonitor: AppUpdateMonitor
    @ObservedObject private var collectionModeController: UsageCollectionModeController
    @ObservedObject private var archiveController: HistoricalTokenArchiveController
    @AppStorage(SettingsTabSelectionStore.key) private var selectedTabRaw = SettingsTabSelection.data.rawValue
    @State private var isConfirmingClear = false
    @State private var pendingImportURL: URL?
    @State private var projectBeingRenamed: TokenProjectCatalogEntry?
    @State private var projectNameDraft = ""
    @State private var isAdvancedExpanded = false
    @State private var isConfirmingArchiveDelete = false

    init(
        database: UsageHistoryDatabaseWorking,
        updateMonitor: AppUpdateMonitor = AppUpdateMonitor(),
        tokenPayloadAuditStore: CodexTokenPayloadAuditStore = .applicationSupportStore(),
        tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore = .applicationSupportStore(),
        performanceInstrumentationStore: AppPerformanceInstrumentationStore = .shared,
        profileTokenUsageStore: CodexProfileTokenUsageStore = .applicationSupportStore(),
        profileTokenClient: CodexProfileTokenUsageFetching = UnavailableCodexProfileTokenUsageClient(),
        codexSourceHealthStore: CodexSourceHealthStore = .shared,
        codexSourceHealthReader: CodexSourceHealthReading = CodexSourceHealthReader(),
        remoteControlHealthReader: CodexRemoteControlHealthReading = CodexRemoteControlHealthReader(),
        localSourceCoverageProbe: CodexLocalSourceCoverageProbing = CodexLocalSourceCoverageProbe(),
        collectionModeController: UsageCollectionModeController = UsageCollectionModeController(),
        archiveController: HistoricalTokenArchiveController = .shared,
        autoRefreshProfileTokens: Bool = false
    ) {
        _viewModel = StateObject(
            wrappedValue: DataManagementSettingsViewModel(
                database: database,
                tokenPayloadAuditStore: tokenPayloadAuditStore,
                tokenPayloadAuditDiagnosticsStore: tokenPayloadAuditDiagnosticsStore,
                performanceInstrumentationStore: performanceInstrumentationStore,
                profileTokenUsageStore: profileTokenUsageStore,
                profileTokenClient: profileTokenClient,
                codexSourceHealthStore: codexSourceHealthStore,
                codexSourceHealthReader: codexSourceHealthReader,
                remoteControlHealthReader: remoteControlHealthReader,
                localSourceCoverageProbe: localSourceCoverageProbe,
                autoRefreshProfileTokens: autoRefreshProfileTokens
            )
        )
        self.updateMonitor = updateMonitor
        self.collectionModeController = collectionModeController
        self.archiveController = archiveController
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
            Form {
                collectionModeSection
                databaseSection
                retentionSection
                tokenHistorySection
                profileTokenSection
                DisclosureGroup("Advanced", isExpanded: advancedExpandedBinding) {
                    advancedDatabaseDetails
                    codexSourceHealthSection
                    localSourceCoverageSection
                    remoteControlHealthSection
                    liveTokenPayloadSection
                    projectsSection
                }
                feedbackSection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Data", systemImage: "externaldrive")
            }
            .tag(SettingsTabSelection.data)

            InstallUpdateSettingsView(
                viewModel: InstallUpdateSettingsViewModel(updateMonitor: updateMonitor)
            )
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(SettingsTabSelection.updates)
        }
        .frame(width: 760, height: 700)
        .scenePadding()
        .task {
            await viewModel.refreshData()
        }
        .sheet(item: $projectBeingRenamed) { entry in
            projectRenameSheet(for: entry)
        }
        .alert("Clear Analytics Data?", isPresented: $isConfirmingClear) {
            Button("Clear Analytics Data", role: .destructive) {
                Task {
                    await viewModel.clearAnalyticsData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes detailed dimensions and performance metadata. Rate-limit History, lightweight token totals, preferences, status state, backups, and archives are preserved.")
        }
        .alert(
            "Import Backup?",
            isPresented: Binding(
                get: { pendingImportURL != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingImportURL = nil
                    }
                }
            )
        ) {
            Button("Import", role: .destructive) {
                if let pendingImportURL {
                    Task {
                        await viewModel.importBackup(from: pendingImportURL)
                    }
                }
                pendingImportURL = nil
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("The backup is normalized, retained, budgeted, and validated in an offline candidate. Current history remains unchanged unless every check passes.")
        }
        .alert("Delete Historical Archive?", isPresented: $isConfirmingArchiveDelete) {
            Button("Delete Archive", role: .destructive) {
                try? archiveController.deleteOpenedArchive()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the currently validated archive file will be deleted. Operational history is not affected.")
        }
    }

    private var selectedTabBinding: Binding<SettingsTabSelection> {
        Binding(
            get: {
                SettingsTabSelectionStore.selectedTab(from: selectedTabRaw)
            },
            set: { selection in
                selectedTabRaw = selection.rawValue
            }
        )
    }

    private var advancedExpandedBinding: Binding<Bool> {
        Binding(
            get: { isAdvancedExpanded },
            set: { expanded in
                isAdvancedExpanded = expanded
                if expanded {
                    Task { await viewModel.refreshAdvancedData() }
                }
            }
        )
    }

    private var databaseSection: some View {
        Section("Storage") {
            Text(viewModel.storageLimitText)
                .monospacedDigit()
                .accessibilityLabel("Operational storage usage")
                .accessibilityValue(viewModel.storageLimitText)

            Text(viewModel.maintenanceStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Storage maintenance status")
                .accessibilityValue(viewModel.maintenanceStatusText)

            HStack {
                Button(viewModel.isOptimizingStorage ? "Optimizing..." : "Optimize Now") {
                    Task { await viewModel.optimizeStorage() }
                }
                .disabled(viewModel.isOptimizingStorage)

                Button("Export Backup...") {
                    exportBackup()
                }

                Button("Import Backup...") {
                    chooseBackupToImport()
                }

                Spacer()

                Button("Clear Analytics Data...", role: .destructive) {
                    isConfirmingClear = true
                }
            }
        }
    }

    private var advancedDatabaseDetails: some View {
        Group {
            LabeledContent("Database location") {
                Text(viewModel.databasePathText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Button("Reveal Database in Finder") {
                viewModel.revealDatabaseInFinder()
            }
            .disabled(!viewModel.canRevealDatabase)
        }
    }

    private var collectionModeSection: some View {
        Section("Collection") {
            Toggle("Detailed Analytics", isOn: detailedAnalyticsBinding)
                .accessibilityLabel("Detailed Analytics")
                .accessibilityHelp("Collect model, project, session, and performance breakdowns locally")

            Text(collectionModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detailedAnalyticsBinding: Binding<Bool> {
        Binding(
            get: { collectionModeController.mode == .detailedAnalytics },
            set: { isEnabled in
                collectionModeController.setMode(isEnabled ? .detailedAnalytics : .lightweight)
            }
        )
    }

    private var collectionModeDescription: String {
        switch collectionModeController.mode {
        case .lightweight:
            "Lightweight keeps rate limits and token totals current with minimal local storage."
        case .detailedAnalytics:
            "Detailed Analytics also records model, project, session, and performance breakdowns."
        }
    }

    private var retentionSection: some View {
        Section("Retention") {
            Text("Rate-limit details are kept for 7 days. Detailed token and performance samples are kept for 72 hours, hourly summaries for 90 days, and daily summaries for one year.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tokenHistorySection: some View {
        Section("Token History") {
            HStack {
                Button(viewModel.isImportingTokenHistory ? "Importing..." : "Import Last 7 Days...") {
                    viewModel.importRecentTokenHistoryFromCodexSessions()
                }
                .disabled(viewModel.isImportingTokenHistory || collectionModeController.mode != .detailedAnalytics)

                Button("Build Historical Archive...") {
                    buildHistoricalArchive()
                }
                .disabled(viewModel.isImportingTokenHistory)

                Button("Open Archive...") {
                    openHistoricalArchive()
                }
            }

            Text("The 7-day import adds recent detail to the operational store and requires Detailed Analytics. Historical archives are separate, read-only files and do not count toward the operational limit.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let tokenImportSummaryText = viewModel.tokenImportSummaryText {
                Text(tokenImportSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let archive = archiveController.openedArchive {
                Divider()
                LabeledContent("Open archive") {
                    Text(archive.displayName)
                }
                LabeledContent("Archive size") {
                    Text(ByteCountFormatter.string(fromByteCount: archive.byteSize, countStyle: .file))
                        .monospacedDigit()
                }
                Text(archive.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack {
                    Button("Export Archive...") { exportHistoricalArchive() }
                    Button("Reveal Archive") { archiveController.reveal() }
                    Button("Close Archive") { archiveController.close() }
                    Spacer()
                    Button("Delete Archive...", role: .destructive) {
                        isConfirmingArchiveDelete = true
                    }
                }
            }
        }
    }

    private var profileTokenSection: some View {
        Section("Codex Account Tokens") {
            HStack {
                Button(viewModel.isRefreshingProfileTokens ? "Refreshing..." : "Refresh Account Tokens") {
                    Task {
                        await viewModel.refreshProfileTokens()
                    }
                }
                .disabled(viewModel.isRefreshingProfileTokens)

                Spacer()

                Text(viewModel.profileTokenStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Codex account tokens are server counts. Local captured tokens are component totals from this Mac: input + cached input + output + reasoning.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Last sync")
                    Text(viewModel.profileTokenLastSyncText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Server lifetime")
                    Text(viewModel.profileTokenLifetimeText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Peak day")
                    Text(viewModel.profileTokenPeakDailyText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Daily buckets")
                    Text(viewModel.profileTokenBucketCountText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Longest turn")
                    Text(viewModel.profileTokenLongestTurnText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Current streak")
                    Text(viewModel.profileTokenCurrentStreakText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Longest streak")
                    Text(viewModel.profileTokenLongestStreakText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Last error")
                    Text(viewModel.profileTokenLastErrorText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)

            if viewModel.profileTokenComparisonRows.isEmpty {
                Text("No comparison is available yet. Refresh Codex account tokens to compare server counts with local captured tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Period")
                            .fontWeight(.semibold)
                        Text("Server account")
                            .fontWeight(.semibold)
                        Text("Local captured")
                            .fontWeight(.semibold)
                        Text("Delta")
                            .fontWeight(.semibold)
                    }

                    ForEach(viewModel.profileTokenComparisonRows) { row in
                        GridRow {
                            Text(row.title)
                            Text(viewModel.tokenCountText(row.profileTokens))
                                .monospacedDigit()
                            Text(viewModel.tokenCountText(row.localCapturedTokens))
                                .monospacedDigit()
                            Text(viewModel.profileTokenDeltaText(for: row))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    private var codexSourceHealthSection: some View {
        Section("Codex Version & Source") {
            HStack {
                Button(viewModel.isRefreshingCodexSourceHealth ? "Refreshing..." : "Refresh") {
                    Task {
                        await viewModel.refreshCodexSourceHealth()
                    }
                }
                .disabled(viewModel.isRefreshingCodexSourceHealth)

                Button("Export Source Health...") {
                    exportCodexSourceHealth()
                }
                .disabled(!viewModel.canExportCodexSourceHealth)

                Spacer()

                Text(viewModel.codexSourceHealthStatusText)
                    .font(.caption)
                    .foregroundStyle(viewModel.codexSourceHealthState.status.shouldShowPopoverWarning ? .orange : .secondary)
            }

            Text("This local-only view reads Codex version signals: executable paths and versions, models-cache metadata, and update metadata freshness.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Last check")
                    Text(viewModel.codexSourceHealthLastCheckedText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Active")
                    Text(viewModel.codexSourceHealthActiveVersionText)
                        .monospaced()
                }
                GridRow {
                    Text("Active path")
                    Text(viewModel.codexSourceHealthActiveExecutableText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(viewModel.codexSourceHealthActiveExecutableText)
                }
                GridRow {
                    Text("App bundle")
                    Text(viewModel.codexSourceHealthAppBundledVersionText)
                        .monospaced()
                }
                GridRow {
                    Text("Homebrew")
                    Text(viewModel.codexSourceHealthHomebrewVersionText)
                        .monospaced()
                }
                GridRow {
                    Text("Models cache")
                    Text(viewModel.codexSourceHealthModelsCacheText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("version.json")
                    Text(viewModel.codexSourceHealthVersionMetadataText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("Dismissed update")
                    Text(viewModel.codexSourceHealthDismissedUpdateText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("Last error")
                    Text(viewModel.codexSourceHealthLastErrorText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)

            if !viewModel.codexSourceHealthWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.codexSourceHealthWarnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var localSourceCoverageSection: some View {
        Section("Local Source Coverage") {
            HStack {
                Text(viewModel.localSourceCoverageHeadlineText)
                    .font(.caption)
                    .foregroundStyle(viewModel.localSourceCoverageSnapshot.attentionCount == 0 ? Color.secondary : Color.orange)

                Spacer()

                Text(viewModel.localSourceCoverageUpdatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("Aggregate-only freshness across Codex logs, sessions, state metadata, model cache, and app-server diagnostics.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.localSourceCoverageRows.isEmpty {
                Text("No local source coverage snapshot has been built yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.localSourceCoverageRows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.title)
                                    .font(.caption)
                                    .fontWeight(.semibold)

                                Spacer()

                                Text(row.status.displayText)
                                    .font(.caption)
                                    .foregroundStyle(localSourceCoverageStatusColor(row.status))
                            }

                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                                GridRow {
                                    Text("Source")
                                    Text(row.sourceStateText)
                                }
                                GridRow {
                                    Text("Latest source")
                                    Text(viewModel.localSourceCoverageDateText(row.latestSourceEventAt))
                                        .monospacedDigit()
                                }
                                GridRow {
                                    Text("Stored")
                                    Text(row.storedStateText)
                                }
                                GridRow {
                                    Text("Latest stored")
                                    Text(viewModel.localSourceCoverageDateText(row.latestStoredEventAt))
                                        .monospacedDigit()
                                }
                                GridRow {
                                    Text("Detail")
                                    Text(row.detailText)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                if let lastErrorSummary = row.lastErrorSummary {
                                    GridRow {
                                        Text("Last error")
                                        Text(lastErrorSummary)
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var remoteControlHealthSection: some View {
        Section("Remote Control & App Server") {
            HStack {
                Button(viewModel.isRefreshingRemoteControlHealth ? "Refreshing..." : "Refresh Remote Control Health") {
                    Task {
                        await viewModel.refreshRemoteControlHealth()
                    }
                }
                .disabled(viewModel.isRefreshingRemoteControlHealth)

                Button("Clear Remote Control Diagnostics") {
                    viewModel.clearRemoteControlDiagnostics()
                }

                Spacer()

                Text(viewModel.remoteControlEnrollmentHealthText)
                    .font(.caption)
                    .foregroundStyle(
                        viewModel.tokenPayloadAuditDiagnostics.remoteControlPopoverWarningText == nil
                            ? Color.secondary
                            : Color.orange
                    )
            }

            Text("This stores only app-server status, safe remote-control status enums, and aggregate enrollment counts from local Codex metadata.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Connection")
                    Text(viewModel.tokenPayloadAuditDiagnosticsConnectionText)
                }
                GridRow {
                    Text("Last method")
                    Text(viewModel.tokenPayloadAuditDiagnosticsLastMethodText)
                        .monospaced()
                }
                GridRow {
                    Text("Remote notifications")
                    Text(viewModel.remoteControlNotificationCountText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Remote status")
                    Text(viewModel.remoteControlStatusText)
                }
                GridRow {
                    Text("Status updated")
                    Text(viewModel.remoteControlLastStatusUpdateText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Enrollment count")
                    Text(viewModel.remoteControlEnrollmentCountText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Enrollment update")
                    Text(viewModel.remoteControlEnrollmentLatestUpdateText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Enrollment check")
                    Text(viewModel.remoteControlEnrollmentLastCheckedText)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Last error")
                    Text(viewModel.remoteControlLastErrorText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Notification audit")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Clear Notification Audit") {
                        viewModel.clearNotificationAudit()
                    }
                    .disabled(viewModel.tokenPayloadAuditDiagnostics.notificationAudit.totalCount == 0)
                }

                Text("Counts app-server notification methods and stores only sanitized status, enum, and presence metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Audited")
                        Text(viewModel.notificationAuditTotalText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Supported")
                        Text(viewModel.notificationAuditSupportedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Unsupported")
                        Text(viewModel.notificationAuditUnsupportedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Rejected fields")
                        Text(viewModel.notificationAuditRejectedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Unsupported shapes")
                        Text(viewModel.notificationAuditUnsupportedShapeText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last audited")
                        Text(viewModel.notificationAuditLastMethodText)
                            .monospaced()
                    }
                    GridRow {
                        Text("Last update")
                        Text(viewModel.notificationAuditLastUpdatedText)
                            .monospacedDigit()
                    }
                }
                .font(.caption)

                if viewModel.notificationAuditRows.isEmpty {
                    Text("No additional app-server notifications have been audited yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Method")
                                .fontWeight(.semibold)
                            Text("Count")
                                .fontWeight(.semibold)
                            Text("Last safe summary")
                                .fontWeight(.semibold)
                        }

                        ForEach(viewModel.notificationAuditRows) { row in
                            GridRow {
                                Text(row.method)
                                    .monospaced()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(row.count)")
                                    .monospacedDigit()
                                Text(row.lastSummary ?? "--")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func localSourceCoverageStatusColor(_ status: CodexLocalSourceCoverageStatus) -> Color {
        switch status {
        case .healthy, .passiveNoSamples:
            return .secondary
        case .stale, .sourceMissing, .schemaMissing, .noMatchedRows, .failed, .notChecked:
            return .orange
        }
    }

    private var liveTokenPayloadSection: some View {
        Section("Live Token Payload") {
            if let audit = viewModel.tokenPayloadAudit {
                LabeledContent("Last capture") {
                    Text(viewModel.tokenPayloadAuditCapturedAtText)
                        .monospacedDigit()
                }

                LabeledContent("Fields") {
                    Text("\(audit.capturedFieldCount) captured, \(audit.rejectedFieldCount) rejected")
                        .monospacedDigit()
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("Model")
                        Text(presenceText(audit.hasModelMetadata))
                    }
                    GridRow {
                        Text("Project")
                        Text(presenceText(audit.hasProjectMetadata))
                    }
                    GridRow {
                        Text("Effort")
                        Text(presenceText(audit.hasEffortMetadata))
                    }
                    GridRow {
                        Text("Source")
                        Text(presenceText(audit.hasSourceMetadata))
                    }
                    GridRow {
                        Text("Runtime")
                        Text(presenceText(audit.hasRuntimePolicyMetadata))
                    }
                }
                .font(.caption)

                Text(audit.interpretationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No live token payload has been captured yet. This updates after Codex emits a token usage notification while the app is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Capture diagnostics")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Connection")
                        Text(viewModel.tokenPayloadAuditDiagnosticsConnectionText)
                    }
                    GridRow {
                        Text("Last method")
                        Text(viewModel.tokenPayloadAuditDiagnosticsLastMethodText)
                            .monospaced()
                    }
                    GridRow {
                        Text("Token notifications")
                        Text("\(viewModel.tokenPayloadAuditDiagnostics.tokenUsageNotificationCount)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Sanitized")
                        Text("\(viewModel.tokenPayloadAuditDiagnostics.auditSanitizeSuccessCount)/\(viewModel.tokenPayloadAuditDiagnostics.auditSanitizeAttemptCount)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Audit write")
                        Text(viewModel.tokenPayloadAuditDiagnosticsLastAuditStatusText)
                    }
                    GridRow {
                        Text("Last update")
                        Text(viewModel.tokenPayloadAuditDiagnosticsUpdatedAtText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last error")
                        Text(viewModel.tokenPayloadAuditDiagnosticsLastErrorText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)

                Text(viewModel.tokenPayloadAuditDiagnostics.interpretationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Local token capture")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Source")
                        Text(viewModel.localTokenCaptureState.sourceKey)
                            .monospaced()
                    }
                    GridRow {
                        Text("Status")
                        Text(viewModel.localTokenCaptureState.status.displayText)
                    }
                    GridRow {
                        Text("Last checked")
                        Text(viewModel.localTokenCaptureLastCheckedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last token event")
                        Text(viewModel.localTokenCaptureLastEventText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last log row")
                        Text("\(viewModel.localTokenCaptureState.lastLogRowID)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last result")
                        Text(viewModel.localTokenCaptureResultText)
                    }
                    GridRow {
                        Text("Last error")
                        Text(viewModel.localTokenCaptureLastErrorText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Turn performance capture")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Source")
                        Text(viewModel.turnPerformanceCaptureState.sourceKey)
                            .monospaced()
                    }
                    GridRow {
                        Text("Status")
                        Text(viewModel.turnPerformanceCaptureState.status.displayText)
                    }
                    GridRow {
                        Text("Last checked")
                        Text(viewModel.turnPerformanceCaptureLastCheckedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last event")
                        Text(viewModel.turnPerformanceCaptureLastEventText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last log row")
                        Text("\(viewModel.turnPerformanceCaptureState.lastLogRowID)")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last result")
                        Text(viewModel.turnPerformanceCaptureResultText)
                    }
                    GridRow {
                        Text("Runtime dimensions")
                        Text("\(viewModel.turnPerformanceRuntimeDimensionRowCountText) rows, \(viewModel.turnPerformanceRuntimeDimensionKeyCountText) keys")
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Latest dimension")
                        Text(viewModel.turnPerformanceRuntimeDimensionLatestSeenText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last error")
                        Text(viewModel.turnPerformanceCaptureLastErrorText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Session task timing")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Source")
                        Text(viewModel.sessionTaskTimingCaptureState.sourceKey)
                            .monospaced()
                    }
                    GridRow {
                        Text("Status")
                        Text(viewModel.sessionTaskTimingCaptureState.status.displayText)
                    }
                    GridRow {
                        Text("Last checked")
                        Text(viewModel.sessionTaskTimingCaptureLastCheckedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Latest task")
                        Text(viewModel.sessionTaskTimingCaptureLastEventText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Files")
                        Text(viewModel.sessionTaskTimingCaptureFilesText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last result")
                        Text(viewModel.sessionTaskTimingCaptureResultText)
                    }
                    GridRow {
                        Text("Last error")
                        Text(viewModel.sessionTaskTimingCaptureLastErrorText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Thread catalog")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Source")
                        Text(viewModel.threadCatalogCaptureState.sourcePath ?? viewModel.threadCatalogCaptureState.sourceKey)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    GridRow {
                        Text("Status")
                        Text(viewModel.threadCatalogCaptureState.status.displayText)
                    }
                    GridRow {
                        Text("Last checked")
                        Text(viewModel.threadCatalogCaptureLastCheckedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Latest thread")
                        Text(viewModel.threadCatalogCaptureLatestThreadText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Threads")
                        Text(viewModel.threadCatalogCaptureThreadsText)
                    }
                    GridRow {
                        Text("Edges/tools")
                        Text(viewModel.threadCatalogCaptureRelationshipsText)
                    }
                    GridRow {
                        Text("Last error")
                        Text(viewModel.threadCatalogCaptureLastErrorText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Model capabilities")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Source")
                        Text(viewModel.modelCapabilitiesCaptureState.sourcePath ?? viewModel.modelCapabilitiesCaptureState.sourceKey)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    GridRow {
                        Text("Status")
                        Text(viewModel.modelCapabilitiesCaptureState.status.displayText)
                    }
                    GridRow {
                        Text("Last checked")
                        Text(viewModel.modelCapabilitiesCaptureLastCheckedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Cache fetched")
                        Text(viewModel.modelCapabilitiesCaptureFetchedText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Client")
                        Text(viewModel.modelCapabilitiesCaptureClientVersionText)
                            .monospaced()
                    }
                    GridRow {
                        Text("Models")
                        Text(viewModel.modelCapabilitiesCaptureModelsText)
                    }
                    GridRow {
                        Text("Details")
                        Text(viewModel.modelCapabilitiesCaptureDetailsText)
                    }
                    GridRow {
                        Text("Last error")
                        Text(viewModel.modelCapabilitiesCaptureLastErrorText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
            }

            Divider()

            performanceDiagnosticsSection

            HStack {
                Button("Export Payload Audit...") {
                    exportTokenPayloadAudit()
                }
                .disabled(!viewModel.canExportTokenPayloadAudit)

                Button("Clear Payload Audit") {
                    viewModel.clearTokenPayloadAudit()
                }
                .disabled(viewModel.tokenPayloadAudit == nil)

                Button("Clear Capture Diagnostics") {
                    viewModel.clearTokenPayloadAuditDiagnostics()
                }
            }
        }
    }

    private var performanceDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance diagnostics")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if viewModel.performanceInstrumentationSummary.eventCount == 0 {
                Text("No dashboard or menu timings have been captured yet. Open the menu popover or dashboards to collect local diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Events")
                        Text(viewModel.performanceDiagnosticsEventCountText)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("Last")
                        Text(viewModel.performanceDiagnosticsLastEventText)
                    }
                    GridRow {
                        Text("Slowest")
                        Text(viewModel.performanceDiagnosticsSlowestEventText)
                    }
                    GridRow {
                        Text("Last error")
                        Text(viewModel.performanceDiagnosticsLastErrorText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Flow")
                            .fontWeight(.semibold)
                        Text("Count")
                            .fontWeight(.semibold)
                        Text("P50")
                            .fontWeight(.semibold)
                        Text("P95")
                            .fontWeight(.semibold)
                    }

                    ForEach(viewModel.performanceInstrumentationSummary.rows.prefix(6)) { row in
                        GridRow {
                            Text(row.kind.displayTitle)
                                .lineLimit(1)
                            Text("\(row.eventCount)")
                                .monospacedDigit()
                            Text(Self.performanceDurationText(row.p50Milliseconds))
                                .monospacedDigit()
                            Text(Self.performanceDurationText(row.p95Milliseconds))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.caption)
            }

            HStack {
                Button("Export Diagnostics...") {
                    exportPerformanceDiagnostics()
                }
                .disabled(!viewModel.canExportPerformanceDiagnostics)

                Button("Clear Diagnostics") {
                    viewModel.clearPerformanceDiagnostics()
                }
                .disabled(viewModel.performanceInstrumentationSummary.eventCount == 0)
            }
        }
    }

    private var projectsSection: some View {
        Section("Projects") {
            if viewModel.projectEntries.isEmpty {
                Text("No project token history has been imported yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.projectEntries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.effectiveDisplayName)
                                .fontWeight(.medium)
                                .lineLimit(1)

                            Text(entry.projectPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.projectPath)
                        }

                        Spacer(minLength: 12)

                        Button("Rename...") {
                            projectNameDraft = entry.effectiveDisplayName
                            projectBeingRenamed = entry
                        }

                        Button("Reset Name") {
                            Task {
                                await viewModel.resetProjectName(entry)
                            }
                        }
                        .disabled(entry.displayName == nil)
                    }
                }
            }
        }
    }

    private func projectRenameSheet(for entry: TokenProjectCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Project")
                .font(.headline)

            Text(entry.projectPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            TextField("Project name", text: $projectNameDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    projectBeingRenamed = nil
                }
                Button("Save") {
                    let displayName = projectNameDraft
                    projectBeingRenamed = nil
                    Task {
                        await viewModel.renameProject(entry, displayName: displayName)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        } else if let statusMessage = viewModel.statusMessage {
            Text(statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [sqliteBackupContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "codex-usage-history-backup.sqlite3"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            await viewModel.exportBackup(to: url)
        }
    }

    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [sqliteBackupContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        pendingImportURL = url
    }

    private func buildHistoricalArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [sqliteBackupContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "codex-token-history-archive.sqlite3"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let replaceExisting = FileManager.default.fileExists(atPath: url.path)
        Task {
            if let descriptor = await viewModel.buildHistoricalArchive(
                at: url,
                replaceExisting: replaceExisting
            ) {
                try? archiveController.open(descriptor.url)
            }
        }
    }

    private func openHistoricalArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [sqliteBackupContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? archiveController.open(url)
    }

    private func exportHistoricalArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [sqliteBackupContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "codex-token-history-archive-copy.sqlite3"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? archiveController.export(to: url)
    }

    private func exportTokenPayloadAudit() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "codex-live-token-payload-audit.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        viewModel.exportTokenPayloadAudit(to: url)
    }

    private func exportPerformanceDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "codex-performance-diagnostics.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        viewModel.exportPerformanceDiagnostics(to: url)
    }

    private func exportCodexSourceHealth() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "codex-source-health-redacted.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        viewModel.exportCodexSourceHealth(to: url)
    }

    private func presenceText(_ isPresent: Bool) -> String {
        isPresent ? "Present" : "Missing"
    }

    private static func performanceDurationText(_ milliseconds: Double) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.1fs", milliseconds / 1_000)
        }

        return "\(Int(milliseconds.rounded()))ms"
    }

    private var sqliteBackupContentType: UTType {
        UTType(filenameExtension: "sqlite3") ?? .data
    }
}
