import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testClearHistoryDeletesTokenUsageSamples() async throws {
        let store = try makeStore()
        let metadata = CodexSessionTokenImportFileMetadata(path: "/tmp/session.jsonl", fileSize: 123, modifiedAt: 456)

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 120, totalTotal: 120),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.recordCodexSessionTokenImportFile(metadata, importedAt: 789, status: .imported)
        XCTAssertTrue(try store.hasAnyHistory())
        XCTAssertEqual(try store.codexSessionTokenImportFileRecords().count, 1)

        try store.clearHistory()

        XCTAssertTrue(try store.tokenUsageSamples().isEmpty)
        XCTAssertTrue(try store.codexSessionTokenImportFileRecords().isEmpty)
        XCTAssertFalse(try store.hasAnyHistory())
    }

    func testExportsCSVRows() async throws {
        let store = try makeStore()

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))

        let csv = try store.csv(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertTrue(csv.contains("timestamp,bucket_id,bucket_name,bucket_kind,window,used_percent"))
        XCTAssertTrue(csv.contains("2026-04-14T20:00:00Z,codex,All models,aggregate,sevenDay,20.000"))
        XCTAssertTrue(csv.contains("2026-04-14T20:00:00Z,codex_gpt55,GPT-5.5,model,sevenDay,7.000"))
    }

    func testHasAnyHistoryReflectsSamplesAndClear() async throws {
        let store = try makeStore()

        XCTAssertFalse(try store.hasAnyHistory())

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastInput: 120, lastTotal: 120, totalInput: 120, totalTotal: 120),
            at: date("2026-04-14T20:10:00Z")
        )
        XCTAssertTrue(try store.hasAnyHistory())

        try store.clearHistory()
        XCTAssertFalse(try store.hasAnyHistory())
        XCTAssertEqual(try store.availableSeries(window: .sevenDay), [])
        XCTAssertEqual(try store.availableTokenComponentSeries(), [])
    }

    func testDatabaseInfoReportsURLAndByteSize() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))

        let info = try store.databaseInfo()

        XCTAssertEqual(info.databaseURL, databaseURL)
        XCTAssertGreaterThan(info.totalByteSize, 0)
    }

    func testRawRetentionDefaultsAndPersists() async throws {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .fourteenDays)

        UsageHistoryRawRetentionStore.save(.ninetyDays, to: defaults)

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .ninetyDays)
    }

    func testRecordUsesUpdatedRawRetentionProvider() async throws {
        var retention = UsageHistoryRawRetention.thirtyDays.timeInterval
        let store = try UsageHistoryStore.inMemory(
            notificationCenter: NotificationCenter(),
            calendar: calendar,
            rawRetentionProvider: { retention }
        )
        let oldDate = date("2026-04-01T12:00:00Z")
        let currentDate = date("2026-04-14T20:00:00Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: oldDate)
        retention = UsageHistoryRawRetention.sevenDays.timeInterval
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: currentDate)

        let oldDayPoints = try store.points(range: .day, window: .sevenDay, now: date("2026-04-01T13:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: currentDate, calendar: calendar)

        XCTAssertEqual(oldDayPoints.map(\.usedPercent), [12])
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 12 })
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 40 })
    }

    func testHistoryBoundsUseRequestedRollupGranularity() async throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-01T12:30:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-14T20:00:00Z"))

        let hourlyBounds = try store.historyBounds(window: .sevenDay, granularity: .hour)
        let dailyBounds = try store.historyBounds(window: .sevenDay, granularity: .day)

        XCTAssertEqual(hourlyBounds?.earliest, date("2026-04-01T12:30:00Z"))
        XCTAssertEqual(hourlyBounds?.latest, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(dailyBounds?.earliest, date("2026-04-01T12:30:00Z"))
        XCTAssertEqual(dailyBounds?.latest, date("2026-04-14T20:00:00Z"))
    }

    func testBackupExportProducesImportableDatabase() async throws {
        let (sourceStore, _) = try makeTemporaryStore()
        try sourceStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        _ = try sourceStore.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 120,
                    lastTotal: 120,
                    totalInput: 120,
                    totalTotal: 120
                ),
                receivedAt: date("2026-04-14T20:10:00Z"),
                context: TokenUsageContext(
                    sessionID: "session-backup",
                    projectPath: "/Users/example/Projects/backup-project",
                    effort: "high",
                    source: "cli"
                )
            ),
        ])
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")

        try sourceStore.exportBackup(to: backupURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let (destinationStore, _) = try makeTemporaryStore()
        try destinationStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 80)), at: date("2026-04-14T20:00:00Z"))

        try destinationStore.importBackup(from: backupURL)
        let points = try destinationStore.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [20])
        let tokenSamples = try destinationStore.tokenUsageSamples()
        XCTAssertEqual(tokenSamples.map(\.observedTotalTokens), [120])
        XCTAssertEqual(tokenSamples.first?.projectName, "backup-project")
        XCTAssertEqual(tokenSamples.first?.effort, "high")
        XCTAssertEqual(tokenSamples.first?.source, "cli")
        XCTAssertEqual(try destinationStore.availableSeries(window: .sevenDay).map(\.id), ["codex"])
        XCTAssertEqual(try destinationStore.availableTokenComponentSeries().map(\.id), ["tokens_all", "model:gpt-5.5"])
    }

    func testTokenProjectDisplayNamesCanBeRenamedResetAndSurviveCatalogRebuild() async throws {
        let notificationCenter = NotificationCenter()
        let (store, _) = try makeTemporaryStore(notificationCenter: notificationCenter)
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 120,
                    lastTotal: 120,
                    totalInput: 120,
                    totalTotal: 120
                ),
                receivedAt: date("2026-04-14T20:10:00Z"),
                context: TokenUsageContext(projectPath: "/Users/example/Projects/backup-project")
            ),
        ])
        let expectation = expectation(description: "Rename posts history change notification")
        let observer = notificationCenter.addObserver(
            forName: UsageHistoryStore.didChangeNotification,
            object: store,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }

        try store.updateTokenProjectDisplayName(
            projectPath: "/Users/example/Projects/backup-project",
            displayName: "Client Work"
        )
        await fulfillment(of: [expectation], timeout: 1)
        notificationCenter.removeObserver(observer)

        var entries = try store.tokenProjectCatalogEntries()
        XCTAssertEqual(entries.first?.generatedName, "backup-project")
        XCTAssertEqual(entries.first?.displayName, "Client Work")
        XCTAssertEqual(entries.first?.effectiveDisplayName, "Client Work")
        XCTAssertEqual(
            try store.tokenDashboardSeries(breakdownDimension: .project).first { $0.id == "project:/Users/example/Projects/backup-project" }?.name,
            "Client Work"
        )

        try store.rebuildTokenContextCatalogs()
        entries = try store.tokenProjectCatalogEntries()
        XCTAssertEqual(entries.first?.displayName, "Client Work")

        try store.updateTokenProjectDisplayName(
            projectPath: "/Users/example/Projects/backup-project",
            displayName: "   "
        )

        entries = try store.tokenProjectCatalogEntries()
        XCTAssertNil(entries.first?.displayName)
        XCTAssertEqual(entries.first?.effectiveDisplayName, "backup-project")
    }

    func testTokenProjectDisplayNameRejectsControlCharacters() async throws {
        let (store, _) = try makeTemporaryStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    lastInput: 120,
                    lastTotal: 120,
                    totalInput: 120,
                    totalTotal: 120
                ),
                receivedAt: date("2026-04-14T20:10:00Z"),
                context: TokenUsageContext(projectPath: "/Users/example/Projects/backup-project")
            ),
        ])

        XCTAssertThrowsError(
            try store.updateTokenProjectDisplayName(
                projectPath: "/Users/example/Projects/backup-project",
                displayName: "Bad\nName"
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, UsageHistoryStoreError.invalidProjectDisplayName.localizedDescription)
        }
    }

    func testBackupImportPreservesTokenProjectDisplayNames() async throws {
        let (sourceStore, _) = try makeTemporaryStore()
        _ = try sourceStore.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    lastInput: 120,
                    lastTotal: 120,
                    totalInput: 120,
                    totalTotal: 120
                ),
                receivedAt: date("2026-04-14T20:10:00Z"),
                context: TokenUsageContext(projectPath: "/Users/example/Projects/backup-project")
            ),
        ])
        try sourceStore.updateTokenProjectDisplayName(
            projectPath: "/Users/example/Projects/backup-project",
            displayName: "Client Work"
        )
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")
        try sourceStore.exportBackup(to: backupURL)
        let (destinationStore, _) = try makeTemporaryStore()

        try destinationStore.importBackup(from: backupURL)

        let entries = try destinationStore.tokenProjectCatalogEntries()
        XCTAssertEqual(entries.first?.displayName, "Client Work")
        XCTAssertEqual(entries.first?.effectiveDisplayName, "Client Work")
    }

    func testBackupImportCleansMalformedTokenModelLabelsAndRebuildsCatalogs() async throws {
        let sourceDirectoryURL = try makeTemporaryDirectory()
        let sourceURL = sourceDirectoryURL.appendingPathComponent("source.sqlite3")
        var sourceStore: UsageHistoryStore? = try UsageHistoryStore(
            databaseURL: sourceURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        sourceStore = nil
        try insertMalformedTokenModelRows(into: sourceURL)
        let (destinationStore, _) = try makeTemporaryStore()

        try destinationStore.importBackup(from: sourceURL)

        XCTAssertEqual(try destinationStore.tokenUsageSamples().map(\.model), ["gpt-5.5", "gpt-5.5", nil])
        XCTAssertEqual(try destinationStore.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 125)
        XCTAssertEqual(
            try destinationStore.tokenDashboardSeries().map(\.id),
            ["tokens_all", "model:gpt-5.5", "tokens_unattributed"]
        )
    }

    func testImportBackupReplacesHistoryAndNotifies() async throws {
        let (sourceStore, _) = try makeTemporaryStore()
        try sourceStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")
        try sourceStore.exportBackup(to: backupURL)
        let notificationCenter = NotificationCenter()
        let (destinationStore, _) = try makeTemporaryStore(notificationCenter: notificationCenter)
        try destinationStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 80)), at: date("2026-04-14T20:00:00Z"))
        let expectation = expectation(description: "Import posts history change notification")
        let observer = notificationCenter.addObserver(
            forName: UsageHistoryStore.didChangeNotification,
            object: destinationStore,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        try destinationStore.importBackup(from: backupURL)
        await fulfillment(of: [expectation], timeout: 1)
        let points = try destinationStore.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [20])
    }

    func testInvalidBackupImportThrowsUserFacingFailure() async throws {
        let (store, _) = try makeTemporaryStore()
        let invalidURL = try makeTemporaryDirectory().appendingPathComponent("invalid.sqlite3")
        try Data("not a sqlite backup".utf8).write(to: invalidURL)

        XCTAssertThrowsError(try store.importBackup(from: invalidURL)) { error in
            XCTAssertEqual(error.localizedDescription, UsageHistoryStoreError.invalidBackup.localizedDescription)
        }
    }

    @MainActor
    func testSettingsViewModelFormatsDatabaseInfoAndPersistsRetention() async throws {
        let defaults = makeIsolatedDefaults()
        let (store, databaseURL) = try makeTemporaryStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))

        let viewModel = DataManagementSettingsViewModel(store: store, defaults: defaults)
        await viewModel.refreshDatabaseInfo()

        XCTAssertEqual(viewModel.databasePathText, databaseURL.path)
        XCTAssertNotEqual(viewModel.databaseSizeText, "--")

        viewModel.selectedRetention = .ninetyDays

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .ninetyDays)
        XCTAssertEqual(viewModel.statusMessage, "Raw sample retention updated.")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testSettingsViewModelExportImportClearAndFailureMessages() async throws {
        let (store, _) = try makeTemporaryStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let viewModel = DataManagementSettingsViewModel(store: store, defaults: makeIsolatedDefaults())
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")

        await viewModel.exportBackup(to: backupURL)

        XCTAssertEqual(viewModel.statusMessage, "Backup exported.")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        await viewModel.clearHistory()

        XCTAssertEqual(viewModel.statusMessage, "History cleared.")
        XCTAssertFalse(try store.hasAnyHistory())

        await viewModel.importBackup(from: backupURL)

        XCTAssertEqual(viewModel.statusMessage, "Backup imported.")
        XCTAssertTrue(try store.hasAnyHistory())

        let invalidURL = try makeTemporaryDirectory().appendingPathComponent("invalid.sqlite3")
        try Data("not a sqlite backup".utf8).write(to: invalidURL)
        await viewModel.importBackup(from: invalidURL)

        XCTAssertEqual(viewModel.errorMessage, "Backup could not be imported.")
        XCTAssertNil(viewModel.statusMessage)
    }

    @MainActor
    func testSettingsViewModelLoadsRenamesAndResetsProjectNames() async throws {
        let (store, _) = try makeTemporaryStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    lastInput: 120,
                    lastTotal: 120,
                    totalInput: 120,
                    totalTotal: 120
                ),
                receivedAt: date("2026-04-14T20:10:00Z"),
                context: TokenUsageContext(projectPath: "/Users/example/Projects/backup-project")
            ),
        ])
        let viewModel = DataManagementSettingsViewModel(store: store, defaults: makeIsolatedDefaults())
        await viewModel.refreshProjectEntries()

        XCTAssertEqual(viewModel.projectEntries.map(\.effectiveDisplayName), ["backup-project"])

        guard let entry = viewModel.projectEntries.first else {
            XCTFail("Expected project entry")
            return
        }
        await viewModel.renameProject(entry, displayName: "Client Work")

        XCTAssertEqual(viewModel.statusMessage, "Project name updated.")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.projectEntries.map(\.effectiveDisplayName), ["Client Work"])

        await viewModel.renameProject(viewModel.projectEntries[0], displayName: "Bad\nName")

        XCTAssertEqual(viewModel.errorMessage, UsageHistoryStoreError.invalidProjectDisplayName.localizedDescription)

        await viewModel.resetProjectName(viewModel.projectEntries[0])

        XCTAssertEqual(viewModel.statusMessage, "Project name reset.")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.projectEntries.map(\.effectiveDisplayName), ["backup-project"])
    }

    @MainActor
    func testSettingsViewModelImportsTokenHistoryAndReportsFailure() async throws {
        let store = try makeStore()
        let releaseSuccessfulImport = DispatchSemaphore(value: 0)
        let successfulImportStarted = expectation(description: "Successful import started")
        let successImporter = StubTokenBackfillImporter { _, _ in
            successfulImportStarted.fulfill()
            releaseSuccessfulImport.wait()
            return CodexSessionTokenBackfillSummary(
                request: .recent(now: self.date("2026-05-17T12:00:00Z")),
                filesDiscovered: 7,
                filesScanned: 3,
                filesSkippedByBounds: 2,
                filesSkippedUnchanged: 2,
                tokenEventsImported: 12,
                duplicateEventsSkipped: 4,
                modelEventsRepaired: 1,
                failedLinesSkipped: 1,
                elapsedTime: 0.1
            )
        }
        let successViewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            tokenBackfillImporter: successImporter
        )

        successViewModel.importRecentTokenHistoryFromCodexSessions(now: date("2026-05-17T12:00:00Z"))
        await fulfillment(of: [successfulImportStarted], timeout: 1)

        XCTAssertTrue(successViewModel.isImportingTokenHistory)
        XCTAssertEqual(successImporter.receivedRequests.map(\.mode), [.recent])
        releaseSuccessfulImport.signal()
        await waitForImportToFinish(successViewModel)

        XCTAssertFalse(successViewModel.isImportingTokenHistory)
        XCTAssertEqual(
            successViewModel.tokenImportSummaryText,
            "Recent sessions: scanned 3 of 7 files. Imported 12 token events. 2 outside this import scope. 2 unchanged files skipped. 4 duplicates skipped. 1 model labels repaired. 1 unreadable lines skipped. 0.1s elapsed."
        )
        XCTAssertNil(successViewModel.statusMessage)
        XCTAssertNil(successViewModel.errorMessage)

        let allHistoryImporter = StubTokenBackfillImporter { _, _ in
            CodexSessionTokenBackfillSummary(filesScanned: 1, tokenEventsImported: 0, duplicateEventsSkipped: 0, failedLinesSkipped: 0)
        }
        let allHistoryViewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            tokenBackfillImporter: allHistoryImporter
        )

        allHistoryViewModel.importAllTokenHistoryFromCodexSessions()
        await waitForImportToFinish(allHistoryViewModel)

        XCTAssertEqual(allHistoryImporter.receivedRequests.map(\.mode), [.allHistory])

        let failingViewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            tokenBackfillImporter: StubTokenBackfillImporter { _, _ in
                throw UsageHistoryStoreError.databaseUnavailable
            }
        )

        failingViewModel.importTokenHistoryFromCodexSessions()
        await waitForImportToFinish(failingViewModel)

        XCTAssertFalse(failingViewModel.isImportingTokenHistory)
        XCTAssertNil(failingViewModel.tokenImportSummaryText)
        XCTAssertEqual(failingViewModel.errorMessage, "Token history could not be imported.")
        XCTAssertNil(failingViewModel.statusMessage)
    }

}
