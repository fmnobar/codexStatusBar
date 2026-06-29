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
            lastInput: 250,
            lastTotal: 250,
            totalInput: 2_000,
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
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
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
                    lastInput: 125,
                    lastTotal: 125,
                    totalInput: 125,
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
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 250,
                lastTotal: 250,
                totalInput: 2_000,
                totalTotal: 2_000
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-b",
                lastInput: 400,
                lastTotal: 400,
                totalInput: 2_500,
                totalTotal: 2_500
            ),
            at: date("2026-04-14T20:10:00Z")
        )

        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(samples.map(\.observedTotalTokens), [250, 500])
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 750)
    }

    func testTokenUsageFirstObservedSampleUsesLastTotalInsteadOfCumulativeTotal() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-late",
                lastInput: 600,
                lastTotal: 600,
                totalInput: 12_000,
                totalTotal: 12_000
            ),
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
                lastInput: 70,
                lastCached: 30,
                lastOutput: 15,
                lastReasoning: 5,
                lastTotal: 100,
                totalInput: 70,
                totalCached: 30,
                totalOutput: 15,
                totalReasoning: 5,
                totalTotal: 100
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
                lastInput: 120,
                lastTotal: 120,
                totalInput: 120,
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

    func testTotalTokenSeriesVisibleForNonInputComponentOnlySamples() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-cached",
                turnID: "turn-a",
                model: "cache-only",
                lastCached: 50,
                lastTotal: 0,
                totalCached: 50,
                totalTotal: 50
            ),
            at: date("2026-04-14T20:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-output",
                turnID: "turn-a",
                model: "output-only",
                lastOutput: 30,
                lastTotal: 0,
                totalOutput: 30,
                totalTotal: 30
            ),
            at: date("2026-04-14T20:05:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-reasoning",
                turnID: "turn-a",
                model: "reasoning-only",
                lastReasoning: 20,
                lastTotal: 0,
                totalReasoning: 20,
                totalTotal: 20
            ),
            at: date("2026-04-14T20:10:00Z")
        )

        let points = try store.tokenPoints(
            category: .total,
            range: .day,
            periodStart: date("2026-04-14T00:00:00Z"),
            periodEnd: date("2026-04-15T00:00:00Z")
        )
        let availableSeries = try store.availableTokenSeries(category: .total)

        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(Set(points.map(\.tokenCount)), [20, 30, 50])
        XCTAssertEqual(
            Set(availableSeries.map(\.id)),
            ["tokens_all", "model:cache-only", "model:output-only", "model:reasoning-only"]
        )
        XCTAssertEqual(try store.availableTokenSeries(category: .input), [])
        XCTAssertEqual(
            try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar),
            100
        )
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

    func testTokenAttributionCoverageRowsUseObservedVolumeAndMeaningfulDimensions() async throws {
        let store = try makeStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-attributed",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 100,
                    lastTotal: 100,
                    totalInput: 100,
                    totalTotal: 100
                ),
                receivedAt: date("2026-05-02T10:15:00Z"),
                context: TokenUsageContext(
                    sessionID: "session-a",
                    projectPath: "/Users/example/Projects/codex_codex",
                    effort: "high",
                    source: "cli",
                    dimensions: [
                        TokenUsageDimension(.approvalPolicy, "never"),
                        TokenUsageDimension(.approvalPolicy, "on-request"),
                        TokenUsageDimension(.sourceKind, "cli"),
                    ].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-hidden",
                    turnID: "turn-a",
                    lastInput: 50,
                    lastTotal: 50,
                    totalInput: 50,
                    totalTotal: 50
                ),
                receivedAt: date("2026-05-03T10:15:00Z"),
                context: TokenUsageContext(
                    sessionID: "session-hidden",
                    dimensions: [TokenUsageDimension(.sourceKind, "codex-log")].compactMap { $0 }
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-partial",
                    turnID: "turn-a",
                    model: "gpt-5.4",
                    lastInput: 25,
                    lastTotal: 25,
                    totalInput: 25,
                    totalTotal: 25
                ),
                receivedAt: date("2026-05-04T10:15:00Z"),
                context: TokenUsageContext(
                    sessionID: "session-partial",
                    effort: "low"
                )
            ),
        ])

        let rows = try store.tokenAttributionCoverageRows(
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z")
        )
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        XCTAssertEqual(rows.map(\.id), [
            "model",
            "project",
            "effort",
            "source",
            "dimension:source_kind",
            "dimension:approval_policy",
        ])
        XCTAssertEqual(rowsByID["model"]?.attributedTokenCount, 125)
        XCTAssertEqual(rowsByID["model"]?.missingTokenCount, 50)
        XCTAssertEqual(rowsByID["model"]?.distinctValueCount, 2)
        XCTAssertEqual(rowsByID["project"]?.attributedTokenCount, 100)
        XCTAssertEqual(rowsByID["project"]?.missingTokenCount, 75)
        XCTAssertEqual(rowsByID["effort"]?.attributedTokenCount, 125)
        XCTAssertEqual(rowsByID["source"]?.attributedTokenCount, 100)

        XCTAssertEqual(rowsByID["dimension:approval_policy"]?.attributedTokenCount, 100)
        XCTAssertEqual(rowsByID["dimension:approval_policy"]?.missingTokenCount, 75)
        XCTAssertEqual(rowsByID["dimension:approval_policy"]?.distinctValueCount, 1)
        XCTAssertEqual(rowsByID["dimension:source_kind"]?.attributedTokenCount, 100)
        XCTAssertEqual(rowsByID["dimension:source_kind"]?.missingTokenCount, 75)
        XCTAssertEqual(rowsByID["dimension:source_kind"]?.distinctValueCount, 1)

        XCTAssertTrue(
            try store.tokenAttributionCoverageRows(
                periodStart: date("2026-06-01T00:00:00Z"),
                periodEnd: date("2026-07-01T00:00:00Z")
            ).isEmpty
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
        await viewModel.waitForAttributionCoverageLoad()

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
    func testTokenDashboardModelBreakdownCarriesCapabilityAnnotationsOnlyForModelRows() async throws {
        let store = try makeStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
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
                receivedAt: date("2026-05-02T10:15:00Z"),
                context: TokenUsageContext(effort: "high")
            ),
        ])
        try store.importCodexModelCapabilities(
            CodexModelCapabilitiesImportBatch(
                models: [
                    try XCTUnwrap(CodexModelCapability(
                        slug: "gpt-5.5",
                        displayName: "GPT-5.5",
                        visibility: "public",
                        supportedInAPI: true,
                        priority: 1,
                        contextWindow: 100_000,
                        maxContextWindow: 200_000,
                        effectiveContextWindowPercent: 50,
                        defaultReasoningLevel: "high",
                        supportsReasoningSummaries: true,
                        defaultReasoningSummary: "auto",
                        supportsVerbosity: true,
                        defaultVerbosity: "medium",
                        shellType: "default_shell",
                        applyPatchToolType: "apply_patch",
                        webSearchToolType: "web_search",
                        supportsParallelToolCalls: true,
                        supportsImageDetailOriginal: true,
                        supportsSearchTool: true,
                        truncationPolicyMode: "auto",
                        truncationPolicyLimit: nil,
                        reasoningLevels: [
                            try XCTUnwrap(CodexModelCapabilityReasoningLevel(position: 0, effort: "low")),
                            try XCTUnwrap(CodexModelCapabilityReasoningLevel(position: 1, effort: "high")),
                        ],
                        serviceTiers: [
                            try XCTUnwrap(CodexModelCapabilityServiceTier(position: 0, tierID: "priority", tierName: "Priority")),
                        ],
                        speedTiers: [
                            try XCTUnwrap(CodexModelCapabilitySpeedTier(position: 0, tierID: "fast")),
                        ],
                        inputModalities: [
                            try XCTUnwrap(CodexModelCapabilityInputModality(position: 0, modality: "text")),
                            try XCTUnwrap(CodexModelCapabilityInputModality(position: 1, modality: "image")),
                        ],
                        toolIdentifiers: [
                            try XCTUnwrap(CodexModelCapabilityToolIdentifier(position: 0, toolKind: "shell_type", toolValue: "default_shell")),
                        ]
                    )),
                ],
                cacheFetchedAt: date("2026-05-02T09:00:00Z"),
                clientVersion: "1.0.0"
            )
        )

        let worker = UsageHistoryDatabaseWorker(store: store)
        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")
        let modelSnapshot = try await worker.tokenDashboardSnapshot(
            for: TokenDashboardLoadRequest(
                breakdownDimension: .model,
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd,
                includeAttributionCoverage: false
            )
        )
        let effortSnapshot = try await worker.tokenDashboardSnapshot(
            for: TokenDashboardLoadRequest(
                breakdownDimension: .effort,
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd,
                includeAttributionCoverage: false
            )
        )

        XCTAssertEqual(modelSnapshot.modelCapabilities.map(\.slug), ["gpt-5.5"])
        XCTAssertTrue(effortSnapshot.modelCapabilities.isEmpty)

        let viewModel = TokenDashboardViewModel(
            store: store,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        let modelSeries = try XCTUnwrap(viewModel.series.first { $0.id == "model:gpt-5.5" })
        let annotation = try XCTUnwrap(viewModel.modelCapabilityAnnotation(for: modelSeries))

        XCTAssertTrue(annotation.compactText.contains("Ctx 200k"))
        XCTAssertTrue(annotation.compactText.contains("Reason high"))
        XCTAssertTrue(annotation.compactText.contains("Image"))
        XCTAssertTrue(annotation.compactText.contains("Web"))
        XCTAssertTrue(annotation.detailText.contains("Service tiers Priority"))
        XCTAssertNil(viewModel.modelCapabilityAnnotation(for: try XCTUnwrap(viewModel.series.first { $0.id == TokenDashboardSeries.aggregateID })))

        viewModel.selectedBreakdownDimension = .effort
        await viewModel.reload()

        XCTAssertTrue(viewModel.modelCapabilities.isEmpty)
        XCTAssertNil(viewModel.modelCapabilityAnnotation(for: try XCTUnwrap(viewModel.series.first { $0.kind == .effort })))
    }

    @MainActor
    func testTokenDashboardViewModelRecordsReloadInstrumentation() async throws {
        var currentDate = date("2026-05-17T12:00:00Z")
        let store = try makeStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "thread-instrument",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 100,
                    lastTotal: 100,
                    totalInput: 100,
                    totalTotal: 100
                ),
                receivedAt: date("2026-05-02T10:15:00Z"),
                context: TokenUsageContext(effort: "high")
            ),
        ])
        let instrumentationStore = AppPerformanceInstrumentationStore(
            fileURL: try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json"),
            now: { currentDate }
        )
        let viewModel = TokenDashboardViewModel(
            database: UsageHistoryDatabaseWorker(store: store),
            performanceInstrumentationStore: instrumentationStore,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        currentDate = currentDate.addingTimeInterval(0.15)
        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        XCTAssertEqual(instrumentationStore.events.map(\.kind), [.tokenDashboardReload, .tokenDashboardReload])
        let initialPrimaryEvent = try XCTUnwrap(
            instrumentationStore.events.first { $0.metadata["phase"] == "primary" }
        )
        let initialCoverageEvent = try XCTUnwrap(
            instrumentationStore.events.first { $0.metadata["phase"] == "coverage" }
        )
        XCTAssertEqual(initialPrimaryEvent.status, .success)
        XCTAssertEqual(initialPrimaryEvent.metadata["dashboard"], "token")
        XCTAssertEqual(initialPrimaryEvent.metadata["range"], "month")
        XCTAssertEqual(initialPrimaryEvent.metadata["cacheHit"], "false")
        XCTAssertEqual(initialCoverageEvent.status, .success)

        viewModel.selectedBreakdownDimension = .effort
        currentDate = currentDate.addingTimeInterval(0.1)
        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        let breakdownPrimaryEvent = try XCTUnwrap(
            instrumentationStore.events.last {
                $0.kind == .tokenDashboardBreakdownChange && $0.metadata["phase"] == "primary"
            }
        )
        XCTAssertEqual(breakdownPrimaryEvent.metadata["cacheHit"], "false")
    }

    @MainActor
    func testTokenDashboardSnapshotCacheReusesBreakdownAndPeriodResults() async throws {
        var currentDate = date("2026-05-17T12:00:00Z")
        let database = TokenDashboardCacheSpyDatabase()
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { currentDate },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 1_000)

        currentDate = currentDate.addingTimeInterval(30)
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)

        viewModel.sortBreakdownRows(by: .total)
        viewModel.selectSeries("model:gpt-5.5")
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)

        viewModel.selectedBreakdownDimension = .effort
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 2_000)

        viewModel.selectedBreakdownDimension = .model
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 1_000)
    }

    @MainActor
    func testTokenDashboardLoadsPrimaryBeforeDelayedCoverage() async throws {
        let database = TokenDashboardCacheSpyDatabase(coverageDelayNanoseconds: 100_000_000)
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()

        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 1_000)
        XCTAssertTrue(viewModel.isAttributionCoverageLoading)
        XCTAssertTrue(viewModel.attributionCoverageRows.isEmpty)
        XCTAssertFalse(viewModel.canExportCSV)
        let requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)

        await viewModel.waitForAttributionCoverageLoad()

        XCTAssertFalse(viewModel.isAttributionCoverageLoading)
        XCTAssertNil(viewModel.attributionCoverageErrorMessage)
        XCTAssertFalse(viewModel.attributionCoverageRows.isEmpty)
        XCTAssertTrue(viewModel.canExportCSV)
        let coverageRequestCount = await database.coverageRequestCount()
        XCTAssertEqual(coverageRequestCount, 1)
    }

    @MainActor
    func testTokenDashboardFirstLoadShowsPrimaryLoadingState() async throws {
        let database = TokenDashboardCacheSpyDatabase(stubs: [
            .success(value: 1, delayNanoseconds: 150_000_000),
        ])
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        let reloadTask = Task { await viewModel.reload() }
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(viewModel.primaryLoadState, .loading)
        XCTAssertTrue(viewModel.shouldShowPrimaryLoadingState)
        XCTAssertFalse(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertFalse(viewModel.shouldShowTokenContent)
        XCTAssertEqual(viewModel.loadingState.title, "Loading token dashboard")
        XCTAssertFalse(viewModel.canExportCSV)

        let didLoad = await reloadTask.value
        XCTAssertTrue(didLoad)
        await viewModel.waitForAttributionCoverageLoad()

        XCTAssertEqual(viewModel.primaryLoadState, .loaded)
        XCTAssertTrue(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertFalse(viewModel.shouldShowPrimaryLoadingState)
        XCTAssertTrue(viewModel.shouldShowTokenContent)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 1_000)
        XCTAssertTrue(viewModel.canExportCSV)
    }

    @MainActor
    func testTokenDashboardBreakdownChangeShowsLoadingInsteadOfStaleCurrentData() async throws {
        let database = TokenDashboardCacheSpyDatabase(stubs: [
            .success(value: 1),
            .success(value: 2, delayNanoseconds: 150_000_000),
        ])
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 1_000)

        viewModel.selectedBreakdownDimension = .effort
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(viewModel.primaryLoadState, .loading)
        XCTAssertFalse(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertTrue(viewModel.shouldShowPrimaryLoadingState)
        XCTAssertFalse(viewModel.shouldShowTokenContent)
        XCTAssertFalse(viewModel.canExportCSV)

        try await Task.sleep(nanoseconds: 220_000_000)
        await viewModel.waitForAttributionCoverageLoad()

        XCTAssertEqual(viewModel.primaryLoadState, .loaded)
        XCTAssertTrue(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertEqual(viewModel.selectedBreakdownDimension, .effort)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 2_000)
        XCTAssertTrue(viewModel.canExportCSV)
    }

    @MainActor
    func testTokenDashboardCoverageCacheReusesPeriodAcrossBreakdowns() async throws {
        let database = TokenDashboardCacheSpyDatabase()
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        var coverageRequestCount = await database.coverageRequestCount()
        XCTAssertEqual(coverageRequestCount, 1)
        XCTAssertEqual(viewModel.coverageCacheEntryCount, 1)

        viewModel.selectedBreakdownDimension = .effort
        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        let requestCount = await database.requestCount()
        coverageRequestCount = await database.coverageRequestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(coverageRequestCount, 1)
        XCTAssertFalse(viewModel.attributionCoverageRows.isEmpty)
    }

    @MainActor
    func testTokenDashboardCoverageFailureKeepsPrimaryAndDoesNotCache() async throws {
        let database = TokenDashboardCacheSpyDatabase(
            coverageError: TokenDashboardCacheSpyDatabase.TokenDashboardCacheSpyError.configuredFailure
        )
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 1_000)
        XCTAssertEqual(viewModel.attributionCoverageErrorMessage, "Attribution coverage could not be loaded.")
        XCTAssertEqual(viewModel.coverageCacheEntryCount, 0)
        XCTAssertFalse(viewModel.canExportCSV)
        var requestCount = await database.requestCount()
        var coverageRequestCount = await database.coverageRequestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(coverageRequestCount, 1)

        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        requestCount = await database.requestCount()
        coverageRequestCount = await database.coverageRequestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(coverageRequestCount, 2)
    }

    @MainActor
    func testTokenDashboardHistoryChangeReloadsAreDebounced() async throws {
        let database = TokenDashboardCacheSpyDatabase(stubs: [
            .success(value: 1),
            .success(value: 2),
        ])
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            historyChangeDebounceInterval: 0.05,
            automaticallyReload: false
        )

        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        viewModel.scheduleHistoryChangeReload()
        viewModel.scheduleHistoryChangeReload()
        viewModel.scheduleHistoryChangeReload()

        try await Task.sleep(nanoseconds: 150_000_000)
        await viewModel.waitForAttributionCoverageLoad()

        let requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 2_000)
        XCTAssertEqual(viewModel.snapshotCacheEntryCount, 1)
        XCTAssertEqual(viewModel.coverageCacheEntryCount, 1)
    }

    @MainActor
    func testTokenDashboardViewModelRecordsWorkerAndCacheReloadTimings() async throws {
        var currentDate = date("2026-05-17T12:00:00Z")
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json")
        let instrumentationStore = AppPerformanceInstrumentationStore(
            fileURL: diagnosticsURL,
            now: { currentDate }
        )
        let database = TokenDashboardCacheSpyDatabase()
        let viewModel = TokenDashboardViewModel(
            database: database,
            performanceInstrumentationStore: instrumentationStore,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        currentDate = currentDate.addingTimeInterval(0.2)
        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()
        currentDate = currentDate.addingTimeInterval(0.1)
        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        let requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(instrumentationStore.events.map(\.kind), [.tokenDashboardReload, .tokenDashboardReload, .tokenDashboardReload, .tokenDashboardReload])
        XCTAssertEqual(instrumentationStore.events.map(\.status), [.success, .success, .success, .success])
        let primaryEvents = instrumentationStore.events.filter { $0.metadata["phase"] == "primary" }
        let coverageEvents = instrumentationStore.events.filter { $0.metadata["phase"] == "coverage" }
        XCTAssertEqual(primaryEvents.count, 2)
        XCTAssertEqual(coverageEvents.count, 2)
        XCTAssertEqual(primaryEvents[0].metadata["cacheHit"], "false")
        XCTAssertEqual(primaryEvents[1].metadata["cacheHit"], "true")
        XCTAssertEqual(primaryEvents[0].metadata["dashboard"], "token")
        XCTAssertEqual(primaryEvents[0].metadata["range"], "month")

        viewModel.selectedBreakdownDimension = .effort
        currentDate = currentDate.addingTimeInterval(0.3)
        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

        let breakdownPrimaryEvent = try XCTUnwrap(
            instrumentationStore.events.last {
                $0.kind == .tokenDashboardBreakdownChange && $0.metadata["phase"] == "primary"
            }
        )
        XCTAssertEqual(breakdownPrimaryEvent.metadata["breakdown"], "Effort")
        XCTAssertEqual(breakdownPrimaryEvent.metadata["cacheHit"], "false")
    }

    @MainActor
    func testTokenDashboardSnapshotCacheReusesRevisitedPeriods() async throws {
        let database = TokenDashboardCacheSpyDatabase()
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))

        viewModel.goToPreviousPeriod()
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-01T00:00:00Z"))

        viewModel.goToNextPeriod()
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
    }

    @MainActor
    func testTokenDashboardSnapshotCacheDoesNotCacheFailures() async throws {
        let database = TokenDashboardCacheSpyDatabase(stubs: [
            .failure,
            .success(value: 42),
        ])
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        let failed = await viewModel.reload()
        XCTAssertFalse(failed)
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.errorMessage, "Token dashboard could not be loaded.")

        let succeeded = await viewModel.reload()
        XCTAssertTrue(succeeded)
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 42_000)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testTokenDashboardSnapshotCacheInvalidationClearsEntriesAndReloads() async throws {
        let database = TokenDashboardCacheSpyDatabase(stubs: [
            .success(value: 7),
            .success(value: 8),
        ])
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 7_000)
        XCTAssertEqual(viewModel.snapshotCacheEntryCount, 1)

        await viewModel.reload()
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)

        viewModel.invalidateSnapshotCache()
        XCTAssertEqual(viewModel.snapshotCacheEntryCount, 0)

        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 8_000)
    }

    @MainActor
    func testTokenDashboardSnapshotCacheResetsUnavailableBreakdownToModel() async throws {
        let database = TokenDashboardCacheSpyDatabase(
            stubs: [
                .success(value: 1, availableDimensions: [.model]),
                .success(value: 2, availableDimensions: [.model]),
            ]
        )
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        viewModel.selectedBreakdownDimension = .effort
        let applied = await viewModel.reload()
        XCTAssertFalse(applied)
        XCTAssertEqual(viewModel.selectedBreakdownDimension, .model)
        XCTAssertTrue(viewModel.series.isEmpty)

        let modelApplied = await viewModel.reload()
        XCTAssertTrue(modelApplied)
        let requests = await database.requestsSnapshot()
        XCTAssertEqual(requests.map(\.breakdownDimension), [.effort, .model])
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 2_000)
    }

    @MainActor
    func testTokenDashboardStaleAsyncResultIsIgnoredAfterBreakdownChange() async throws {
        let database = TokenDashboardCacheSpyDatabase(stubs: [
            .success(value: 1, delayNanoseconds: 150_000_000),
            .success(value: 2),
        ])
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        let firstReload = Task { await viewModel.reload() }
        try await Task.sleep(nanoseconds: 20_000_000)

        viewModel.selectedBreakdownDimension = .effort
        let secondResult = await viewModel.reload()
        let firstResult = await firstReload.value

        XCTAssertTrue(secondResult)
        XCTAssertFalse(firstResult)
        let requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.selectedBreakdownDimension, .effort)
        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 2_000)
    }

    @MainActor
    func testTokenDashboardSnapshotCachePrunesToBoundedEntryCount() async throws {
        let database = TokenDashboardCacheSpyDatabase()
        let viewModel = TokenDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        for range in UsageHistoryRange.allCases {
            viewModel.selectedRange = range
            for breakdownDimension in TokenDashboardBreakdownDimension.allCases {
                viewModel.selectedBreakdownDimension = breakdownDimension
                await viewModel.reload()
            }
        }

        let requestCount = await database.requestCount()
        XCTAssertGreaterThan(requestCount, 24)
        XCTAssertEqual(viewModel.snapshotCacheEntryCount, 24)
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
        await viewModel.waitForAttributionCoverageLoad()

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
        await viewModel.waitForAttributionCoverageLoad()

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
        await viewModel.waitForAttributionCoverageLoad()

        XCTAssertEqual(viewModel.breakdownColumnTitle, "Project")
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["tokens_all"])
        XCTAssertTrue(viewModel.breakdownRows.contains { $0.series.name == "Main Work" })

        viewModel.selectSeries("project:/Users/example/Projects/codex_codex")

        XCTAssertEqual(viewModel.summaryTiles.first?.tokenCount, 165)
        XCTAssertTrue(viewModel.csvText.contains("project,month"))
        XCTAssertTrue(viewModel.csvText.contains("project:/Users/example/Projects/codex_codex,Main Work,project,/Users/example/Projects/codex_codex,Main Work,/Users/example/Projects/codex_codex,input,100"))

        viewModel.selectedBreakdownDimension = .approvalPolicy
        await viewModel.reload()
        await viewModel.waitForAttributionCoverageLoad()

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
        await viewModel.waitForAttributionCoverageLoad()

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
        XCTAssertEqual(emptyViewModel.primaryLoadState, .loaded)
        XCTAssertFalse(emptyViewModel.shouldShowPrimaryLoadingState)
        XCTAssertTrue(emptyViewModel.isDisplayingCurrentSnapshot)
        XCTAssertFalse(emptyViewModel.hasVisiblePoints)
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
            tokenUsage: tokenNotification(
                threadID: "thread-a",
                turnID: "turn-a",
                lastInput: 100,
                lastTotal: 100,
                totalInput: 100,
                totalTotal: 100
            ),
            at: date("2026-04-13T23:00:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-b",
                turnID: "turn-a",
                lastInput: 200,
                lastTotal: 200,
                totalInput: 200,
                totalTotal: 200
            ),
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
                totalTokens: 415
            )
        )
        XCTAssertEqual(
            try store.tokenTotalForDay(containing: date("2026-04-14T22:00:00Z"), calendar: calendar),
            415
        )
    }

    func testLocalTokenComparisonTotalsUseUTCComponentSums() async throws {
        let store = try makeStore()

        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-april",
                turnID: "turn-a",
                lastInput: 10,
                lastCached: 20,
                lastOutput: 3,
                lastReasoning: 2,
                lastTotal: 13,
                totalInput: 10,
                totalCached: 20,
                totalOutput: 3,
                totalReasoning: 2,
                totalTotal: 13
            ),
            at: date("2026-04-30T23:30:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-may-29",
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
            at: date("2026-05-29T23:30:00Z")
        )
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread-may-30",
                turnID: "turn-a",
                lastInput: 200,
                lastCached: 60,
                lastOutput: 11,
                lastReasoning: 4,
                lastTotal: 211,
                totalInput: 200,
                totalCached: 60,
                totalOutput: 11,
                totalReasoning: 4,
                totalTotal: 211
            ),
            at: date("2026-05-30T00:30:00Z")
        )

        let totals = try store.localTokenComparisonTotals(now: date("2026-05-30T12:00:00Z"))

        XCTAssertEqual(totals.allTimeTokens, 35 + 160 + 275)
        XCTAssertEqual(totals.currentUTCMonthTokens, 160 + 275)
        XCTAssertEqual(totals.currentUTCDayTokens, 275)
    }

    func testProfileTokenComparisonSummaryKeepsServerAndLocalTotalsSeparate() {
        let snapshot = CodexProfileTokenUsageSnapshot(
            fetchedAt: date("2026-05-30T12:00:00Z"),
            lifetimeTokens: 1_000,
            peakDailyTokens: 400,
            dailyBuckets: [
                CodexProfileTokenDailyBucket(date: "2026-05-29", tokens: 100),
                CodexProfileTokenDailyBucket(date: "2026-05-30", tokens: 200),
            ]
        )
        let localTotals = LocalTokenComparisonTotals(
            generatedAt: date("2026-05-30T12:00:00Z"),
            allTimeTokens: 1_500,
            currentUTCMonthTokens: 450,
            currentUTCDayTokens: 275
        )

        let summary = CodexProfileTokenComparisonSummary.make(
            profileSnapshot: snapshot,
            localTotals: localTotals,
            now: date("2026-05-30T12:00:00Z")
        )

        XCTAssertEqual(summary.rows.map(\.title), ["All time", "Current UTC month", "Current UTC day"])
        XCTAssertEqual(summary.rows.map(\.profileTokens), [1_000, 300, 200])
        XCTAssertEqual(summary.rows.map(\.localCapturedTokens), [1_500, 450, 275])
        XCTAssertEqual(summary.rows.map(\.deltaTokens), [500, 150, 75])
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
                totalTokens: 291_376
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
        let totalTokens = await worker.todayTotalTokens(at: timestamp, calendar: calendar)

        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 100,
                cachedInputTokens: 80,
                outputTokens: 5,
                reasoningOutputTokens: 1,
                totalTokens: 186
            )
        )
        XCTAssertEqual(totalTokens, 186)
    }

    func testWorkerTodayTokenTotalsReturnZeroAfterSuccessfulNoNewEventsCheckWithNoRows() async throws {
        let store = try makeStore()
        let timestamp = date("2026-05-17T12:00:00Z")
        try store.recordCodexLiveTokenCaptureState(
            CodexLiveTokenCaptureState(lastCheckedAt: timestamp, status: .noNewEvents)
        )
        let worker = UsageHistoryDatabaseWorker(store: store)

        let totals = await worker.todayTokenCategoryTotals(at: timestamp, calendar: calendar)
        let totalTokens = await worker.todayTotalTokens(at: timestamp, calendar: calendar)

        XCTAssertEqual(totals, .zero)
        XCTAssertEqual(totalTokens, 0)
    }

    func testWorkerTokenWindowTotalsSurviveUTCDayBoundary() async throws {
        let store = try makeStore()
        let sampleTimestamp = date("2026-06-28T04:00:07Z")
        let refreshTimestamp = date("2026-06-29T00:37:00Z")
        try store.record(
            tokenUsage: tokenNotification(
                threadID: "thread",
                turnID: "turn",
                lastInput: 210_000_000,
                lastCached: 200_000_000,
                lastOutput: 10_000_000,
                lastReasoning: 1_365_879,
                lastTotal: 421_365_879,
                totalInput: 210_000_000,
                totalCached: 200_000_000,
                totalOutput: 10_000_000,
                totalReasoning: 1_365_879,
                totalTotal: 421_365_879
            ),
            at: sampleTimestamp
        )
        try store.recordCodexLiveTokenCaptureState(
            CodexLiveTokenCaptureState(lastCheckedAt: refreshTimestamp, status: .noNewEvents)
        )
        let worker = UsageHistoryDatabaseWorker(store: store)
        let periodStart = refreshTimestamp.addingTimeInterval(-7 * 24 * 60 * 60)
        let expectedWindowTotals = TokenCategoryTotals(
            inputTokens: 210_000_000,
            cachedInputTokens: 200_000_000,
            outputTokens: 10_000_000,
            reasoningOutputTokens: 1_365_879,
            totalTokens: 421_365_879
        )

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(try store.tokenUsageSamples().count, 1)
        XCTAssertEqual(
            try store.tokenCategoryTotals(periodStart: periodStart, periodEnd: refreshTimestamp),
            expectedWindowTotals
        )
        let currentUTCDayTotals = await worker.todayTokenCategoryTotals(at: refreshTimestamp, calendar: utcCalendar)
        let windowTotals = await worker.tokenCategoryTotals(
            periodStart: periodStart,
            periodEnd: refreshTimestamp
        )

        XCTAssertEqual(currentUTCDayTotals, .zero)
        XCTAssertEqual(windowTotals, expectedWindowTotals)
    }

    func testApplicationSupportFallbackWorkerDoesNotPermanentlyHideTokenTotals() async throws {
        let fallbackStore = try makeStore()
        let recoveredStore = try makeStore()
        let timestamp = date("2026-05-17T12:00:00Z")
        try recoveredStore.record(
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
        try recoveredStore.recordCodexLiveTokenCaptureState(
            CodexLiveTokenCaptureState(lastCheckedAt: timestamp, status: .noNewEvents)
        )
        let openSequence = StoreOpenSequence(stores: [fallbackStore, recoveredStore])
        let worker = UsageHistoryDatabaseWorker(
            storeFactory: {
                openSequence.nextStore()
            },
            cacheStoreOnOpen: false
        )

        let firstTotals = await worker.todayTokenCategoryTotals(at: timestamp, calendar: calendar)
        let recoveredTotals = await worker.todayTokenCategoryTotals(at: timestamp, calendar: calendar)

        XCTAssertNil(firstTotals)
        XCTAssertEqual(
            recoveredTotals,
            TokenCategoryTotals(
                inputTokens: 100,
                cachedInputTokens: 80,
                outputTokens: 5,
                reasoningOutputTokens: 1,
                totalTokens: 186
            )
        )
        XCTAssertEqual(openSequence.openAttempts, 2)
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

    func testCodexLogTokenImporterDoesNotTreatPrefixKeysAsModel() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let body = """
        event.name="codex.sse_event" event.kind=response.completed input_token_count=100 output_token_count=2 cached_token_count=80 reasoning_token_count=1 tool_token_count=102 event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation model_provider=openai codex.turn.model=gpt-5.7 cwd='/Users/example/Projects/prefix safe'
        """
        try createCodexLogsDatabase(at: databaseURL, rows: [(timestamp, body)])
        let importer = CodexLogTokenUsageImporter(logsDatabaseURL: databaseURL)

        _ = try importer.importTokenHistory(
            into: store,
            containing: timestamp,
            calendar: calendar
        )
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)
        let dimensions = try store.tokenDimensionCatalogEntries()
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()

        XCTAssertEqual(sample.model, "gpt-5.7")
        XCTAssertEqual(sample.projectPath, "/Users/example/Projects/prefix safe")
        XCTAssertEqual(dimensions, ["model_provider=openai", "source_kind=codex-log"])
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
                totalTokens: 1825
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
                totalTokens: 1_825
            )
        )
    }

    func testLiveTokenCaptureFallsBackToRecentActiveSessionTokensWhenLogsHaveNoTokenEvents() async throws {
        let store = try makeStore()
        let tempDirectory = try makeTemporaryDirectory()
        let databaseURL = tempDirectory.appendingPathComponent("logs_2.sqlite")
        let sessionsURL = tempDirectory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let timestamp = date("2026-06-13T12:48:13Z")

        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (
                    timestamp,
                    """
                    event.name="codex.session_event" event.kind=heartbeat conversation.id=conversation model=gpt-5.5
                    """
                ),
            ]
        )
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-06-13T12-00-00-test.jsonl")
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-06-13T12:48:13Z",
                    lastInput: 100,
                    lastCached: 80,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 120,
                    totalInput: 100,
                    totalCached: 80,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 120,
                    model: "gpt-5.5"
                ),
            ],
            to: sessionURL
        )
        let sessionImporter = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let state = store.captureLiveCodexLogTokenHistory(
            at: timestamp,
            calendar: calendar,
            force: true,
            logsDatabaseURL: databaseURL,
            sessionTokenBackfillImporter: sessionImporter
        )
        let worker = UsageHistoryDatabaseWorker(store: store)
        let totals = await worker.todayTokenCategoryTotals(at: timestamp, calendar: calendar)

        XCTAssertEqual(state.status, .imported)
        XCTAssertEqual(state.result.insertedCount, 1)
        XCTAssertEqual(state.lastImportedEventAt, timestamp)
        XCTAssertEqual(
            totals,
            TokenCategoryTotals(
                inputTokens: 100,
                cachedInputTokens: 80,
                outputTokens: 20,
                reasoningOutputTokens: 5,
                totalTokens: 205
            )
        )
    }

    func testLiveTokenCaptureSessionFallbackUsesNarrowNonForcedRequest() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-06-13T12:48:13Z")
        try createCodexLogsDatabase(
            at: databaseURL,
            rows: [
                (
                    timestamp,
                    """
                    event.name="codex.session_event" event.kind=heartbeat conversation.id=conversation model=gpt-5.5
                    """
                ),
            ]
        )
        let sessionImporter = StubTokenBackfillImporter { _, request in
            CodexSessionTokenBackfillSummary(
                request: request,
                filesScanned: 0,
                tokenEventsImported: 0,
                duplicateEventsSkipped: 0,
                failedLinesSkipped: 0
            )
        }

        let state = store.captureLiveCodexLogTokenHistory(
            at: timestamp,
            calendar: calendar,
            force: true,
            logsDatabaseURL: databaseURL,
            sessionTokenBackfillImporter: sessionImporter
        )

        XCTAssertEqual(state.status, .noNewEvents)
        XCTAssertEqual(sessionImporter.receivedRequests.count, 1)
        let request = try XCTUnwrap(sessionImporter.receivedRequests.first)
        XCTAssertEqual(request.mode, .recent)
        XCTAssertEqual(
            request.since,
            Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -UsageHistoryStore.liveSessionTokenFallbackRecentDayCount,
                to: timestamp
            )
        )
        XCTAssertFalse(request.forceRescan)
        XCTAssertEqual(request.maximumFileSize, UsageHistoryStore.liveSessionTokenFallbackMaximumFileSize)
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

    func testCodexOtelTurnPerformanceImporterCapturesSafeMetadataOnly() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let body = """
        event.name="codex.sse_event" event.kind=response.completed "duration_ms":1234 success=true event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation turn.id=turn-a model=gpt-5.5 slug=gpt-5.5 codex.turn.reasoning_effort=xhigh cwd="/Users/example/Projects/otel app" source=desktop originator=vscode app.version=1.2.3 terminal.type=apple-terminal transport=websocket wire_api=responses api.path=/v1/responses user.email=private@example.com user.account_id=acct_123 prompt="do not store this" request_body="secret"
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rowsWithTargets: [(timestamp, "codex_otel.trace_safe", body)]
        )
        let importer = CodexOtelTurnPerformanceImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTurnPerformanceEvents(
            into: store,
            afterLogRowID: 0,
            containing: timestamp,
            calendar: calendar
        )
        let event = try XCTUnwrap(store.turnPerformanceEvents().first)

        XCTAssertEqual(result.importResult, CodexTurnPerformanceImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(result.maxLogRowID, 1)
        XCTAssertEqual(event.target, "codex_otel.trace_safe")
        XCTAssertEqual(event.eventName, "codex.sse_event")
        XCTAssertEqual(event.eventKind, "response.completed")
        XCTAssertEqual(event.durationMilliseconds, 1_234)
        XCTAssertEqual(event.success, true)
        XCTAssertEqual(event.threadID, "conversation")
        XCTAssertEqual(event.turnID, "turn-a")
        XCTAssertEqual(event.model, "gpt-5.5")
        XCTAssertEqual(event.sessionID, "conversation")
        XCTAssertEqual(event.projectPath, "/Users/example/Projects/otel app")
        XCTAssertEqual(event.projectName, "otel app")
        XCTAssertEqual(event.effort, "xhigh")
        XCTAssertEqual(event.source, "desktop")
        XCTAssertEqual(event.originator, "vscode")
        XCTAssertEqual(event.appVersion, "1.2.3")
        XCTAssertEqual(event.terminalType, "apple-terminal")
        XCTAssertEqual(event.transport, "websocket")
        XCTAssertEqual(event.wireAPI, "responses")
        XCTAssertEqual(event.apiPath, "/v1/responses")
        XCTAssertFalse(String(describing: event).contains("private@example.com"))
        XCTAssertFalse(String(describing: event).contains("acct_123"))
        XCTAssertFalse(String(describing: event).contains("secret"))
    }

    func testCodexOtelTurnPerformanceImporterMapsUnsafeErrorToSafeSummary() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let body = """
        event.name=codex.websocket_event event.kind=response.failed duration_ms=20 success=false event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation error.message="stream disconnected for user.email=private@example.com" model=gpt-5.5 cwd=/Users/example/Projects/otel
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rowsWithTargets: [(timestamp, "codex_api::endpoint::responses_websocket", body)]
        )
        let importer = CodexOtelTurnPerformanceImporter(logsDatabaseURL: databaseURL)

        _ = try importer.importTurnPerformanceEvents(
            into: store,
            afterLogRowID: 0,
            containing: timestamp,
            calendar: calendar
        )
        let event = try XCTUnwrap(store.turnPerformanceEvents().first)

        XCTAssertEqual(event.success, false)
        XCTAssertEqual(event.errorSummary, "connection")
        XCTAssertFalse(String(describing: event).contains("private@example.com"))
    }

    func testCodexOtelTurnPerformanceImporterCapturesRuntimeDimensionsOnly() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let body = """
        event.name="codex.sse_event" event.kind=response.completed event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation auth_mode=chatgpt turn.has_metadata_header=true websocket.warmup=connected codex.request.reasoning_effort=high request.item_count=7 connection.retry_count=2 tool_output_size_bytes=20480 prompt="do not store this" message="do not store this" tool_output="private tool result" request_body="private request" response_body="private response" user.email=private@example.com
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rowsWithTargets: [(timestamp, "codex_otel.log_only", body)]
        )
        let importer = CodexOtelTurnPerformanceImporter(logsDatabaseURL: databaseURL)

        let result = try importer.importTurnPerformanceEvents(
            into: store,
            afterLogRowID: 0,
            containing: timestamp,
            calendar: calendar
        )
        let event = try XCTUnwrap(store.turnPerformanceEvents().first)
        let dimensions = event.runtimeDimensions.map { "\($0.key.rawValue)=\($0.value)" }

        XCTAssertEqual(result.importResult.insertedCount, 1)
        XCTAssertEqual(result.importResult.runtimeDimensionInsertedCount, 7)
        XCTAssertEqual(event.effort, "high")
        XCTAssertEqual(
            dimensions,
            [
                "auth_mode=chatgpt",
                "connection_retry_count_bucket=2-5",
                "request_item_count_bucket=6-20",
                "request_reasoning_effort=high",
                "tool_output_size_bucket=10k-100k",
                "turn_has_metadata_header=true",
                "websocket_warmup=connected",
            ]
        )
        XCTAssertFalse(String(describing: event).contains("private@example.com"))
        XCTAssertFalse(String(describing: event).contains("private tool result"))
        XCTAssertFalse(String(describing: event).contains("private request"))
        XCTAssertFalse(String(describing: event).contains("private response"))
        XCTAssertEqual(try store.turnPerformanceRuntimeDimensionSummary().rowCount, 7)
        XCTAssertEqual(try store.turnPerformanceRuntimeDimensionCatalogEntries().count, 7)
    }

    func testCodexOtelTurnPerformanceDuplicateImportRepairsRuntimeDimensions() async throws {
        let store = try makeStore()
        let timestamp = date("2026-05-17T12:48:13Z")
        let baseEvent = CodexTurnPerformanceEvent(
            sourceKey: "codex-otel-logs",
            sourceRowID: 10,
            target: "codex_otel.trace_safe",
            eventTimestamp: timestamp,
            eventName: "codex.sse_event",
            eventKind: "response.completed",
            durationMilliseconds: 100,
            success: true,
            errorSummary: nil,
            threadID: "conversation",
            turnID: "turn-a",
            model: "gpt-5.5",
            sessionID: "conversation",
            projectPath: "/Users/example/Projects/otel",
            effort: "high",
            source: "desktop",
            originator: nil,
            appVersion: nil,
            terminalType: nil,
            transport: nil,
            wireAPI: nil,
            apiPath: nil
        )
        let repairedEvent = CodexTurnPerformanceEvent(
            sourceKey: "codex-otel-logs",
            sourceRowID: 10,
            target: "codex_otel.trace_safe",
            eventTimestamp: timestamp,
            eventName: "codex.sse_event",
            eventKind: "response.completed",
            durationMilliseconds: 100,
            success: true,
            errorSummary: nil,
            threadID: "conversation",
            turnID: "turn-a",
            model: "gpt-5.5",
            sessionID: "conversation",
            projectPath: "/Users/example/Projects/otel",
            effort: "high",
            source: "desktop",
            originator: nil,
            appVersion: nil,
            terminalType: nil,
            transport: nil,
            wireAPI: nil,
            apiPath: nil,
            runtimeDimensions: [
                try XCTUnwrap(CodexOtelRuntimeDimension(.authMode, "chatgpt")),
                try XCTUnwrap(CodexOtelRuntimeDimension.boolean(.turnHasMetadataHeader, "true")),
            ]
        )

        let firstResult = try store.importTurnPerformanceEvents([baseEvent])
        let secondResult = try store.importTurnPerformanceEvents([repairedEvent])

        XCTAssertEqual(firstResult, CodexTurnPerformanceImportResult(insertedCount: 1, duplicateCount: 0))
        XCTAssertEqual(secondResult.insertedCount, 0)
        XCTAssertEqual(secondResult.duplicateCount, 1)
        XCTAssertEqual(secondResult.runtimeDimensionInsertedCount, 2)
        XCTAssertEqual(try store.turnPerformanceEvents().count, 1)
        XCTAssertEqual(try store.turnPerformanceEvents().first?.runtimeDimensions.count, 2)
        XCTAssertEqual(try store.turnPerformanceRuntimeDimensionSummary().distinctKeyCount, 2)
    }

    func testCodexOtelTurnPerformanceCaptureIsIncrementalAndRecordsState() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let body = """
        event.name=codex.sse_event event.kind=response.completed duration_ms=100 success=true event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation model=gpt-5.5
        """
        try createCodexLogsDatabase(
            at: databaseURL,
            rowsWithTargets: [(timestamp, "codex_api::sse::responses", body)]
        )

        let firstState = store.captureCodexOtelTurnPerformance(
            at: timestamp,
            calendar: calendar,
            force: true,
            logsDatabaseURL: databaseURL
        )
        let secondState = store.captureCodexOtelTurnPerformance(
            at: timestamp.addingTimeInterval(10),
            calendar: calendar,
            force: true,
            logsDatabaseURL: databaseURL
        )

        XCTAssertEqual(firstState.status, .imported)
        XCTAssertEqual(firstState.insertedCount, 1)
        XCTAssertEqual(firstState.lastLogRowID, 1)
        XCTAssertEqual(secondState.status, .noNewEvents)
        XCTAssertEqual(secondState.lastLogRowID, 1)
        XCTAssertEqual(try store.turnPerformanceEvents().count, 1)
        XCTAssertEqual(try store.codexTurnPerformanceCaptureState().status, .noNewEvents)
    }

    func testCodexOtelTurnPerformanceImporterBoundsRowsWithoutSkippingUnprocessedMatches() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let rows: [(Date, String, String)] = (1...3).map { index in
            (
                timestamp.addingTimeInterval(TimeInterval(index)),
                "codex_api::sse::responses",
                """
                event.name=codex.sse_event event.kind=response.completed duration_ms=\(index) success=true event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation-\(index) model=gpt-5.5
                """
            )
        }
        try createCodexLogsDatabase(at: databaseURL, rowsWithTargets: rows)
        let importer = CodexOtelTurnPerformanceImporter(
            logsDatabaseURL: databaseURL,
            maximumRowsPerRun: 2
        )

        let firstResult = try importer.importTurnPerformanceEvents(
            into: store,
            afterLogRowID: 0,
            containing: timestamp,
            calendar: calendar
        )
        let secondResult = try importer.importTurnPerformanceEvents(
            into: store,
            afterLogRowID: firstResult.maxLogRowID,
            containing: timestamp,
            calendar: calendar
        )

        XCTAssertEqual(firstResult.importResult.insertedCount, 2)
        XCTAssertEqual(firstResult.maxLogRowID, 2)
        XCTAssertEqual(secondResult.importResult.insertedCount, 1)
        XCTAssertEqual(secondResult.maxLogRowID, 3)
        XCTAssertEqual(try store.turnPerformanceEvents().count, 3)
    }

    func testCodexOtelTurnPerformanceCaptureUsesBoundedRowsByDefault() async throws {
        let store = try makeStore()
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("logs_2.sqlite")
        let timestamp = date("2026-05-17T12:48:13Z")
        let rows: [(Date, String, String)] = (1...3).map { index in
            (
                timestamp.addingTimeInterval(TimeInterval(index)),
                "codex_api::sse::responses",
                """
                event.name=codex.sse_event event.kind=response.completed duration_ms=\(index) success=true event.timestamp=2026-05-17T12:48:13.035Z conversation.id=conversation-\(index) model=gpt-5.5
                """
            )
        }
        try createCodexLogsDatabase(at: databaseURL, rowsWithTargets: rows)

        let firstState = store.captureCodexOtelTurnPerformance(
            at: timestamp,
            calendar: calendar,
            force: true,
            logsDatabaseURL: databaseURL,
            maximumRowsPerRun: 2
        )
        let secondState = store.captureCodexOtelTurnPerformance(
            at: timestamp.addingTimeInterval(1),
            calendar: calendar,
            force: true,
            logsDatabaseURL: databaseURL,
            maximumRowsPerRun: 2
        )

        XCTAssertEqual(firstState.status, .imported)
        XCTAssertEqual(firstState.insertedCount, 2)
        XCTAssertEqual(firstState.lastLogRowID, 2)
        XCTAssertEqual(secondState.status, .imported)
        XCTAssertEqual(secondState.insertedCount, 1)
        XCTAssertEqual(secondState.lastLogRowID, 3)
        XCTAssertEqual(try store.turnPerformanceEvents().count, 3)
    }

    func testPerformanceDashboardQueriesAggregateTimingAndReliabilityInputs() async throws {
        let store = try makeStore()
        try seedPerformanceDashboardFixture(in: store)

        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")
        let timingSamples = try store.performanceDashboardTimingSamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let reliabilitySamples = try store.performanceDashboardReliabilitySamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let presentation = PerformanceDashboardPresentationBuilder.build(
            timingSamples: timingSamples,
            reliabilitySamples: reliabilitySamples,
            breakdownDimension: .model,
            range: .month,
            calendar: calendar
        )
        let rowsByID = Dictionary(uniqueKeysWithValues: presentation.breakdownRows.map { ($0.id, $0) })
        let aggregate = try XCTUnwrap(rowsByID[PerformanceDashboardSeries.aggregateID])
        let model = try XCTUnwrap(rowsByID["model:gpt-5.5"])

        XCTAssertEqual(timingSamples.count, 4)
        XCTAssertEqual(reliabilitySamples.count, 3)
        XCTAssertEqual(aggregate.turnCount, 4)
        XCTAssertEqual(aggregate.completedTurnCount, 3)
        XCTAssertEqual(aggregate.incompleteTurnCount, 1)
        XCTAssertEqual(aggregate.medianDurationMilliseconds, 3_000)
        XCTAssertEqual(aggregate.p95DurationMilliseconds, 9_000)
        XCTAssertEqual(aggregate.medianFirstTokenMilliseconds, 300)
        XCTAssertEqual(aggregate.eventCount, 3)
        XCTAssertEqual(aggregate.failureCount, 1)
        XCTAssertEqual(aggregate.failurePercent, 0.5, accuracy: 0.0001)
        XCTAssertEqual(aggregate.topErrorSummary, "connection")
        XCTAssertEqual(model.turnCount, 2)
        XCTAssertEqual(model.medianDurationMilliseconds, 2_000)
        XCTAssertEqual(model.p95DurationMilliseconds, 3_000)
        XCTAssertEqual(model.eventCount, 2)
        XCTAssertEqual(try store.performanceDashboardBounds()?.earliest, date("2026-05-02T10:00:00Z"))
    }

    func testSessionTaskTimingUpsertMaintainsIndexedEventTimestamp() throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let completed = date("2026-05-17T10:00:05Z")
        let started = date("2026-05-17T10:00:00Z")

        let firstImport = try store.importSessionTaskTimingEvents([
            try XCTUnwrap(CodexSessionTaskTimingEvent(
                sessionID: "session-event-timestamp",
                turnID: "turn-a",
                completedAt: completed,
                recordedAt: completed
            )),
        ])

        XCTAssertEqual(firstImport.insertedCount, 1)
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT CAST(event_timestamp AS TEXT) FROM codex_session_task_timing_events WHERE session_id = 'session-event-timestamp'"
            ),
            ["\(completed.timeIntervalSince1970Int)"]
        )

        let repairImport = try store.importSessionTaskTimingEvents([
            try XCTUnwrap(CodexSessionTaskTimingEvent(
                sessionID: "session-event-timestamp",
                turnID: "turn-a",
                startedAt: started,
                recordedAt: completed
            )),
        ])

        XCTAssertEqual(repairImport.updatedCount, 1)
        XCTAssertEqual(
            try sqliteStrings(
                at: databaseURL,
                sql: "SELECT CAST(event_timestamp AS TEXT) FROM codex_session_task_timing_events WHERE session_id = 'session-event-timestamp'"
            ),
            ["\(started.timeIntervalSince1970Int)"]
        )
        XCTAssertEqual(try store.sessionTaskTimingEvents().count, 1)
    }

    func testPerformanceDashboardPresentationQueryMatchesBuilderForBreakdowns() throws {
        let store = try makeStore()
        try seedPerformanceDashboardFixture(in: store)

        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")
        let timingSamples = try store.performanceDashboardTimingSamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let reliabilitySamples = try store.performanceDashboardReliabilitySamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )

        for breakdownDimension in PerformanceDashboardBreakdownDimension.allCases {
            let expected = PerformanceDashboardPresentationBuilder.build(
                timingSamples: timingSamples,
                reliabilitySamples: reliabilitySamples,
                breakdownDimension: breakdownDimension,
                range: .month,
                calendar: calendar
            )
            let actual = try store.performanceDashboardPresentation(
                breakdownDimension: breakdownDimension,
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd,
                calendar: calendar
            )

            XCTAssertEqual(actual.durationPoints, expected.durationPoints, "duration points for \(breakdownDimension)")
            XCTAssertEqual(actual.reliabilityPoints, expected.reliabilityPoints, "reliability points for \(breakdownDimension)")
            XCTAssertEqual(actual.breakdownRows, expected.breakdownRows, "breakdown rows for \(breakdownDimension)")
            XCTAssertEqual(actual.series, expected.series, "series for \(breakdownDimension)")
        }
    }

    func testPerformanceDashboardReliabilityQueryPreservesErrorCountsAndUnknownRows() throws {
        let store = try makeStore()
        try store.importTurnPerformanceEvents([
            performanceDashboardReliabilityEvent(
                rowID: 1,
                timestamp: date("2026-05-02T10:00:00Z"),
                success: true,
                model: "gpt-5.5",
                transport: "websocket"
            ),
            performanceDashboardReliabilityEvent(
                rowID: 2,
                timestamp: date("2026-05-02T11:00:00Z"),
                success: false,
                errorSummary: "timeout",
                model: "gpt-5.5",
                transport: "websocket"
            ),
            performanceDashboardReliabilityEvent(
                rowID: 3,
                timestamp: date("2026-05-02T12:00:00Z"),
                success: false,
                errorSummary: "timeout",
                model: "gpt-5.5",
                transport: "websocket"
            ),
            performanceDashboardReliabilityEvent(
                rowID: 4,
                timestamp: date("2026-05-02T13:00:00Z"),
                success: false,
                errorSummary: "connection",
                model: "gpt-5.4",
                transport: "sse"
            ),
            performanceDashboardReliabilityEvent(
                rowID: 5,
                timestamp: date("2026-05-02T14:00:00Z"),
                success: nil,
                model: nil,
                transport: nil
            ),
        ])

        let points = try store.performanceDashboardReliabilityPoints(
            breakdownDimension: .model,
            range: .month,
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z"),
            calendar: calendar
        )
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.series.id, $0) })
        let aggregate = try XCTUnwrap(pointsByID[PerformanceDashboardSeries.aggregateID])
        let model55 = try XCTUnwrap(pointsByID["model:gpt-5.5"])
        let model54 = try XCTUnwrap(pointsByID["model:gpt-5.4"])
        let unattributed = try XCTUnwrap(pointsByID[PerformanceDashboardSeries.unattributedID])

        XCTAssertEqual(aggregate.successCount, 1)
        XCTAssertEqual(aggregate.failureCount, 3)
        XCTAssertEqual(aggregate.unknownCount, 1)
        XCTAssertEqual(aggregate.errorCounts, ["timeout": 2, "connection": 1])
        XCTAssertEqual(aggregate.topErrorSummary, "timeout")
        XCTAssertEqual(model55.successCount, 1)
        XCTAssertEqual(model55.failureCount, 2)
        XCTAssertEqual(model55.errorCounts, ["timeout": 2])
        XCTAssertEqual(model54.successCount, 0)
        XCTAssertEqual(model54.failureCount, 1)
        XCTAssertEqual(model54.errorCounts, ["connection": 1])
        XCTAssertEqual(unattributed.unknownCount, 1)
        XCTAssertEqual(unattributed.failureCount, 0)
        XCTAssertNil(unattributed.topErrorSummary)

        let transportPoints = try store.performanceDashboardReliabilityPoints(
            breakdownDimension: .transport,
            range: .month,
            periodStart: date("2026-05-01T00:00:00Z"),
            periodEnd: date("2026-06-01T00:00:00Z"),
            calendar: calendar
        )
        let transportIDs = Set(transportPoints.map(\.series.id))
        XCTAssertTrue(transportIDs.contains("transport:websocket"))
        XCTAssertTrue(transportIDs.contains("transport:sse"))
        XCTAssertTrue(transportIDs.contains(PerformanceDashboardSeries.unattributedID))
    }

    @MainActor
    func testPerformanceDashboardViewModelDefaultsFiltersAndExportsVisibleRows() async throws {
        let store = try makeStore()
        try seedPerformanceDashboardFixture(in: store)

        let viewModel = PerformanceDashboardViewModel(
            store: store,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedRange, .month)
        XCTAssertEqual(viewModel.selectedBreakdownDimension, .model)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedSeriesIDs, [PerformanceDashboardSeries.aggregateID])
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "4")
        XCTAssertTrue(viewModel.efficiencyTokenSamples.isEmpty)
        XCTAssertEqual(viewModel.modelCapabilities.map(\.slug), ["gpt-5.5"])
        XCTAssertEqual(viewModel.exportFilename, "codex-performance-dashboard-month-2026-05.csv")
        XCTAssertEqual(viewModel.formattedDuration(1_250), "1.2s")
        XCTAssertEqual(viewModel.formattedCountAxisValue(1_200_000), "1.2M")
        XCTAssertTrue(viewModel.csvText.contains("duration_bucket,month"))
        XCTAssertTrue(viewModel.csvText.contains("reliability_bucket,month"))
        XCTAssertTrue(viewModel.csvText.contains("breakdown_row,model,performance_all,All,aggregate,all,,4"))
        let modelSeries = try XCTUnwrap(viewModel.breakdownRows.first { $0.series.id == "model:gpt-5.5" }?.series)
        XCTAssertEqual(viewModel.modelCapabilityAnnotation(for: modelSeries)?.compactText, "Ctx 100k · Reason high · Image · Web")
        XCTAssertNil(viewModel.modelCapabilityAnnotation(for: try XCTUnwrap(viewModel.breakdownRows.first { $0.series.id == PerformanceDashboardSeries.aggregateID }?.series)))

        viewModel.selectSeries("model:gpt-5.5")

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["model:gpt-5.5"])
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "2")
        XCTAssertTrue(viewModel.csvText.contains("breakdown_row,model,model:gpt-5.5,gpt-5.5,model,gpt-5.5,,2"))
        XCTAssertFalse(viewModel.csvText.contains("model:gpt-5.4"))

        viewModel.selectedBreakdownDimension = .transport
        await viewModel.reload()

        XCTAssertEqual(viewModel.breakdownColumnTitle, "Transport")
        XCTAssertEqual(viewModel.selectedSeriesIDs, [PerformanceDashboardSeries.aggregateID])
        XCTAssertTrue(viewModel.modelCapabilities.isEmpty)
        XCTAssertTrue(viewModel.breakdownRows.contains { $0.series.id == "transport:websocket" })
        XCTAssertTrue(viewModel.breakdownRows.contains { $0.series.id == "transport:sse" })
        XCTAssertNil(viewModel.modelCapabilityAnnotation(for: try XCTUnwrap(viewModel.breakdownRows.first { $0.series.id == "transport:websocket" }?.series)))

        viewModel.selectSeries("transport:websocket")

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["transport:websocket"])
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "0")
        XCTAssertEqual(viewModel.visibleSummaryRow.eventCount, 2)
        XCTAssertEqual(viewModel.visibleSummaryRow.failurePercent, 0.5, accuracy: 0.0001)

        viewModel.selectedBreakdownDimension = .model
        await viewModel.reload()
        viewModel.sortBreakdownRows(by: .turns)

        XCTAssertEqual(viewModel.breakdownSortIndicator(for: .turns), "chevron.down")
        XCTAssertEqual(viewModel.sortedBreakdownRows.first?.series.id, PerformanceDashboardSeries.aggregateID)

        viewModel.sortBreakdownRows(by: .turns)

        XCTAssertEqual(viewModel.breakdownSortIndicator(for: .turns), "chevron.up")
        XCTAssertEqual(viewModel.sortedBreakdownRows.last?.series.id, PerformanceDashboardSeries.aggregateID)
    }

    func testPerformanceDashboardWorkerSnapshotsAreModeSpecific() async throws {
        let store = try makeStore()
        try seedPerformanceDashboardFixture(in: store)
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "token-only",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 1_000,
                    lastCached: 0,
                    lastOutput: 0,
                    lastReasoning: 0,
                    lastTotal: 1_000,
                    totalInput: 1_000,
                    totalTotal: 1_000
                ),
                receivedAt: date("2026-05-01T09:00:00Z")
            ),
        ])
        let worker = UsageHistoryDatabaseWorker(store: store)
        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")

        let performanceResult = try await worker.performanceDashboardSnapshot(
            for: PerformanceDashboardLoadRequest(
                mode: .performance,
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        )

        XCTAssertTrue(performanceResult.timingSamples.isEmpty)
        XCTAssertTrue(performanceResult.reliabilitySamples.isEmpty)
        XCTAssertTrue(performanceResult.efficiencyTokenSamples.isEmpty)
        XCTAssertEqual(performanceResult.modelCapabilities.map(\.slug), ["gpt-5.5"])
        XCTAssertFalse(performanceResult.durationPoints.isEmpty)
        XCTAssertFalse(performanceResult.reliabilityPoints.isEmpty)
        XCTAssertFalse(performanceResult.breakdownRows.isEmpty)
        XCTAssertTrue(performanceResult.efficiencyPoints.isEmpty)
        XCTAssertTrue(performanceResult.efficiencyRows.isEmpty)
        XCTAssertEqual(performanceResult.historyBounds?.earliest, date("2026-05-02T10:00:00Z"))

        let efficiencyResult = try await worker.performanceDashboardSnapshot(
            for: PerformanceDashboardLoadRequest(
                mode: .efficiency,
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        )

        XCTAssertTrue(efficiencyResult.timingSamples.isEmpty)
        XCTAssertTrue(efficiencyResult.reliabilitySamples.isEmpty)
        XCTAssertTrue(efficiencyResult.efficiencyTokenSamples.isEmpty)
        XCTAssertEqual(efficiencyResult.modelCapabilities.map(\.slug), ["gpt-5.5"])
        XCTAssertTrue(efficiencyResult.durationPoints.isEmpty)
        XCTAssertTrue(efficiencyResult.reliabilityPoints.isEmpty)
        XCTAssertTrue(efficiencyResult.breakdownRows.isEmpty)
        XCTAssertFalse(efficiencyResult.efficiencyPoints.isEmpty)
        XCTAssertFalse(efficiencyResult.efficiencyRows.isEmpty)
        XCTAssertEqual(efficiencyResult.historyBounds?.earliest, date("2026-05-01T09:00:00Z"))
    }

    func testDashboardSnapshotsDoNotRunMetadataCaptureImporters() async throws {
        let directory = try makeTemporaryDirectory()
        let appSupportDirectory = directory.appendingPathComponent(
            "Library/Application Support/CodexStatusBar",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let store = try UsageHistoryStore(
            databaseURL: appSupportDirectory.appendingPathComponent("usage-history.sqlite3"),
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        try seedPerformanceDashboardFixture(in: store)
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "token-dashboard",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 1_000,
                    lastCached: 200,
                    lastOutput: 300,
                    lastReasoning: 50,
                    lastTotal: 1_300,
                    totalInput: 1_000,
                    totalCached: 200,
                    totalOutput: 300,
                    totalReasoning: 50,
                    totalTotal: 1_300
                ),
                receivedAt: date("2026-05-02T12:00:00Z")
            ),
        ])
        let importerSpy = DashboardMetadataImporterSpy()
        let worker = UsageHistoryDatabaseWorker(
            store: store,
            turnPerformanceImporter: { store, date, calendar, force in
                importerSpy.captureTurnPerformance(store: store, date: date, calendar: calendar, force: force)
            },
            sessionTaskTimingImporter: { store, date, calendar, force in
                importerSpy.captureSessionTaskTiming(store: store, date: date, calendar: calendar, force: force)
            }
        )
        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")

        let tokenResult = try await worker.tokenDashboardSnapshot(
            for: TokenDashboardLoadRequest(
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        )
        XCTAssertFalse(tokenResult.points.isEmpty)

        let performanceResult = try await worker.performanceDashboardSnapshot(
            for: PerformanceDashboardLoadRequest(
                mode: .performance,
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        )
        XCTAssertFalse(performanceResult.durationPoints.isEmpty)
        XCTAssertFalse(performanceResult.reliabilityPoints.isEmpty)

        XCTAssertEqual(importerSpy.eventsSnapshot(), [])

        _ = await worker.captureTurnPerformanceIfNeeded(at: date("2026-05-02T12:05:00Z"), calendar: calendar, force: false)
        _ = await worker.captureSessionTaskTimingIfNeeded(at: date("2026-05-02T12:06:00Z"), calendar: calendar, force: false)

        XCTAssertEqual(
            importerSpy.eventsSnapshot(),
            [
                DashboardMetadataImporterSpy.Event(kind: .turnPerformance, force: false),
                DashboardMetadataImporterSpy.Event(kind: .sessionTaskTiming, force: false),
            ]
        )
    }

    func testTokenDashboardSnapshotCanSkipAndLoadAttributionCoverageSeparately() async throws {
        let store = try makeStore()
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "coverage-thread",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 1_000,
                    lastCached: 200,
                    lastOutput: 300,
                    lastReasoning: 50,
                    lastTotal: 1_550,
                    totalInput: 1_000,
                    totalCached: 200,
                    totalOutput: 300,
                    totalReasoning: 50,
                    totalTotal: 1_550
                ),
                receivedAt: date("2026-05-02T12:00:03Z"),
                context: TokenUsageContext(effort: "high", source: "cli")
            ),
        ])
        let worker = UsageHistoryDatabaseWorker(store: store)
        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")
        let primaryRequest = TokenDashboardLoadRequest(
            range: .month,
            periodStart: periodStart,
            periodEnd: periodEnd,
            includeAttributionCoverage: false
        )
        let fullRequest = TokenDashboardLoadRequest(
            range: .month,
            periodStart: periodStart,
            periodEnd: periodEnd,
            includeAttributionCoverage: true
        )

        let primary = try await worker.tokenDashboardSnapshot(for: primaryRequest)
        let full = try await worker.tokenDashboardSnapshot(for: fullRequest)
        let coverageRows = try await worker.tokenAttributionCoverageRows(
            periodStart: periodStart,
            periodEnd: periodEnd
        )

        XCTAssertEqual(primary.points, full.points)
        XCTAssertEqual(primary.series, full.series)
        XCTAssertEqual(primary.availableBreakdownDimensions, full.availableBreakdownDimensions)
        XCTAssertEqual(primary.historyBounds, full.historyBounds)
        XCTAssertTrue(primary.attributionCoverageRows.isEmpty)
        XCTAssertFalse(full.attributionCoverageRows.isEmpty)
        XCTAssertEqual(coverageRows, full.attributionCoverageRows)
        XCTAssertNil(primary.queryTimings.attributionCoverage)
        XCTAssertNotNil(full.queryTimings.attributionCoverage)
    }

    func testReadOnlyDashboardQueryWorkerMatchesWriterSnapshots() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        try store.record(
            snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7),
            at: date("2026-05-02T12:00:00Z")
        )
        try seedPerformanceDashboardFixture(in: store)
        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "readonly-token",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 1_000,
                    lastCached: 200,
                    lastOutput: 300,
                    lastReasoning: 50,
                    lastTotal: 1_300,
                    totalInput: 1_000,
                    totalCached: 200,
                    totalOutput: 300,
                    totalReasoning: 50,
                    totalTotal: 1_300
                ),
                receivedAt: date("2026-05-02T12:00:03Z")
            ),
        ])

        let readOnlyStore = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar,
            openMode: .readOnly
        )
        let tempStoreStatement = try readOnlyStore.prepare("PRAGMA temp_store")
        defer { sqlite3_finalize(tempStoreStatement) }
        XCTAssertEqual(sqlite3_step(tempStoreStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(tempStoreStatement, 0), 2)

        let writer = UsageHistoryDatabaseWorker(store: store)
        let queryWorker = UsageHistoryDashboardQueryWorker(store: readOnlyStore)
        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")
        let usageRequest = UsageHistoryLoadRequest(
            chartKind: .capacity,
            range: .month,
            window: .sevenDay,
            periodStart: periodStart,
            periodEnd: periodEnd,
            now: date("2026-05-03T00:00:00Z"),
            calendar: calendar
        )
        let tokenRequest = TokenDashboardLoadRequest(
            range: .month,
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let performanceRequest = PerformanceDashboardLoadRequest(
            mode: .performance,
            range: .month,
            periodStart: periodStart,
            periodEnd: periodEnd,
            calendar: calendar
        )

        let readOnlyUsageSnapshot = try await queryWorker.usageHistorySnapshot(for: usageRequest)
        let writerUsageSnapshot = try await writer.usageHistorySnapshot(for: usageRequest)
        let readOnlyTokenSnapshot = try await queryWorker.tokenDashboardSnapshot(for: tokenRequest)
        let writerTokenSnapshot = try await writer.tokenDashboardSnapshot(for: tokenRequest)
        let readOnlyPerformanceSnapshot = try await queryWorker.performanceDashboardSnapshot(for: performanceRequest)
        let writerPerformanceSnapshot = try await writer.performanceDashboardSnapshot(for: performanceRequest)

        XCTAssertEqual(readOnlyUsageSnapshot, writerUsageSnapshot)
        XCTAssertEqual(readOnlyTokenSnapshot, writerTokenSnapshot)
        XCTAssertEqual(readOnlyPerformanceSnapshot, writerPerformanceSnapshot)
        XCTAssertThrowsError(
            try readOnlyStore.record(
                snapshot: CodexUsageSnapshot.aggregateOnly(
                    displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 99)
                ),
                at: date("2026-05-02T12:10:00Z")
            )
        )
    }

    func testDashboardQueryWorkerMissingDatabaseReturnsEmptySnapshot() async throws {
        let currentCalendar = try XCTUnwrap(calendar)
        let queryWorker = UsageHistoryDashboardQueryWorker(
            storeFactory: {
                throw UsageHistoryStoreError.databaseOpenFailed("missing fixture")
            },
            fallbackStoreFactory: {
                try UsageHistoryStore.inMemory(
                    notificationCenter: NotificationCenter(),
                    calendar: currentCalendar
                )
            }
        )
        let result = try await queryWorker.usageHistorySnapshot(
            for: UsageHistoryLoadRequest(
                chartKind: .capacity,
                range: .day,
                window: .sevenDay,
                periodStart: date("2026-05-02T00:00:00Z"),
                periodEnd: date("2026-05-03T00:00:00Z"),
                now: date("2026-05-02T12:00:00Z"),
                calendar: calendar
            )
        )

        XCTAssertFalse(result.hasAnyHistory)
        XCTAssertTrue(result.points.isEmpty)
        XCTAssertTrue(result.series.isEmpty)
    }

    func testDatabaseRouterRoutesSnapshotsToQueryWorkerAndWritesToWriter() async throws {
        let writer = DashboardRoutingWriterSpy()
        let query = DashboardRoutingQuerySpy()
        let router = UsageHistoryDatabaseRouter(writer: writer, dashboardQueryWorker: query)
        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")

        _ = try await router.usageHistorySnapshot(
            for: UsageHistoryLoadRequest(
                chartKind: .capacity,
                range: .month,
                window: .sevenDay,
                periodStart: periodStart,
                periodEnd: periodEnd,
                now: date("2026-05-02T12:00:00Z"),
                calendar: calendar
            )
        )
        _ = try await router.tokenDashboardSnapshot(
            for: TokenDashboardLoadRequest(
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        )
        _ = try await router.performanceDashboardSnapshot(
            for: PerformanceDashboardLoadRequest(
                mode: .performance,
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd,
                calendar: calendar
            )
        )
        _ = await router.captureTurnPerformanceIfNeeded(
            at: date("2026-05-02T12:05:00Z"),
            calendar: calendar,
            force: true
        )

        let queryEvents = await query.eventsSnapshot()
        let writerEvents = await writer.eventsSnapshot()

        XCTAssertEqual(queryEvents, [.usageHistory, .tokenDashboard, .performanceDashboard])
        XCTAssertEqual(writerEvents, [.turnPerformance(force: true)])
    }

    func testRouterSnapshotCompletesWhileWriterCaptureIsBlocked() async throws {
        let writer = BlockingDashboardRoutingWriterSpy()
        let query = DashboardRoutingQuerySpy()
        let router = UsageHistoryDatabaseRouter(writer: writer, dashboardQueryWorker: query)
        let captureDate = date("2026-05-02T12:05:00Z")
        let currentCalendar = try XCTUnwrap(calendar)
        let captureTask = Task {
            await router.captureTurnPerformanceIfNeeded(
                at: captureDate,
                calendar: currentCalendar,
                force: true
            )
        }

        await writer.waitForCaptureStart()
        let snapshot = try await router.usageHistorySnapshot(
            for: UsageHistoryLoadRequest(
                chartKind: .capacity,
                range: .month,
                window: .sevenDay,
                periodStart: date("2026-05-01T00:00:00Z"),
                periodEnd: date("2026-06-01T00:00:00Z"),
                now: date("2026-05-02T12:00:00Z"),
                calendar: calendar
            )
        )

        await writer.releaseCapture()
        _ = await captureTask.value
        let queryEvents = await query.eventsSnapshot()

        XCTAssertFalse(snapshot.hasAnyHistory)
        XCTAssertEqual(queryEvents, [.usageHistory])
    }

    @MainActor
    func testBackgroundMetadataCaptureCoordinatorDelaysAndStaggersNonForcedCaptures() async throws {
        let database = BackgroundMetadataCaptureSpyDatabase(failTurnPerformance: true)
        let delayRecorder = BackgroundMetadataCaptureDelayRecorder()
        let now = date("2026-05-02T12:00:00Z")
        let coordinator = CodexBackgroundMetadataCaptureCoordinator(
            database: database,
            initialDelay: 10,
            staggerDelay: 5,
            now: { now },
            sleeper: { interval in
                await delayRecorder.record(interval)
            }
        )

        await coordinator.runOnce()

        let recordedDelays = await delayRecorder.intervalsSnapshot()
        let captureEvents = await database.eventsSnapshot()
        let liveTokenCaptureCount = await database.liveTokenCaptureCount()

        XCTAssertEqual(recordedDelays, [10, 5, 5, 5])
        XCTAssertEqual(
            captureEvents,
            [
                .turnPerformance(force: false),
                .sessionTaskTiming(force: false),
                .threadCatalog(force: false),
                .modelCapabilities(force: false),
            ]
        )
        XCTAssertEqual(liveTokenCaptureCount, 0)
    }

    func testPerformanceDashboardEfficiencyAggregatesTokensTimingReliabilityAndContext() async throws {
        let store = try makeStore()
        try seedPerformanceDashboardFixture(in: store)

        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")
        let tokenSamples = try store.performanceDashboardEfficiencyTokenSamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let timingSamples = try store.performanceDashboardTimingSamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let reliabilitySamples = try store.performanceDashboardReliabilitySamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let presentation = PerformanceDashboardPresentationBuilder.buildEfficiency(
            tokenSamples: tokenSamples,
            timingSamples: timingSamples,
            reliabilitySamples: reliabilitySamples,
            modelCapabilities: try store.codexModelCapabilities(),
            breakdownDimension: .model,
            range: .month,
            calendar: calendar
        )
        let rowsByID = Dictionary(uniqueKeysWithValues: presentation.rows.map { ($0.id, $0) })
        let aggregate = try XCTUnwrap(rowsByID[PerformanceDashboardSeries.aggregateID])
        let model = try XCTUnwrap(rowsByID["model:gpt-5.5"])

        XCTAssertEqual(tokenSamples.count, 3)
        XCTAssertEqual(aggregate.totalTokens, 16_000)
        XCTAssertEqual(aggregate.inputTokens, 6_500)
        XCTAssertEqual(aggregate.cachedInputTokens, 7_250)
        XCTAssertEqual(aggregate.outputTokens, 1_700)
        XCTAssertEqual(aggregate.reasoningOutputTokens, 550)
        XCTAssertEqual(aggregate.turnCount, 4)
        XCTAssertEqual(aggregate.failurePercent, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(aggregate.tokensPerMinute), 73_846.153, accuracy: 0.01)
        XCTAssertEqual(aggregate.cacheShare, 0.453125, accuracy: 0.0001)
        XCTAssertEqual(model.totalTokens, 10_000)
        XCTAssertEqual(try XCTUnwrap(model.tokensPerMinute), 150_000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(model.outputTokensPerMinute), 10_500, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(model.contextPressure), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try store.performanceDashboardBounds()?.earliest, date("2026-05-02T10:00:00Z"))
    }

    func testPerformanceDashboardEfficiencyPresentationQueryMatchesBuilderForBreakdowns() throws {
        let store = try makeStore()
        try seedPerformanceDashboardFixture(in: store)

        let periodStart = date("2026-05-01T00:00:00Z")
        let periodEnd = date("2026-06-01T00:00:00Z")
        let tokenSamples = try store.performanceDashboardEfficiencyTokenSamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let timingSamples = try store.performanceDashboardTimingSamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let reliabilitySamples = try store.performanceDashboardReliabilitySamples(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let modelCapabilities = try store.codexModelCapabilities()

        for breakdownDimension in [PerformanceDashboardBreakdownDimension.model, .project, .effort, .source] {
            let expected = PerformanceDashboardPresentationBuilder.buildEfficiency(
                tokenSamples: tokenSamples,
                timingSamples: timingSamples,
                reliabilitySamples: reliabilitySamples,
                modelCapabilities: modelCapabilities,
                breakdownDimension: breakdownDimension,
                range: .month,
                calendar: calendar
            )
            let actual = try store.performanceDashboardEfficiencyPresentation(
                breakdownDimension: breakdownDimension,
                range: .month,
                periodStart: periodStart,
                periodEnd: periodEnd,
                calendar: calendar
            )

            XCTAssertEqual(actual.points, expected.points, "efficiency points for \(breakdownDimension)")
            XCTAssertEqual(actual.rows, expected.rows, "efficiency rows for \(breakdownDimension)")
            XCTAssertEqual(actual.series, expected.series, "efficiency series for \(breakdownDimension)")
        }
    }

    @MainActor
    func testPerformanceDashboardEfficiencyModeFiltersAndExportsVisibleRows() async throws {
        let store = try makeStore()
        try seedPerformanceDashboardFixture(in: store)

        let viewModel = PerformanceDashboardViewModel(
            store: store,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar
        )
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedMode, .performance)
        viewModel.selectedMode = .efficiency
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedMode, .efficiency)
        XCTAssertEqual(viewModel.selectedRange, .month)
        XCTAssertEqual(viewModel.selectedBreakdownDimension, .model)
        XCTAssertEqual(viewModel.selectedSeriesIDs, [PerformanceDashboardSeries.aggregateID])
        XCTAssertEqual(viewModel.availableBreakdownDimensions, [.model, .project, .effort, .source])
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "16.0k")
        XCTAssertEqual(viewModel.exportFilename, "codex-efficiency-dashboard-month-2026-05.csv")
        XCTAssertTrue(viewModel.csvText.contains("efficiency_bucket,month"))
        XCTAssertTrue(viewModel.csvText.contains("efficiency_breakdown_row,model,performance_all,All,aggregate,all,,4,3,16000"))

        viewModel.selectedMode = .performance
        await viewModel.reload()

        XCTAssertEqual(viewModel.summaryTiles.first?.value, "4")
        XCTAssertTrue(viewModel.efficiencyTokenSamples.isEmpty)

        viewModel.selectedMode = .efficiency
        await viewModel.reload()

        XCTAssertEqual(viewModel.summaryTiles.first?.value, "16.0k")

        viewModel.selectSeries("model:gpt-5.5")

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["model:gpt-5.5"])
        XCTAssertEqual(viewModel.visibleEfficiencySummaryRow.totalTokens, 10_000)
        XCTAssertEqual(try XCTUnwrap(viewModel.visibleEfficiencySummaryRow.tokensPerMinute), 150_000, accuracy: 0.01)
        XCTAssertTrue(viewModel.csvText.contains("efficiency_breakdown_row,model,model:gpt-5.5,gpt-5.5,model,gpt-5.5,,2,2,10000"))
        XCTAssertFalse(viewModel.csvText.contains("model:gpt-5.4"))

        viewModel.selectedBreakdownDimension = .transport
        await viewModel.reload()

        XCTAssertEqual(viewModel.selectedBreakdownDimension, .model)
        XCTAssertEqual(viewModel.selectedSeriesIDs, [PerformanceDashboardSeries.aggregateID])

        viewModel.sortEfficiencyRows(by: .tokens)

        XCTAssertEqual(viewModel.efficiencySortIndicator(for: .tokens), "chevron.down")
        XCTAssertEqual(viewModel.sortedEfficiencyRows.first?.series.id, PerformanceDashboardSeries.aggregateID)

        viewModel.sortEfficiencyRows(by: .tokens)

        XCTAssertEqual(viewModel.efficiencySortIndicator(for: .tokens), "chevron.up")
        XCTAssertEqual(viewModel.sortedEfficiencyRows.last?.series.id, PerformanceDashboardSeries.aggregateID)
    }

    @MainActor
    func testPerformanceDashboardSnapshotCacheReusesModeBreakdownAndPeriodResults() async throws {
        let database = PerformanceDashboardCacheSpyDatabase()
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "1")

        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)

        viewModel.sortBreakdownRows(by: .turns)
        viewModel.selectSeries("model:gpt-5.5")
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)

        viewModel.selectedMode = .efficiency
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "2.0k")

        viewModel.selectedMode = .performance
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "1")

        viewModel.selectedBreakdownDimension = .effort
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 3)

        viewModel.selectedBreakdownDimension = .model
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 3)
    }

    @MainActor
    func testPerformanceDashboardFirstLoadShowsPrimaryLoadingState() async throws {
        let database = PerformanceDashboardCacheSpyDatabase(stubs: [
            .success(value: 1, delayNanoseconds: 150_000_000),
        ])
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        let reloadTask = Task { await viewModel.reload() }
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(viewModel.primaryLoadState, .loading)
        XCTAssertTrue(viewModel.shouldShowPrimaryLoadingState)
        XCTAssertFalse(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertFalse(viewModel.hasVisibleData)
        XCTAssertEqual(viewModel.loadingState.title, "Loading performance data")
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "—")
        XCTAssertFalse(viewModel.canExportCSV)

        let didLoad = await reloadTask.value
        XCTAssertTrue(didLoad)

        XCTAssertEqual(viewModel.primaryLoadState, .loaded)
        XCTAssertTrue(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertFalse(viewModel.shouldShowPrimaryLoadingState)
        XCTAssertTrue(viewModel.hasVisibleData)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "1")
        XCTAssertTrue(viewModel.canExportCSV)
    }

    @MainActor
    func testPerformanceDashboardModeChangeShowsLoadingInsteadOfStaleRows() async throws {
        let database = PerformanceDashboardCacheSpyDatabase(stubs: [
            .success(value: 1),
            .success(value: 2, delayNanoseconds: 150_000_000),
        ])
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "1")

        viewModel.selectedMode = .efficiency
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(viewModel.primaryLoadState, .loading)
        XCTAssertFalse(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertTrue(viewModel.shouldShowPrimaryLoadingState)
        XCTAssertFalse(viewModel.hasVisibleData)
        XCTAssertEqual(viewModel.loadingState.title, "Loading efficiency data")
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "—")
        XCTAssertFalse(viewModel.canExportCSV)

        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(viewModel.primaryLoadState, .loaded)
        XCTAssertTrue(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertEqual(viewModel.selectedMode, .efficiency)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "2.0k")
        XCTAssertTrue(viewModel.canExportCSV)
    }

    @MainActor
    func testPerformanceDashboardCurrentPeriodSnapshotIdentitySurvivesClockAdvance() async throws {
        var currentDate = date("2026-05-17T12:00:00Z")
        let database = PerformanceDashboardCacheSpyDatabase()
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { currentDate },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()

        XCTAssertTrue(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertTrue(viewModel.hasVisibleData)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "1")
        XCTAssertTrue(viewModel.canExportCSV)

        currentDate = date("2026-05-17T12:05:00Z")

        XCTAssertTrue(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertTrue(viewModel.hasVisibleData)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "1")
        XCTAssertTrue(viewModel.canExportCSV)

        await viewModel.reload()

        let requestCount = await database.requestCount()
        let requests = await database.requestsSnapshot()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(requests.first?.periodEnd, date("2026-05-17T12:00:00Z"))
        XCTAssertTrue(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertTrue(viewModel.hasVisibleData)
    }

    @MainActor
    func testPerformanceDashboardSameSelectionRefreshKeepsContentWithRefreshingState() async throws {
        let database = PerformanceDashboardCacheSpyDatabase(stubs: [
            .success(value: 1),
            .success(value: 2, delayNanoseconds: 150_000_000),
        ])
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "1")

        viewModel.invalidateSnapshotCacheAndReload()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(viewModel.primaryLoadState, .loading)
        XCTAssertTrue(viewModel.isDisplayingCurrentSnapshot)
        XCTAssertFalse(viewModel.shouldShowPrimaryLoadingState)
        XCTAssertTrue(viewModel.isRefreshingCurrentSnapshot)
        XCTAssertTrue(viewModel.hasVisibleData)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "1")

        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(viewModel.primaryLoadState, .loaded)
        XCTAssertFalse(viewModel.isRefreshingCurrentSnapshot)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "2")
    }

    @MainActor
    func testPerformanceDashboardViewModelRecordsWorkerAndCacheReloadTimings() async throws {
        var currentDate = date("2026-05-17T12:00:00Z")
        let diagnosticsURL = try makeTemporaryDirectory().appendingPathComponent("performance-diagnostics.json")
        let instrumentationStore = AppPerformanceInstrumentationStore(
            fileURL: diagnosticsURL,
            now: { currentDate }
        )
        let database = PerformanceDashboardCacheSpyDatabase()
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            performanceInstrumentationStore: instrumentationStore,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        currentDate = currentDate.addingTimeInterval(0.2)
        await viewModel.reload()
        currentDate = currentDate.addingTimeInterval(0.1)
        await viewModel.reload()

        let requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(instrumentationStore.events.map(\.kind), [.performanceDashboardReload, .performanceDashboardReload])
        XCTAssertEqual(instrumentationStore.events.map(\.status), [.success, .success])
        XCTAssertEqual(instrumentationStore.events[0].metadata["cacheHit"], "false")
        XCTAssertEqual(instrumentationStore.events[1].metadata["cacheHit"], "true")
        XCTAssertEqual(instrumentationStore.events[0].metadata["mode"], "performance")
        XCTAssertEqual(instrumentationStore.events[0].metadata["range"], "month")

        viewModel.selectedMode = .efficiency
        currentDate = currentDate.addingTimeInterval(0.3)
        await viewModel.reload()

        XCTAssertEqual(instrumentationStore.events.last?.kind, .performanceDashboardModeChange)
        XCTAssertEqual(instrumentationStore.events.last?.metadata["mode"], "efficiency")
    }

    @MainActor
    func testPerformanceDashboardSnapshotCacheReusesRevisitedPeriods() async throws {
        let database = PerformanceDashboardCacheSpyDatabase()
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))

        viewModel.goToPreviousPeriod()
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-01T00:00:00Z"))

        viewModel.goToNextPeriod()
        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-05-01T00:00:00Z"))
    }

    @MainActor
    func testPerformanceDashboardSnapshotCacheNormalizesUnsupportedEfficiencyBreakdown() async throws {
        let database = PerformanceDashboardCacheSpyDatabase()
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        viewModel.selectedMode = .efficiency
        await viewModel.reload()
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        let requests = await database.requestsSnapshot()
        XCTAssertEqual(requests.last?.breakdownDimension, .model)

        viewModel.selectedBreakdownDimension = .transport
        await viewModel.reload()
        XCTAssertEqual(viewModel.selectedBreakdownDimension, .model)
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testPerformanceDashboardSnapshotCacheDoesNotCacheFailures() async throws {
        let database = PerformanceDashboardCacheSpyDatabase(stubs: [
            .failure,
            .success(value: 42),
        ])
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        let failed = await viewModel.reload()
        XCTAssertFalse(failed)
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.errorMessage, "Performance dashboard could not be loaded.")

        let succeeded = await viewModel.reload()
        XCTAssertTrue(succeeded)
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "42")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPerformanceDashboardSnapshotCacheInvalidationClearsEntriesAndReloads() async throws {
        let database = PerformanceDashboardCacheSpyDatabase(stubs: [
            .success(value: 7),
            .success(value: 8),
        ])
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        await viewModel.reload()
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "7")
        XCTAssertEqual(viewModel.snapshotCacheEntryCount, 1)

        await viewModel.reload()
        var requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 1)

        viewModel.invalidateSnapshotCache()
        XCTAssertEqual(viewModel.snapshotCacheEntryCount, 0)

        await viewModel.reload()
        requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "8")
    }

    @MainActor
    func testPerformanceDashboardStaleAsyncResultIsIgnoredAfterBreakdownChange() async throws {
        let database = PerformanceDashboardCacheSpyDatabase(stubs: [
            .success(value: 1, delayNanoseconds: 150_000_000),
            .success(value: 2),
        ])
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        let firstReload = Task { await viewModel.reload() }
        try await Task.sleep(nanoseconds: 20_000_000)

        viewModel.selectedBreakdownDimension = .effort
        let secondResult = await viewModel.reload()
        let firstResult = await firstReload.value

        XCTAssertTrue(secondResult)
        XCTAssertFalse(firstResult)
        let requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.selectedBreakdownDimension, .effort)
        XCTAssertEqual(viewModel.summaryTiles.first?.value, "2")
    }

    @MainActor
    func testPerformanceDashboardSnapshotCachePrunesToBoundedEntryCount() async throws {
        let database = PerformanceDashboardCacheSpyDatabase()
        let viewModel = PerformanceDashboardViewModel(
            database: database,
            now: { self.date("2026-05-17T12:00:00Z") },
            calendar: calendar,
            automaticallyReload: false
        )

        for range in UsageHistoryRange.allCases {
            viewModel.selectedMode = .performance
            viewModel.selectedRange = range
            for breakdownDimension in PerformanceDashboardBreakdownDimension.allCases {
                viewModel.selectedBreakdownDimension = breakdownDimension
                await viewModel.reload()
            }
        }

        viewModel.selectedMode = .efficiency
        viewModel.selectedRange = .month
        viewModel.selectedBreakdownDimension = .model
        await viewModel.reload()

        let requestCount = await database.requestCount()
        XCTAssertEqual(requestCount, 25)
        XCTAssertEqual(viewModel.snapshotCacheEntryCount, 24)
    }

    private func performanceDashboardReliabilityEvent(
        rowID: Int64,
        timestamp: Date,
        success: Bool?,
        errorSummary: String? = nil,
        model: String?,
        transport: String?
    ) -> CodexTurnPerformanceEvent {
        CodexTurnPerformanceEvent(
            sourceKey: "reliability-test",
            sourceRowID: rowID,
            target: transport == "sse" ? "codex_api::sse::responses" : "codex_api::endpoint::responses_websocket",
            eventTimestamp: timestamp,
            eventName: success == false ? "response.failed" : "response.completed",
            eventKind: success == false ? "response.failed" : "response.completed",
            durationMilliseconds: nil,
            success: success,
            errorSummary: errorSummary,
            threadID: "thread-\(rowID)",
            turnID: "turn-\(rowID)",
            model: model,
            sessionID: "session-\(rowID)",
            projectPath: nil,
            effort: nil,
            source: nil,
            originator: nil,
            appVersion: nil,
            terminalType: nil,
            transport: transport,
            wireAPI: transport == nil ? nil : "responses",
            apiPath: nil,
            recordedAt: timestamp
        )
    }

    private func seedPerformanceDashboardFixture(in store: UsageHistoryStore) throws {
        try store.importSessionTaskTimingEvents([
            try XCTUnwrap(CodexSessionTaskTimingEvent(
                sessionID: "session-a",
                turnID: "turn-a",
                sourcePath: "/tmp/session-a.jsonl",
                startedAt: date("2026-05-02T10:00:00Z"),
                completedAt: date("2026-05-02T10:00:01Z"),
                durationMilliseconds: 1_000,
                timeToFirstTokenMilliseconds: 100,
                model: "gpt-5.5",
                projectPath: "/Users/example/Projects/codex_codex",
                effort: "high",
                source: "cli",
                recordedAt: date("2026-05-02T10:00:01Z")
            )),
            try XCTUnwrap(CodexSessionTaskTimingEvent(
                sessionID: "session-a",
                turnID: "turn-b",
                sourcePath: "/tmp/session-a.jsonl",
                startedAt: date("2026-05-02T11:00:00Z"),
                completedAt: date("2026-05-02T11:00:03Z"),
                durationMilliseconds: 3_000,
                timeToFirstTokenMilliseconds: 300,
                model: "gpt-5.5",
                projectPath: "/Users/example/Projects/codex_codex",
                effort: "high",
                source: "cli",
                recordedAt: date("2026-05-02T11:00:03Z")
            )),
            try XCTUnwrap(CodexSessionTaskTimingEvent(
                sessionID: "session-b",
                turnID: "turn-a",
                sourcePath: "/tmp/session-b.jsonl",
                startedAt: date("2026-05-03T11:00:00Z"),
                completedAt: date("2026-05-03T11:00:09Z"),
                durationMilliseconds: 9_000,
                timeToFirstTokenMilliseconds: 900,
                model: "gpt-5.4",
                projectPath: "/Users/example/Other/perf",
                effort: "low",
                source: "vscode",
                recordedAt: date("2026-05-03T11:00:09Z")
            )),
            try XCTUnwrap(CodexSessionTaskTimingEvent(
                sessionID: "session-c",
                turnID: "turn-a",
                sourcePath: "/tmp/session-c.jsonl",
                startedAt: date("2026-05-04T12:00:00Z"),
                completedAt: nil,
                durationMilliseconds: nil,
                timeToFirstTokenMilliseconds: nil,
                model: nil,
                projectPath: nil,
                effort: nil,
                source: nil,
                recordedAt: date("2026-05-04T12:00:00Z")
            )),
        ])

        try store.importTurnPerformanceEvents([
            CodexTurnPerformanceEvent(
                sourceKey: "otel",
                sourceRowID: 1,
                target: "codex_api::endpoint::responses_websocket",
                eventTimestamp: date("2026-05-02T10:00:02Z"),
                eventName: "response.completed",
                eventKind: "response.completed",
                durationMilliseconds: 1_100,
                success: true,
                errorSummary: nil,
                threadID: "session-a",
                turnID: "turn-a",
                model: "gpt-5.5",
                sessionID: "session-a",
                projectPath: "/Users/example/Projects/codex_codex",
                effort: "high",
                source: "cli",
                originator: "codex",
                appVersion: "1.0.0",
                terminalType: "apple-terminal",
                transport: "websocket",
                wireAPI: "responses",
                apiPath: "/v1/responses",
                recordedAt: date("2026-05-02T10:00:02Z")
            ),
            CodexTurnPerformanceEvent(
                sourceKey: "otel",
                sourceRowID: 2,
                target: "codex_api::endpoint::responses_websocket",
                eventTimestamp: date("2026-05-02T11:00:02Z"),
                eventName: "response.failed",
                eventKind: "response.failed",
                durationMilliseconds: 2_000,
                success: false,
                errorSummary: "connection",
                threadID: "session-a",
                turnID: "turn-b",
                model: "gpt-5.5",
                sessionID: "session-a",
                projectPath: "/Users/example/Projects/codex_codex",
                effort: "high",
                source: "cli",
                originator: "codex",
                appVersion: "1.0.0",
                terminalType: "apple-terminal",
                transport: "websocket",
                wireAPI: "responses",
                apiPath: "/v1/responses",
                recordedAt: date("2026-05-02T11:00:02Z")
            ),
            CodexTurnPerformanceEvent(
                sourceKey: "otel",
                sourceRowID: 3,
                target: "codex_api::sse::responses",
                eventTimestamp: date("2026-05-03T11:00:02Z"),
                eventName: "response.completed",
                eventKind: "response.completed",
                durationMilliseconds: 3_000,
                success: nil,
                errorSummary: nil,
                threadID: "session-b",
                turnID: "turn-a",
                model: "gpt-5.4",
                sessionID: "session-b",
                projectPath: "/Users/example/Other/perf",
                effort: "low",
                source: "vscode",
                originator: "codex",
                appVersion: "1.0.0",
                terminalType: "apple-terminal",
                transport: "sse",
                wireAPI: "responses",
                apiPath: "/v1/responses",
                recordedAt: date("2026-05-03T11:00:02Z")
            ),
        ])

        _ = try store.importTokenUsageSamples([
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "token-a",
                    turnID: "turn-a",
                    model: "gpt-5.5",
                    lastInput: 4_000,
                    lastCached: 5_000,
                    lastOutput: 700,
                    lastReasoning: 300,
                    lastTotal: 10_000,
                    totalInput: 4_000,
                    totalCached: 5_000,
                    totalOutput: 700,
                    totalReasoning: 300,
                    totalTotal: 10_000,
                    contextWindow: 80_000
                ),
                receivedAt: date("2026-05-02T10:00:03Z"),
                context: TokenUsageContext(
                    projectPath: "/Users/example/Projects/codex_codex",
                    effort: "high",
                    source: "cli"
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "token-b",
                    turnID: "turn-a",
                    model: "gpt-5.4",
                    lastInput: 2_000,
                    lastCached: 2_000,
                    lastOutput: 800,
                    lastReasoning: 200,
                    lastTotal: 5_000,
                    totalInput: 2_000,
                    totalCached: 2_000,
                    totalOutput: 800,
                    totalReasoning: 200,
                    totalTotal: 5_000
                ),
                receivedAt: date("2026-05-03T11:00:03Z"),
                context: TokenUsageContext(
                    projectPath: "/Users/example/Other/perf",
                    effort: "low",
                    source: "vscode"
                )
            ),
            ImportedCodexTokenUsageSample(
                notification: tokenNotification(
                    threadID: "token-c",
                    turnID: "turn-a",
                    model: nil,
                    lastInput: 500,
                    lastCached: 250,
                    lastOutput: 200,
                    lastReasoning: 50,
                    lastTotal: 1_000,
                    totalInput: 500,
                    totalCached: 250,
                    totalOutput: 200,
                    totalReasoning: 50,
                    totalTotal: 1_000
                ),
                receivedAt: date("2026-05-04T12:00:03Z")
            ),
        ])

        try store.importCodexModelCapabilities(
            CodexModelCapabilitiesImportBatch(
                models: [
                    try XCTUnwrap(CodexModelCapability(
                        slug: "gpt-5.5",
                        displayName: "GPT-5.5",
                        visibility: "public",
                        supportedInAPI: true,
                        priority: 1,
                        contextWindow: 100_000,
                        maxContextWindow: 100_000,
                        effectiveContextWindowPercent: 100,
                        defaultReasoningLevel: "high",
                        supportsReasoningSummaries: true,
                        defaultReasoningSummary: "auto",
                        supportsVerbosity: true,
                        defaultVerbosity: "medium",
                        shellType: "default",
                        applyPatchToolType: "apply_patch",
                        webSearchToolType: "web_search",
                        supportsParallelToolCalls: true,
                        supportsImageDetailOriginal: true,
                        supportsSearchTool: true,
                        truncationPolicyMode: "auto",
                        truncationPolicyLimit: nil
                    )),
                ],
                cacheFetchedAt: date("2026-05-02T09:00:00Z"),
                clientVersion: "1.0.0"
            )
        )
    }

}

private final class DashboardMetadataImporterSpy: @unchecked Sendable {
    enum Kind: Equatable {
        case turnPerformance
        case sessionTaskTiming
    }

    struct Event: Equatable {
        let kind: Kind
        let force: Bool
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func captureTurnPerformance(
        store: UsageHistoryStore,
        date: Date,
        calendar: Calendar,
        force: Bool
    ) -> CodexTurnPerformanceCaptureState {
        record(kind: .turnPerformance, force: force)
        return CodexTurnPerformanceCaptureState(lastCheckedAt: date, status: .imported, insertedCount: 1)
    }

    func captureSessionTaskTiming(
        store: UsageHistoryStore,
        date: Date,
        calendar: Calendar,
        force: Bool
    ) -> CodexSessionTaskTimingCaptureState {
        record(kind: .sessionTaskTiming, force: force)
        return CodexSessionTaskTimingCaptureState(lastCheckedAt: date, status: .imported, insertedCount: 1)
    }

    func eventsSnapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func record(kind: Kind, force: Bool) {
        lock.lock()
        events.append(Event(kind: kind, force: force))
        lock.unlock()
    }
}

private final class StoreOpenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let stores: [UsageHistoryStore]
    private var index = 0

    init(stores: [UsageHistoryStore]) {
        self.stores = stores
    }

    var openAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func nextStore() -> UsageHistoryStore {
        lock.lock()
        defer { lock.unlock() }
        let store = stores[min(index, stores.count - 1)]
        index += 1
        return store
    }
}

private actor DashboardRoutingQuerySpy: UsageHistoryDashboardQueryWorking {
    enum Event: Equatable {
        case usageHistory
        case tokenDashboard
        case performanceDashboard
    }

    private var events: [Event] = []

    func eventsSnapshot() -> [Event] {
        events
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult {
        events.append(.usageHistory)
        return UsageHistoryLoadResult(
            points: [],
            tokenPoints: [],
            tokenComponentPoints: [],
            tokenComponentBucketPoints: [],
            series: [],
            historyBounds: nil,
            hasAnyHistory: false
        )
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult {
        events.append(.tokenDashboard)
        return TokenDashboardLoadResult(
            points: [],
            series: [],
            attributionCoverageRows: [],
            availableBreakdownDimensions: [.model],
            historyBounds: nil
        )
    }

    func performanceDashboardSnapshot(
        for request: PerformanceDashboardLoadRequest
    ) async throws -> PerformanceDashboardLoadResult {
        events.append(.performanceDashboard)
        return PerformanceDashboardLoadResult(
            timingSamples: [],
            reliabilitySamples: [],
            efficiencyTokenSamples: [],
            modelCapabilities: [],
            durationPoints: [],
            reliabilityPoints: [],
            breakdownRows: [],
            efficiencyPoints: [],
            efficiencyRows: [],
            series: [],
            historyBounds: nil
        )
    }
}

private actor DashboardRoutingWriterSpy: UsageHistoryDatabaseWorking {
    enum Event: Equatable {
        case recordUsage
        case recordTokens
        case liveTokenCapture(force: Bool)
        case turnPerformance(force: Bool)
        case sessionTaskTiming(force: Bool)
        case threadCatalog(force: Bool)
        case modelCapabilities(force: Bool)
        case databaseInfo
        case exportBackup
        case importBackup
        case clearHistory
        case projectCatalog
        case dimensionCatalog
        case renameProject
        case importTokenHistory
    }

    private enum SpyError: Error {
        case unexpectedSnapshot
    }

    private var events: [Event] = []

    func eventsSnapshot() -> [Event] {
        events
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {
        events.append(.recordUsage)
    }

    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        events.append(.recordTokens)
        return nil
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        nil
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        nil
    }

    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexLiveTokenCaptureState {
        events.append(.liveTokenCapture(force: force))
        return CodexLiveTokenCaptureState(status: .noNewEvents)
    }

    func liveTokenCaptureState() async -> CodexLiveTokenCaptureState {
        CodexLiveTokenCaptureState(status: .noNewEvents)
    }

    func captureTurnPerformanceIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexTurnPerformanceCaptureState {
        events.append(.turnPerformance(force: force))
        return CodexTurnPerformanceCaptureState(status: .noNewEvents)
    }

    func turnPerformanceCaptureState() async -> CodexTurnPerformanceCaptureState {
        CodexTurnPerformanceCaptureState(status: .noNewEvents)
    }

    func captureSessionTaskTimingIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexSessionTaskTimingCaptureState {
        events.append(.sessionTaskTiming(force: force))
        return CodexSessionTaskTimingCaptureState(status: .noNewEvents)
    }

    func sessionTaskTimingCaptureState() async -> CodexSessionTaskTimingCaptureState {
        CodexSessionTaskTimingCaptureState(status: .noNewEvents)
    }

    func captureThreadCatalogIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexThreadCatalogCaptureState {
        events.append(.threadCatalog(force: force))
        return CodexThreadCatalogCaptureState(status: .noNewEvents)
    }

    func threadCatalogCaptureState() async -> CodexThreadCatalogCaptureState {
        CodexThreadCatalogCaptureState(status: .noNewEvents)
    }

    func captureModelCapabilitiesIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexModelCapabilitiesCaptureState {
        events.append(.modelCapabilities(force: force))
        return CodexModelCapabilitiesCaptureState(status: .noNewEvents)
    }

    func modelCapabilitiesCaptureState() async -> CodexModelCapabilitiesCaptureState {
        CodexModelCapabilitiesCaptureState(status: .noNewEvents)
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult {
        throw SpyError.unexpectedSnapshot
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult {
        throw SpyError.unexpectedSnapshot
    }

    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult {
        throw SpyError.unexpectedSnapshot
    }

    func databaseInfo() async throws -> UsageHistoryDatabaseInfo {
        events.append(.databaseInfo)
        throw SpyError.unexpectedSnapshot
    }

    func exportBackup(to destinationURL: URL) async throws {
        events.append(.exportBackup)
    }

    func importBackup(from sourceURL: URL) async throws {
        events.append(.importBackup)
    }

    func clearHistory() async throws {
        events.append(.clearHistory)
    }

    func tokenProjectCatalogEntries() async throws -> [TokenProjectCatalogEntry] {
        events.append(.projectCatalog)
        return []
    }

    func tokenDimensionCatalogEntries() async throws -> [TokenUsageDimensionCatalogEntry] {
        events.append(.dimensionCatalog)
        return []
    }

    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) async throws {
        events.append(.renameProject)
    }

    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) async throws -> CodexSessionTokenBackfillSummary {
        events.append(.importTokenHistory)
        return CodexSessionTokenBackfillSummary(
            request: request,
            filesScanned: 0,
            tokenEventsImported: 0,
            duplicateEventsSkipped: 0,
            failedLinesSkipped: 0
        )
    }
}

private actor BlockingDashboardRoutingWriterSpy: UsageHistoryDatabaseWorking {
    private var captureStarted = false
    private var captureStartContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForCaptureStart() async {
        if captureStarted {
            return
        }

        await withCheckedContinuation { continuation in
            captureStartContinuation = continuation
        }
    }

    func releaseCapture() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {}

    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        nil
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        nil
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        nil
    }

    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexLiveTokenCaptureState {
        CodexLiveTokenCaptureState(status: .noNewEvents)
    }

    func liveTokenCaptureState() async -> CodexLiveTokenCaptureState {
        CodexLiveTokenCaptureState(status: .noNewEvents)
    }

    func captureTurnPerformanceIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexTurnPerformanceCaptureState {
        captureStarted = true
        captureStartContinuation?.resume()
        captureStartContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return CodexTurnPerformanceCaptureState(status: .noNewEvents)
    }

    func turnPerformanceCaptureState() async -> CodexTurnPerformanceCaptureState {
        CodexTurnPerformanceCaptureState(status: .noNewEvents)
    }

    func captureSessionTaskTimingIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexSessionTaskTimingCaptureState {
        CodexSessionTaskTimingCaptureState(status: .noNewEvents)
    }

    func sessionTaskTimingCaptureState() async -> CodexSessionTaskTimingCaptureState {
        CodexSessionTaskTimingCaptureState(status: .noNewEvents)
    }

    func captureThreadCatalogIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexThreadCatalogCaptureState {
        CodexThreadCatalogCaptureState(status: .noNewEvents)
    }

    func threadCatalogCaptureState() async -> CodexThreadCatalogCaptureState {
        CodexThreadCatalogCaptureState(status: .noNewEvents)
    }

    func captureModelCapabilitiesIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexModelCapabilitiesCaptureState {
        CodexModelCapabilitiesCaptureState(status: .noNewEvents)
    }

    func modelCapabilitiesCaptureState() async -> CodexModelCapabilitiesCaptureState {
        CodexModelCapabilitiesCaptureState(status: .noNewEvents)
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult {
        XCTFail("Writer should not serve dashboard snapshots")
        return UsageHistoryLoadResult(
            points: [],
            tokenPoints: [],
            tokenComponentPoints: [],
            tokenComponentBucketPoints: [],
            series: [],
            historyBounds: nil,
            hasAnyHistory: false
        )
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult {
        XCTFail("Writer should not serve dashboard snapshots")
        return TokenDashboardLoadResult(
            points: [],
            series: [],
            attributionCoverageRows: [],
            availableBreakdownDimensions: [],
            historyBounds: nil
        )
    }

    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult {
        XCTFail("Writer should not serve dashboard snapshots")
        return PerformanceDashboardLoadResult(
            timingSamples: [],
            reliabilitySamples: [],
            efficiencyTokenSamples: [],
            modelCapabilities: [],
            durationPoints: [],
            reliabilityPoints: [],
            breakdownRows: [],
            efficiencyPoints: [],
            efficiencyRows: [],
            series: [],
            historyBounds: nil
        )
    }

    func databaseInfo() async throws -> UsageHistoryDatabaseInfo {
        throw UsageHistoryStoreError.databaseUnavailable
    }

    func exportBackup(to destinationURL: URL) async throws {}

    func importBackup(from sourceURL: URL) async throws {}

    func clearHistory() async throws {}

    func tokenProjectCatalogEntries() async throws -> [TokenProjectCatalogEntry] {
        []
    }

    func tokenDimensionCatalogEntries() async throws -> [TokenUsageDimensionCatalogEntry] {
        []
    }

    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) async throws {}

    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) async throws -> CodexSessionTokenBackfillSummary {
        CodexSessionTokenBackfillSummary(
            request: request,
            filesScanned: 0,
            tokenEventsImported: 0,
            duplicateEventsSkipped: 0,
            failedLinesSkipped: 0
        )
    }
}

private actor BackgroundMetadataCaptureDelayRecorder {
    private var intervals: [TimeInterval] = []

    func record(_ interval: TimeInterval) {
        intervals.append(interval)
    }

    func intervalsSnapshot() -> [TimeInterval] {
        intervals
    }
}

private actor BackgroundMetadataCaptureSpyDatabase: UsageHistoryDatabaseWorking {
    enum Event: Equatable {
        case turnPerformance(force: Bool)
        case sessionTaskTiming(force: Bool)
        case threadCatalog(force: Bool)
        case modelCapabilities(force: Bool)
    }

    private enum SpyError: Error {
        case unused
    }

    private let failTurnPerformance: Bool
    private var events: [Event] = []
    private var liveTokenCaptures = 0

    init(failTurnPerformance: Bool = false) {
        self.failTurnPerformance = failTurnPerformance
    }

    func eventsSnapshot() -> [Event] {
        events
    }

    func liveTokenCaptureCount() -> Int {
        liveTokenCaptures
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {}

    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        nil
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        nil
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        nil
    }

    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexLiveTokenCaptureState {
        liveTokenCaptures += 1
        return CodexLiveTokenCaptureState(status: .noNewEvents)
    }

    func liveTokenCaptureState() async -> CodexLiveTokenCaptureState {
        CodexLiveTokenCaptureState(status: .noNewEvents)
    }

    func captureTurnPerformanceIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexTurnPerformanceCaptureState {
        events.append(.turnPerformance(force: force))
        if failTurnPerformance {
            return CodexTurnPerformanceCaptureState(lastCheckedAt: date, status: .failed, lastErrorText: "configured failure")
        }
        return CodexTurnPerformanceCaptureState(lastCheckedAt: date, status: .imported, insertedCount: 1)
    }

    func turnPerformanceCaptureState() async -> CodexTurnPerformanceCaptureState {
        CodexTurnPerformanceCaptureState(status: .neverChecked)
    }

    func captureSessionTaskTimingIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexSessionTaskTimingCaptureState {
        events.append(.sessionTaskTiming(force: force))
        return CodexSessionTaskTimingCaptureState(lastCheckedAt: date, status: .imported, insertedCount: 1)
    }

    func sessionTaskTimingCaptureState() async -> CodexSessionTaskTimingCaptureState {
        CodexSessionTaskTimingCaptureState(status: .neverChecked)
    }

    func captureThreadCatalogIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexThreadCatalogCaptureState {
        events.append(.threadCatalog(force: force))
        return CodexThreadCatalogCaptureState(lastCheckedAt: date, status: .imported, threadsInsertedCount: 1)
    }

    func threadCatalogCaptureState() async -> CodexThreadCatalogCaptureState {
        CodexThreadCatalogCaptureState(status: .neverChecked)
    }

    func captureModelCapabilitiesIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexModelCapabilitiesCaptureState {
        events.append(.modelCapabilities(force: force))
        return CodexModelCapabilitiesCaptureState(lastCheckedAt: date, status: .imported, modelsInsertedCount: 1)
    }

    func modelCapabilitiesCaptureState() async -> CodexModelCapabilitiesCaptureState {
        CodexModelCapabilitiesCaptureState(status: .neverChecked)
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult {
        throw SpyError.unused
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult {
        throw SpyError.unused
    }

    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult {
        throw SpyError.unused
    }

    func databaseInfo() async throws -> UsageHistoryDatabaseInfo {
        throw SpyError.unused
    }

    func exportBackup(to destinationURL: URL) async throws {
        throw SpyError.unused
    }

    func importBackup(from sourceURL: URL) async throws {
        throw SpyError.unused
    }

    func clearHistory() async throws {
        throw SpyError.unused
    }

    func tokenProjectCatalogEntries() async throws -> [TokenProjectCatalogEntry] {
        throw SpyError.unused
    }

    func tokenDimensionCatalogEntries() async throws -> [TokenUsageDimensionCatalogEntry] {
        throw SpyError.unused
    }

    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) async throws {
        throw SpyError.unused
    }

    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) async throws -> CodexSessionTokenBackfillSummary {
        throw SpyError.unused
    }
}

private actor TokenDashboardCacheSpyDatabase: UsageHistoryDatabaseWorking {
    struct Stub {
        let resultValue: Int?
        let delayNanoseconds: UInt64
        let error: Error?
        let availableDimensions: [TokenDashboardBreakdownDimension]

        static func success(
            value: Int,
            delayNanoseconds: UInt64 = 0,
            availableDimensions: [TokenDashboardBreakdownDimension] = TokenDashboardBreakdownDimension.allCases
        ) -> Stub {
            Stub(
                resultValue: value,
                delayNanoseconds: delayNanoseconds,
                error: nil,
                availableDimensions: availableDimensions
            )
        }

        static var failure: Stub {
            Stub(
                resultValue: nil,
                delayNanoseconds: 0,
                error: TokenDashboardCacheSpyError.configuredFailure,
                availableDimensions: TokenDashboardBreakdownDimension.allCases
            )
        }
    }

    enum TokenDashboardCacheSpyError: Error {
        case configuredFailure
        case unused
    }

    private var stubs: [Stub]
    private let coverageDelayNanoseconds: UInt64
    private let coverageError: Error?
    private var tokenRequests: [TokenDashboardLoadRequest] = []
    private var coverageRequests: [(periodStart: Date, periodEnd: Date)] = []

    init(
        stubs: [Stub] = [],
        coverageDelayNanoseconds: UInt64 = 0,
        coverageError: Error? = nil
    ) {
        self.stubs = stubs
        self.coverageDelayNanoseconds = coverageDelayNanoseconds
        self.coverageError = coverageError
    }

    func requestCount() -> Int {
        tokenRequests.count
    }

    func requestsSnapshot() -> [TokenDashboardLoadRequest] {
        tokenRequests
    }

    func coverageRequestCount() -> Int {
        coverageRequests.count
    }

    func coverageRequestsSnapshot() -> [(periodStart: Date, periodEnd: Date)] {
        coverageRequests
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {}

    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        nil
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        nil
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        nil
    }

    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexLiveTokenCaptureState {
        CodexLiveTokenCaptureState(status: .neverChecked)
    }

    func liveTokenCaptureState() async -> CodexLiveTokenCaptureState {
        CodexLiveTokenCaptureState(status: .neverChecked)
    }

    func captureTurnPerformanceIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexTurnPerformanceCaptureState {
        CodexTurnPerformanceCaptureState(status: .neverChecked)
    }

    func turnPerformanceCaptureState() async -> CodexTurnPerformanceCaptureState {
        CodexTurnPerformanceCaptureState(status: .neverChecked)
    }

    func captureSessionTaskTimingIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexSessionTaskTimingCaptureState {
        CodexSessionTaskTimingCaptureState(status: .neverChecked)
    }

    func sessionTaskTimingCaptureState() async -> CodexSessionTaskTimingCaptureState {
        CodexSessionTaskTimingCaptureState(status: .neverChecked)
    }

    func captureThreadCatalogIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexThreadCatalogCaptureState {
        CodexThreadCatalogCaptureState(status: .neverChecked)
    }

    func threadCatalogCaptureState() async -> CodexThreadCatalogCaptureState {
        CodexThreadCatalogCaptureState(status: .neverChecked)
    }

    func captureModelCapabilitiesIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexModelCapabilitiesCaptureState {
        CodexModelCapabilitiesCaptureState(status: .neverChecked)
    }

    func modelCapabilitiesCaptureState() async -> CodexModelCapabilitiesCaptureState {
        CodexModelCapabilitiesCaptureState(status: .neverChecked)
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult {
        throw TokenDashboardCacheSpyError.unused
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult {
        let callIndex = tokenRequests.count
        tokenRequests.append(request)

        if callIndex < stubs.count {
            let stub = stubs[callIndex]
            if stub.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: stub.delayNanoseconds)
            }
            if let error = stub.error {
                throw error
            }
            return Self.result(
                for: request,
                value: stub.resultValue ?? callIndex + 1,
                availableDimensions: stub.availableDimensions
            )
        }

        return Self.result(
            for: request,
            value: callIndex + 1,
            availableDimensions: TokenDashboardBreakdownDimension.allCases
        )
    }

    func tokenAttributionCoverageRows(periodStart: Date, periodEnd: Date) async throws -> [TokenAttributionCoverageRow] {
        coverageRequests.append((periodStart: periodStart, periodEnd: periodEnd))
        if coverageDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: coverageDelayNanoseconds)
        }
        if let coverageError {
            throw coverageError
        }

        return Self.coverageRows(
            availableDimensions: TokenDashboardBreakdownDimension.allCases,
            tokenCount: 1_000
        )
    }

    func performanceDashboardSnapshot(for request: PerformanceDashboardLoadRequest) async throws -> PerformanceDashboardLoadResult {
        throw TokenDashboardCacheSpyError.unused
    }

    func databaseInfo() async throws -> UsageHistoryDatabaseInfo {
        throw TokenDashboardCacheSpyError.unused
    }

    func exportBackup(to destinationURL: URL) async throws {
        throw TokenDashboardCacheSpyError.unused
    }

    func importBackup(from sourceURL: URL) async throws {
        throw TokenDashboardCacheSpyError.unused
    }

    func clearHistory() async throws {
        throw TokenDashboardCacheSpyError.unused
    }

    func tokenProjectCatalogEntries() async throws -> [TokenProjectCatalogEntry] {
        throw TokenDashboardCacheSpyError.unused
    }

    func tokenDimensionCatalogEntries() async throws -> [TokenUsageDimensionCatalogEntry] {
        throw TokenDashboardCacheSpyError.unused
    }

    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) async throws {
        throw TokenDashboardCacheSpyError.unused
    }

    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) async throws -> CodexSessionTokenBackfillSummary {
        throw TokenDashboardCacheSpyError.unused
    }

    private static func result(
        for request: TokenDashboardLoadRequest,
        value: Int,
        availableDimensions: [TokenDashboardBreakdownDimension]
    ) -> TokenDashboardLoadResult {
        let aggregate = TokenDashboardSeries(
            id: TokenDashboardSeries.aggregateID,
            name: "All captured",
            kind: .aggregate,
            contextID: "all"
        )
        let child = childSeries(for: request.breakdownDimension)
        let bucketEnd = request.periodStart.addingTimeInterval(60 * 60)
        let tokenCount = Int64(value * 1_000)
        let series = [aggregate, child]
        let points = series.map {
            TokenDashboardComponentPoint(
                bucketStart: request.periodStart,
                bucketEnd: bucketEnd,
                seriesID: $0.id,
                seriesName: $0.name,
                seriesKind: $0.kind,
                component: .input,
                tokenCount: tokenCount
            )
        }
        let coverageRows = request.includeAttributionCoverage
            ? coverageRows(availableDimensions: availableDimensions, tokenCount: tokenCount)
            : []
        let historyBounds = UsageHistoryBounds(
            earliest: request.periodStart.addingTimeInterval(-90 * 24 * 60 * 60),
            latest: request.periodEnd
        )

        return TokenDashboardLoadResult(
            points: points,
            series: series,
            attributionCoverageRows: coverageRows,
            availableBreakdownDimensions: availableDimensions,
            historyBounds: historyBounds
        )
    }

    private static func coverageRows(
        availableDimensions: [TokenDashboardBreakdownDimension],
        tokenCount: Int64
    ) -> [TokenAttributionCoverageRow] {
        availableDimensions.map { dimension in
            TokenAttributionCoverageRow(
                id: dimension.dimensionKey.map { "dimension:\($0.rawValue)" } ?? dimension.rawValue,
                title: dimension.displayTitle,
                attributedTokenCount: tokenCount,
                missingTokenCount: 0,
                distinctValueCount: 1,
                dimensionKey: dimension.dimensionKey
            )
        }
    }

    private static func childSeries(for dimension: TokenDashboardBreakdownDimension) -> TokenDashboardSeries {
        switch dimension {
        case .model:
            return TokenDashboardSeries(id: "model:gpt-5.5", name: "gpt-5.5", kind: .model, contextID: "gpt-5.5")
        case .effort:
            return TokenDashboardSeries(id: "effort:high", name: "high", kind: .effort, contextID: "high")
        case .project:
            return TokenDashboardSeries(
                id: "project:/Users/example/Projects/codex_codex",
                name: "codex_codex",
                kind: .project,
                contextID: "/Users/example/Projects/codex_codex",
                projectPath: "/Users/example/Projects/codex_codex"
            )
        case .originator,
             .sourceKind,
             .threadSource,
             .cliVersion,
             .modelProvider,
             .memoryMode,
             .approvalPolicy,
             .sandboxType,
             .permissionProfile,
             .realtimeActive,
             .truncationPolicy,
             .isSubagent,
             .subagentParentThreadID,
             .subagentDepth,
             .agentRole,
             .agentNickname,
             .usageMode:
            let dimensionKey = dimension.dimensionKey
            let value = dimension == .realtimeActive || dimension == .isSubagent ? "false" : "captured"
            return TokenDashboardSeries(
                id: "dimension:\(dimension.rawValue):\(value)",
                name: value,
                kind: .dimension,
                contextID: value,
                dimensionKey: dimensionKey
            )
        }
    }
}

private actor PerformanceDashboardCacheSpyDatabase: UsageHistoryDatabaseWorking {
    struct Stub {
        let resultValue: Int?
        let delayNanoseconds: UInt64
        let error: Error?

        static func success(value: Int, delayNanoseconds: UInt64 = 0) -> Stub {
            Stub(resultValue: value, delayNanoseconds: delayNanoseconds, error: nil)
        }

        static var failure: Stub {
            Stub(resultValue: nil, delayNanoseconds: 0, error: PerformanceDashboardCacheSpyError.configuredFailure)
        }
    }

    private enum PerformanceDashboardCacheSpyError: Error {
        case configuredFailure
        case unused
    }

    private var stubs: [Stub]
    private var performanceRequests: [PerformanceDashboardLoadRequest] = []

    init(stubs: [Stub] = []) {
        self.stubs = stubs
    }

    func requestCount() -> Int {
        performanceRequests.count
    }

    func requestsSnapshot() -> [PerformanceDashboardLoadRequest] {
        performanceRequests
    }

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {}

    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        nil
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        nil
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        nil
    }

    func captureLiveTokenHistoryIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexLiveTokenCaptureState {
        CodexLiveTokenCaptureState(status: .neverChecked)
    }

    func liveTokenCaptureState() async -> CodexLiveTokenCaptureState {
        CodexLiveTokenCaptureState(status: .neverChecked)
    }

    func captureTurnPerformanceIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexTurnPerformanceCaptureState {
        CodexTurnPerformanceCaptureState(status: .neverChecked)
    }

    func turnPerformanceCaptureState() async -> CodexTurnPerformanceCaptureState {
        CodexTurnPerformanceCaptureState(status: .neverChecked)
    }

    func captureSessionTaskTimingIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexSessionTaskTimingCaptureState {
        CodexSessionTaskTimingCaptureState(status: .neverChecked)
    }

    func sessionTaskTimingCaptureState() async -> CodexSessionTaskTimingCaptureState {
        CodexSessionTaskTimingCaptureState(status: .neverChecked)
    }

    func captureThreadCatalogIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexThreadCatalogCaptureState {
        CodexThreadCatalogCaptureState(status: .neverChecked)
    }

    func threadCatalogCaptureState() async -> CodexThreadCatalogCaptureState {
        CodexThreadCatalogCaptureState(status: .neverChecked)
    }

    func captureModelCapabilitiesIfNeeded(
        at date: Date,
        calendar: Calendar,
        force: Bool
    ) async -> CodexModelCapabilitiesCaptureState {
        CodexModelCapabilitiesCaptureState(status: .neverChecked)
    }

    func modelCapabilitiesCaptureState() async -> CodexModelCapabilitiesCaptureState {
        CodexModelCapabilitiesCaptureState(status: .neverChecked)
    }

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func tokenDashboardSnapshot(for request: TokenDashboardLoadRequest) async throws -> TokenDashboardLoadResult {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func performanceDashboardSnapshot(
        for request: PerformanceDashboardLoadRequest
    ) async throws -> PerformanceDashboardLoadResult {
        let callIndex = performanceRequests.count
        performanceRequests.append(request)

        if callIndex < stubs.count {
            let stub = stubs[callIndex]
            if stub.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: stub.delayNanoseconds)
            }
            if let error = stub.error {
                throw error
            }
            return Self.result(for: request, value: stub.resultValue ?? callIndex + 1)
        }

        return Self.result(for: request, value: callIndex + 1)
    }

    func databaseInfo() async throws -> UsageHistoryDatabaseInfo {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func exportBackup(to destinationURL: URL) async throws {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func importBackup(from sourceURL: URL) async throws {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func clearHistory() async throws {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func tokenProjectCatalogEntries() async throws -> [TokenProjectCatalogEntry] {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func tokenDimensionCatalogEntries() async throws -> [TokenUsageDimensionCatalogEntry] {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func updateTokenProjectDisplayName(projectPath: String, displayName: String?) async throws {
        throw PerformanceDashboardCacheSpyError.unused
    }

    func importTokenHistory(
        importer: CodexSessionTokenBackfillImporting,
        request: CodexSessionTokenBackfillRequest
    ) async throws -> CodexSessionTokenBackfillSummary {
        throw PerformanceDashboardCacheSpyError.unused
    }

    private static func result(
        for request: PerformanceDashboardLoadRequest,
        value: Int
    ) -> PerformanceDashboardLoadResult {
        let aggregate = PerformanceDashboardSeries(
            id: PerformanceDashboardSeries.aggregateID,
            name: "All",
            kind: .aggregate,
            contextID: "all"
        )
        let child = childSeries(for: request.breakdownDimension)
        let series = [aggregate, child]
        let bucketEnd = request.calendar.date(
            byAdding: request.range.chartBucketComponent,
            value: 1,
            to: request.periodStart
        ) ?? request.periodEnd
        let historyBounds = UsageHistoryBounds(
            earliest: request.periodStart.addingTimeInterval(-90 * 24 * 60 * 60),
            latest: request.periodEnd
        )

        switch request.mode {
        case .performance:
            return PerformanceDashboardLoadResult(
                timingSamples: [],
                reliabilitySamples: [],
                efficiencyTokenSamples: [],
                modelCapabilities: [],
                durationPoints: series.map {
                    PerformanceDashboardDurationPoint(
                        bucketStart: request.periodStart,
                        bucketEnd: bucketEnd,
                        series: $0,
                        turnCount: value,
                        completedTurnCount: value,
                        incompleteTurnCount: 0,
                        durationValues: [Int64(value * 1_000)],
                        firstTokenValues: [Int64(value * 100)]
                    )
                },
                reliabilityPoints: series.map {
                    PerformanceDashboardReliabilityPoint(
                        bucketStart: request.periodStart,
                        bucketEnd: bucketEnd,
                        series: $0,
                        successCount: value,
                        failureCount: 0,
                        unknownCount: 0,
                        errorCounts: [:]
                    )
                },
                breakdownRows: series.map {
                    PerformanceDashboardBreakdownRow(
                        series: $0,
                        turnCount: value,
                        completedTurnCount: value,
                        incompleteTurnCount: 0,
                        durationValues: [Int64(value * 1_000)],
                        firstTokenValues: [Int64(value * 100)],
                        eventCount: value,
                        successCount: value,
                        failureCount: 0,
                        unknownCount: 0,
                        errorCounts: [:]
                    )
                },
                efficiencyPoints: [],
                efficiencyRows: [],
                series: series,
                historyBounds: historyBounds
            )
        case .efficiency:
            return PerformanceDashboardLoadResult(
                timingSamples: [],
                reliabilitySamples: [],
                efficiencyTokenSamples: [],
                modelCapabilities: [],
                durationPoints: [],
                reliabilityPoints: [],
                breakdownRows: [],
                efficiencyPoints: series.map {
                    PerformanceDashboardEfficiencyPoint(
                        bucketStart: request.periodStart,
                        bucketEnd: bucketEnd,
                        series: $0,
                        turnCount: value,
                        completedTurnCount: value,
                        durationValues: [Int64(value * 1_000)],
                        firstTokenValues: [Int64(value * 100)],
                        durationTotalMilliseconds: Int64(value * 60_000),
                        eventCount: value,
                        successCount: value,
                        failureCount: 0,
                        unknownCount: 0,
                        inputTokens: Int64(value * 500),
                        cachedInputTokens: Int64(value * 300),
                        outputTokens: Int64(value * 150),
                        reasoningOutputTokens: Int64(value * 50),
                        contextPressureValues: [0.25]
                    )
                },
                efficiencyRows: series.map {
                    PerformanceDashboardEfficiencyRow(
                        series: $0,
                        turnCount: value,
                        completedTurnCount: value,
                        durationValues: [Int64(value * 1_000)],
                        firstTokenValues: [Int64(value * 100)],
                        durationTotalMilliseconds: Int64(value * 60_000),
                        eventCount: value,
                        successCount: value,
                        failureCount: 0,
                        unknownCount: 0,
                        inputTokens: Int64(value * 500),
                        cachedInputTokens: Int64(value * 300),
                        outputTokens: Int64(value * 150),
                        reasoningOutputTokens: Int64(value * 50),
                        contextPressureValues: [0.25]
                    )
                },
                series: series,
                historyBounds: historyBounds
            )
        }
    }

    private static func childSeries(
        for breakdownDimension: PerformanceDashboardBreakdownDimension
    ) -> PerformanceDashboardSeries {
        switch breakdownDimension {
        case .model:
            return PerformanceDashboardSeries(
                id: "model:gpt-5.5",
                name: "gpt-5.5",
                kind: .model,
                contextID: "gpt-5.5"
            )
        case .effort:
            return PerformanceDashboardSeries(
                id: "effort:xhigh",
                name: "xhigh",
                kind: .effort,
                contextID: "xhigh"
            )
        case .project:
            return PerformanceDashboardSeries(
                id: "project:/Users/example/codex",
                name: "codex",
                kind: .project,
                contextID: "/Users/example/codex",
                projectPath: "/Users/example/codex"
            )
        case .source:
            return PerformanceDashboardSeries(
                id: "source:cli",
                name: "cli",
                kind: .source,
                contextID: "cli"
            )
        case .transport:
            return PerformanceDashboardSeries(
                id: "transport:websocket",
                name: "websocket",
                kind: .transport,
                contextID: "websocket"
            )
        case .wireAPI:
            return PerformanceDashboardSeries(
                id: "wire_api:responses",
                name: "responses",
                kind: .wireAPI,
                contextID: "responses"
            )
        }
    }
}
