import AppKit
import Foundation
import SQLite3

struct HistoricalTokenArchiveDescriptor: Equatable, Sendable {
    let url: URL
    let byteSize: Int64
    let fileIdentifier: UInt64

    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

struct HistoricalTokenArchiveBuildResult: Equatable, Sendable {
    let descriptor: HistoricalTokenArchiveDescriptor
    let summary: CodexSessionTokenBackfillSummary
}

enum HistoricalTokenArchiveError: LocalizedError, Equatable {
    case invalidArchive
    case destinationExists
    case pathChanged

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "The selected file is not a Codex token-history archive."
        case .destinationExists:
            "An archive already exists at that location and replacement was not confirmed."
        case .pathChanged:
            "The selected archive changed on disk. No file was deleted."
        }
    }
}

extension UsageHistoryStore {
    static let historicalArchiveFormat = "codex-token-history-v1"

    static func buildHistoricalTokenArchive(
        at destinationURL: URL,
        importer: CodexSessionTokenBackfillImporting,
        replaceExisting: Bool,
        fileManager: FileManager = .default
    ) throws -> (HistoricalTokenArchiveDescriptor, CodexSessionTokenBackfillSummary) {
        let destinationURL = destinationURL.standardizedFileURL
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path), !replaceExisting {
            throw HistoricalTokenArchiveError.destinationExists
        }

        let temporaryURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString.lowercased()).partial"
        )
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let summary: CodexSessionTokenBackfillSummary
        do {
            let store = try UsageHistoryStore(databaseURL: temporaryURL)
            summary = try importer.importTokenHistory(into: store, request: .allHistory())
            try Task.checkCancellation()
            while try store.backfillNextTokenDimensionSetChunk(sampleLimit: 1_000) {}
            _ = try store.finalizeTokenDimensionSetMigrationIfReady()
            try store.prepareHistoricalTokenArchive()
            try store.checkpointWriteAheadLog()
        }

        try Task.checkCancellation()
        try validateHistoricalTokenArchive(at: temporaryURL)
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: temporaryURL.path)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destinationURL.path) {
            let backupName = ".\(destinationURL.lastPathComponent).replacement-backup"
            let backupURL = parentURL.appendingPathComponent(backupName)
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: backupName,
                options: []
            )
            do {
                try validateHistoricalTokenArchive(at: destinationURL)
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
            } catch {
                if fileManager.fileExists(atPath: backupURL.path) {
                    _ = try? fileManager.replaceItemAt(
                        destinationURL,
                        withItemAt: backupURL,
                        backupItemName: nil,
                        options: []
                    )
                }
                throw error
            }
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        let descriptor = try historicalTokenArchiveDescriptor(at: destinationURL, fileManager: fileManager)
        return (descriptor, summary)
    }

    static func historicalTokenArchiveDescriptor(
        at archiveURL: URL,
        fileManager: FileManager = .default
    ) throws -> HistoricalTokenArchiveDescriptor {
        let archiveURL = archiveURL.standardizedFileURL
        try validateHistoricalTokenArchive(at: archiveURL)
        let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              let identifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            throw HistoricalTokenArchiveError.invalidArchive
        }
        return HistoricalTokenArchiveDescriptor(
            url: archiveURL,
            byteSize: size,
            fileIdentifier: identifier
        )
    }

    static func validateHistoricalTokenArchive(at archiveURL: URL) throws {
        let store = try UsageHistoryStore(databaseURL: archiveURL, openMode: .readOnly)
        guard try store.metadataValue(for: "archive_format") == historicalArchiveFormat,
              try store.archiveScalarText("PRAGMA quick_check") == "ok",
              try store.archiveScalarInt64("SELECT COUNT(*) FROM pragma_foreign_key_check") == 0,
              try store.tableExists(table: "token_usage_samples"),
              try store.tableExists(table: "token_dimension_sets")
        else {
            throw HistoricalTokenArchiveError.invalidArchive
        }
    }

    static func exportHistoricalTokenArchive(
        _ descriptor: HistoricalTokenArchiveDescriptor,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try validateDescriptorIdentity(descriptor, fileManager: fileManager)
        try sqliteBackupCopy(from: descriptor.url, to: destinationURL, fileManager: fileManager)
        try validateHistoricalTokenArchive(at: destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destinationURL.path)
    }

    static func deleteHistoricalTokenArchive(
        _ descriptor: HistoricalTokenArchiveDescriptor,
        fileManager: FileManager = .default
    ) throws {
        try validateDescriptorIdentity(descriptor, fileManager: fileManager)
        try fileManager.removeItem(at: descriptor.url)
    }

    static func sqliteBackupCopy(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let sourceURL = sourceURL.standardizedFileURL
        let destinationURL = destinationURL.standardizedFileURL
        guard sourceURL != destinationURL else {
            throw UsageHistoryStoreError.fileOperationFailed("SQLite backup source and destination must differ.")
        }
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let source,
              sqlite3_open_v2(destinationURL.path, &destination, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let destination
        else {
            if let source { sqlite3_close(source) }
            if let destination { sqlite3_close(destination) }
            throw UsageHistoryStoreError.fileOperationFailed("SQLite backup could not open its source or destination.")
        }
        defer {
            sqlite3_close(source)
            sqlite3_close(destination)
        }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw UsageHistoryStoreError.fileOperationFailed("SQLite backup could not start.")
        }
        defer { sqlite3_backup_finish(backup) }
        guard sqlite3_backup_step(backup, -1) == SQLITE_DONE else {
            throw UsageHistoryStoreError.fileOperationFailed("SQLite backup did not complete.")
        }
    }

    private func prepareHistoricalTokenArchive() throws {
        try transaction {
            for table in [
                "usage_samples", "usage_rollups", "usage_series_catalog",
                "codex_session_token_imports", "codex_live_token_capture_state",
                "codex_turn_performance_dimensions",
                "codex_turn_performance_events", "codex_turn_performance_dimension_catalog",
                "codex_turn_performance_capture_state", "codex_session_task_timing_events",
                "codex_session_task_timing_import_files", "codex_session_task_timing_capture_state",
                "telemetry_hourly_rollups", "telemetry_error_hourly_rollups",
                "telemetry_daily_rollups", "telemetry_error_daily_rollups",
                "codex_thread_spawn_edges", "codex_thread_dynamic_tools", "codex_thread_catalog",
                "codex_thread_catalog_capture_state", "codex_model_capability_reasoning_levels",
                "codex_model_capability_service_tiers", "codex_model_capability_speed_tiers",
                "codex_model_capability_input_modalities", "codex_model_capability_tools",
                "codex_model_capabilities", "codex_model_capabilities_capture_state",
            ] {
                try execute("DELETE FROM \(table)")
            }
            try setMetadataValue(Self.historicalArchiveFormat, for: "archive_format")
            try setMetadataValue(String(Date().timeIntervalSince1970Int), for: "archive_created_at")
            try execute("DELETE FROM storage_maintenance_journal")
        }
    }

    private func archiveScalarInt64(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HistoricalTokenArchiveError.invalidArchive
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func archiveScalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HistoricalTokenArchiveError.invalidArchive
        }
        return columnText(statement, index: 0)
    }

    private static func validateDescriptorIdentity(
        _ descriptor: HistoricalTokenArchiveDescriptor,
        fileManager: FileManager
    ) throws {
        let current = try historicalTokenArchiveDescriptor(at: descriptor.url, fileManager: fileManager)
        guard current.fileIdentifier == descriptor.fileIdentifier else {
            throw HistoricalTokenArchiveError.pathChanged
        }
    }
}

