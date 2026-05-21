import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testRecordsAllTokenUsageFields() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 120,
                lastCached: 80,
                lastOutput: 40,
                lastReasoning: 12,
                lastTotal: 160,
                totalInput: 1_200,
                totalCached: 800,
                totalOutput: 400,
                totalReasoning: 120,
                totalTotal: 1_600,
                contextWindow: 258_400
            ),
            at: date("2026-04-14T20:00:00Z")
        )

        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.threadID, "thread-a")
        XCTAssertEqual(samples.first?.turnID, "turn-a")
        XCTAssertEqual(samples.first?.model, "gpt-5.5")
        XCTAssertNil(samples.first?.sessionID)
        XCTAssertNil(samples.first?.projectPath)
        XCTAssertNil(samples.first?.projectName)
        XCTAssertNil(samples.first?.effort)
        XCTAssertNil(samples.first?.source)
        XCTAssertEqual(samples.first?.modelContextWindow, 258_400)
        XCTAssertEqual(samples.first?.last.inputTokens, 120)
        XCTAssertEqual(samples.first?.last.cachedInputTokens, 80)
        XCTAssertEqual(samples.first?.last.outputTokens, 40)
        XCTAssertEqual(samples.first?.last.reasoningOutputTokens, 12)
        XCTAssertEqual(samples.first?.last.totalTokens, 160)
        XCTAssertEqual(samples.first?.total.inputTokens, 1_200)
        XCTAssertEqual(samples.first?.total.cachedInputTokens, 800)
        XCTAssertEqual(samples.first?.total.outputTokens, 400)
        XCTAssertEqual(samples.first?.total.reasoningOutputTokens, 120)
        XCTAssertEqual(samples.first?.total.totalTokens, 1_600)
        XCTAssertEqual(samples.first?.observedInputTokens, 120)
        XCTAssertEqual(samples.first?.observedCachedInputTokens, 80)
        XCTAssertEqual(samples.first?.observedOutputTokens, 40)
        XCTAssertEqual(samples.first?.observedReasoningOutputTokens, 12)
        XCTAssertEqual(samples.first?.observedTotalTokens, 160)
    }

    func testTokenUsageComputesObservedCategoryDeltas() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 100,
                lastCached: 20,
                lastOutput: 30,
                lastReasoning: 5,
                lastTotal: 155,
                totalInput: 1_000,
                totalCached: 200,
                totalOutput: 300,
                totalReasoning: 50,
                totalTotal: 1_550
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-b",
                lastInput: 90,
                lastCached: 30,
                lastOutput: 60,
                lastReasoning: 25,
                lastTotal: 205,
                totalInput: 1_100,
                totalCached: 230,
                totalOutput: 360,
                totalReasoning: 65,
                totalTotal: 1_755
            ),
            at: date("2026-04-14T20:10:00Z")
        )

        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(samples.map(\.observedInputTokens), [100, 100])
        XCTAssertEqual(samples.map(\.observedCachedInputTokens), [20, 30])
        XCTAssertEqual(samples.map(\.observedOutputTokens), [30, 60])
        XCTAssertEqual(samples.map(\.observedReasoningOutputTokens), [5, 15])
        XCTAssertEqual(samples.map(\.observedTotalTokens), [155, 205])
    }

    func testTokenUsageDeduplicatesRepeatedThreadTurnAndCumulativeTotal() async throws {
        let store = try makeStore()
        let notification = tokenNotification(
            threadID: "thread-a",
            turnID: "turn-a",
            lastTotal: 250,
            totalTotal: 2_000
        )

        try store.record(tokenUsage: notification, at: date("2026-04-14T20:00:00Z"))
        try store.record(tokenUsage: notification, at: date("2026-04-14T20:00:05Z"))

        XCTAssertEqual(try store.tokenUsageSamples().count, 1)
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 250)
    }

    func testTokenUsageReimportFillsMissingModelWithoutInflatingTotals() async throws {
        let store = try makeStore()
        let receivedAt = date("2026-04-14T20:00:00Z")
        let firstImport = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: nil,
                    lastTotal: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])
        let repairImport = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: " gpt-future-1 ",
                    lastTotal: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(firstImport, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(repairImport, TokenUsageImportResult(insertedCount: 0, duplicateCount: 1, repairedModelCount: 1))
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.model, "gpt-future-1")
        XCTAssertEqual(samples.first?.observedTotalTokens, 125)
        XCTAssertEqual(try store.availableTokenSeries(category: .total).map(\.id), ["tokens_all", "model:gpt-future-1"])
        XCTAssertEqual(try store.tokenTotalForDay(containing: receivedAt, calendar: calendar), 125)
    }

    func testTokenUsageReimportDoesNotClearExistingModel() async throws {
        let store = try makeStore()
        let receivedAt = date("2026-04-14T20:00:00Z")

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: "codex-stable-model",
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-b",
                    turnID: "turn-a",
                    model: " \tgpt-5.6\n ",
                    lastInput: 80,
                    lastTotal: 80,
                    totalInput: 80,
                    totalTotal: 80
                ),
                receivedAt: date("2026-04-14T20:05:00Z")
            ),
        ])
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: nil,
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])

        let samples = try store.tokenUsageSamples()
        let availableSeries = try store.availableTokenComponentSeries()

        XCTAssertEqual(samples.map(\.model), ["codex-stable-model", "gpt-5.6"])
        XCTAssertEqual(availableSeries.map(\.id), [
            "tokens_all",
            "model:codex-stable-model",
            "model:gpt-5.6",
        ])
    }

    func testTokenUsageImportStoresContextDimensionsAndCatalogs() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let receivedAt = date("2026-04-14T20:00:00Z")
        let context = TokenUsageContext(
            sessionID: "session-abc",
            projectPath: "/Users/example/Projects/codex_codex",
            effort: "xhigh",
            source: "cli"
        )

        let result = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-context",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 125,
                    lastCached: 25,
                    lastOutput: 10,
                    lastReasoning: 5,
                    lastTotal: 165,
                    totalInput: 125,
                    totalCached: 25,
                    totalOutput: 10,
                    totalReasoning: 5,
                    totalTotal: 165
                ),
                receivedAt: receivedAt,
                context: context
            ),
        ])

        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(result, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(samples.first?.sessionID, "session-abc")
        XCTAssertEqual(samples.first?.projectPath, "/Users/example/Projects/codex_codex")
        XCTAssertEqual(samples.first?.projectName, "codex_codex")
        XCTAssertEqual(samples.first?.effort, "xhigh")
        XCTAssertEqual(samples.first?.source, "cli")
        XCTAssertEqual(
            try sqliteStrings(at: databaseURL, sql: "SELECT project_path || '|' || project_name FROM token_project_catalog"),
            ["/Users/example/Projects/codex_codex|codex_codex"]
        )
        XCTAssertEqual(try sqliteStrings(at: databaseURL, sql: "SELECT effort FROM token_effort_catalog"), ["xhigh"])
        XCTAssertEqual(try sqliteStrings(at: databaseURL, sql: "SELECT source FROM token_source_catalog"), ["cli"])
    }

    func testTokenUsageImportStoresSafeDimensionsAndCatalog() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let receivedAt = date("2026-04-14T20:00:00Z")
        let dimensions = [
            TokenUsageDimension(.originator, "vscode"),
            TokenUsageDimension(.approvalPolicy, "never"),
            TokenUsageDimension(.sandboxType, "danger-full-access"),
            TokenUsageDimension(.usageMode, "/fast"),
            TokenUsageDimension.boolean(.isSubagent, true),
            TokenUsageDimension(.subagentParentThreadID, "019c-parent-thread"),
        ].compactMap(\.self)

        let result = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-dimensions",
                    turnID: "turn-a",
                    lastInput: 100,
                    lastCached: 25,
                    lastOutput: 10,
                    lastReasoning: 5,
                    lastTotal: 140,
                    totalInput: 100,
                    totalCached: 25,
                    totalOutput: 10,
                    totalReasoning: 5,
                    totalTotal: 140,
                    dimensions: dimensions
                ),
                receivedAt: receivedAt
            ),
        ])

        XCTAssertEqual(result, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: """
                SELECT dimension_key || '=' || dimension_value
                FROM token_usage_dimensions
                ORDER BY dimension_key, dimension_value
                """
            ),
            [
                "approval_policy=never",
                "is_subagent=true",
                "originator=vscode",
                "sandbox_type=danger-full-access",
                "subagent_parent_thread_id=019c-parent-thread",
                "usage_mode=fast",
            ]
        )
        XCTAssertEqual(
            try store.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" },
            [
                "approval_policy=never",
                "is_subagent=true",
                "originator=vscode",
                "sandbox_type=danger-full-access",
                "subagent_parent_thread_id=019c-parent-thread",
                "usage_mode=fast",
            ]
        )
    }

    func testTokenUsageReimportRepairsMissingContextWithoutInflatingTotals() async throws {
        let store = try makeStore()
        let receivedAt = date("2026-04-14T20:00:00Z")

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-context",
                    turnID: "turn-a",
                    lastInput: 100,
                    lastTotal: 100,
                    totalInput: 100,
                    totalTotal: 100
                ),
                receivedAt: receivedAt
            ),
        ])

        let repairResult = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-context",
                    turnID: "turn-a",
                    lastInput: 100,
                    lastTotal: 100,
                    totalInput: 100,
                    totalTotal: 100
                ),
                receivedAt: receivedAt,
                context: TokenUsageContext(
                    sessionID: "session-context",
                    projectPath: "/Users/example/Projects/context-project",
                    effort: "high",
                    source: "vscode"
                )
            ),
        ])

        let sample = try XCTUnwrap(store.tokenUsageSamples().first)

        XCTAssertEqual(repairResult, TokenUsageImportResult(insertedCount: 0, duplicateCount: 1, repairedContextCount: 1))
        XCTAssertEqual(sample.projectName, "context-project")
        XCTAssertEqual(sample.effort, "high")
        XCTAssertEqual(sample.source, "vscode")
        XCTAssertEqual(sample.observedTotalTokens, 100)
        XCTAssertEqual(try store.tokenTotalForDay(containing: receivedAt, calendar: calendar), 100)
    }

    func testTokenUsageReimportRepairsMissingDimensionsWithoutInflatingTotals() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let receivedAt = date("2026-04-14T20:00:00Z")

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-dimension-repair",
                    turnID: "turn-a",
                    lastInput: 100,
                    lastTotal: 100,
                    totalInput: 100,
                    totalTotal: 100
                ),
                receivedAt: receivedAt
            ),
        ])

        let repairResult = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-dimension-repair",
                    turnID: "turn-a",
                    lastInput: 100,
                    lastTotal: 100,
                    totalInput: 100,
                    totalTotal: 100,
                    dimensions: [
                        TokenUsageDimension(.threadSource, "cli"),
                        TokenUsageDimension(.usageMode, "fast"),
                    ].compactMap(\.self)
                ),
                receivedAt: receivedAt
            ),
        ])

        XCTAssertEqual(
            repairResult,
            TokenUsageImportResult(insertedCount: 0, duplicateCount: 1, repairedDimensionCount: 2)
        )
        XCTAssertEqual(try store.tokenTotalForDay(containing: receivedAt, calendar: calendar), 100)
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT dimension_key || '=' || dimension_value FROM token_usage_dimensions ORDER BY dimension_key"
            ),
            ["thread_source=cli", "usage_mode=fast"]
        )
    }

    func testTokenDimensionCleanupMigrationNormalizesAndDropsUnsafeRows() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let databaseURL = directoryURL.appendingPathComponent("usage-history.sqlite3")
        var store: UsageHistoryStore? = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        try store?.record(
            tokenUsage: tokenNotification(
                threadID: "thread-cleanup",
                turnID: "turn-a",
                lastInput: 100,
                lastTotal: 100,
                totalInput: 100,
                totalTotal: 100
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        store = nil
        let timestamp = Int64(date("2026-04-14T20:00:00Z").timeIntervalSince1970)
        try executeSQLite(
            at: databaseURL,
            sql: """
            INSERT INTO token_usage_dimensions (
                thread_id, turn_id, total_total_tokens, dimension_key, dimension_value, seen_at
            ) VALUES
                ('thread-cleanup', 'turn-a', 100, 'usage_mode', '/fast', \(timestamp)),
                ('thread-cleanup', 'turn-a', 100, 'source_kind', '/Users/example/session.jsonl', \(timestamp)),
                ('thread-cleanup', 'turn-a', 100, 'instructions', 'do not store this', \(timestamp));
            DELETE FROM usage_history_metadata WHERE key = 'token_dimension_cleanup_version';
            """
        )

        let reopenedStore = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )

        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT dimension_key || '=' || dimension_value FROM token_usage_dimensions ORDER BY dimension_key"
            ),
            ["usage_mode=fast"]
        )
        XCTAssertEqual(
            try reopenedStore.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" },
            ["usage_mode=fast"]
        )
        XCTAssertEqual(try reopenedStore.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 100)
    }

    func testTokenUsageImportRejectsUnsafeContextValues() async throws {
        let store = try makeStore()

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-unsafe",
                    turnID: "turn-a",
                    lastInput: 100,
                    lastTotal: 100,
                    totalInput: 100,
                    totalTotal: 100
                ),
                receivedAt: date("2026-04-14T20:00:00Z"),
                context: TokenUsageContext(
                    sessionID: "/Users/example/session.jsonl",
                    projectPath: "/Users/example/project}:trace_span",
                    effort: "high/unsafe",
                    source: "cli\nprompt"
                )
            ),
        ])

        let sample = try XCTUnwrap(store.tokenUsageSamples().first)

        XCTAssertNil(sample.sessionID)
        XCTAssertNil(sample.projectPath)
        XCTAssertNil(sample.projectName)
        XCTAssertNil(sample.effort)
        XCTAssertEqual(sample.source, "cli")
    }

    func testTokenUsageReimportRepairsMalformedExistingModelWithoutInflatingTotals() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let receivedAt = date("2026-04-14T20:00:00Z")

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: nil,
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])
        try executeSQLite(
            at: databaseURL,
            sql: """
            UPDATE token_usage_samples
            SET model = 'gpt-5.5
            Tests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:'
            WHERE thread_id = 'thread-a';
            """
        )

        let repairImport = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-a",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
                    totalTotal: 125
                ),
                receivedAt: receivedAt
            ),
        ])

        XCTAssertEqual(repairImport, TokenUsageImportResult(insertedCount: 0, duplicateCount: 1, repairedModelCount: 1))
        XCTAssertEqual(try store.tokenUsageSamples().map(\.model), ["gpt-5.5"])
        XCTAssertEqual(try store.tokenTotalForDay(containing: receivedAt, calendar: calendar), 125)
        XCTAssertEqual(try store.availableTokenSeries(category: .total).map(\.id), ["tokens_all", "model:gpt-5.5"])
    }

    func testTokenUsageComputesSameThreadCumulativeDeltas() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 250, totalTotal: 2_000),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-b", lastTotal: 400, totalTotal: 2_500),
            at: date("2026-04-14T20:10:00Z")
        )

        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(samples.map(\.observedTotalTokens), [250, 500])
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 750)
    }

    func testTokenUsageFirstObservedSampleUsesLastTotalInsteadOfCumulativeTotal() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-late", lastTotal: 600, totalTotal: 12_000),
            at: date("2026-04-14T20:00:00Z")
        )

        XCTAssertEqual(try store.tokenUsageSamples().first?.observedTotalTokens, 600)
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 600)
    }

    func testTokenHistoryPointsIncludeAggregateAndModelSeries() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastTotal: 120,
                totalTotal: 120
            ),
            at: date("2026-04-14T20:00:00Z")
        )

        let points = try store.tokenPoints(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let series = try store.tokenSeries(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )

        XCTAssertEqual(points.map(\.seriesID), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(points.map(\.seriesName), ["All tokens", "gpt-5.5"])
        XCTAssertEqual(points.map(\.seriesKind), [.aggregate, .model])
        XCTAssertEqual(points.map(\.tokenCount), [120, 120])
        XCTAssertEqual(series.map(\.id), ["tokens_all", "model:gpt-5.5"])
    }

    func testAvailableTokenSeriesIncludesTrackedModelsOutsideSelectedPeriod() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastTotal: 120,
                totalTotal: 120
            ),
            at: date("2026-04-13T20:00:00Z")
        )

        let emptyCurrentDayPoints = try store.tokenPoints(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let availableSeries = try store.availableTokenSeries(category: .total)

        XCTAssertEqual(emptyCurrentDayPoints, [])
        XCTAssertEqual(availableSeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(availableSeries.map(\.name), ["All tokens", "gpt-5.5"])
    }

    func testTokenModelSeriesTrimWhitespaceAndDeduplicate() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5\n",
                lastInput: 80,
                lastCached: 20,
                lastOutput: 10,
                lastReasoning: 2,
                lastTotal: 112,
                totalInput: 80,
                totalCached: 20,
                totalOutput: 10,
                totalReasoning: 2,
                totalTotal: 112
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                model: " gpt-5.5 ",
                lastInput: 120,
                lastCached: 40,
                lastOutput: 20,
                lastReasoning: 4,
                lastTotal: 184,
                totalInput: 120,
                totalCached: 40,
                totalOutput: 20,
                totalReasoning: 4,
                totalTotal: 184
            ),
            at: date("2026-04-14T20:05:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-c",
                turnID: "turn-a",
                model: "gpt-5.5\nTests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:",
                lastInput: 60,
                lastCached: 10,
                lastOutput: 8,
                lastReasoning: 2,
                lastTotal: 80,
                totalInput: 60,
                totalCached: 10,
                totalOutput: 8,
                totalReasoning: 2,
                totalTotal: 80
            ),
            at: date("2026-04-14T20:10:00Z")
        )

        let points = try store.tokenPoints(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let componentPoints = try store.tokenComponentPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let availableSeries = try store.availableTokenSeries(category: .total)
        let availableComponentSeries = try store.availableTokenComponentSeries()

        XCTAssertFalse(points.contains { $0.seriesName.contains("\n") })
        XCTAssertFalse(componentPoints.contains { $0.seriesName.contains("\n") })
        XCTAssertEqual(Set(points.map(\.seriesID)), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(Set(componentPoints.map(\.seriesID)), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(availableSeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(availableSeries.map(\.name), ["All tokens", "gpt-5.5"])
        XCTAssertEqual(availableComponentSeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(availableComponentSeries.map(\.name), ["All tokens", "gpt-5.5"])
    }

    func testTokenComponentPointsIncludeAggregateAndModelSeries() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 120,
                lastCached: 80,
                lastOutput: 30,
                lastReasoning: 10,
                lastTotal: 240,
                totalInput: 120,
                totalCached: 80,
                totalOutput: 30,
                totalReasoning: 10,
                totalTotal: 240
            ),
            at: date("2026-04-14T20:00:00Z")
        )

        let points = try store.tokenComponentPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let availableSeries = try store.availableTokenComponentSeries()
        let bounds = try store.tokenComponentHistoryBounds()

        XCTAssertEqual(points.map(\.seriesID), [
            "tokens_all",
            "tokens_all",
            "tokens_all",
            "tokens_all",
            "model:gpt-5.5",
            "model:gpt-5.5",
            "model:gpt-5.5",
            "model:gpt-5.5",
        ])
        XCTAssertEqual(points.map(\.component), [
            .input,
            .cached,
            .output,
            .reasoning,
            .input,
            .cached,
            .output,
            .reasoning,
        ])
        XCTAssertEqual(points.map(\.tokenCount), [120, 80, 30, 10, 120, 80, 30, 10])
        XCTAssertEqual(availableSeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(bounds?.earliest, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(bounds?.latest, date("2026-04-14T20:00:00Z"))
    }

    func testTokenComponentBucketPointsAggregateSamplesInSQLite() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastCached: 40,
                lastOutput: 20,
                lastReasoning: 5,
                lastTotal: 165,
                totalInput: 100,
                totalCached: 40,
                totalOutput: 20,
                totalReasoning: 5,
                totalTotal: 165
            ),
            at: date("2026-04-14T20:10:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                model: "gpt-5.4",
                lastInput: 50,
                lastCached: 10,
                lastOutput: 30,
                lastReasoning: 2,
                lastTotal: 92,
                totalInput: 50,
                totalCached: 10,
                totalOutput: 30,
                totalReasoning: 2,
                totalTotal: 92
            ),
            at: date("2026-04-14T20:25:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-c",
                turnID: "turn-a",
                lastInput: 25,
                lastTotal: 25,
                totalInput: 25,
                totalTotal: 25
            ),
            at: date("2026-04-14T21:05:00Z")
        )

        let points = try store.tokenComponentBucketPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z"),
            now: date("2026-04-14T22:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(Set(points.map(\.seriesID)), ["tokens_all"])
        XCTAssertEqual(points.map(\.bucketStart), [
            date("2026-04-14T20:00:00Z"),
            date("2026-04-14T20:00:00Z"),
            date("2026-04-14T20:00:00Z"),
            date("2026-04-14T20:00:00Z"),
            date("2026-04-14T21:00:00Z"),
        ])
        XCTAssertEqual(points.map(\.component), [.input, .cached, .output, .reasoning, .input])
        XCTAssertEqual(points.map(\.tokenCount), [150, 50, 50, 7, 25])
        XCTAssertEqual(
            points.filter { $0.bucketStart == date("2026-04-14T20:00:00Z") }.map(\.latestSampleTimestamp),
            Array(repeating: date("2026-04-14T20:25:00Z"), count: 4)
        )
    }

    func testTokenComponentBucketPointsUseCalendarBucketsForAllRanges() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastInput: 100, lastTotal: 100, totalInput: 100, totalTotal: 100),
            at: date("2026-01-10T12:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-b", turnID: "turn-a", lastInput: 200, lastTotal: 200, totalInput: 200, totalTotal: 200),
            at: date("2026-04-14T12:10:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-c", turnID: "turn-a", lastInput: 300, lastTotal: 300, totalInput: 300, totalTotal: 300),
            at: date("2026-04-15T09:00:00Z")
        )

        let dayPoints = try store.tokenComponentBucketPoints(
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z"),
            now: date("2026-04-14T21:00:00Z"),
            calendar: calendar
        )
        let weekPoints = try store.tokenComponentBucketPoints(
            range: .week,
            periodStart: date("2026-04-12T00:00:00Z"),
            periodEnd: date("2026-04-19T00:00:00Z"),
            now: date("2026-04-17T21:00:00Z"),
            calendar: calendar
        )
        let monthPoints = try store.tokenComponentBucketPoints(
            range: .month,
            periodStart: date("2026-04-01T00:00:00Z"),
            periodEnd: date("2026-05-01T00:00:00Z"),
            now: date("2026-04-30T21:00:00Z"),
            calendar: calendar
        )
        let yearPoints = try store.tokenComponentBucketPoints(
            range: .year,
            periodStart: date("2026-01-01T00:00:00Z"),
            periodEnd: date("2027-01-01T00:00:00Z"),
            now: date("2026-12-31T21:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(dayPoints.map(\.bucketStart), [date("2026-04-14T12:00:00Z")])
        XCTAssertEqual(dayPoints.map(\.tokenCount), [200])
        XCTAssertEqual(weekPoints.map(\.bucketStart), [date("2026-04-14T00:00:00Z"), date("2026-04-15T00:00:00Z")])
        XCTAssertEqual(weekPoints.map(\.tokenCount), [200, 300])
        XCTAssertEqual(monthPoints.map(\.bucketStart), [date("2026-04-14T00:00:00Z"), date("2026-04-15T00:00:00Z")])
        XCTAssertEqual(monthPoints.map(\.tokenCount), [200, 300])
        XCTAssertEqual(yearPoints.map(\.bucketStart), [date("2026-01-01T00:00:00Z"), date("2026-04-01T00:00:00Z")])
        XCTAssertEqual(yearPoints.map(\.tokenCount), [100, 500])
    }

    func testTokenComponentBucketPointsReturnEmptyRowsForEmptyPeriods() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastInput: 100, lastTotal: 100, totalInput: 100, totalTotal: 100),
            at: date("2026-04-14T20:00:00Z")
        )

        let points = try store.tokenComponentBucketPoints(
            range: .day,
            periodStart: date("2026-04-15T00:00:00Z"),
            periodEnd: date("2026-04-16T00:00:00Z"),
            now: date("2026-04-16T00:00:00Z"),
            calendar: calendar
        )

        XCTAssertTrue(points.isEmpty)
    }

    func testTokenDashboardPointsAggregateComponentsModelsAndUnattributedRows() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastCached: 40,
                lastOutput: 20,
                lastReasoning: 5,
                lastTotal: 165,
                totalInput: 100,
                totalCached: 40,
                totalOutput: 20,
                totalReasoning: 5,
                totalTotal: 165
            ),
            at: date("2026-05-02T10:15:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                lastInput: 50,
                lastCached: 10,
                lastOutput: 30,
                lastReasoning: 2,
                lastTotal: 92,
                totalInput: 50,
                totalCached: 10,
                totalOutput: 30,
                totalReasoning: 2,
                totalTotal: 92
            ),
            at: date("2026-05-02T11:15:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-c",
                turnID: "turn-a",
                model: "future-model",
                lastInput: 200,
                lastCached: 80,
                lastOutput: 25,
                lastReasoning: 7,
                lastTotal: 312,
                totalInput: 200,
                totalCached: 80,
                totalOutput: 25,
                totalReasoning: 7,
                totalTotal: 312
            ),
            at: date("2026-05-03T09:15:00Z")
        )

        let points = try store.tokenDashboardPoints(
            range: .month,
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z")
        )
        let series = try store.tokenDashboardSeries()

        XCTAssertEqual(series.map(\.id), [
            "tokens_all",
            "model:future-model",
            "model:gpt-5.5",
            "tokens_unattributed",
        ])
        XCTAssertEqual(series.map(\.name), ["All captured", "future-model", "gpt-5.5", "Unattributed"])
        XCTAssertEqual(
            dashboardTokenCount(points, seriesID: "tokens_all", component: .input, bucketStart: date("2026-05-02T00:00:00Z")),
            150
        )
        XCTAssertEqual(
            dashboardTokenCount(points, seriesID: "model:gpt-5.5", component: .cached, bucketStart: date("2026-05-02T00:00:00Z")),
            40
        )
        XCTAssertEqual(
            dashboardTokenCount(points, seriesID: "tokens_unattributed", component: .output, bucketStart: date("2026-05-02T00:00:00Z")),
            30
        )
        XCTAssertEqual(
            dashboardTokenCount(points, seriesID: "model:future-model", component: .reasoning, bucketStart: date("2026-05-03T00:00:00Z")),
            7
        )
    }

    func testTokenDashboardPointsGroupByEffortAndProject() async throws {
        let store = try makeStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-high",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 165,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 165
                ),
                receivedAt: date("2026-05-02T10:15:00Z"),
                context: TokenUsageContext(
                    sessionID: "session-high",
                    projectPath: "/Users/example/Projects/codex_codex",
                    effort: "high",
                    source: "cli",
                    dimensions: [
                        TokenUsageDimension(.approvalPolicy, "never"),
                        TokenUsageDimension.boolean(.isSubagent, false),
                    ].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-medium",
                    turnID: "turn-a",
                    model: "gpt-5.4",
                    lastInput: 60,
                    lastCached: 10,
                    lastOutput: 8,
                    lastReasoning: 2,
                    lastTotal: 80,
                    totalInput: 60,
                    totalCached: 10,
                    totalOutput: 8,
                    totalReasoning: 2,
                    totalTotal: 80
                ),
                receivedAt: date("2026-05-02T11:15:00Z"),
                context: TokenUsageContext(
                    sessionID: "session-medium",
                    projectPath: "/Users/example/Other/codex_codex",
                    effort: "medium",
                    source: "cli",
                    dimensions: [
                        TokenUsageDimension(.approvalPolicy, "on-request"),
                        TokenUsageDimension.boolean(.isSubagent, true),
                    ].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-unattributed",
                    turnID: "turn-a",
                    lastInput: 30,
                    lastCached: 5,
                    lastOutput: 7,
                    lastReasoning: 1,
                    lastTotal: 43,
                    totalInput: 30,
                    totalCached: 5,
                    totalOutput: 7,
                    totalReasoning: 1,
                    totalTotal: 43
                ),
                receivedAt: date("2026-05-02T12:15:00Z")
            ),
        ])

        let effortPoints = try store.tokenDashboardPoints(
            breakdownDimension: .effort,
            range: .month,
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z")
        )
        let effortSeries = try store.tokenDashboardSeries(breakdownDimension: .effort)
        let projectPoints = try store.tokenDashboardPoints(
            breakdownDimension: .project,
            range: .month,
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z")
        )
        let projectSeries = try store.tokenDashboardSeries(breakdownDimension: .project)

        XCTAssertEqual(effortSeries.map(\.id), ["tokens_all", "effort:high", "effort:medium", "tokens_unattributed"])
        XCTAssertEqual(
            dashboardTokenCount(effortPoints, seriesID: "effort:high", component: .input, bucketStart: date("2026-05-02T00:00:00Z")),
            100
        )
        XCTAssertEqual(
            dashboardTokenCount(effortPoints, seriesID: "effort:medium", component: .cached, bucketStart: date("2026-05-02T00:00:00Z")),
            10
        )
        XCTAssertEqual(
            dashboardTokenCount(effortPoints, seriesID: "tokens_unattributed", component: .output, bucketStart: date("2026-05-02T00:00:00Z")),
            7
        )

        XCTAssertEqual(projectSeries.map(\.id), [
            "tokens_all",
            "project:/Users/example/Other/codex_codex",
            "project:/Users/example/Projects/codex_codex",
            "tokens_unattributed",
        ])
        XCTAssertEqual(projectSeries.first { $0.id == "project:/Users/example/Other/codex_codex" }?.name, "codex_codex (Other)")
        XCTAssertEqual(projectSeries.first { $0.id == "project:/Users/example/Projects/codex_codex" }?.name, "codex_codex (Projects)")
        XCTAssertEqual(projectSeries.first { $0.id == "project:/Users/example/Projects/codex_codex" }?.projectPath, "/Users/example/Projects/codex_codex")
        XCTAssertEqual(
            dashboardTokenCount(projectPoints, seriesID: "project:/Users/example/Projects/codex_codex", component: .reasoning, bucketStart: date("2026-05-02T00:00:00Z")),
            5
        )
        XCTAssertEqual(
            dashboardTokenCount(projectPoints, seriesID: "tokens_unattributed", component: .input, bucketStart: date("2026-05-02T00:00:00Z")),
            30
        )
    }

    func testTokenDashboardPointsGroupByGenericDimensions() async throws {
        let store = try makeStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-never",
                    turnID: "turn-a",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 165,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 165
                ),
                receivedAt: date("2026-05-02T10:15:00Z"),
                context: TokenUsageContext(
                    dimensions: [
                        TokenUsageDimension(.approvalPolicy, "never"),
                        TokenUsageDimension(.sandboxType, "danger-full-access"),
                        TokenUsageDimension(.sourceKind, "cli"),
                        TokenUsageDimension.boolean(.isSubagent, false),
                        TokenUsageDimension(.agentRole, "default"),
                        TokenUsageDimension(.usageMode, "/fast"),
                    ].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-request",
                    turnID: "turn-a",
                    lastInput: 60,
                    lastCached: 10,
                    lastOutput: 8,
                    lastReasoning: 2,
                    lastTotal: 80,
                    totalInput: 60,
                    totalCached: 10,
                    totalOutput: 8,
                    totalReasoning: 2,
                    totalTotal: 80
                ),
                receivedAt: date("2026-05-02T11:15:00Z"),
                context: TokenUsageContext(
                    dimensions: [
                        TokenUsageDimension(.approvalPolicy, "on-request"),
                        TokenUsageDimension(.sandboxType, "workspace-write"),
                        TokenUsageDimension(.sourceKind, "vscode"),
                        TokenUsageDimension.boolean(.isSubagent, true),
                        TokenUsageDimension(.agentRole, "worker"),
                        TokenUsageDimension(.usageMode, "normal"),
                    ].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-unattributed",
                    turnID: "turn-a",
                    lastInput: 30,
                    lastCached: 5,
                    lastOutput: 7,
                    lastReasoning: 1,
                    lastTotal: 43,
                    totalInput: 30,
                    totalCached: 5,
                    totalOutput: 7,
                    totalReasoning: 1,
                    totalTotal: 43
                ),
                receivedAt: date("2026-05-02T12:15:00Z")
            ),
        ])

        let approvalSeries = try store.tokenDashboardSeries(breakdownDimension: .approvalPolicy)
        let approvalPoints = try store.tokenDashboardPoints(
            breakdownDimension: .approvalPolicy,
            range: .month,
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z")
        )
        let subagentSeries = try store.tokenDashboardSeries(breakdownDimension: .isSubagent)
        let modeSeries = try store.tokenDashboardSeries(breakdownDimension: .usageMode)

        XCTAssertEqual(approvalSeries.map(\.id), [
            "tokens_all",
            "dimension:approval_policy:never",
            "dimension:approval_policy:on-request",
            "tokens_unattributed",
        ])
        XCTAssertEqual(approvalSeries.first { $0.id == "dimension:approval_policy:never" }?.dimensionKey, .approvalPolicy)
        XCTAssertEqual(subagentSeries.map(\.name), ["All captured", "No", "Yes", "Unattributed"])
        XCTAssertEqual(modeSeries.map(\.id), [
            "tokens_all",
            "dimension:usage_mode:fast",
            "dimension:usage_mode:normal",
            "tokens_unattributed",
        ])
        XCTAssertEqual(
            dashboardTokenCount(approvalPoints, seriesID: "dimension:approval_policy:never", component: .input, bucketStart: date("2026-05-02T00:00:00Z")),
            100
        )
        XCTAssertEqual(
            dashboardTokenCount(approvalPoints, seriesID: "dimension:approval_policy:on-request", component: .cached, bucketStart: date("2026-05-02T00:00:00Z")),
            10
        )
        XCTAssertEqual(
            dashboardTokenCount(approvalPoints, seriesID: "tokens_unattributed", component: .output, bucketStart: date("2026-05-02T00:00:00Z")),
            7
        )
        XCTAssertEqual(
            dashboardTokenCount(approvalPoints, seriesID: "tokens_all", component: .input, bucketStart: date("2026-05-02T00:00:00Z")),
            190
        )
    }

    func testTokenDashboardDimensionQueryDoesNotDoubleCountConflictingDimensionRows() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 100,
                lastTotal: 100,
                totalInput: 100,
                totalTotal: 100
            ),
            at: date("2026-05-02T10:15:00Z")
        )
        try executeSQLite(
            at: databaseURL,
            sql: """
            INSERT INTO token_usage_dimensions (
                thread_id, turn_id, total_total_tokens, dimension_key, dimension_value, seen_at
            ) VALUES
                ('thread-a', 'turn-a', 100, 'approval_policy', 'never', \(Int64(date("2026-05-02T10:15:00Z").timeIntervalSince1970))),
                ('thread-a', 'turn-a', 100, 'approval_policy', 'on-request', \(Int64(date("2026-05-02T10:16:00Z").timeIntervalSince1970)));
            """
        )

        let points = try store.tokenDashboardPoints(
            breakdownDimension: .approvalPolicy,
            range: .month,
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z")
        )

        let aggregateInput = dashboardTokenCount(
            points,
            seriesID: "tokens_all",
            component: .input,
            bucketStart: date("2026-05-02T00:00:00Z")
        )
        let dimensionInput = points
            .filter { $0.seriesKind == .dimension && $0.component == .input }
            .reduce(Int64(0)) { $0 + $1.tokenCount }

        XCTAssertEqual(aggregateInput, 100)
        XCTAssertEqual(dimensionInput, 100)
    }

    func testTokenAttributionCoverageRowsMeasureTokenVolumeByDimension() async throws {
        let store = try makeStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-attributed",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 165,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 165
                ),
                receivedAt: date("2026-05-02T10:15:00Z"),
                context: TokenUsageContext(
                    projectPath: "/Users/example/Projects/codex_codex",
                    effort: "xhigh",
                    source: "cli",
                    dimensions: [
                        TokenUsageDimension(.approvalPolicy, "never"),
                        TokenUsageDimension(.sourceKind, "cli"),
                    ].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-model-only",
                    turnID: "turn-a",
                    model: "gpt-5.4",
                    lastInput: 60,
                    lastCached: 10,
                    lastOutput: 8,
                    lastReasoning: 2,
                    lastTotal: 80,
                    totalInput: 60,
                    totalCached: 10,
                    totalOutput: 8,
                    totalReasoning: 2,
                    totalTotal: 80
                ),
                receivedAt: date("2026-05-02T11:15:00Z"),
                context: TokenUsageContext(
                    dimensions: [TokenUsageDimension(.sourceKind, "codex-log")].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-unattributed",
                    turnID: "turn-a",
                    lastInput: 30,
                    lastCached: 5,
                    lastOutput: 7,
                    lastReasoning: 1,
                    lastTotal: 43,
                    totalInput: 30,
                    totalCached: 5,
                    totalOutput: 7,
                    totalReasoning: 1,
                    totalTotal: 43
                ),
                receivedAt: date("2026-05-02T12:15:00Z")
            ),
        ])

        let rows = try store.tokenAttributionCoverageRows(
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z")
        )
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        XCTAssertEqual(rowsByID["model"]?.attributedTokenCount, 245)
        XCTAssertEqual(rowsByID["model"]?.missingTokenCount, 43)
        XCTAssertEqual(rowsByID["model"]?.totalTokenCount, 288)
        XCTAssertEqual(rowsByID["model"]?.distinctValueCount, 2)
        XCTAssertEqual(rowsByID["project"]?.attributedTokenCount, 165)
        XCTAssertEqual(rowsByID["project"]?.missingTokenCount, 123)
        XCTAssertEqual(rowsByID["effort"]?.attributedTokenCount, 165)
        XCTAssertEqual(rowsByID["source"]?.attributedTokenCount, 165)
        XCTAssertEqual(rowsByID["dimension:approval_policy"]?.attributedTokenCount, 165)
        XCTAssertEqual(rowsByID["dimension:source_kind"]?.attributedTokenCount, 165)
        XCTAssertEqual(rowsByID["dimension:source_kind"]?.missingTokenCount, 123)
        XCTAssertEqual(rowsByID["dimension:source_kind"]?.distinctValueCount, 1)
        XCTAssertNil(rowsByID["dimension:usage_mode"])
        XCTAssertEqual(rowsByID["model"]?.attributedPercent ?? 0, 245.0 / 288.0, accuracy: 0.0001)
    }

    func testTokenSeriesDiscoveryReadsFromCatalog() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        try executeSQLite(
            at: databaseURL,
            sql: """
            INSERT INTO token_series_catalog (
                series_id, series_name, series_kind, seen_at,
                has_total, has_input, has_cached, has_output, has_reasoning
            ) VALUES
                ('tokens_all', 'All tokens', 'aggregate', \(Int64(date("2026-05-03T09:00:00Z").timeIntervalSince1970)), 1, 1, 1, 0, 0),
                ('model:gpt-5.5', 'gpt-5.5', 'model', \(Int64(date("2026-05-03T09:01:00Z").timeIntervalSince1970)), 1, 1, 0, 0, 0),
                ('tokens_unattributed', 'Unattributed', 'unattributed', \(Int64(date("2026-05-03T09:02:00Z").timeIntervalSince1970)), 0, 1, 0, 0, 0);
            INSERT INTO token_effort_catalog (effort, first_seen_at, last_seen_at)
            VALUES ('high', \(Int64(date("2026-05-03T09:00:00Z").timeIntervalSince1970)), \(Int64(date("2026-05-03T09:00:00Z").timeIntervalSince1970)));
            INSERT INTO token_project_catalog (project_path, project_name, first_seen_at, last_seen_at)
            VALUES ('/Users/example/Projects/codex_codex', 'codex_codex', \(Int64(date("2026-05-03T09:00:00Z").timeIntervalSince1970)), \(Int64(date("2026-05-03T09:00:00Z").timeIntervalSince1970)));
            INSERT INTO token_dimension_catalog (dimension_key, dimension_value, first_seen_at, last_seen_at)
            VALUES ('approval_policy', 'never', \(Int64(date("2026-05-03T09:00:00Z").timeIntervalSince1970)), \(Int64(date("2026-05-03T09:00:00Z").timeIntervalSince1970)));
            """
        )

        let dashboardSeries = try store.tokenDashboardSeries()
        let effortSeries = try store.tokenDashboardSeries(breakdownDimension: .effort)
        let projectSeries = try store.tokenDashboardSeries(breakdownDimension: .project)
        let approvalPolicySeries = try store.tokenDashboardSeries(breakdownDimension: .approvalPolicy)
        let availableBreakdowns = try store.tokenDashboardAvailableBreakdownDimensions()
        let historySeries = try store.availableTokenComponentSeries()
        let rawSamples = try store.tokenUsageSamples()

        XCTAssertEqual(rawSamples, [])
        XCTAssertEqual(dashboardSeries.map(\.id), ["tokens_all", "model:gpt-5.5", "tokens_unattributed"])
        XCTAssertEqual(dashboardSeries.map(\.name), ["All captured", "gpt-5.5", "Unattributed"])
        XCTAssertEqual(effortSeries.map(\.id), ["tokens_all", "effort:high", "tokens_unattributed"])
        XCTAssertEqual(projectSeries.map(\.id), ["tokens_all", "project:/Users/example/Projects/codex_codex", "tokens_unattributed"])
        XCTAssertEqual(approvalPolicySeries.map(\.id), ["tokens_all", "dimension:approval_policy:never", "tokens_unattributed"])
        XCTAssertEqual(availableBreakdowns, [.model, .effort, .project, .approvalPolicy])
        XCTAssertEqual(historySeries.map(\.id), ["tokens_all", "model:gpt-5.5"])
    }

    func testTokenDashboardAvailableBreakdownsHideUncatalogedAndLowSignalDimensions() async throws {
        let store = try makeStore()
        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastTotal: 100,
                totalInput: 100,
                totalTotal: 100
            ),
            at: date("2026-05-03T09:00:00Z")
        )

        XCTAssertEqual(try store.tokenDashboardAvailableBreakdownDimensions(), [.model])
        XCTAssertEqual(
            try store.tokenDashboardAvailableBreakdownDimensions(periodStart: periodStart, periodEnd: periodEnd),
            [.model]
        )

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-b",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 50,
                    lastTotal: 50,
                    totalInput: 50,
                    totalTotal: 50
                ),
                receivedAt: date("2026-05-03T10:00:00Z"),
                context: TokenUsageContext(
                    dimensions: [TokenUsageDimension(.sourceKind, "codex-log")].compactMap { $0 }
                )
            ),
        ])

        XCTAssertEqual(try store.tokenDashboardAvailableBreakdownDimensions(), [.model])
        XCTAssertEqual(
            try store.tokenDashboardAvailableBreakdownDimensions(periodStart: periodStart, periodEnd: periodEnd),
            [.model]
        )
        XCTAssertEqual(
            try store.tokenDashboardSeries(breakdownDimension: .sourceKind).map(\.id),
            ["tokens_all", "tokens_unattributed"]
        )

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-outside-period",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 75,
                    lastTotal: 75,
                    totalInput: 75,
                    totalTotal: 75
                ),
                receivedAt: date("2026-06-03T11:00:00Z"),
                context: TokenUsageContext(
                    dimensions: [TokenUsageDimension(.sourceKind, "cli")].compactMap { $0 }
                )
            ),
        ])

        XCTAssertEqual(try store.tokenDashboardAvailableBreakdownDimensions(), [.model, .sourceKind])
        XCTAssertEqual(
            try store.tokenDashboardAvailableBreakdownDimensions(periodStart: periodStart, periodEnd: periodEnd),
            [.model]
        )

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-c",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 25,
                    lastTotal: 25,
                    totalInput: 25,
                    totalTotal: 25
                ),
                receivedAt: date("2026-05-03T11:00:00Z"),
                context: TokenUsageContext(
                    dimensions: [TokenUsageDimension(.sourceKind, "vscode")].compactMap { $0 }
                )
            ),
        ])

        XCTAssertEqual(try store.tokenDashboardAvailableBreakdownDimensions(), [.model, .sourceKind])
        XCTAssertEqual(
            try store.tokenDashboardAvailableBreakdownDimensions(periodStart: periodStart, periodEnd: periodEnd),
            [.model, .sourceKind]
        )
        XCTAssertEqual(
            try store.tokenDashboardSeries(
                breakdownDimension: .sourceKind,
                periodStart: periodStart,
                periodEnd: periodEnd
            ).map(\.id),
            ["tokens_all", "dimension:source_kind:vscode", "tokens_unattributed"]
        )
        XCTAssertFalse(
            try store.tokenDashboardAvailableBreakdownDimensions(periodStart: periodStart, periodEnd: periodEnd)
                .contains(.isSubagent)
        )

        let sourceKindPoints = try store.tokenDashboardPoints(
            breakdownDimension: .sourceKind,
            range: .month,
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        XCTAssertEqual(
            dashboardTokenCount(
                sourceKindPoints,
                seriesID: "dimension:source_kind:vscode",
                component: .input,
                bucketStart: date("2026-05-03T00:00:00Z")
            ),
            25
        )
        XCTAssertNil(
            dashboardTokenCount(
                sourceKindPoints,
                seriesID: "dimension:source_kind:codex-log",
                component: .input,
                bucketStart: date("2026-05-03T00:00:00Z")
            )
        )
        XCTAssertEqual(
            dashboardTokenCount(
                sourceKindPoints,
                seriesID: TokenDashboardSeries.unattributedID,
                component: .input,
                bucketStart: date("2026-05-03T00:00:00Z")
            ),
            150
        )
    }

    @MainActor
    func testTokenDashboardViewModelDefaultsFiltersAndExportsVisibleRows() async throws {
        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastCached: 40,
                lastOutput: 20,
                lastReasoning: 5,
                lastTotal: 165,
                totalInput: 100,
                totalCached: 40,
                totalOutput: 20,
                totalReasoning: 5,
                totalTotal: 165
            ),
            at: date("2026-05-02T10:15:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                model: "gpt-5.4",
                lastInput: 30,
                lastCached: 10,
                lastOutput: 8,
                lastReasoning: 2,
                lastTotal: 50,
                totalInput: 30,
                totalCached: 10,
                totalOutput: 8,
                totalReasoning: 2,
                totalTotal: 50
            ),
            at: date("2026-05-03T10:15:00Z")
        )

        let viewModel = TokenDashboardViewModel(
            store: store,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedRange, .month)
        XCTAssertEqual(viewModel.selectedBreakdownDimension, .model)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 215)
        XCTAssertEqual(viewModel.exportFilename, "codex-token-dashboard-month-2026-05.csv")
        XCTAssertEqual(viewModel.compactSeriesTitle("gpt-5.4-mini"), "5.4 Mini")
        XCTAssertEqual(viewModel.compactSeriesTitle("Unattributed"), "Unattributed")
        XCTAssertEqual(viewModel.formattedTokenValue(6_495_500_000), "6.5B")
        XCTAssertEqual(viewModel.formattedTokenValue(3_318_500_000), "3.3B")
        XCTAssertEqual(viewModel.formattedTokenValue(42_800), "42.8k")
        XCTAssertEqual(viewModel.formattedTokenValue(900), "900")
        XCTAssertFalse(viewModel.formattedTokenValue(6_495_500_000).contains("tok"))
        XCTAssertEqual(viewModel.formattedYAxisValue(10_000), "10,000")
        XCTAssertEqual(viewModel.formattedYAxisValue(1_200_000_000), "1.2B")
        XCTAssertTrue(viewModel.csvText.contains("model,month,2026-05-01T00:00:00Z,2026-06-01T00:00:00Z,2026-05-02T00:00:00Z,2026-05-03T00:00:00Z,tokens_all,All captured,aggregate,all,All captured,,input,100"))
        XCTAssertTrue(viewModel.csvText.contains("coverage_dimension,dimension_title,attributed_tokens,missing_tokens,total_tokens,attributed_percent,distinct_values,dimension_key"))
        XCTAssertTrue(viewModel.csvText.contains("model,Model,215,0,215,1.0000,2,"))

        viewModel.selectSeries("model:gpt-5.5")

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["model:gpt-5.5"])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 165)
        XCTAssertFalse(viewModel.csvText.contains("model:gpt-5.4"))
        XCTAssertTrue(viewModel.csvText.contains("model:gpt-5.5,gpt-5.5,model,gpt-5.5,gpt-5.5,,input,100"))
    }

    @MainActor
    func testTokenDashboardViewModelSwitchesBreakdownDimensionAndFiltersRows() async throws {
        let store = try makeStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-high",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 165,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 165
                ),
                receivedAt: date("2026-05-02T10:15:00Z"),
                context: TokenUsageContext(
                    sessionID: "session-high",
                    projectPath: "/Users/example/Projects/codex_codex",
                    effort: "high",
                    source: "cli",
                    dimensions: [
                        TokenUsageDimension(.approvalPolicy, "never"),
                        TokenUsageDimension.boolean(.isSubagent, false),
                    ].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-medium",
                    turnID: "turn-a",
                    model: "gpt-5.4",
                    lastInput: 30,
                    lastCached: 10,
                    lastOutput: 8,
                    lastReasoning: 2,
                    lastTotal: 50,
                    totalInput: 30,
                    totalCached: 10,
                    totalOutput: 8,
                    totalReasoning: 2,
                    totalTotal: 50
                ),
                receivedAt: date("2026-05-03T10:15:00Z"),
                context: TokenUsageContext(
                    sessionID: "session-medium",
                    projectPath: "/Users/example/Other/codex_codex",
                    effort: "medium",
                    source: "cli",
                    dimensions: [
                        TokenUsageDimension(.approvalPolicy, "on-request"),
                        TokenUsageDimension.boolean(.isSubagent, true),
                    ].compactMap { $0 }
                )
            ),
        ])

        let viewModel = TokenDashboardViewModel(
            store: store,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        let coverageRowsByID = Dictionary(uniqueKeysWithValues: viewModel.attributionCoverageRows.map { ($0.id, $0) })
        XCTAssertEqual(coverageRowsByID["model"]?.attributedTokenCount, 215)
        XCTAssertEqual(coverageRowsByID["project"]?.attributedTokenCount, 215)
        XCTAssertEqual(coverageRowsByID["effort"]?.attributedTokenCount, 215)
        XCTAssertEqual(coverageRowsByID["source"]?.attributedTokenCount, 215)
        XCTAssertEqual(coverageRowsByID["dimension:approval_policy"]?.distinctValueCount, 2)
        XCTAssertEqual(coverageRowsByID["dimension:is_subagent"]?.distinctValueCount, 2)

        viewModel.sortAttributionCoverageRows(by: .dimension)
        XCTAssertEqual(viewModel.sortedAttributionCoverageRows.first?.title, "Approval policy")

        viewModel.sortAttributionCoverageRows(by: .dimension)
        XCTAssertEqual(viewModel.sortedAttributionCoverageRows.first?.title, "Subagent")

        viewModel.selectedBreakdownDimension = .effort
        await viewModel.reload()

        XCTAssertEqual(viewModel.breakdownColumnTitle, "Effort")
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertEqual(viewModel.breakdownRows.map(\.series.id), ["tokens_all", "effort:high", "effort:medium"])
        XCTAssertEqual(
            viewModel.breakdownPercentOfTotal(for: try XCTUnwrap(viewModel.breakdownRows.first { $0.series.id == "effort:high" })),
            165.0 / 215.0,
            accuracy: 0.0001
        )

        viewModel.sortBreakdownRows(by: .total)
        XCTAssertEqual(viewModel.breakdownRows.map(\.series.id), ["tokens_all", "effort:high", "effort:medium"])

        viewModel.sortBreakdownRows(by: .total)
        XCTAssertEqual(viewModel.breakdownRows.map(\.series.id), ["effort:medium", "effort:high", "tokens_all"])

        viewModel.sortBreakdownRows(by: .title)
        XCTAssertEqual(viewModel.breakdownRows.map(\.series.id), ["tokens_all", "effort:high", "effort:medium"])

        viewModel.selectSeries("effort:high")

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["effort:high"])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 165)
        XCTAssertTrue(viewModel.csvText.contains("effort,month"))
        XCTAssertTrue(viewModel.csvText.contains("effort:high,high,effort,high,high,,input,100"))

        viewModel.selectSeries(TokenDashboardSeries.aggregateID)
        XCTAssertEqual(viewModel.selectedSeriesIDs, [TokenDashboardSeries.aggregateID])

        try store.updateTokenProjectDisplayName(
            projectPath: "/Users/example/Projects/codex_codex",
            displayName: "Main Work"
        )
        viewModel.selectedBreakdownDimension = .project
        await viewModel.reload()

        XCTAssertEqual(viewModel.breakdownColumnTitle, "Project")
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertTrue(viewModel.breakdownRows.contains { $0.series.name == "Main Work" })

        viewModel.selectSeries("project:/Users/example/Projects/codex_codex")

        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 165)
        XCTAssertTrue(viewModel.csvText.contains("project,month"))
        XCTAssertTrue(viewModel.csvText.contains("project:/Users/example/Projects/codex_codex,Main Work,project,/Users/example/Projects/codex_codex,Main Work,/Users/example/Projects/codex_codex,input,100"))

        viewModel.selectedBreakdownDimension = .approvalPolicy
        await viewModel.reload()

        XCTAssertEqual(viewModel.breakdownColumnTitle, "Approval policy")
        XCTAssertTrue(viewModel.availableBreakdownDimensions.contains(.approvalPolicy))
        XCTAssertFalse(viewModel.availableBreakdownDimensions.contains(.agentNickname))
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertEqual(viewModel.breakdownRows.map(\.series.id), [
            "tokens_all",
            "dimension:approval_policy:never",
            "dimension:approval_policy:on-request",
        ])

        viewModel.selectSeries("dimension:approval_policy:never")

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["dimension:approval_policy:never"])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 165)
        XCTAssertTrue(viewModel.csvText.contains("approval_policy,month"))
        XCTAssertTrue(viewModel.csvText.contains("dimension:approval_policy:never,never,dimension,never,never,,input,100,approval_policy"))

        viewModel.selectedRange = .day
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedBreakdownDimension, .model)
        XCTAssertTrue(viewModel.attributionCoverageRows.isEmpty)
    }

    @MainActor
    func testTokenDashboardNavigationBoundsAndEmptyStates() async throws {
        let emptyViewModel = TokenDashboardViewModel(
            store: try makeStore(),
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await emptyViewModel.reload()

        XCTAssertEqual(emptyViewModel.emptyState.title, "No token data yet")
        XCTAssertFalse(emptyViewModel.canGoToPreviousPeriod)

        let store = try makeStore()
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                lastInput: 100,
                lastTotal: 100,
                totalInput: 100,
                totalTotal: 100
            ),
            at: date("2026-04-14T10:00:00Z")
        )
        let viewModel = TokenDashboardViewModel(
            store: store,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        XCTAssertTrue(viewModel.canGoToPreviousPeriod)
        XCTAssertFalse(viewModel.canGoToNextPeriod)

        viewModel.goToPreviousPeriod()
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-01T00:00:00Z"))
        XCTAssertTrue(viewModel.hasVisiblePoints)
        XCTAssertTrue(viewModel.canGoToNextPeriod)

        viewModel.goToNextPeriod()
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(viewModel.emptyState.title, "No tokens for this selection")
    }

    func testTokenTotalForDayUsesLocalCalendarDay() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-a", turnID: "turn-a", lastTotal: 100, totalTotal: 100),
            at: date("2026-04-13T23:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(threadID: "thread-b", turnID: "turn-a", lastTotal: 200, totalTotal: 200),
            at: date("2026-04-14T20:00:00Z")
        )

        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 200)
        XCTAssertNil(try store.tokenTotalForDay(containing: date("2026-04-15T21:00:00Z"), calendar: calendar))
    }

    func testTokenCategoryTotalsForDaySumsObservedCategories() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 100,
                lastCached: 25,
                lastOutput: 40,
                lastReasoning: 5,
                lastTotal: 145,
                totalInput: 1_000,
                totalCached: 250,
                totalOutput: 400,
                totalReasoning: 50,
                totalTotal: 1_450
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-b",
                lastInput: 80,
                lastCached: 30,
                lastOutput: 50,
                lastReasoning: 15,
                lastTotal: 175,
                totalInput: 1_150,
                totalCached: 280,
                totalOutput: 450,
                totalReasoning: 65,
                totalTotal: 1_625
            ),
            at: date("2026-04-14T21:00:00Z")
        )

        let totals = try store.tokenCategoryTotalsForDay(
            containing: date("2026-04-14T22:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 250,
                cachedInputTokens: 55,
                outputTokens: 90,
                reasoningOutputTokens: 20,
                totalTokens: 320
            )
        )
    }

    func testTokenCategoryTotalsForDayReturnsNilWithoutSamples() async throws {
        let store = try makeStore()

        XCTAssertNil(
            try store.tokenCategoryTotalsForDay(
                containing: date("2026-04-14T22:00:00Z"),
                calendar: calendar
            )
        )
    }

    func testTokenCategoryTotalsForDayDeduplicatesRepeatedNotifications() async throws {
        let store = try makeStore()
        let notification = tokenNotification(
            threadID: "thread-a",
            turnID: "turn-a",
            lastInput: 100,
            lastCached: 20,
            lastOutput: 30,
            lastReasoning: 5,
            lastTotal: 155,
            totalInput: 100,
            totalCached: 20,
            totalOutput: 30,
            totalReasoning: 5,
            totalTotal: 155
        )

        try store.record(tokenUsage: notification, at: date("2026-04-14T20:00:00Z"))
        try store.record(tokenUsage: notification, at: date("2026-04-14T20:00:05Z"))

        XCTAssertEqual(
            try store.tokenCategoryTotalsForDay(containing: date("2026-04-14T22:00:00Z"), calendar: calendar),
            TokenCategoryTotals(
                inputTokens: 100,
                cachedInputTokens: 20,
                outputTokens: 30,
                reasoningOutputTokens: 5,
                totalTokens: 155
            )
        )
    }

    func testCodexLogTokenImporterImportsTodayResponseCompletedCategories() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let body = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=146059 output_token_count=37 cached_token_count=145280 reasoning_token_count=0 tool_token_count=146096 event.timestamp=2026-05-17T12:48:13.035Z conversation.id=019dd6bb-c26b-72c2-bb51-0fff5324362a model=gpt-5.5 slug=gpt-5.5 source=desktop usage_mode=/fast approval_policy=never sandbox_type=danger-full-access permission_profile=full
        """
        let duplicateBody = body + " user.email=\"private@example.com\""
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (timestamp, body),
                (timestamp, duplicateBody),
                (date("2026-05-16T12:00:00Z"), body.replacingOccurrences(of: "2026-05-17T12:48:13.035Z", with: "2026-05-16T12:00:00.000Z")),
            ]
        )
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTokenHistory(
            into: store,
            containing: timestamp,
            calendar: calendar
        )
        let totals = try store.tokenCategoryTotalsForDay(containing: timestamp, calendar: calendar)
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 146_059,
                cachedInputTokens: 145_280,
                outputTokens: 37,
                reasoningOutputTokens: 0,
                totalTokens: 146_096
            )
        )
        XCTAssertEqual(samples.map(\.model), ["gpt-5.5"])
        XCTAssertEqual(
            try store.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" },
            [
                "approval_policy=never",
                "permission_profile=full",
                "sandbox_type=danger-full-access",
                "source_kind=desktop",
                "usage_mode=fast",
            ]
        )
        XCTAssertFalse(samples.contains { $0.threadID.contains("private") || $0.turnID.contains("private") })
    }

    func testCodexLogLiveCaptureImportsOnlyNewRowsAndCarriesEarlierContext() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:00:00Z")
        let contextBody = """
        conversation.id=conversation cwd="/Users/example/Projects/live-app" model=gpt-5.5 reasoning_effort=xhigh source=cli approval_policy=never
        """
        let oldTokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=100 output_token_count=5 cached_token_count=80 reasoning_token_count=1 tool_token_count=105 event.timestamp=2026-05-17T12:01:00.000Z conversation.id=conversation
        """
        let newTokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=200 output_token_count=10 cached_token_count=160 reasoning_token_count=2 tool_token_count=210 event.timestamp=2026-05-17T12:02:00.000Z conversation.id=conversation
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (timestamp, contextBody),
                (date("2026-05-17T12:01:00Z"), oldTokenBody),
                (date("2026-05-17T12:02:00Z"), newTokenBody),
            ]
        )
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTokenHistory(
            into: store,
            afterLogRowID: 2,
            containing: timestamp,
            calendar: calendar
        )
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(result.importResult, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(result.maxLogRowID, 3)
        XCTAssertEqual(result.lastImportedEventAt, date("2026-05-17T12:02:00Z"))
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.model, "gpt-5.5")
        XCTAssertEqual(samples.first?.projectPath, "/Users/example/Projects/live-app")
        XCTAssertEqual(samples.first?.effort, "xhigh")
        XCTAssertEqual(samples.first?.source, "cli")
        XCTAssertEqual(try store.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" }, ["approval_policy=never", "source_kind=cli"])
    }

    func testCodexLogLiveCaptureBoundsInitialImportToRecentRows() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:00:00Z")
        let firstTokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=100 output_token_count=5 cached_token_count=80 reasoning_token_count=1 tool_token_count=105 event.timestamp=2026-05-17T12:00:00.000Z conversation.id=conversation model=gpt-5.5
        """
        let secondTokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=200 output_token_count=10 cached_token_count=160 reasoning_token_count=2 tool_token_count=210 event.timestamp=2026-05-17T12:01:00.000Z conversation.id=conversation model=gpt-5.5
        """
        let thirdTokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=300 output_token_count=15 cached_token_count=240 reasoning_token_count=3 tool_token_count=315 event.timestamp=2026-05-17T12:02:00.000Z conversation.id=conversation model=gpt-5.5
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (timestamp, firstTokenBody),
                (date("2026-05-17T12:01:00Z"), secondTokenBody),
                (date("2026-05-17T12:02:00Z"), thirdTokenBody),
            ]
        )
        let importer = CodexLogTokenUsageImporter(
            logsDatabaseURL: databaseURL,
            incrementalContextLookbackRowCount: 1
        )

        let result = try importer.importTokenHistory(
            into: store,
            afterLogRowID: 0,
            containing: timestamp,
            calendar: calendar
        )
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(result.importResult, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(result.maxLogRowID, 3)
        XCTAssertEqual(samples.map(\.total.totalTokens), [315])
    }

    func testCodexLogLiveCaptureDoesNotUseContextOutsideLookbackWindow() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:00:00Z")
        let contextBody = """
        conversation.id=conversation cwd="/Users/example/Projects/live-app" model=gpt-5.5 reasoning_effort=xhigh source=cli approval_policy=never
        """
        let oldTokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=100 output_token_count=5 cached_token_count=80 reasoning_token_count=1 tool_token_count=105 event.timestamp=2026-05-17T12:01:00.000Z conversation.id=conversation
        """
        let newTokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=200 output_token_count=10 cached_token_count=160 reasoning_token_count=2 tool_token_count=210 event.timestamp=2026-05-17T12:02:00.000Z conversation.id=conversation
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (timestamp, contextBody),
                (date("2026-05-17T12:01:00Z"), oldTokenBody),
                (date("2026-05-17T12:02:00Z"), newTokenBody),
            ]
        )
        let importer = CodexLogTokenUsageImporter(
            logsDatabaseURL: databaseURL,
            incrementalContextLookbackRowCount: 0
        )

        let result = try importer.importTokenHistory(
            into: store,
            afterLogRowID: 2,
            containing: timestamp,
            calendar: calendar
        )
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)

        XCTAssertEqual(result.importResult, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(result.maxLogRowID, 3)
        XCTAssertNil(sample.model)
        XCTAssertNil(sample.projectPath)
        XCTAssertNil(sample.effort)
        XCTAssertEqual(sample.source, "codex-log")
    }

    func testCodexLogLiveCaptureAdvancesCursorWhenNoMatchingRowsExist() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:00:00Z")
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (timestamp, "unrelated startup log"),
                (date("2026-05-17T12:01:00Z"), "another unrelated log"),
            ]
        )
        let importer = CodexLogTokenUsageImporter(
            logsDatabaseURL: databaseURL,
            incrementalContextLookbackRowCount: 1
        )

        let result = try importer.importTokenHistory(
            into: store,
            afterLogRowID: 0,
            containing: timestamp,
            calendar: calendar
        )

        XCTAssertEqual(result.importResult, .empty)
        XCTAssertEqual(result.maxLogRowID, 2)
        XCTAssertNil(result.lastImportedEventAt)
    }

    func testLiveTokenCaptureStateRecordsSuccessAndNoNewEvents() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:00:00Z")
        let body = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=100 output_token_count=5 cached_token_count=80 reasoning_token_count=1 tool_token_count=105 event.timestamp=2026-05-17T12:00:00.000Z conversation.id=conversation model=gpt-5.5
        """
        try createCodexLogsDatabase(at: databaseURL, rows: [(timestamp, body)])

        let firstState = store.captureLiveCodexLogTokenHistory(
            at: timestamp,
            calendar: calendar,
            force: true,
            logsDatabaseURL: databaseURL
        )
        let secondState = store.captureLiveCodexLogTokenHistory(
            at: date("2026-05-17T12:01:00Z"),
            calendar: calendar,
            force: true,
            logsDatabaseURL: databaseURL
        )

        XCTAssertEqual(firstState.status, .imported)
        XCTAssertEqual(firstState.result.insertedCount, 1)
        XCTAssertEqual(firstState.lastLogRowID, 1)
        XCTAssertEqual(secondState.status, .noNewEvents)
        XCTAssertEqual(secondState.lastLogRowID, 1)
        XCTAssertEqual(try store.codexLiveTokenCaptureState().status, .noNewEvents)
    }

    func testLiveTokenCaptureStateRecordsFailureForMissingLogDatabase() async throws {
        let store = try makeStore()
        let missingURL = try makeTemporaryDirectory().appendingPathComponent("missing.sqlite")

        let state = store.captureLiveCodexLogTokenHistory(
            at: date("2026-05-17T12:00:00Z"),
            calendar: calendar,
            force: true,
            logsDatabaseURL: missingURL
        )

        XCTAssertEqual(state.status, .failed)
        XCTAssertNotNil(state.lastErrorText)
        XCTAssertEqual(try store.codexLiveTokenCaptureState().status, .failed)
    }

    func testWorkerTodayTokenTotalsRequireSuccessfulLiveCapture() async throws {
        let store = try makeStore()
        let timestamp = date("2026-05-17T12:00:00Z")
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread",
                turnID: "turn",
                lastInput: 100,
                lastCached: 80,
                lastOutput: 5,
                lastReasoning: 1,
                lastTotal: 105,
                totalInput: 100,
                totalCached: 80,
                totalOutput: 5,
                totalReasoning: 1,
                totalTotal: 105
            ),
            at: timestamp
        )
        let worker = UsageHistoryDatabaseWorker(store: store)

        let totals = await worker.todayTokenCategoryTotals(at: timestamp, calendar: calendar)

        XCTAssertNil(totals)
    }

    func testWorkerTodayTokenTotalsReturnAfterSuccessfulNoNewEventsCheck() async throws {
        let store = try makeStore()
        let timestamp = date("2026-05-17T12:00:00Z")
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread",
                turnID: "turn",
                lastInput: 100,
                lastCached: 80,
                lastOutput: 5,
                lastReasoning: 1,
                lastTotal: 105,
                totalInput: 100,
                totalCached: 80,
                totalOutput: 5,
                totalReasoning: 1,
                totalTotal: 105
            ),
            at: timestamp
        )
        try store.recordCodexLiveTokenCaptureState(
            CodexLiveTokenCaptureState(lastCheckedAt: timestamp, status: .noNewEvents)
        )
        let worker = UsageHistoryDatabaseWorker(store: store)

        let totals = await worker.todayTokenCategoryTotals(at: timestamp, calendar: calendar)

        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 100,
                cachedInputTokens: 80,
                outputTokens: 5,
                reasoningOutputTokens: 1,
                totalTokens: 105
            )
        )
    }

    func testCodexLogTokenImporterExtractsDottedContextAndSafeDimensions() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let body = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=1000 output_token_count=20 cached_token_count=800 reasoning_token_count=5 tool_token_count=1020 event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation codex.turn.model=gpt-5.6 cwd="/Users/example/Projects/with space" codex.turn.reasoning_effort=xhigh;request.payload=private source=desktop originator=vscode codex.cli_version=1.2.3 codex.turn.model_provider=openai codex.turn.approval_policy=never codex.turn.sandbox_policy.type=danger-full-access codex.turn.permission_profile.type=full codex.turn.truncation_policy.mode=auto codex.turn.realtime_active=true usage_mode=/fast prompt="do not store this"
        """
        try createCodexLogsDatabase(at: databaseURL, rows: [(timestamp, body)])
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTokenHistory(
            into: store,
            containing: timestamp,
            calendar: calendar
        )
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)
        let dimensions = try store.tokenDimensionCatalogEntries()
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()

        XCTAssertEqual(result, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(sample.model, "gpt-5.6")
        XCTAssertEqual(sample.sessionID, "conversation")
        XCTAssertEqual(sample.projectPath, "/Users/example/Projects/with space")
        XCTAssertEqual(sample.projectName, "with space")
        XCTAssertEqual(sample.effort, "xhigh")
        XCTAssertEqual(sample.source, "desktop")
        XCTAssertEqual(
            dimensions,
            [
                "approval_policy=never",
                "cli_version=1.2.3",
                "model_provider=openai",
                "originator=vscode",
                "permission_profile=full",
                "realtime_active=true",
                "sandbox_type=danger-full-access",
                "source_kind=desktop",
                "truncation_policy=auto",
                "usage_mode=fast",
            ]
        )
        XCTAssertFalse(dimensions.contains { $0.contains("request") || $0.contains("private") || $0.contains("prompt") })
    }

    func testCodexLogTokenImporterCarriesSafeContextFromEarlierTraceRows() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let contextBody = """
        session_loop{thread_id=conversation}:run_turn{turn.id=turn-a model=gpt-5.5 codex.turn.reasoning_effort=xhigh approval_policy=never sandbox_policy.type=danger-full-access}:run_sampling_request{turn_id=turn-a model=gpt-5.5 cwd=/Users/example/Projects/carried}:try_run_sampling_request{turn_id=turn-a model=gpt-5.5} event.name="codex.websocket_event" event.kind=response.output_text.delta source=message cwd=/unsafe/message/path
        """
        let tokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=1000 output_token_count=20 cached_token_count=800 reasoning_token_count=5 tool_token_count=1020 event.timestamp=2026-05-17T12:48:14.035Z conversation.id=conversation
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (timestamp, contextBody),
                (timestamp.addingTimeInterval(1), tokenBody),
            ]
        )
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTokenHistory(
            into: store,
            containing: timestamp,
            calendar: calendar
        )
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(sample.model, "gpt-5.5")
        XCTAssertEqual(sample.projectPath, "/Users/example/Projects/carried")
        XCTAssertEqual(sample.projectName, "carried")
        XCTAssertEqual(sample.effort, "xhigh")
        XCTAssertEqual(sample.source, "codex-log")
        XCTAssertEqual(
            try store.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" }.sorted(),
            [
                "approval_policy=never",
                "sandbox_type=danger-full-access",
                "source_kind=codex-log",
            ]
        )
    }

    func testCodexLogTokenImporterDoesNotCarryContextAcrossConversations() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let contextBody = """
        session_loop{thread_id=conversation-a}:run_turn{turn.id=turn-a model=gpt-5.5 codex.turn.reasoning_effort=xhigh}:run_sampling_request{turn_id=turn-a model=gpt-5.5 cwd=/Users/example/Projects/a} event.name="codex.websocket_event" event.kind=response.output_text.delta
        """
        let tokenBody = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=1000 output_token_count=20 cached_token_count=800 reasoning_token_count=5 tool_token_count=1020 event.timestamp=2026-05-17T12:48:14.035Z conversation.id=conversation-b
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (timestamp, contextBody),
                (timestamp.addingTimeInterval(1), tokenBody),
            ]
        )
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        _ = try importer.importTokenHistory(
            into: store,
            containing: timestamp,
            calendar: calendar
        )
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)

        XCTAssertNil(sample.model)
        XCTAssertNil(sample.projectPath)
        XCTAssertNil(sample.projectName)
        XCTAssertNil(sample.effort)
        XCTAssertEqual(sample.source, "codex-log")
    }

    func testCodexLogTokenImporterRepairsExistingRowsWithoutInflatingTotals() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let timestampText = "2026-05-17T12:48:13.035Z"
        let threadID = [
            "codex-log:conversation",
            [
                timestampText,
                "1000",
                "800",
                "20",
                "5",
                "unknown-model",
            ].joined(separator: ":"),
        ].joined(separator: ":")
        try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: threadID,
                    turnID: "response.completed",
                    lastInput: 1000,
                    lastCached: 800,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 1020,
                    totalInput: 1000,
                    totalCached: 800,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 1020
                ),
                receivedAt: timestamp
            ),
        ])
        let body = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=1000 output_token_count=20 cached_token_count=800 reasoning_token_count=5 tool_token_count=1020 event.timestamp=\(timestampText) conversation.id=conversation codex.turn.model=gpt-5.6 codex.turn.cwd=/Users/example/Projects/repaired codex.turn.reasoning_effort=xhigh source=desktop codex.turn.approval_policy=never codex.turn.sandbox_type=danger-full-access
        """
        try createCodexLogsDatabase(at: databaseURL, rows: [(timestamp, body)])
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTokenHistory(
            into: store,
            containing: timestamp,
            calendar: calendar
        )
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)
        let totals = try store.tokenCategoryTotalsForDay(containing: timestamp, calendar: calendar)

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.repairedModelCount, 1)
        XCTAssertEqual(result.repairedContextCount, 1)
        XCTAssertGreaterThanOrEqual(result.repairedDimensionCount, 3)
        XCTAssertEqual(try store.tokenUsageSamples().count, 1)
        XCTAssertEqual(sample.model, "gpt-5.6")
        XCTAssertEqual(sample.projectPath, "/Users/example/Projects/repaired")
        XCTAssertEqual(sample.projectName, "repaired")
        XCTAssertEqual(sample.effort, "xhigh")
        XCTAssertEqual(sample.source, "desktop")
        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 1000,
                cachedInputTokens: 800,
                outputTokens: 20,
                reasoningOutputTokens: 5,
                totalTokens: 1020
            )
        )
        XCTAssertEqual(
            try store.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" }.sorted(),
            [
                "approval_policy=never",
                "sandbox_type=danger-full-access",
                "source_kind=desktop",
            ]
        )
        XCTAssertEqual(try store.tokenDashboardAvailableBreakdownDimensions(), [.model, .effort, .project, .approvalPolicy, .sandboxType, .sourceKind])
    }

    func testCodexLogTokenImporterPreservesExistingSafeContextWhenLaterLogOmitsIt() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let timestampText = "2026-05-17T12:48:13.035Z"
        let threadID = [
            "codex-log:conversation",
            [
                timestampText,
                "1000",
                "800",
                "20",
                "5",
                "gpt-5.5",
            ].joined(separator: ":"),
        ].joined(separator: ":")
        try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: threadID,
                    turnID: "response.completed",
                    model: "gpt-5.5",
                    lastInput: 1000,
                    lastCached: 800,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 1020,
                    totalInput: 1000,
                    totalCached: 800,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 1020
                ),
                receivedAt: timestamp,
                context: TokenUsageContext(
                    sessionID: "conversation",
                    projectPath: "/Users/example/Projects/original",
                    effort: "xhigh"
                )
            ),
        ])
        let body = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=1000 output_token_count=20 cached_token_count=800 reasoning_token_count=5 tool_token_count=1020 event.timestamp=\(timestampText) conversation.id=conversation model=gpt-5.5 slug=gpt-5.5 source=desktop
        """
        try createCodexLogsDatabase(at: databaseURL, rows: [(timestamp, body)])
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTokenHistory(
            into: store,
            containing: timestamp,
            calendar: calendar
        )
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(sample.projectPath, "/Users/example/Projects/original")
        XCTAssertEqual(sample.projectName, "original")
        XCTAssertEqual(sample.effort, "xhigh")
        XCTAssertEqual(sample.source, "desktop")
        XCTAssertEqual(try store.tokenUsageSamples().count, 1)
    }

    func testRecentTokenHistoryImportUsesCodexDesktopLogs() async throws {
        let store = try makeStore()
        let tempDirectory = try makeTemporaryDirectory()
        let databaseURL = tempDirectory.appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (
                    timestamp,
                    """
                    event.name="codex.sse_event" event.kind=response.completed input_token_count=1000 output_token_count=20 cached_token_count=800 reasoning_token_count=5 tool_token_count=1020 event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation model=gpt-5.5 slug=gpt-5.5
                    """
                ),
            ]
        )

        let result = store.importRecentTokenHistoryIfAvailable(
            containing: timestamp,
            calendar: calendar,
            logsDatabaseURL: databaseURL
        )
        let totals = try store.tokenCategoryTotalsForDay(containing: timestamp, calendar: calendar)

        XCTAssertEqual(result, TokenUsageImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 1_000,
                cachedInputTokens: 800,
                outputTokens: 20,
                reasoningOutputTokens: 5,
                totalTokens: 1_020
            )
        )
    }

    @MainActor
    func testTokenHistoryReloadUsesPreviouslyCapturedCodexDesktopLogs() async throws {
        let store = try makeStore()
        let tempDirectory = try makeTemporaryDirectory()
        let databaseURL = tempDirectory.appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (
                    timestamp,
                    """
                    event.name="codex.sse_event" event.kind=response.completed input_token_count=1200 output_token_count=30 cached_token_count=900 reasoning_token_count=7 tool_token_count=1230 event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation model=gpt-5.5 slug=gpt-5.5
                    """
                ),
            ]
        )
        let importResult = store.importRecentTokenHistoryIfAvailable(
            containing: timestamp,
            calendar: calendar,
            logsDatabaseURL: databaseURL
        )
        XCTAssertEqual(importResult.insertedCount, 1)
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { timestamp },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedChartKind = .tokens
        await viewModel.reload()

        XCTAssertEqual(try store.availableTokenComponentSeries().map(\.id), ["tokens_all", "model:gpt-5.5"])
        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["tokens_all"])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketName), [
            "All tokens",
            "All tokens",
            "All tokens",
            "All tokens",
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenComponent), [
            .input,
            .cached,
            .output,
            .reasoning,
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [
            1_200,
            900,
            30,
            7,
        ])
    }

}
