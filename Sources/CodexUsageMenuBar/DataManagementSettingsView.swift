import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    private let store: UsageHistoryStore
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let byteFormatter: ByteCountFormatter
    private var databaseInfo: UsageHistoryDatabaseInfo?

    init(
        store: UsageHistoryStore,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        byteFormatter: ByteCountFormatter = ByteCountFormatter()
    ) {
        self.store = store
        self.defaults = defaults
        self.fileManager = fileManager
        self.byteFormatter = byteFormatter
        selectedRetention = UsageHistoryRawRetentionStore.load(from: defaults)
        refreshDatabaseInfo()
    }

    var databaseURL: URL? {
        databaseInfo?.databaseURL
    }

    var canRevealDatabase: Bool {
        databaseURL != nil
    }

    func refreshDatabaseInfo() {
        do {
            let info = try store.databaseInfo(fileManager: fileManager)
            databaseInfo = info
            databasePathText = info.databaseURL.path
            databaseSizeText = byteFormatter.string(fromByteCount: info.totalByteSize)
        } catch {
            databaseInfo = nil
            databasePathText = "Unavailable"
            databaseSizeText = "--"
        }
    }

    func revealDatabaseInFinder() {
        guard let databaseURL else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
    }

    func exportBackup(to destinationURL: URL) {
        do {
            try store.exportBackup(to: destinationURL, fileManager: fileManager)
            statusMessage = "Backup exported."
            errorMessage = nil
            refreshDatabaseInfo()
        } catch {
            statusMessage = nil
            errorMessage = "Backup could not be exported."
        }
    }

    func importBackup(from sourceURL: URL) {
        do {
            try store.importBackup(from: sourceURL)
            statusMessage = "Backup imported."
            errorMessage = nil
            refreshDatabaseInfo()
        } catch {
            statusMessage = nil
            errorMessage = "Backup could not be imported."
        }
    }

    func clearHistory() {
        do {
            try store.clearHistory()
            statusMessage = "History cleared."
            errorMessage = nil
            refreshDatabaseInfo()
        } catch {
            statusMessage = nil
            errorMessage = "History could not be cleared."
        }
    }
}

struct DataManagementSettingsView: View {
    @StateObject private var viewModel: DataManagementSettingsViewModel
    @State private var isConfirmingClear = false
    @State private var pendingImportURL: URL?

    init(store: UsageHistoryStore) {
        _viewModel = StateObject(wrappedValue: DataManagementSettingsViewModel(store: store))
    }

    var body: some View {
        TabView {
            Form {
                databaseSection
                retentionSection
                feedbackSection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Data", systemImage: "externaldrive")
            }

            InstallUpdateSettingsView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 580, height: 430)
        .scenePadding()
        .alert("Clear History?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) {
                viewModel.clearHistory()
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
                    viewModel.importBackup(from: pendingImportURL)
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

        viewModel.exportBackup(to: url)
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