@MainActor
final class HistoricalTokenArchiveController: ObservableObject {
    static let shared = HistoricalTokenArchiveController()

    @Published private(set) var openedArchive: HistoricalTokenArchiveDescriptor?
    private var activeViewerCount = 0

    func open(_ url: URL) throws {
        activeViewerCount = 0
        openedArchive = try UsageHistoryStore.historicalTokenArchiveDescriptor(at: url)
    }

    func close() {
        activeViewerCount = 0
        openedArchive = nil
    }

    func beginViewing() {
        guard openedArchive != nil else { return }
        activeViewerCount += 1
    }

    func endViewing() {
        activeViewerCount = max(activeViewerCount - 1, 0)
        if activeViewerCount == 0 {
            openedArchive = nil
        }
    }

    func reveal() {
        guard let openedArchive else { return }
        NSWorkspace.shared.activateFileViewerSelecting([openedArchive.url])
    }

    func export(to destinationURL: URL) throws {
        guard let openedArchive else { throw HistoricalTokenArchiveError.invalidArchive }
        try UsageHistoryStore.exportHistoricalTokenArchive(openedArchive, to: destinationURL)
    }

    func deleteOpenedArchive() throws {
        guard let openedArchive else { throw HistoricalTokenArchiveError.invalidArchive }
        try UsageHistoryStore.deleteHistoricalTokenArchive(openedArchive)
        activeViewerCount = 0
        self.openedArchive = nil
    }
}
