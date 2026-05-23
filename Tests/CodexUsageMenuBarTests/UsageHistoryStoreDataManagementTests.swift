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
        let timingEvent = try XCTUnwrap(try destinationStore.sessionTaskTimingEvents().first)
        XCTAssertEqual(timingEvent.sessionID, "session-backup")
        XCTAssertEqual(timingEvent.durationMilliseconds, 4_000)
        XCTAssertEqual(timingEvent.timeToFirstTokenMilliseconds, 700)
        XCTAssertEqual(timingEvent.projectName, "backup-project")
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

}
