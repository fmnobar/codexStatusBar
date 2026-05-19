import AppKit
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

    private let database: UsageHistoryDatabaseWorking
    private let defaults: UserDefaults
    private let byteFormatter: ByteCountFormatter
    private let tokenBackfillImporter: CodexSessionTokenBackfillImporting
    private var databaseInfo: UsageHistoryDatabaseInfo?

    init(
        database: UsageHistoryDatabaseWorking,
        defaults: UserDefaults = .standard,
        byteFormatter: ByteCountFormatter = ByteCountFormatter(),
        tokenBackfillImporter: CodexSessionTokenBackfillImporting = CodexSessionTokenBackfillImporter()
    ) {
        self.database = database
        self.defaults = defaults
        self.byteFormatter = byteFormatter
        self.tokenBackfillImporter = tokenBackfillImporter
        selectedRetention = UsageHistoryRawRetentionStore.load(from: defaults)
    }

    convenience init(
        store: UsageHistoryStore,
        defaults: UserDefaults = .standard,
        byteFormatter: ByteCountFormatter = ByteCountFormatter(),
        tokenBackfillImporter: CodexSessionTokenBackfillImporting = CodexSessionTokenBackfillImporter()
    ) {
        self.init(
            database: UsageHistoryDatabaseWorker(store: store),
            defaults: defaults,
            byteFormatter: byteFormatter,
            tokenBackfillImporter: tokenBackfillImporter
        )
    }

    var databaseURL: URL? {
        databaseInfo?.databaseURL
    }

    var canRevealDatabase: Bool {
        databaseURL != nil
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

    func refreshData() async {
        await refreshDatabaseInfo()
        await refreshProjectEntries()
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
        updateMonitor: AppUpdateMonitor = AppUpdateMonitor()
    ) {
        _viewModel = StateObject(wrappedValue: DataManagementSettingsViewModel(database: database))
        self.updateMonitor = updateMonitor
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
            Form {
                databaseSection
                retentionSection
                tokenHistorySection
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

    private var sqliteBackupContentType: UTType {
        UTType(filenameExtension: "sqlite3") ?? .data
    }
}
