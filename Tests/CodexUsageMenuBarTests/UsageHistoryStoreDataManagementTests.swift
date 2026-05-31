import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testClearHistoryDeletesTokenUsageSamples() async throws {
        let store = try makeStore()
        let metadata = CodexSessionTokenImportFileMetadata(path: "/tmp/session.jsonl", fileSize: 123, modifiedAt: 456)
        let timingMetadata = CodexSessionTokenImportFileMetadata(path: "/tmp/task-session.jsonl", fileSize: 456, modifiedAt: 789)

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 120, totalTotal: 120),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.recordCodexSessionTokenImportFile(metadata, importedAt: 789, status: .imported)
        try store.importSessionTaskTimingEvents([
            CodexSessionTaskTimingEvent(
                sessionID: "session-clear",
                turnID: "turn-clear",
                startedAt: date("2026-04-14T20:00:00Z"),
                completedAt: date("2026-04-14T20:00:03Z"),
                recordedAt: date("2026-04-14T20:00:03Z")
            )!,
        ])
        try store.recordCodexSessionTaskTimingImportFile(timingMetadata, importedAt: 999, status: .imported)
        try store.recordCodexSessionTaskTimingCaptureState(
            CodexSessionTaskTimingCaptureState(lastCheckedAt: date("2026-04-14T20:00:04Z"), status: .imported, insertedCount: 1)
        )
        try store.importCodexThreadCatalog(
            CodexThreadCatalogImportBatch(
                threads: [
                    CodexThreadCatalogThread(
                        threadID: "thread-clear",
                        rolloutPath: "/tmp/rollout.jsonl",
                        createdAt: date("2026-04-14T20:00:00Z"),
                        updatedAt: date("2026-04-14T20:00:04Z"),
                        source: "cli",
                        modelProvider: "openai",
                        cwd: "/Users/example/Projects/clear",
                        sandboxPolicy: "danger-full-access",
                        approvalMode: "never",
                        tokensUsed: 10,
                        hasUserEvent: true,
                        archived: false,
                        archivedAt: nil,
                        gitSHA: nil,
                        gitBranch: "main",
                        gitOriginURL: nil,
                        cliVersion: "0.42.0",
                        agentNickname: nil,
                        agentRole: nil,
                        agentPath: nil,
                        memoryMode: "enabled",
                        model: "gpt-5.5",
                        reasoningEffort: "high",
                        threadSource: "cli"
                    )!,
                ],
                spawnEdges: [],
                dynamicTools: [],
                pruneThreads: true,
                pruneSpawnEdges: true,
                pruneDynamicTools: true
            )
        )
        try store.recordCodexThreadCatalogCaptureState(
            CodexThreadCatalogCaptureState(lastCheckedAt: date("2026-04-14T20:00:05Z"), status: .imported, threadsInsertedCount: 1)
        )
        try store.importCodexModelCapabilities(
            CodexModelCapabilitiesImportBatch(
                models: [
                    CodexModelCapability(
                        slug: "gpt-5.5",
                        displayName: "GPT-5.5",
                        visibility: "stable",
                        supportedInAPI: true,
                        priority: 1,
                        contextWindow: 258_400,
                        maxContextWindow: 400_000,
                        effectiveContextWindowPercent: 82,
                        defaultReasoningLevel: "xhigh",
                        supportsReasoningSummaries: true,
                        defaultReasoningSummary: "auto",
                        supportsVerbosity: true,
                        defaultVerbosity: "medium",
                        shellType: "default_shell",
                        applyPatchToolType: "apply_patch",
                        webSearchToolType: "web_search",
                        supportsParallelToolCalls: true,
                        supportsImageDetailOriginal: false,
                        supportsSearchTool: true,
                        truncationPolicyMode: "auto",
                        truncationPolicyLimit: 12_000,
                        reasoningLevels: [
                            CodexModelCapabilityReasoningLevel(position: 0, effort: "xhigh")!,
                        ],
                        serviceTiers: [],
                        speedTiers: [],
                        inputModalities: [],
                        toolIdentifiers: []
                    )!,
                ],
                cacheFetchedAt: date("2026-04-14T20:00:06Z"),
                clientVersion: "0.99.0"
            )
        )
        try store.recordCodexModelCapabilitiesCaptureState(
            CodexModelCapabilitiesCaptureState(lastCheckedAt: date("2026-04-14T20:00:06Z"), status: .imported, modelsInsertedCount: 1)
        )
        XCTAssertTrue(try store.hasAnyHistory())
        XCTAssertEqual(try store.codexSessionTokenImportFileRecords().count, 1)
        XCTAssertEqual(try store.sessionTaskTimingEvents().count, 1)
        XCTAssertEqual(try store.codexThreadCatalogThreads().count, 1)
        XCTAssertEqual(try store.codexModelCapabilities().count, 1)

        try store.clearHistory()

        XCTAssertTrue(try store.tokenUsageSamples().isEmpty)
        XCTAssertTrue(try store.codexSessionTokenImportFileRecords().isEmpty)
        XCTAssertTrue(try store.sessionTaskTimingEvents().isEmpty)
        XCTAssertNil(try store.codexSessionTaskTimingImportFileRecord(path: timingMetadata.path))
        XCTAssertEqual(try store.codexSessionTaskTimingCaptureState().status, .neverChecked)
        XCTAssertTrue(try store.codexThreadCatalogThreads().isEmpty)
        XCTAssertEqual(try store.codexThreadCatalogCaptureState().status, .neverChecked)
        XCTAssertTrue(try store.codexModelCapabilities().isEmpty)
        XCTAssertEqual(try store.codexModelCapabilitiesCaptureState().status, .neverChecked)
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
        try sourceStore.importSessionTaskTimingEvents([
            CodexSessionTaskTimingEvent(
                sessionID: "session-backup",
                turnID: "turn-backup",
                startedAt: date("2026-04-14T20:11:00Z"),
                completedAt: date("2026-04-14T20:11:04Z"),
                durationMilliseconds: 4_000,
                timeToFirstTokenMilliseconds: 700,
                modelContextWindow: 258_400,
                collaborationModeKind: "agentic",
                model: "gpt-5.5",
                projectPath: "/Users/example/Projects/backup-project",
                effort: "high",
                source: "cli",
                recordedAt: date("2026-04-14T20:11:04Z")
            )!,
        ])
        try sourceStore.recordCodexSessionTaskTimingCaptureState(
            CodexSessionTaskTimingCaptureState(
                lastCheckedAt: date("2026-04-14T20:11:05Z"),
                lastImportedEventAt: date("2026-04-14T20:11:04Z"),
                status: .imported,
                filesDiscovered: 1,
                filesScanned: 1,
                insertedCount: 1
            )
        )
        try sourceStore.importCodexThreadCatalog(
            CodexThreadCatalogImportBatch(
                threads: [
                    CodexThreadCatalogThread(
                        threadID: "thread-backup",
                        rolloutPath: "/tmp/rollout-backup.jsonl",
                        createdAt: date("2026-04-14T20:09:00Z"),
                        updatedAt: date("2026-04-14T20:12:00Z"),
                        source: "cli",
                        modelProvider: "openai",
                        cwd: "/Users/example/Projects/backup-project",
                        sandboxPolicy: "{\"type\":\"workspace-write\"}",
                        approvalMode: "on-request",
                        tokensUsed: 500,
                        hasUserEvent: true,
                        archived: false,
                        archivedAt: nil,
                        gitSHA: "abcdef",
                        gitBranch: "main",
                        gitOriginURL: "git@github.com:example/backup.git",
                        cliVersion: "0.42.0",
                        agentNickname: "helper",
                        agentRole: "default",
                        agentPath: "/tmp/agent.md",
                        memoryMode: "enabled",
                        model: "gpt-5.5",
                        reasoningEffort: "high",
                        threadSource: "cli"
                    )!,
                ],
                spawnEdges: [
                    CodexThreadSpawnEdge(parentThreadID: "thread-backup", childThreadID: "thread-child", status: "running")!,
                ],
                dynamicTools: [
                    CodexThreadDynamicTool(threadID: "thread-backup", position: 0, name: "list_prs", namespace: "github", deferLoading: true)!,
                ],
                pruneThreads: true,
                pruneSpawnEdges: true,
                pruneDynamicTools: true
            )
        )
        try sourceStore.recordCodexThreadCatalogCaptureState(
            CodexThreadCatalogCaptureState(
                lastCheckedAt: date("2026-04-14T20:12:05Z"),
                lastImportedThreadUpdatedAt: date("2026-04-14T20:12:00Z"),
                status: .imported,
                threadsInsertedCount: 1,
                spawnEdgesInsertedCount: 1,
                dynamicToolsInsertedCount: 1,
                sourcePath: "/Users/example/.codex/state_5.sqlite"
            )
        )
        try sourceStore.importCodexModelCapabilities(
            CodexModelCapabilitiesImportBatch(
                models: [
                    CodexModelCapability(
                        slug: "gpt-5.5",
                        displayName: "GPT-5.5",
                        visibility: "stable",
                        supportedInAPI: true,
                        priority: 1,
                        contextWindow: 258_400,
                        maxContextWindow: 400_000,
                        effectiveContextWindowPercent: 82,
                        defaultReasoningLevel: "xhigh",
                        supportsReasoningSummaries: true,
                        defaultReasoningSummary: "auto",
                        supportsVerbosity: true,
                        defaultVerbosity: "medium",
                        shellType: "default_shell",
                        applyPatchToolType: "apply_patch",
                        webSearchToolType: "web_search",
                        supportsParallelToolCalls: true,
                        supportsImageDetailOriginal: false,
                        supportsSearchTool: true,
                        truncationPolicyMode: "auto",
                        truncationPolicyLimit: 12_000,
                        reasoningLevels: [
                            CodexModelCapabilityReasoningLevel(position: 0, effort: "xhigh")!,
                        ],
                        serviceTiers: [
                            CodexModelCapabilityServiceTier(position: 0, tierID: "priority", tierName: "Priority")!,
                        ],
                        speedTiers: [
                            CodexModelCapabilitySpeedTier(position: 0, tierID: "fast")!,
                        ],
                        inputModalities: [
                            CodexModelCapabilityInputModality(position: 0, modality: "text")!,
                        ],
                        toolIdentifiers: [
                            CodexModelCapabilityToolIdentifier(position: 0, toolKind: "shell_type", toolValue: "default_shell")!,
                        ]
                    )!,
                ],
                cacheFetchedAt: date("2026-04-14T20:13:00Z"),
                clientVersion: "0.99.0"
            )
        )
        try sourceStore.recordCodexModelCapabilitiesCaptureState(
            CodexModelCapabilitiesCaptureState(
                lastCheckedAt: date("2026-04-14T20:13:05Z"),
                cacheFetchedAt: date("2026-04-14T20:13:00Z"),
                status: .imported,
                modelsInsertedCount: 1,
                childRowsInsertedCount: 4,
                clientVersion: "0.99.0",
                sourcePath: "/Users/example/.codex/models_cache.json"
            )
        )
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")

        try sourceStore.exportBackup(to: backupURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let (destinationStore, destinationDatabaseURL) = try makeTemporaryStore()
        try destinationStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 80)), at: date("2026-04-14T20:00:00Z"))

        try destinationStore.importBackup(from: backupURL)
        let points = try destinationStore.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [20])
        let tokenSamples = try destinationStore.tokenUsageSamples()
        XCTAssertEqual(tokenSamples.map(\.observedTotalTokens), [120])
        XCTAssertEqual(tokenSamples.first?.projectName, "backup-project")
        XCTAssertEqual(tokenSamples.first?.effort, "high")
        XCTAssertEqual(tokenSamples.first?.source, "cli")
        let timingEvent = try XCTUnwrap(try destinationStore.sessionTaskTimingEvents().first)
        XCTAssertEqual(timingEvent.sessionID, "session-backup")
        XCTAssertEqual(timingEvent.durationMilliseconds, 4_000)
        XCTAssertEqual(timingEvent.timeToFirstTokenMilliseconds, 700)
        XCTAssertEqual(timingEvent.projectName, "backup-project")
        XCTAssertEqual(
            try sqliteStrings(
                at: destinationDatabaseURL,
                sql: "SELECT CAST(event_timestamp AS TEXT) FROM codex_session_task_timing_events WHERE session_id = 'session-backup'"
            ),
            ["\(date("2026-04-14T20:11:00Z").timeIntervalSince1970Int)"]
        )
        XCTAssertEqual(try destinationStore.codexSessionTaskTimingCaptureState().status, .imported)
        let thread = try XCTUnwrap(try destinationStore.codexThreadCatalogThreads().first)
        XCTAssertEqual(thread.threadID, "thread-backup")
        XCTAssertEqual(thread.projectName, "backup-project")
        XCTAssertEqual(thread.sandboxPolicy, "workspace-write")
        XCTAssertEqual(try destinationStore.codexThreadSpawnEdges().first?.status, "running")
        XCTAssertEqual(try destinationStore.codexThreadDynamicTools().first?.namespace, "github")
        XCTAssertEqual(try destinationStore.codexThreadCatalogCaptureState().status, .imported)
        let model = try XCTUnwrap(try destinationStore.codexModelCapabilities().first)
        XCTAssertEqual(model.slug, "gpt-5.5")
        XCTAssertEqual(model.reasoningLevels.map(\.effort), ["xhigh"])
        XCTAssertEqual(model.serviceTiers.map(\.tierID), ["priority"])
        XCTAssertEqual(try destinationStore.codexModelCapabilitiesCaptureState().status, .imported)
        XCTAssertEqual(try destinationStore.availableSeries(window: .sevenDay).map(\.id), ["codex"])
        XCTAssertEqual(try destinationStore.availableTokenComponentSeries().map(\.id), ["tokens_all", "model:gpt-5.5"])
    }

    func testBackupImportReconstructsMissingSessionTaskTimingEventTimestamp() async throws {
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("legacy-backup.sqlite3")
        try createLegacyHistoryDatabase(at: backupURL)
        let completed = date("2026-04-14T20:11:04Z").timeIntervalSince1970Int
        let recorded = date("2026-04-14T20:11:05Z").timeIntervalSince1970Int
        try executeSQLite(
            at: backupURL,
            sql: """
            CREATE TABLE codex_session_task_timing_events (
                session_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                source_path TEXT,
                started_at INTEGER,
                completed_at INTEGER,
                duration_ms INTEGER,
                time_to_first_token_ms INTEGER,
                model_context_window INTEGER,
                collaboration_mode_kind TEXT,
                model TEXT,
                project_path TEXT,
                project_name TEXT,
                effort TEXT,
                source TEXT,
                dimensions_json TEXT,
                recorded_at INTEGER NOT NULL,
                PRIMARY KEY (session_id, turn_id)
            );
            INSERT INTO codex_session_task_timing_events (
                session_id, turn_id, completed_at, recorded_at
            ) VALUES ('session-legacy-backup', 'turn-a', \(completed), \(recorded));
            """
        )
        let (destinationStore, destinationDatabaseURL) = try makeTemporaryStore()

        try destinationStore.importBackup(from: backupURL)

        XCTAssertEqual(
            try sqliteStrings(
                at: destinationDatabaseURL,
                sql: "SELECT CAST(event_timestamp AS TEXT) FROM codex_session_task_timing_events WHERE session_id = 'session-legacy-backup'"
            ),
            ["\(completed)"]
        )
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

    func testBackupImportPreservesTokenDimensions() async throws {
        let (sourceStore, _) = try makeTemporaryStore()
        _ = try sourceStore.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    lastInput: 120,
                    lastTotal: 120,
                    totalInput: 120,
                    totalTotal: 120,
                    dimensions: [
                        TokenUsageDimension(.originator, "vscode"),
                        TokenUsageDimension(.usageMode, "/fast"),
                    ].compactMap(\.self)
                ),
                receivedAt: date("2026-04-14T20:10:00Z")
            ),
        ])
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")
        try sourceStore.exportBackup(to: backupURL)
        let (destinationStore, databaseURL) = try makeTemporaryStore()

        try destinationStore.importBackup(from: backupURL)

        XCTAssertEqual(
            try destinationStore.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" },
            ["originator=vscode", "usage_mode=fast"]
        )
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT dimension_key || '=' || dimension_value FROM token_usage_dimensions ORDER BY dimension_key"
            ),
            ["originator=vscode", "usage_mode=fast"]
        )
    }

    func testClearHistoryRemovesTokenDimensions() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    lastInput: 120,
                    lastTotal: 120,
                    totalInput: 120,
                    totalTotal: 120,
                    dimensions: [TokenUsageDimension(.usageMode, "fast")].compactMap(\.self)
                ),
                receivedAt: date("2026-04-14T20:10:00Z")
            ),
        ])

        try store.clearHistory()

        XCTAssertEqual(try store.tokenDimensionCatalogEntries(), [])
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "SELECT COUNT(*) FROM token_usage_dimensions"),
            ["0"]
        )
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "SELECT COUNT(*) FROM token_dimension_catalog"),
            ["0"]
        )
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
    func testTokenPayloadAuditStorePersistsExportsAndClears() throws {
        let auditURL = try makeTemporaryDirectory().appendingPathComponent("live-token-payload-audit.json")
        let store = CodexTokenPayloadAuditStore(fileURL: auditURL)
        let audit = tokenPayloadAudit()

        XCTAssertNil(store.latestAudit)

        switch store.record(audit) {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected audit persistence to succeed, got \(error)")
        }

        XCTAssertEqual(store.latestAudit, audit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: auditURL.path))

        let reloadedStore = CodexTokenPayloadAuditStore(fileURL: auditURL)
        XCTAssertEqual(reloadedStore.latestAudit, audit)
        XCTAssertTrue(try XCTUnwrap(reloadedStore.exportData()).contains(Data("gpt-5.5".utf8)))

        reloadedStore.clear()

        XCTAssertNil(reloadedStore.latestAudit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: auditURL.path))
    }

    @MainActor
    func testTokenPayloadAuditStoreReportsWriteFailureWithoutDroppingLatestAudit() throws {
        let blockedParentURL = try makeTemporaryDirectory().appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedParentURL)
        let auditURL = blockedParentURL.appendingPathComponent("live-token-payload-audit.json")
        let store = CodexTokenPayloadAuditStore(fileURL: auditURL)
        let audit = tokenPayloadAudit()

        switch store.record(audit) {
        case .success:
            XCTFail("Expected audit persistence to fail")
        case .failure:
            break
        }

        XCTAssertEqual(store.latestAudit, audit)
    }

    @MainActor
    func testPerformanceInstrumentationStoreRecordsSanitizesPrunesExportsAndClears() throws {
        var currentDate = date("2026-05-20T12:00:00Z")
        var uuidIndex = 0
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json")
        let store = AppPerformanceInstrumentationStore(
            fileURL: diagnosticsURL,
            now: { currentDate },
            makeUUID: {
                uuidIndex += 1
                return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", uuidIndex))!
            },
            retentionLimit: 2,
            retentionAge: 60
        )

        store.record(
            kind: .tokenDashboardReload,
            durationMilliseconds: 12,
            metadata: [
                "dashboard": "token",
                "breakdown": "model",
                "unsafe": "ignored",
                "surface": "/Users/example/private",
            ]
        )
        currentDate = currentDate.addingTimeInterval(1)
        let span = store.begin(.performanceDashboardReload, metadata: ["dashboard": "performance", "cacheHit": "false"])
        currentDate = currentDate.addingTimeInterval(0.25)
        store.finish(span, status: .success, metadata: ["rowCount": "7"])
        currentDate = currentDate.addingTimeInterval(1)
        store.record(kind: .menuPopoverOpenToContent, durationMilliseconds: 5)

        XCTAssertEqual(store.events.map(\.kind), [.performanceDashboardReload, .menuPopoverOpenToContent])
        XCTAssertEqual(store.events[0].metadata["dashboard"], "performance")
        XCTAssertEqual(store.events[0].metadata["rowCount"], "7")
        XCTAssertNil(store.events[0].metadata["unsafe"])
        XCTAssertNil(store.events[0].metadata["surface"])

        let exported = try XCTUnwrap(store.exportData())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AppPerformanceEvent].self, from: exported)
        XCTAssertEqual(decoded.count, 2)

        let summary = store.summary()
        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertEqual(summary.lastEvent?.kind, .menuPopoverOpenToContent)
        XCTAssertEqual(summary.rows.first?.kind, .performanceDashboardReload)

        store.clear()

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertNil(try store.exportData())
    }

    @MainActor
    func testPerformanceInstrumentationStoreRetainsRepresentativeSamplesByKind() throws {
        var currentDate = date("2026-05-20T12:00:00Z")
        var uuidIndex = 0
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json")
        let store = AppPerformanceInstrumentationStore(
            fileURL: diagnosticsURL,
            now: { currentDate },
            makeUUID: {
                uuidIndex += 1
                return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", uuidIndex))!
            },
            retentionLimit: 12,
            retentionAge: 3_600
        )

        for index in 0..<40 {
            store.record(kind: .historyReload, durationMilliseconds: Double(index))
            currentDate = currentDate.addingTimeInterval(1)
        }

        store.record(kind: .tokenDashboardReload, durationMilliseconds: 20)
        currentDate = currentDate.addingTimeInterval(1)
        store.record(kind: .performanceDashboardReload, durationMilliseconds: 30)
        currentDate = currentDate.addingTimeInterval(1)

        for index in 0..<20 {
            store.record(kind: .historyReload, durationMilliseconds: Double(index))
            currentDate = currentDate.addingTimeInterval(1)
        }

        XCTAssertEqual(store.events.count, 12)
        XCTAssertTrue(store.events.contains { $0.kind == .historyReload })
        XCTAssertTrue(store.events.contains { $0.kind == .tokenDashboardReload })
        XCTAssertTrue(store.events.contains { $0.kind == .performanceDashboardReload })
        XCTAssertEqual(store.events, store.events.sorted { $0.endedAt < $1.endedAt })
    }

    @MainActor
    func testPerformanceInstrumentationStorePrunesExpiredSamplesBeforeRepresentativeRetention() throws {
        var currentDate = date("2026-05-20T12:00:00Z")
        var uuidIndex = 0
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json")
        let store = AppPerformanceInstrumentationStore(
            fileURL: diagnosticsURL,
            now: { currentDate },
            makeUUID: {
                uuidIndex += 1
                return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", uuidIndex))!
            },
            retentionLimit: 12,
            retentionAge: 60
        )

        store.record(kind: .tokenDashboardReload, durationMilliseconds: 20)
        currentDate = currentDate.addingTimeInterval(61)
        store.record(kind: .historyReload, durationMilliseconds: 10)

        XCTAssertEqual(store.events.map(\.kind), [.historyReload])
    }

    @MainActor
    func testPerformanceSpanTrackerDiscardsCancelledSpansWithoutRecordingOutliers() throws {
        var currentDate = date("2026-05-20T12:00:00Z")
        var uuidIndex = 0
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json")
        let store = AppPerformanceInstrumentationStore(
            fileURL: diagnosticsURL,
            now: { currentDate },
            makeUUID: {
                uuidIndex += 1
                return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", uuidIndex))!
            }
        )
        let tracker = AppPerformanceSpanTracker(
            kind: .menuPopoverOpenToContent,
            instrumentationStore: store,
            baseMetadata: ["surface": "menuPopover"]
        )

        tracker.begin()
        currentDate = currentDate.addingTimeInterval(129)
        tracker.discardPendingSpan()
        tracker.finish(status: .success)

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertFalse(tracker.hasPendingSpan)

        tracker.begin()
        currentDate = currentDate.addingTimeInterval(0.125)
        tracker.finish(status: .success)

        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].kind, .menuPopoverOpenToContent)
        XCTAssertEqual(store.events[0].status, .success)
        XCTAssertEqual(store.events[0].metadata["surface"], "menuPopover")
        XCTAssertEqual(store.events[0].durationMilliseconds, 125, accuracy: 0.1)
    }

    @MainActor
    func testPerformanceInstrumentationStoreWriteFailureDoesNotBlockRecording() throws {
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json")
        try FileManager.default.createDirectory(at: diagnosticsURL, withIntermediateDirectories: true)
        let store = AppPerformanceInstrumentationStore(fileURL: diagnosticsURL)

        store.record(kind: .tokenDashboardReload, durationMilliseconds: 10)

        XCTAssertEqual(store.events.count, 1)
        XCTAssertNotNil(store.lastErrorText)
    }

    @MainActor
    func testAppServerAuditDiagnosticsStoreTracksPersistsAndClearsCaptureState() throws {
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("live-token-payload-audit-diagnostics.json")
        let store = CodexAppServerAuditDiagnosticsStore(fileURL: diagnosticsURL, now: { Date(timeIntervalSince1970: 1_777_100_000) })

        store.record(.connected(mode: .standardIO))
        store.record(.inboundMethod("thread/tokenUsage/updated"))
        store.record(.tokenUsageNotification)
        store.record(.auditSanitizeAttempt(success: true))
        store.record(.auditPersistAttempt(success: true, errorText: nil))

        XCTAssertTrue(store.diagnostics.isConnected)
        XCTAssertEqual(store.diagnostics.connectionMode, .standardIO)
        XCTAssertEqual(store.diagnostics.lastInboundMethod, "thread/tokenUsage/updated")
        XCTAssertEqual(store.diagnostics.tokenUsageNotificationCount, 1)
        XCTAssertEqual(store.diagnostics.auditSanitizeSuccessCount, 1)
        XCTAssertEqual(store.diagnostics.lastAuditPersistenceStatus, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticsURL.path))

        let reloadedStore = CodexAppServerAuditDiagnosticsStore(fileURL: diagnosticsURL)
        XCTAssertEqual(reloadedStore.diagnostics.tokenUsageNotificationCount, 1)
        XCTAssertEqual(reloadedStore.diagnostics.lastAuditPersistenceStatus, .succeeded)

        reloadedStore.clear()

        XCTAssertEqual(reloadedStore.diagnostics.tokenUsageNotificationCount, 0)
        XCTAssertEqual(reloadedStore.diagnostics.lastAuditPersistenceStatus, .notAttempted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnosticsURL.path))
    }

    @MainActor
    func testSettingsViewModelShowsExportsAndClearsTokenPayloadAudit() async throws {
        let (historyStore, _) = try makeTemporaryStore()
        let auditURL = try makeTemporaryDirectory().appendingPathComponent("live-token-payload-audit.json")
        let auditStore = CodexTokenPayloadAuditStore(fileURL: auditURL)
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("live-token-payload-audit-diagnostics.json")
        let diagnosticsStore = CodexAppServerAuditDiagnosticsStore(fileURL: diagnosticsURL)
        let viewModel = DataManagementSettingsViewModel(
            store: historyStore,
            defaults: makeIsolatedDefaults(),
            tokenPayloadAuditStore: auditStore,
            tokenPayloadAuditDiagnosticsStore: diagnosticsStore
        )
        let audit = tokenPayloadAudit()
        let exportURL = try makeTemporaryDirectory().appendingPathComponent("audit.json")

        XCTAssertFalse(viewModel.canExportTokenPayloadAudit)
        XCTAssertEqual(viewModel.tokenPayloadAuditCapturedAtText, "No capture yet")

        auditStore.record(audit)
        diagnosticsStore.record(.connected(mode: .standardIO))
        diagnosticsStore.record(.inboundMethod("thread/tokenUsage/updated"))
        diagnosticsStore.record(.tokenUsageNotification)
        diagnosticsStore.record(.auditSanitizeAttempt(success: true))
        diagnosticsStore.record(.auditPersistAttempt(success: true, errorText: nil))

        XCTAssertEqual(viewModel.tokenPayloadAudit, audit)
        XCTAssertTrue(viewModel.canExportTokenPayloadAudit)
        XCTAssertEqual(viewModel.tokenPayloadAuditDiagnosticsConnectionText, "Connected via stdio")
        XCTAssertEqual(viewModel.tokenPayloadAuditDiagnosticsLastMethodText, "thread/tokenUsage/updated")
        XCTAssertEqual(viewModel.tokenPayloadAuditDiagnosticsLastAuditStatusText, "Audit persisted")

        viewModel.exportTokenPayloadAudit(to: exportURL)

        XCTAssertEqual(viewModel.statusMessage, "Payload audit exported.")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        viewModel.clearTokenPayloadAudit()

        XCTAssertEqual(viewModel.statusMessage, "Payload audit cleared.")
        XCTAssertNil(viewModel.tokenPayloadAudit)
        XCTAssertFalse(viewModel.canExportTokenPayloadAudit)

        viewModel.clearTokenPayloadAuditDiagnostics()

        XCTAssertEqual(viewModel.statusMessage, "Capture diagnostics cleared.")
        XCTAssertEqual(viewModel.tokenPayloadAuditDiagnostics.tokenUsageNotificationCount, 0)
    }

    @MainActor
    func testSettingsViewModelShowsExportsAndClearsPerformanceDiagnostics() async throws {
        let (historyStore, _) = try makeTemporaryStore()
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json")
        let performanceStore = AppPerformanceInstrumentationStore(fileURL: diagnosticsURL)
        let viewModel = DataManagementSettingsViewModel(
            store: historyStore,
            defaults: makeIsolatedDefaults(),
            performanceInstrumentationStore: performanceStore
        )
        let exportURL = try makeTemporaryDirectory().appendingPathComponent("performance-export.json")

        XCTAssertFalse(viewModel.canExportPerformanceDiagnostics)
        XCTAssertEqual(viewModel.performanceDiagnosticsEventCountText, "0")

        performanceStore.record(kind: .performanceDashboardOpen, durationMilliseconds: 42, metadata: ["dashboard": "performance"])

        XCTAssertTrue(viewModel.canExportPerformanceDiagnostics)
        XCTAssertEqual(viewModel.performanceDiagnosticsEventCountText, "1")
        XCTAssertTrue(viewModel.performanceDiagnosticsLastEventText.contains("Performance dashboard open"))

        viewModel.exportPerformanceDiagnostics(to: exportURL)

        XCTAssertEqual(viewModel.statusMessage, "Performance diagnostics exported.")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        viewModel.clearPerformanceDiagnostics()

        XCTAssertEqual(viewModel.statusMessage, "Performance diagnostics cleared.")
        XCTAssertEqual(viewModel.performanceInstrumentationSummary.eventCount, 0)
        XCTAssertFalse(viewModel.canExportPerformanceDiagnostics)
    }

    @MainActor
    func testSettingsViewModelShowsLocalTokenCaptureState() async throws {
        let (store, _) = try makeTemporaryStore()
        try store.recordCodexLiveTokenCaptureState(
            CodexLiveTokenCaptureState(
                lastCheckedAt: date("2026-05-17T12:00:00Z"),
                lastImportedEventAt: date("2026-05-17T11:59:00Z"),
                lastLogRowID: 42,
                status: .imported,
                result: TokenUsageImportResult(
                    insertedCount: 2,
                    duplicateCount: 3,
                    repairedModelCount: 1,
                    repairedContextCount: 1,
                    repairedDimensionCount: 1
                )
            )
        )
        let viewModel = DataManagementSettingsViewModel(store: store, defaults: makeIsolatedDefaults())

        await viewModel.refreshData()

        XCTAssertEqual(viewModel.localTokenCaptureState.status, .imported)
        XCTAssertEqual(viewModel.localTokenCaptureState.lastLogRowID, 42)
        XCTAssertEqual(viewModel.localTokenCaptureResultText, "2 imported, 3 duplicate, 3 repaired")
        XCTAssertEqual(viewModel.localTokenCaptureLastErrorText, "None")
    }

    @MainActor
    func testSettingsViewModelShowsSessionTaskTimingCaptureState() async throws {
        let (store, _) = try makeTemporaryStore()
        try store.recordCodexSessionTaskTimingCaptureState(
            CodexSessionTaskTimingCaptureState(
                lastCheckedAt: Date(),
                lastImportedEventAt: date("2026-05-17T11:58:00Z"),
                status: .updated,
                filesDiscovered: 5,
                filesScanned: 2,
                filesSkippedUnchanged: 3,
                insertedCount: 1,
                updatedCount: 2,
                duplicateCount: 4,
                failedLinesSkipped: 1
            )
        )
        let viewModel = DataManagementSettingsViewModel(store: store, defaults: makeIsolatedDefaults())

        await viewModel.refreshData()

        XCTAssertEqual(viewModel.sessionTaskTimingCaptureState.status, .updated)
        XCTAssertEqual(viewModel.sessionTaskTimingCaptureState.filesDiscovered, 5)
        XCTAssertEqual(viewModel.sessionTaskTimingCaptureFilesText, "2 scanned, 3 skipped")
        XCTAssertEqual(viewModel.sessionTaskTimingCaptureResultText, "1 imported, 2 updated, 4 duplicate, 1 failed lines")
        XCTAssertEqual(viewModel.sessionTaskTimingCaptureLastErrorText, "None")
    }

    @MainActor
    func testSettingsViewModelShowsThreadCatalogCaptureState() async throws {
        let (store, _) = try makeTemporaryStore()
        try store.recordCodexThreadCatalogCaptureState(
            CodexThreadCatalogCaptureState(
                lastCheckedAt: date("2026-05-17T11:58:00Z"),
                lastImportedThreadUpdatedAt: date("2026-05-17T11:57:00Z"),
                status: .updated,
                threadsInsertedCount: 1,
                threadsUpdatedCount: 2,
                spawnEdgesInsertedCount: 3,
                spawnEdgesUpdatedCount: 4,
                dynamicToolsInsertedCount: 5,
                dynamicToolsUpdatedCount: 6,
                staleRowsDeletedCount: 7,
                sourcePath: "/Users/example/.codex/state_5.sqlite"
            )
        )
        let viewModel = DataManagementSettingsViewModel(store: store, defaults: makeIsolatedDefaults())

        await viewModel.refreshData()

        XCTAssertEqual(viewModel.threadCatalogCaptureState.status, .updated)
        XCTAssertEqual(viewModel.threadCatalogCaptureThreadsText, "1 imported, 2 updated")
        XCTAssertEqual(viewModel.threadCatalogCaptureRelationshipsText, "8 imported, 10 updated, 7 stale")
        XCTAssertEqual(viewModel.threadCatalogCaptureLastErrorText, "None")
    }

    @MainActor
    func testSettingsViewModelShowsModelCapabilitiesCaptureState() async throws {
        let (store, _) = try makeTemporaryStore()
        try store.recordCodexModelCapabilitiesCaptureState(
            CodexModelCapabilitiesCaptureState(
                lastCheckedAt: date("2026-05-17T11:58:00Z"),
                cacheFetchedAt: date("2026-05-17T11:57:00Z"),
                status: .updated,
                modelsInsertedCount: 1,
                modelsUpdatedCount: 2,
                childRowsInsertedCount: 3,
                staleRowsDeletedCount: 4,
                clientVersion: "0.99.0",
                sourcePath: "/Users/example/.codex/models_cache.json"
            )
        )
        let viewModel = DataManagementSettingsViewModel(store: store, defaults: makeIsolatedDefaults())

        await viewModel.refreshData()

        XCTAssertEqual(viewModel.modelCapabilitiesCaptureState.status, .updated)
        XCTAssertEqual(viewModel.modelCapabilitiesCaptureModelsText, "1 imported, 2 updated")
        XCTAssertEqual(viewModel.modelCapabilitiesCaptureDetailsText, "3 details imported, 4 stale")
        XCTAssertEqual(viewModel.modelCapabilitiesCaptureClientVersionText, "0.99.0")
        XCTAssertEqual(viewModel.modelCapabilitiesCaptureLastErrorText, "None")
    }

    @MainActor
    func testProfileTokenUsageStorePersistsBoundsAndFailureState() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("profile-token-usage.json")
        let store = CodexProfileTokenUsageStore(fileURL: fileURL, dailyBucketLimit: 2)
        let snapshot = CodexProfileTokenUsageSnapshot(
            fetchedAt: date("2026-05-30T12:00:00Z"),
            lifetimeTokens: 1_000,
            peakDailyTokens: 500,
            dailyBuckets: [
                CodexProfileTokenDailyBucket(date: "2026-05-28", tokens: 100),
                CodexProfileTokenDailyBucket(date: "2026-05-29", tokens: 200),
                CodexProfileTokenDailyBucket(date: "2026-05-30", tokens: 300),
            ]
        )

        store.recordSuccess(snapshot)

        XCTAssertEqual(store.state.status, .succeeded)
        XCTAssertEqual(store.state.snapshot?.dailyBuckets.map(\.date), ["2026-05-29", "2026-05-30"])

        let reloadedStore = CodexProfileTokenUsageStore(fileURL: fileURL, dailyBucketLimit: 2)
        XCTAssertEqual(reloadedStore.state.snapshot?.lifetimeTokens, 1_000)
        XCTAssertEqual(reloadedStore.state.snapshot?.dailyBuckets.map(\.tokens), [200, 300])

        reloadedStore.recordFailure("Profile refresh failed.")

        XCTAssertEqual(reloadedStore.state.status, .failed)
        XCTAssertEqual(reloadedStore.state.lastErrorText, "Profile refresh failed.")
        XCTAssertEqual(reloadedStore.state.snapshot?.dailyBuckets.map(\.tokens), [200, 300])
    }

    @MainActor
    func testSettingsViewModelRefreshesProfileTokensAndComparesLocalCapturedTotals() async throws {
        let (store, _) = try makeTemporaryStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 100,
                lastCached: 50,
                lastOutput: 7,
                lastReasoning: 3,
                lastTotal: 107,
                totalInput: 100,
                totalCached: 50,
                totalOutput: 7,
                totalReasoning: 3,
                totalTotal: 107
            ),
            at: date("2026-05-30T01:00:00Z")
        )
        let profileStore = CodexProfileTokenUsageStore(
            fileURL: try makeTemporaryDirectory().appendingPathComponent("profile-token-usage.json")
        )
        let profileClient = StubProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: date("2026-05-30T12:00:00Z"),
                    lifetimeTokens: 1_000,
                    peakDailyTokens: 500,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-05-30", tokens: 120),
                    ]
                )
            )
        )
        let viewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            profileTokenUsageStore: profileStore,
            profileTokenClient: profileClient,
            now: { self.date("2026-05-30T12:00:00Z") }
        )

        await viewModel.refreshProfileTokens()

        XCTAssertEqual(profileClient.requestCount, 1)
        XCTAssertEqual(viewModel.profileTokenStatusText, "Synced")
        XCTAssertEqual(viewModel.profileTokenPeakDailyText, "500")
        XCTAssertEqual(viewModel.profileTokenBucketCountText, "1")
        XCTAssertEqual(viewModel.profileTokenComparisonRows.map(\.profileTokens), [1_000, 120, 120])
        XCTAssertEqual(viewModel.profileTokenComparisonRows.map(\.localCapturedTokens), [160, 160, 160])
        XCTAssertEqual(viewModel.profileTokenComparisonRows.map(\.deltaTokens), [-840, 40, 40])
        XCTAssertEqual(viewModel.statusMessage, "Codex Profile tokens refreshed.")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testSettingsViewModelDoesNotAutoRefreshProfileTokensUnlessEnabled() async throws {
        let (store, _) = try makeTemporaryStore()
        let profileStore = CodexProfileTokenUsageStore(
            fileURL: try makeTemporaryDirectory().appendingPathComponent("profile-token-usage.json")
        )
        let profileClient = StubProfileTokenUsageClient(
            result: .failure(CodexClientError.authTokenUnavailable)
        )
        let viewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            profileTokenUsageStore: profileStore,
            profileTokenClient: profileClient,
            autoRefreshProfileTokens: false,
            now: { self.date("2026-05-30T12:00:00Z") }
        )

        await viewModel.refreshData()

        XCTAssertEqual(profileClient.requestCount, 0)
        XCTAssertEqual(viewModel.profileTokenStatusText, "Not synced")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testSettingsViewModelShowsProfileTokenRefreshFailure() async throws {
        let (store, _) = try makeTemporaryStore()
        let profileStore = CodexProfileTokenUsageStore(
            fileURL: try makeTemporaryDirectory().appendingPathComponent("profile-token-usage.json")
        )
        let profileClient = StubProfileTokenUsageClient(
            result: .failure(CodexClientError.authTokenUnavailable)
        )
        let viewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            profileTokenUsageStore: profileStore,
            profileTokenClient: profileClient
        )

        await viewModel.refreshProfileTokens()

        XCTAssertEqual(viewModel.profileTokenStatusText, "Failed")
        XCTAssertEqual(viewModel.profileTokenLastErrorText, "Codex auth is unavailable.")
        XCTAssertEqual(
            viewModel.errorMessage,
            "Codex Profile tokens could not be refreshed because Codex auth is unavailable."
        )
        XCTAssertNil(viewModel.statusMessage)
    }

    @MainActor
    func testCodexSourceHealthReaderCapturesSafeVersionSignalsAndStaleMetadata() async throws {
        let homeURL = try makeTemporaryDirectory()
        let codexDirectory = homeURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try Data(
            """
            {
              "client_version": "0.135.0",
              "fetched_at": "2026-05-30T19:24:22.281646Z",
              "models": [
                {"slug": "gpt-5.5", "base_instructions": "do not store me"},
                {"slug": "gpt-5.4", "model_messages": ["do not store me"]}
              ],
              "base_instructions": "do not store me"
            }
            """.utf8
        ).write(to: codexDirectory.appendingPathComponent("models_cache.json"))
        try Data(
            """
            {
              "latest_version": "0.128.0",
              "last_checked_at": "2026-05-05T02:25:24.357406Z",
              "ignored": "do not store me"
            }
            """.utf8
        ).write(to: codexDirectory.appendingPathComponent("version.json"))
        let appCodexURL = try makeExecutable("codex-app", in: homeURL)
        let homebrewCodexURL = try makeExecutable("codex-homebrew", in: homeURL)
        let runner = StubCodexSourceVersionCommandRunner(outputs: [
            appCodexURL.path: "codex-cli 0.135.0-alpha.1",
            homebrewCodexURL.path: "codex-cli 0.128.0",
        ])
        let reader = CodexSourceHealthReader(
            homeDirectory: homeURL,
            commandRunner: runner,
            metadataStalenessInterval: 7 * 24 * 60 * 60,
            executableCandidates: [
                CodexExecutableCandidate(url: appCodexURL, kind: .appBundled),
                CodexExecutableCandidate(url: homebrewCodexURL, kind: .homebrew),
            ],
            pathCandidates: []
        )

        let snapshot = try await reader.sourceHealthSnapshot(now: date("2026-05-31T12:00:00Z"))

        XCTAssertEqual(snapshot.status, .mismatch)
        XCTAssertEqual(snapshot.activeExecutablePath, appCodexURL.path)
        XCTAssertEqual(snapshot.appBundledSignal?.version, "0.135.0-alpha.1")
        XCTAssertEqual(snapshot.homebrewSignal?.version, "0.128.0")
        XCTAssertEqual(snapshot.modelsCacheClientVersion, "0.135.0")
        XCTAssertEqual(snapshot.modelsCacheModelCount, 2)
        XCTAssertEqual(snapshot.versionMetadataLatestVersion, "0.128.0")
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("differ") })
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("version.json") })
        XCTAssertFalse(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)?.contains("do not store me") ?? true)
    }

    @MainActor
    func testCodexSourceHealthReaderClassifiesMissingMalformedAndFailedStates() async throws {
        let homeURL = try makeTemporaryDirectory()
        let codexDirectory = homeURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: codexDirectory.appendingPathComponent("models_cache.json"))
        let missingURL = homeURL.appendingPathComponent("missing-codex")
        let missingReader = CodexSourceHealthReader(
            homeDirectory: homeURL,
            commandRunner: StubCodexSourceVersionCommandRunner(outputs: [:]),
            executableCandidates: [CodexExecutableCandidate(url: missingURL, kind: .appBundled)],
            pathCandidates: []
        )

        let missingSnapshot = try await missingReader.sourceHealthSnapshot(now: date("2026-05-31T12:00:00Z"))

        XCTAssertEqual(missingSnapshot.status, .missing)
        XCTAssertNil(missingSnapshot.activeExecutablePath)

        let malformedExecutableURL = try makeExecutable("codex-malformed", in: homeURL)
        let malformedReader = CodexSourceHealthReader(
            homeDirectory: homeURL,
            commandRunner: StubCodexSourceVersionCommandRunner(outputs: [
                malformedExecutableURL.path: "codex-cli 0.135.0",
            ]),
            executableCandidates: [CodexExecutableCandidate(url: malformedExecutableURL, kind: .appBundled)],
            pathCandidates: []
        )

        let malformedSnapshot = try await malformedReader.sourceHealthSnapshot(now: date("2026-05-31T12:00:00Z"))

        XCTAssertEqual(malformedSnapshot.status, .malformed)
        XCTAssertEqual(malformedSnapshot.modelsCacheErrorText, "Malformed JSON.")

        try Data(
            """
            {"client_version": "0.135.0", "fetched_at": "2026-05-31T12:00:00Z", "models": []}
            """.utf8
        ).write(to: codexDirectory.appendingPathComponent("models_cache.json"))
        let executableURL = try makeExecutable("codex-failing", in: homeURL)
        let failedReader = CodexSourceHealthReader(
            homeDirectory: homeURL,
            commandRunner: StubCodexSourceVersionCommandRunner(errors: [
                executableURL.path: CodexSourceHealthReaderError.versionCommandTimedOut,
            ]),
            executableCandidates: [CodexExecutableCandidate(url: executableURL, kind: .appBundled)],
            pathCandidates: []
        )

        let failedSnapshot = try await failedReader.sourceHealthSnapshot(now: date("2026-05-31T12:00:00Z"))

        XCTAssertEqual(failedSnapshot.status, .failed)
        XCTAssertEqual(failedSnapshot.appBundledSignal?.errorText, "Version command timed out.")
    }

    @MainActor
    func testCodexSourceHealthStorePersistsReloadsAndRefreshesOnlyWhenStale() async throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("codex-source-health.json")
        let firstSnapshot = codexSourceHealthSnapshot(
            checkedAt: date("2026-05-30T12:00:00Z"),
            status: .healthy
        )
        let secondSnapshot = codexSourceHealthSnapshot(
            checkedAt: date("2026-05-30T13:00:00Z"),
            status: .stale,
            warnings: ["version.json update metadata is stale."]
        )
        let reader = StubCodexSourceHealthReader(snapshots: [firstSnapshot, secondSnapshot])
        let store = CodexSourceHealthStore(fileURL: fileURL)

        await store.refresh(reader: reader, now: date("2026-05-30T12:00:00Z"))

        XCTAssertEqual(store.state.status, .healthy)
        XCTAssertEqual(reader.requestCount, 1)

        let reloadedStore = CodexSourceHealthStore(fileURL: fileURL)
        XCTAssertEqual(reloadedStore.state.status, .healthy)
        XCTAssertEqual(reloadedStore.state.snapshot?.activeExecutablePath, "/Applications/Codex.app/Contents/Resources/codex")

        await reloadedStore.refreshIfStale(
            reader: reader,
            now: date("2026-05-30T13:30:00Z"),
            staleAfter: 6 * 60 * 60
        )
        XCTAssertEqual(reader.requestCount, 1)

        await reloadedStore.refreshIfStale(
            reader: reader,
            now: date("2026-05-31T12:00:00Z"),
            staleAfter: 6 * 60 * 60
        )
        XCTAssertEqual(reader.requestCount, 2)
        XCTAssertEqual(reloadedStore.state.status, .stale)
        XCTAssertNotNil(reloadedStore.state.popoverWarningText)
    }

    @MainActor
    func testSettingsViewModelRefreshesCodexSourceHealth() async throws {
        let (store, _) = try makeTemporaryStore()
        let sourceHealthStore = CodexSourceHealthStore(
            fileURL: try makeTemporaryDirectory().appendingPathComponent("codex-source-health.json")
        )
        let reader = StubCodexSourceHealthReader(snapshots: [
            codexSourceHealthSnapshot(
                checkedAt: date("2026-05-31T12:00:00Z"),
                status: .mismatch,
                warnings: ["Codex version signals differ: App-bundled 0.135.0-alpha.1, Homebrew 0.128.0."]
            ),
        ])
        let viewModel = DataManagementSettingsViewModel(
            store: store,
            defaults: makeIsolatedDefaults(),
            codexSourceHealthStore: sourceHealthStore,
            codexSourceHealthReader: reader,
            now: { self.date("2026-05-31T12:00:00Z") }
        )

        await viewModel.refreshCodexSourceHealth()

        XCTAssertEqual(reader.requestCount, 1)
        XCTAssertEqual(viewModel.codexSourceHealthStatusText, "Version mismatch")
        XCTAssertEqual(viewModel.codexSourceHealthActiveVersionText, "0.135.0-alpha.1")
        XCTAssertEqual(viewModel.codexSourceHealthAppBundledVersionText, "0.135.0-alpha.1")
        XCTAssertEqual(viewModel.codexSourceHealthHomebrewVersionText, "0.128.0")
        XCTAssertTrue(viewModel.codexSourceHealthModelsCacheText.contains("0.135.0"))
        XCTAssertTrue(viewModel.codexSourceHealthVersionMetadataText.contains("0.128.0"))
        XCTAssertEqual(viewModel.statusMessage, "Codex version and source health refreshed.")
        XCTAssertNil(viewModel.errorMessage)
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

    private func tokenPayloadAudit() -> CodexTokenUsagePayloadAudit {
        CodexTokenUsagePayloadAudit(
            capturedAt: date("2026-05-19T12:00:00Z"),
            threadID: "thread-a",
            turnID: "turn-a",
            fields: [
                CodexTokenPayloadAuditField(
                    keyPath: "model",
                    category: .model,
                    presence: .present,
                    valueKind: "string",
                    sanitizedValue: "gpt-5.5",
                    normalizedValue: "gpt-5.5",
                    dimensionKey: nil,
                    dimensionValue: nil,
                    notes: []
                ),
                CodexTokenPayloadAuditField(
                    keyPath: "prompt",
                    category: .appSession,
                    presence: .rejected,
                    valueKind: "string",
                    sanitizedValue: nil,
                    normalizedValue: nil,
                    dimensionKey: nil,
                    dimensionValue: nil,
                    notes: ["Value rejected by safe normalizer."]
                ),
            ]
        )
    }

    private func makeExecutable(_ name: String, in directoryURL: URL) throws -> URL {
        let fileURL = directoryURL.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        return fileURL
    }

    private func codexSourceHealthSnapshot(
        checkedAt: Date,
        status: CodexSourceHealthStatus,
        warnings: [String] = []
    ) -> CodexSourceHealthSnapshot {
        CodexSourceHealthSnapshot(
            checkedAt: checkedAt,
            status: status,
            activeExecutablePath: "/Applications/Codex.app/Contents/Resources/codex",
            versionSignals: [
                CodexSourceVersionSignal(
                    kind: .appBundled,
                    executablePath: "/Applications/Codex.app/Contents/Resources/codex",
                    version: "0.135.0-alpha.1",
                    fileModifiedAt: checkedAt,
                    errorText: nil
                ),
                CodexSourceVersionSignal(
                    kind: .homebrew,
                    executablePath: "/opt/homebrew/bin/codex",
                    version: "0.128.0",
                    fileModifiedAt: checkedAt,
                    errorText: nil
                ),
            ],
            modelsCachePath: "/Users/example/.codex/models_cache.json",
            modelsCacheClientVersion: "0.135.0",
            modelsCacheFetchedAt: checkedAt,
            modelsCacheModelCount: 7,
            modelsCacheErrorText: nil,
            versionMetadataPath: "/Users/example/.codex/version.json",
            versionMetadataLatestVersion: "0.128.0",
            versionMetadataLastCheckedAt: checkedAt,
            versionMetadataErrorText: nil,
            warnings: warnings,
            errorText: nil
        )
    }

}

