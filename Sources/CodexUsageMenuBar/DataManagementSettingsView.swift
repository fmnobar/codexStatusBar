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
final class DataManagementSettingsViewModel: ObservableObject {
    @Published var selectedRetention: UsageHistoryRawRetention {
        didSet {
            guard selectedRetention != oldValue else {
                return
            }

            UsageHistoryRawRetentionStore.save(selectedRetention, to: defaults)
            statusMessage = "Raw sample retention updated."
            errorMessage = nil
        }
    }

    @Published private(set) var databasePathText = "Unavailable"
    @Published private(set) var databaseSizeText = "--"
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isImportingTokenHistory = false
    @Published private(set) var tokenImportSummaryText: String?
    @Published private(set) var projectEntries: [TokenProjectCatalogEntry] = []
    @Published private(set) var tokenPayloadAudit: CodexTokenUsagePayloadAudit?
    @Published private(set) var tokenPayloadAuditDiagnostics: CodexAppServerAuditDiagnostics
    @Published private(set) var localTokenCaptureState = CodexLiveTokenCaptureState()
    @Published private(set) var turnPerformanceCaptureState = CodexTurnPerformanceCaptureState()
    @Published private(set) var sessionTaskTimingCaptureState = CodexSessionTaskTimingCaptureState()

    private let database: UsageHistoryDatabaseWorking
    private let defaults: UserDefaults
    private let byteFormatter: ByteCountFormatter
    private let tokenBackfillImporter: CodexSessionTokenBackfillImporting
    private let tokenPayloadAuditStore: CodexTokenPayloadAuditStore
    private let tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore
    private var databaseInfo: UsageHistoryDatabaseInfo?
    private var tokenPayloadAuditCancellable: AnyCancellable?
    private var tokenPayloadAuditDiagnosticsCancellable: AnyCancellable?

    init(
        database: UsageHistoryDatabaseWorking,
        defaults: UserDefaults = .standard,
        byteFormatter: ByteCountFormatter = ByteCountFormatter(),
        tokenBackfillImporter: CodexSessionTokenBackfillImporting = CodexSessionTokenBackfillImporter(),
        tokenPayloadAuditStore: CodexTokenPayloadAuditStore = .applicationSupportStore(),
        tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore = .applicationSupportStore()
    ) {
        self.database = database
        self.defaults = defaults
        self.byteFormatter = byteFormatter
        self.tokenBackfillImporter = tokenBackfillImporter
        self.tokenPayloadAuditStore = tokenPayloadAuditStore
        self.tokenPayloadAuditDiagnosticsStore = tokenPayloadAuditDiagnosticsStore
        selectedRetention = UsageHistoryRawRetentionStore.load(from: defaults)
        tokenPayloadAudit = tokenPayloadAuditStore.latestAudit
        tokenPayloadAuditDiagnostics = tokenPayloadAuditDiagnosticsStore.diagnostics
        tokenPayloadAuditCancellable = tokenPayloadAuditStore.$latestAudit.sink { [weak self] audit in
            self?.tokenPayloadAudit = audit
        }
        tokenPayloadAuditDiagnosticsCancellable = tokenPayloadAuditDiagnosticsStore.$diagnostics.sink { [weak self] diagnostics in
            self?.tokenPayloadAuditDiagnostics = diagnostics
        }
    }