@MainActor
private final class StubProfileTokenUsageClient: CodexProfileTokenUsageFetching {
    private let result: Result<CodexProfileTokenUsageSnapshot, Error>
    private(set) var requestCount = 0

    init(result: Result<CodexProfileTokenUsageSnapshot, Error>) {
        self.result = result
    }

    func profileTokenUsageSnapshot() async throws -> CodexProfileTokenUsageSnapshot {
        requestCount += 1
        return try result.get()
    }
}

private final class StubCodexSourceVersionCommandRunner: CodexSourceVersionCommandRunning {
    private let outputs: [String: String]
    private let errors: [String: Error]

    init(outputs: [String: String] = [:], errors: [String: Error] = [:]) {
        self.outputs = outputs
        self.errors = errors
    }

    func versionOutput(for executableURL: URL, timeout: TimeInterval) async throws -> String {
        if let error = errors[executableURL.path] {
            throw error
        }

        return outputs[executableURL.path] ?? "codex-cli 0.135.0"
    }
}

private final class StubCodexSourceHealthReader: CodexSourceHealthReading {
    private var snapshots: [CodexSourceHealthSnapshot]
    private(set) var requestCount = 0

    init(snapshots: [CodexSourceHealthSnapshot]) {
        self.snapshots = snapshots
    }

    func sourceHealthSnapshot(now: Date) async throws -> CodexSourceHealthSnapshot {
        requestCount += 1
        if snapshots.count > 1 {
            return snapshots.removeFirst()
        }

        return snapshots[0]
    }
}