    convenience init(
        store: UsageHistoryStore,
        defaults: UserDefaults = .standard,
        byteFormatter: ByteCountFormatter = ByteCountFormatter(),
        tokenBackfillImporter: CodexSessionTokenBackfillImporting = CodexSessionTokenBackfillImporter(),
        tokenPayloadAuditStore: CodexTokenPayloadAuditStore = .applicationSupportStore(),
        tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore = .applicationSupportStore()
    ) {
        let testSafeWorker = UsageHistoryDatabaseWorker(
            store: store,
            turnPerformanceImporter: { store, _, _, _ in
                (try? store.codexTurnPerformanceCaptureState()) ?? CodexTurnPerformanceCaptureState()
            },
            sessionTaskTimingImporter: { store, _, _, _ in
                (try? store.codexSessionTaskTimingCaptureState()) ?? CodexSessionTaskTimingCaptureState()
            }
        )
        self.init(
            database: testSafeWorker,
            defaults: defaults,
            byteFormatter: byteFormatter,
            tokenBackfillImporter: tokenBackfillImporter,
            tokenPayloadAuditStore: tokenPayloadAuditStore,
            tokenPayloadAuditDiagnosticsStore: tokenPayloadAuditDiagnosticsStore
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

    func refreshDatabaseInfo() async {
        do {
            let info = try await database.databaseInfo()
            databaseInfo = info
            databasePathText = info.databaseURL.path
            databaseSizeText = byteFormatter.string(fromByteCount: info.totalByteSize)
        } catch {
            databaseInfo = nil
            databasePathText = "Unavailable"
            databaseSizeText = "--"
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
    }

    func refreshSessionTaskTimingCaptureState() async {
        sessionTaskTimingCaptureState = await database.captureSessionTaskTimingIfNeeded(
            at: Date(),
            calendar: .autoupdatingCurrent,
            force: false
        )
    }

    func refreshData() async {
        await refreshDatabaseInfo()
        await refreshProjectEntries()
        await refreshLocalTokenCaptureState()
        await refreshTurnPerformanceCaptureState()
        await refreshSessionTaskTimingCaptureState()
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

    func clearHistory() async {
        do {
            try await database.clearHistory()
            statusMessage = "History cleared."
            errorMessage = nil
            tokenImportSummaryText = nil
            projectEntries = []
            await refreshData()
        } catch {
            statusMessage = nil
            errorMessage = "History could not be cleared."
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
    }

    func importTokenHistoryFromCodexSessions() {
        importRecentTokenHistoryFromCodexSessions()
    }

    func importRecentTokenHistoryFromCodexSessions(now: Date = Date()) {
        importTokenHistoryFromCodexSessions(request: .recent(now: now))
    }

    func importAllTokenHistoryFromCodexSessions() {
        importTokenHistoryFromCodexSessions(request: .allHistory())
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
}

struct DataManagementSettingsView: View {
    @StateObject private var viewModel: DataManagementSettingsViewModel
    @ObservedObject private var updateMonitor: AppUpdateMonitor
    @AppStorage(SettingsTabSelectionStore.key) private var selectedTabRaw = SettingsTabSelection.data.rawValue
    @State private var isConfirmingClear = false
    @State private var pendingImportURL: URL?
    @State private var projectBeingRenamed: TokenProjectCatalogEntry?
    @State private var projectNameDraft = ""

    init(
        database: UsageHistoryDatabaseWorking,
        updateMonitor: AppUpdateMonitor = AppUpdateMonitor(),
        tokenPayloadAuditStore: CodexTokenPayloadAuditStore = .applicationSupportStore(),
        tokenPayloadAuditDiagnosticsStore: CodexAppServerAuditDiagnosticsStore = .applicationSupportStore()
    ) {
        _viewModel = StateObject(
            wrappedValue: DataManagementSettingsViewModel(
                database: database,
                tokenPayloadAuditStore: tokenPayloadAuditStore,
                tokenPayloadAuditDiagnosticsStore: tokenPayloadAuditDiagnosticsStore
            )
        )
        self.updateMonitor = updateMonitor
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
            Form {
                databaseSection
                retentionSection
                tokenHistorySection
                liveTokenPayloadSection
                projectsSection
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
        .frame(width: 580, height: 540)
        .scenePadding()
        .task {
            await viewModel.refreshData()
        }
        .sheet(item: $projectBeingRenamed) { entry in
            projectRenameSheet(for: entry)
        }
        .alert("Clear History?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) {
                Task {
                    await viewModel.clearHistory()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes local usage history. Backups and Codex account data are not affected.")
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
            Text("This replaces current local history with the selected backup.")
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

    private var databaseSection: some View {
        Section("History Database") {
            LabeledContent("Location") {
                Text(viewModel.databasePathText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            LabeledContent("Size") {
                Text(viewModel.databaseSizeText)
                    .monospacedDigit()
            }

            HStack {
                Button("Reveal in Finder") {
                    viewModel.revealDatabaseInFinder()
                }
                .disabled(!viewModel.canRevealDatabase)

                Button("Export Backup...") {
                    exportBackup()
                }

                Button("Import Backup...") {
                    chooseBackupToImport()
                }

                Spacer()

                Button("Clear History...", role: .destructive) {
                    isConfirmingClear = true
                }
            }
        }
    }

    private var retentionSection: some View {
        Section("Raw Samples") {
            Picker("Keep raw samples", selection: $viewModel.selectedRetention) {
                ForEach(UsageHistoryRawRetention.allCases) { retention in
                    Text(retention.displayTitle).tag(retention)
                }
            }
            .pickerStyle(.menu)

            Text("Hourly and daily rollups are kept indefinitely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tokenHistorySection: some View {
        Section("Token History") {
            HStack {
                Button(viewModel.isImportingTokenHistory ? "Importing..." : "Import Recent Sessions...") {
                    viewModel.importRecentTokenHistoryFromCodexSessions()
                }
                .disabled(viewModel.isImportingTokenHistory)

                Button("Import All History...") {
                    viewModel.importAllTokenHistoryFromCodexSessions()
                }
                .disabled(viewModel.isImportingTokenHistory)
            }

            Text("Recent import scans active sessions from the last 30 days. All history includes archives and can take a long time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let tokenImportSummaryText = viewModel.tokenImportSummaryText {
                Text(tokenImportSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func presenceText(_ isPresent: Bool) -> String {
        isPresent ? "Present" : "Missing"
    }

    private var sqliteBackupContentType: UTType {
        UTType(filenameExtension: "sqlite3") ?? .data
    }
}
