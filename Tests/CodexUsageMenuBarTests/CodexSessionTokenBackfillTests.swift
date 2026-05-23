import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testSessionTokenBackfillImportsMetadataOnlyTokenEvents() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-04-14T13-00-00-abc.jsonl")
        try writeSessionLines(
            [
                """
                {"timestamp":"2026-04-14T20:00:00.000Z","type":"response_item","payload":{"item":{"type":"message","content":[{"text":"secret prompt text"}]}}}
                """,
                """
                {"timestamp":"2026-04-14T20:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{}}}
                """,
                "{not valid json \"token_count\"",
                tokenCountLine(
                    timestamp: "2026-04-14T20:00:02.123Z",
                    lastInput: 10,
                    lastCached: 2,
                    lastOutput: 3,
                    lastReasoning: 1,
                    lastTotal: 16,
                    totalInput: 10,
                    totalCached: 2,
                    totalOutput: 3,
                    totalReasoning: 1,
                    totalTotal: 16,
                    contextWindow: 258_400
                ),
                tokenCountLine(
                    timestamp: "2026-04-14T20:05:00Z",
                    lastInput: 15,
                    lastCached: 3,
                    lastOutput: 4,
                    lastReasoning: 2,
                    lastTotal: 24,
                    totalInput: 25,
                    totalCached: 5,
                    totalOutput: 7,
                    totalReasoning: 3,
                    totalTotal: 40,
                    contextWindow: 258_400
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let summary = try importer.importTokenHistory(into: store)
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.tokenEventsImported, 2)
        XCTAssertEqual(summary.duplicateEventsSkipped, 0)
        XCTAssertEqual(summary.failedLinesSkipped, 1)
        XCTAssertEqual(samples.map(\.threadID), [
            "session:rollout-2026-04-14T13-00-00-abc",
            "session:rollout-2026-04-14T13-00-00-abc",
        ])
        XCTAssertEqual(samples.map(\.turnID), ["line:4", "line:5"])
        XCTAssertEqual(samples.map(\.model), [nil, nil])
        XCTAssertEqual(samples.map(\.modelContextWindow), [258_400, 258_400])
        XCTAssertEqual(samples.map(\.observedInputTokens), [10, 15])
        XCTAssertEqual(samples.map(\.observedCachedInputTokens), [2, 3])
        XCTAssertEqual(samples.map(\.observedOutputTokens), [3, 4])
        XCTAssertEqual(samples.map(\.observedReasoningOutputTokens), [1, 2])
        XCTAssertEqual(samples.map(\.observedTotalTokens), [16, 24])
        XCTAssertFalse(samples.contains { sample in
            sample.threadID.contains("secret") || sample.turnID.contains("secret") || (sample.model?.contains("secret") ?? false)
        })
    }

    func testSessionTokenBackfillUsesLatestModelMetadataForTokenEvents() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-models.jsonl")
        try writeSessionLines(
            [
                turnContextLine(timestamp: "2026-05-17T15:00:00Z", model: " gpt-5.4 "),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 125,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 125
                ),
                turnContextLine(timestamp: "2026-05-17T15:05:00Z", model: "codex-future-7"),
                tokenCountLine(
                    timestamp: "2026-05-17T15:05:10Z",
                    lastInput: 200,
                    lastCached: 100,
                    lastOutput: 30,
                    lastReasoning: 10,
                    lastTotal: 240,
                    totalInput: 300,
                    totalCached: 140,
                    totalOutput: 50,
                    totalReasoning: 15,
                    totalTotal: 365
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let summary = try importer.importTokenHistory(into: store)
        let samples = try store.tokenUsageSamples()
        let availableSeries = try store.availableTokenComponentSeries()

        XCTAssertEqual(summary.tokenEventsImported, 2)
        XCTAssertEqual(samples.map(\.model), ["gpt-5.4", "codex-future-7"])
        XCTAssertEqual(availableSeries.map(\.id), [
            "tokens_all",
            "model:codex-future-7",
            "model:gpt-5.4",
        ])
    }

    func testSessionTokenBackfillCleansOrDropsMalformedModelMetadata() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-malformed-models.jsonl")
        try writeSessionLines(
            [
                turnContextLine(
                    timestamp: "2026-05-17T15:00:00Z",
                    model: #"gpt-5.5\nTests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:"#
                ),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 125,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 125
                ),
                turnContextLine(timestamp: "2026-05-17T15:05:00Z", model: "/Users/example/.codex/sessions/session.jsonl"),
                tokenCountLine(
                    timestamp: "2026-05-17T15:05:10Z",
                    lastInput: 20,
                    lastCached: 5,
                    lastOutput: 5,
                    lastReasoning: 1,
                    lastTotal: 31,
                    totalInput: 120,
                    totalCached: 45,
                    totalOutput: 25,
                    totalReasoning: 6,
                    totalTotal: 156
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        _ = try importer.importTokenHistory(into: store)

        XCTAssertEqual(try store.tokenUsageSamples().map(\.model), ["gpt-5.5", nil])
        XCTAssertEqual(try store.tokenDashboardSeries().map(\.id), ["tokens_all", "model:gpt-5.5", "tokens_unattributed"])
    }

    func testSessionTokenBackfillUsesTokenCountInfoModelWhenPresent() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-info-model.jsonl")
        try writeSessionLines(
            [
                turnContextLine(timestamp: "2026-05-17T15:00:00Z", model: "gpt-5.4"),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
                    lastInput: 100,
                    lastCached: 40,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 125,
                    totalInput: 100,
                    totalCached: 40,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 125,
                    model: "o-series-next"
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        _ = try importer.importTokenHistory(into: store)

        XCTAssertEqual(try store.tokenUsageSamples().map(\.model), ["o-series-next"])
    }

    func testSessionTokenBackfillAppliesSessionMetadataContextToTokenEvents() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-context.jsonl")
        try writeSessionLines(
            [
                sessionMetaLine(
                    timestamp: "2026-05-17T15:00:00Z",
                    sessionID: "019c-token-session",
                    cwd: "/Users/example/Projects/codex_codex",
                    source: "cli"
                ),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
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
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let summary = try importer.importTokenHistory(into: store)
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)

        XCTAssertEqual(summary.tokenEventsImported, 1)
        XCTAssertEqual(sample.sessionID, "019c-token-session")
        XCTAssertEqual(sample.projectPath, "/Users/example/Projects/codex_codex")
        XCTAssertEqual(sample.projectName, "codex_codex")
        XCTAssertEqual(sample.source, "cli")
        XCTAssertEqual(
            try store.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" },
            ["source_kind=cli"]
        )
    }

    func testSessionTokenBackfillAppliesTurnContextProjectAndEffortChanges() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-context-switch.jsonl")
        try writeSessionLines(
            [
                sessionMetaLine(timestamp: "2026-05-17T15:00:00Z", sessionID: "session-context", source: "cli"),
                turnContextLine(
                    timestamp: "2026-05-17T15:00:01Z",
                    model: "gpt-5.4",
                    cwd: "/Users/example/Projects/alpha",
                    effort: "high"
                ),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
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
                turnContextLine(
                    timestamp: "2026-05-17T15:05:00Z",
                    model: "gpt-5.4-mini",
                    cwd: "/Users/example/Projects/beta",
                    effort: "xhigh",
                    source: "vscode"
                ),
                tokenCountLine(
                    timestamp: "2026-05-17T15:05:10Z",
                    lastInput: 200,
                    lastCached: 100,
                    lastOutput: 30,
                    lastReasoning: 10,
                    lastTotal: 340,
                    totalInput: 300,
                    totalCached: 140,
                    totalOutput: 50,
                    totalReasoning: 15,
                    totalTotal: 505
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        _ = try importer.importTokenHistory(into: store)
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(samples.map(\.model), ["gpt-5.4", "gpt-5.4-mini"])
        XCTAssertEqual(samples.map(\.projectName), ["alpha", "beta"])
        XCTAssertEqual(samples.map(\.effort), ["high", "xhigh"])
        XCTAssertEqual(samples.map(\.source), ["cli", "vscode"])
    }

    func testSessionTokenBackfillCapturesSafeContextDimensions() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-dimensions.jsonl")
        try writeSessionLines(
            [
                sessionMetaLine(
                    timestamp: "2026-05-17T15:00:00Z",
                    sessionID: "session-dimensions",
                    cwd: "/Users/example/Projects/codex_codex",
                    extraPayload: #","originator":"vscode","cli_version":"0.78.0","model_provider":"openai","memory_mode":"enabled","thread_source":"cli""#
                ),
                turnContextLine(
                    timestamp: "2026-05-17T15:00:01Z",
                    model: "gpt-5.5",
                    effort: "high",
                    extraPayload: #","approval_policy":"never","permission_profile":{"type":"full"},"realtime_active":true,"truncation_policy":{"mode":"auto","limit":10000},"usage_mode":"/fast","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019c-parent-thread","depth":1,"agent_role":"explorer","agent_nickname":"Raman"}}}"#
                ),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
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
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        _ = try importer.importTokenHistory(into: store)

        XCTAssertEqual(
            try store.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" },
            [
                "agent_nickname=Raman",
                "agent_role=explorer",
                "approval_policy=never",
                "cli_version=0.78.0",
                "is_subagent=true",
                "memory_mode=enabled",
                "model_provider=openai",
                "originator=vscode",
                "permission_profile=full",
                "realtime_active=true",
                "sandbox_type=danger-full-access",
                "source_kind=subagent",
                "subagent_depth=1",
                "subagent_parent_thread_id=019c-parent-thread",
                "thread_source=cli",
                "truncation_policy=auto",
                "usage_mode=fast",
            ]
        )
    }

    func testSessionTokenBackfillDoesNotInferUsageModeWithoutExplicitMetadata() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-no-mode.jsonl")
        try writeSessionLines(
            [
                turnContextLine(timestamp: "2026-05-17T15:00:01Z", model: "gpt-5.4-mini", effort: "low"),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
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
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        _ = try importer.importTokenHistory(into: store)

        XCTAssertFalse(
            try store.tokenDimensionCatalogEntries().contains { $0.key == .usageMode },
            "Usage mode must only come from explicit usage_mode, speed_mode, or mode metadata."
        )
    }

    func testSessionTokenBackfillReimportsUnchangedOlderContextVersionToRepairContext() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-context-repair.jsonl")
        try writeSessionLines(
            [
                sessionMetaLine(
                    timestamp: "2026-05-17T15:00:00Z",
                    sessionID: "session-repair",
                    cwd: "/Users/example/Projects/repaired",
                    source: "cli"
                ),
                turnContextLine(timestamp: "2026-05-17T15:00:01Z", model: "gpt-5.5", effort: "medium"),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
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
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        _ = try importer.importTokenHistory(into: store)
        try executeSQLite(
            at: databaseURL,
            sql: """
            UPDATE token_usage_samples
            SET session_id = NULL,
                project_path = NULL,
                project_name = NULL,
                effort = NULL,
                source = NULL;
            UPDATE codex_session_token_imports
            SET context_version = '2';
            """
        )

        let repairSummary = try importer.importTokenHistory(into: store)
        let sample = try XCTUnwrap(store.tokenUsageSamples().first)

        XCTAssertEqual(repairSummary.filesScanned, 1)
        XCTAssertEqual(repairSummary.tokenEventsImported, 0)
        XCTAssertEqual(repairSummary.duplicateEventsSkipped, 1)
        XCTAssertEqual(repairSummary.contextEventsRepaired, 1)
        XCTAssertEqual(sample.sessionID, "session-repair")
        XCTAssertEqual(sample.projectName, "repaired")
        XCTAssertEqual(sample.effort, "medium")
        XCTAssertEqual(sample.source, "cli")
        XCTAssertEqual(sample.observedTotalTokens, 165)
    }

    func testSessionTokenBackfillReimportsUnchangedOlderContextVersionToRepairDimensions() async throws {
        let (store, databaseURL) = try makeTemporaryStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-dimension-repair.jsonl")
        try writeSessionLines(
            [
                turnContextLine(
                    timestamp: "2026-05-17T15:00:01Z",
                    model: "gpt-5.5",
                    extraPayload: #","usage_mode":"/fast","approval_policy":"never""#
                ),
                tokenCountLine(
                    timestamp: "2026-05-17T15:00:10Z",
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
            ],
            to: sessionURL
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        _ = try importer.importTokenHistory(into: store)
        try executeSQLite(
            at: databaseURL,
            sql: """
            DELETE FROM token_usage_dimensions;
            DELETE FROM token_dimension_catalog;
            UPDATE codex_session_token_imports
            SET context_version = NULL;
            """
        )

        let repairSummary = try importer.importTokenHistory(into: store)

        XCTAssertEqual(repairSummary.filesScanned, 1)
        XCTAssertEqual(repairSummary.tokenEventsImported, 0)
        XCTAssertEqual(repairSummary.duplicateEventsSkipped, 1)
        XCTAssertEqual(repairSummary.dimensionEventsRepaired, 3)
        XCTAssertEqual(
            try store.tokenDimensionCatalogEntries().map { "\($0.key.rawValue)=\($0.value)" },
            [
                "approval_policy=never",
                "sandbox_type=danger-full-access",
                "usage_mode=fast",
            ]
        )
        XCTAssertEqual(try store.tokenUsageSamples().first?.observedTotalTokens, 165)
    }

    func testSessionTokenBackfillIsIdempotent() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-04-14T20:00:00Z",
                    lastInput: 100,
                    lastCached: 0,
                    lastOutput: 20,
                    lastReasoning: 5,
                    lastTotal: 125,
                    totalInput: 100,
                    totalCached: 0,
                    totalOutput: 20,
                    totalReasoning: 5,
                    totalTotal: 125
                ),
                tokenCountLine(
                    timestamp: "2026-04-14T20:10:00Z",
                    lastInput: 50,
                    lastCached: 5,
                    lastOutput: 30,
                    lastReasoning: 10,
                    lastTotal: 95,
                    totalInput: 150,
                    totalCached: 5,
                    totalOutput: 50,
                    totalReasoning: 15,
                    totalTotal: 220
                ),
            ],
            to: sessionsURL.appendingPathComponent("rollout-2026-04-14T13-00-00-idempotent.jsonl")
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let firstSummary = try importer.importTokenHistory(into: store)
        let secondSummary = try importer.importTokenHistory(into: store)
        let forcedSummary = try importer.importTokenHistory(into: store, request: .allHistory(forceRescan: true))

        XCTAssertEqual(firstSummary.tokenEventsImported, 2)
        XCTAssertEqual(firstSummary.duplicateEventsSkipped, 0)
        XCTAssertEqual(secondSummary.tokenEventsImported, 0)
        XCTAssertEqual(secondSummary.duplicateEventsSkipped, 0)
        XCTAssertEqual(secondSummary.filesScanned, 0)
        XCTAssertEqual(secondSummary.filesSkippedUnchanged, 1)
        XCTAssertEqual(forcedSummary.tokenEventsImported, 0)
        XCTAssertEqual(forcedSummary.duplicateEventsSkipped, 2)
        XCTAssertEqual(try store.tokenUsageSamples().map(\.observedTotalTokens), [125, 95])
        XCTAssertEqual(try store.tokenTotalForDay(containing: date("2026-04-14T21:00:00Z"), calendar: calendar), 220)
    }

    func testSessionTokenBackfillRecentRequestUsesBounds() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        let archivedURL = sessionsURL.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedURL, withIntermediateDirectories: true)
        let oldURL = sessionsURL.appendingPathComponent("rollout-2026-03-01T10-00-00-old.jsonl")
        let recentURL = sessionsURL.appendingPathComponent("rollout-2026-05-10T10-00-00-recent.jsonl")
        let archivedRecentURL = archivedURL.appendingPathComponent("rollout-2026-05-12T10-00-00-archived.jsonl")
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-03-01T18:00:00Z",
                    lastInput: 10,
                    lastCached: 0,
                    lastOutput: 2,
                    lastReasoning: 0,
                    lastTotal: 12,
                    totalInput: 10,
                    totalCached: 0,
                    totalOutput: 2,
                    totalReasoning: 0,
                    totalTotal: 12
                ),
            ],
            to: oldURL
        )
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-05-10T18:00:00Z",
                    lastInput: 20,
                    lastCached: 5,
                    lastOutput: 3,
                    lastReasoning: 1,
                    lastTotal: 29,
                    totalInput: 20,
                    totalCached: 5,
                    totalOutput: 3,
                    totalReasoning: 1,
                    totalTotal: 29
                ),
            ],
            to: recentURL
        )
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-05-12T18:00:00Z",
                    lastInput: 30,
                    lastCached: 5,
                    lastOutput: 4,
                    lastReasoning: 1,
                    lastTotal: 40,
                    totalInput: 30,
                    totalCached: 5,
                    totalOutput: 4,
                    totalReasoning: 1,
                    totalTotal: 40
                ),
            ],
            to: archivedRecentURL
        )
        try setModificationDate(date("2026-05-17T18:10:00Z"), for: oldURL)
        try setModificationDate(date("2026-05-10T18:10:00Z"), for: recentURL)
        try setModificationDate(date("2026-05-12T18:10:00Z"), for: archivedRecentURL)
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL, archivedURL])

        let summary = try importer.importTokenHistory(
            into: store,
            request: .recent(now: date("2026-05-17T12:00:00Z"), days: 30)
        )

        XCTAssertEqual(summary.filesDiscovered, 3)
        XCTAssertEqual(summary.filesSkippedByBounds, 2)
        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.tokenEventsImported, 1)
        XCTAssertEqual(try store.tokenUsageSamples().map(\.receivedAt), [date("2026-05-10T18:00:00Z")])
    }

    func testSessionTokenBackfillReimportsChangedFilesAndRepairsModel() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-repair.jsonl")
        let tokenLineWithoutModel = tokenCountLine(
            timestamp: "2026-05-17T15:00:00Z",
            lastInput: 100,
            lastCached: 10,
            lastOutput: 15,
            lastReasoning: 0,
            lastTotal: 125,
            totalInput: 100,
            totalCached: 10,
            totalOutput: 15,
            totalReasoning: 0,
            totalTotal: 125
        )
        try writeSessionLines([tokenLineWithoutModel], to: sessionURL)
        try setModificationDate(date("2026-05-17T15:01:00Z"), for: sessionURL)
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL])

        let firstSummary = try importer.importTokenHistory(into: store)

        let tokenLineWithModel = tokenCountLine(
            timestamp: "2026-05-17T15:00:00Z",
            lastInput: 100,
            lastCached: 10,
            lastOutput: 15,
            lastReasoning: 0,
            lastTotal: 125,
            totalInput: 100,
            totalCached: 10,
            totalOutput: 15,
            totalReasoning: 0,
            totalTotal: 125,
            model: " gpt-future-2 "
        )
        try writeSessionLines([tokenLineWithModel], to: sessionURL)
        try setModificationDate(date("2026-05-17T15:05:00Z"), for: sessionURL)

        let repairSummary = try importer.importTokenHistory(into: store)
        let samples = try store.tokenUsageSamples()

        XCTAssertEqual(firstSummary.tokenEventsImported, 1)
        XCTAssertEqual(repairSummary.filesScanned, 1)
        XCTAssertEqual(repairSummary.tokenEventsImported, 0)
        XCTAssertEqual(repairSummary.duplicateEventsSkipped, 1)
        XCTAssertEqual(repairSummary.modelEventsRepaired, 1)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.model, "gpt-future-2")
        XCTAssertEqual(samples.first?.observedTotalTokens, 125)
    }

    @MainActor
    func testSessionTokenBackfillScansSessionsAndArchivedAndFeedsTokenCharts() async throws {
        let store = try makeStore()
        let rootURL = try makeTemporaryDirectory()
        let sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        let archivedURL = rootURL.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedURL, withIntermediateDirectories: true)
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-01-10T12:00:00Z",
                    lastInput: 80,
                    lastCached: 0,
                    lastOutput: 20,
                    lastReasoning: 0,
                    lastTotal: 100,
                    totalInput: 80,
                    totalCached: 0,
                    totalOutput: 20,
                    totalReasoning: 0,
                    totalTotal: 100
                ),
            ],
            to: archivedURL.appendingPathComponent("rollout-2026-01-10T04-00-00-archived.jsonl")
        )
        try writeSessionLines(
            [
                tokenCountLine(
                    timestamp: "2026-04-14T12:10:00Z",
                    lastInput: 120,
                    lastCached: 30,
                    lastOutput: 40,
                    lastReasoning: 10,
                    lastTotal: 200,
                    totalInput: 120,
                    totalCached: 30,
                    totalOutput: 40,
                    totalReasoning: 10,
                    totalTotal: 200
                ),
                tokenCountLine(
                    timestamp: "2026-04-15T09:00:00Z",
                    lastInput: 250,
                    lastCached: 60,
                    lastOutput: 70,
                    lastReasoning: 20,
                    lastTotal: 400,
                    totalInput: 370,
                    totalCached: 90,
                    totalOutput: 110,
                    totalReasoning: 30,
                    totalTotal: 600
                ),
            ],
            to: sessionsURL.appendingPathComponent("rollout-2026-04-14T05-00-00-live.jsonl")
        )
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [sessionsURL, archivedURL])

        let summary = try importer.importTokenHistory(into: store)

        XCTAssertEqual(summary.filesScanned, 2)
        XCTAssertEqual(summary.tokenEventsImported, 3)

        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-15T12:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedChartKind = .tokens

        viewModel.selectedRange = .day
        await viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-15T09:00:00Z"),
            date("2026-04-15T09:00:00Z"),
            date("2026-04-15T09:00:00Z"),
            date("2026-04-15T09:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenComponent), [.input, .cached, .output, .reasoning])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [250, 60, 70, 20])

        viewModel.selectedRange = .week
        await viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-14T00:00:00Z"),
            date("2026-04-14T00:00:00Z"),
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [120, 30, 40, 10, 250, 60, 70, 20])

        viewModel.selectedRange = .month
        await viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [120, 30, 40, 10, 250, 60, 70, 20])

        viewModel.selectedRange = .year
        await viewModel.reload()
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-01-01T00:00:00Z"),
            date("2026-01-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.tokenCount), [80, 20, 370, 90, 110, 30])
    }

    func testSessionTokenBackfillMissingDirectoriesReturnsEmptySummary() async throws {
        let store = try makeStore()
        let missingURL = try makeTemporaryDirectory().appendingPathComponent("missing", isDirectory: true)
        let importer = CodexSessionTokenBackfillImporter(sourceDirectories: [missingURL])

        let summary = try importer.importTokenHistory(into: store)

        XCTAssertEqual(summary.filesScanned, 0)
        XCTAssertEqual(summary.tokenEventsImported, 0)
        XCTAssertEqual(summary.duplicateEventsSkipped, 0)
        XCTAssertEqual(summary.failedLinesSkipped, 0)
        XCTAssertEqual(summary.statusMessage, "No Codex session files found.")
        XCTAssertTrue(try store.tokenUsageSamples().isEmpty)
    }

    func testSessionTaskTimingImporterPairsStartCompleteAndAppliesSafeContext() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-task-timing.jsonl")
        try writeSessionLines(
            [
                sessionMetaLine(
                    timestamp: "2026-05-17T15:00:00Z",
                    sessionID: "session-task-timing",
                    cwd: "/Users/example/Projects/task-timing",
                    source: "cli",
                    extraPayload: #","originator":"vscode","cli_version":"0.78.0""#
                ),
                turnContextLine(
                    timestamp: "2026-05-17T15:00:01Z",
                    model: "gpt-5.5",
                    effort: "xhigh",
                    extraPayload: #","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}"#
                ),
                """
                {"timestamp":"2026-05-17T15:00:01.500Z","type":"response_item","payload":{"item":{"type":"message","content":[{"text":"secret task text"}]}}}
                """,
                "{not valid json \"task_started\"",
                taskStartedLine(
                    timestamp: "2026-05-17T15:00:02Z",
                    turnID: "turn-task",
                    startedAt: "2026-05-17T15:00:02Z",
                    modelContextWindow: 258_400,
                    collaborationModeKind: "agentic"
                ),
                taskCompleteLine(
                    timestamp: "2026-05-17T15:00:05Z",
                    turnID: "turn-task",
                    completedAt: "2026-05-17T15:00:05Z",
                    durationMilliseconds: 3_500,
                    timeToFirstTokenMilliseconds: 800
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTaskTimingImporter(sourceDirectories: [sessionsURL])

        let summary = try importer.importTaskTiming(into: store, now: date("2026-05-18T12:00:00Z"))
        let events = try store.sessionTaskTimingEvents()
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(summary.filesDiscovered, 1)
        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.insertedCount, 1)
        XCTAssertEqual(summary.failedLinesSkipped, 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.sessionID, "session-task-timing")
        XCTAssertEqual(event.turnID, "turn-task")
        XCTAssertEqual(event.startedAt, date("2026-05-17T15:00:02Z"))
        XCTAssertEqual(event.completedAt, date("2026-05-17T15:00:05Z"))
        XCTAssertEqual(event.durationMilliseconds, 3_500)
        XCTAssertEqual(event.timeToFirstTokenMilliseconds, 800)
        XCTAssertEqual(event.modelContextWindow, 258_400)
        XCTAssertEqual(event.collaborationModeKind, "agentic")
        XCTAssertEqual(event.model, "gpt-5.5")
        XCTAssertEqual(event.projectPath, "/Users/example/Projects/task-timing")
        XCTAssertEqual(event.projectName, "task-timing")
        XCTAssertEqual(event.effort, "xhigh")
        XCTAssertEqual(event.source, "cli")
        XCTAssertTrue(event.dimensionsJSON?.contains("approval_policy") == true)
        XCTAssertFalse(event.dimensionsJSON?.contains("secret") == true)
    }

    func testSessionTaskTimingImporterSkipsUnchangedAndForceRescanIsIdempotent() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-task-idempotent.jsonl")
        try writeSessionLines(
            [
                taskStartedLine(
                    timestamp: "2026-05-17T15:00:02Z",
                    turnID: "turn-task",
                    startedAt: "2026-05-17T15:00:02Z"
                ),
                taskCompleteLine(
                    timestamp: "2026-05-17T15:00:05Z",
                    turnID: "turn-task",
                    completedAt: "2026-05-17T15:00:05Z"
                ),
            ],
            to: sessionURL
        )
        let importer = CodexSessionTaskTimingImporter(sourceDirectories: [sessionsURL])

        let firstSummary = try importer.importTaskTiming(into: store, now: date("2026-05-18T12:00:00Z"))
        let secondSummary = try importer.importTaskTiming(into: store, now: date("2026-05-18T12:00:00Z"))
        let forcedSummary = try importer.importTaskTiming(
            into: store,
            now: date("2026-05-18T12:00:00Z"),
            forceRescan: true
        )

        XCTAssertEqual(firstSummary.insertedCount, 1)
        XCTAssertEqual(secondSummary.filesScanned, 0)
        XCTAssertEqual(secondSummary.filesSkippedUnchanged, 1)
        XCTAssertEqual(forcedSummary.insertedCount, 0)
        XCTAssertEqual(forcedSummary.updatedCount, 0)
        XCTAssertEqual(forcedSummary.duplicateCount, 1)
        XCTAssertEqual(try store.sessionTaskTimingEvents().count, 1)
    }

    func testSessionTaskTimingImporterReimportsChangedFilesAndRepairsRows() async throws {
        let store = try makeStore()
        let sessionsURL = try makeTemporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let sessionURL = sessionsURL.appendingPathComponent("rollout-2026-05-17T08-00-00-task-repair.jsonl")
        try writeSessionLines(
            [
                taskStartedLine(
                    timestamp: "2026-05-17T15:00:02Z",
                    turnID: "turn-task",
                    startedAt: "2026-05-17T15:00:02Z"
                ),
            ],
            to: sessionURL
        )
        try setModificationDate(date("2026-05-17T15:01:00Z"), for: sessionURL)
        let importer = CodexSessionTaskTimingImporter(sourceDirectories: [sessionsURL])

        let firstSummary = try importer.importTaskTiming(into: store, now: date("2026-05-18T12:00:00Z"))

        try writeSessionLines(
            [
                taskStartedLine(
                    timestamp: "2026-05-17T15:00:02Z",
                    turnID: "turn-task",
                    startedAt: "2026-05-17T15:00:02Z"
                ),
                taskCompleteLine(
                    timestamp: "2026-05-17T15:00:06Z",
                    turnID: "turn-task",
                    completedAt: "2026-05-17T15:00:06Z",
                    timeToFirstTokenMilliseconds: 900
                ),
            ],
            to: sessionURL
        )
        try setModificationDate(date("2026-05-17T15:05:00Z"), for: sessionURL)

        let repairSummary = try importer.importTaskTiming(into: store, now: date("2026-05-18T12:00:00Z"))
        let event = try XCTUnwrap(try store.sessionTaskTimingEvents().first)

        XCTAssertEqual(firstSummary.insertedCount, 1)
        XCTAssertEqual(repairSummary.updatedCount, 1)
        XCTAssertEqual(event.completedAt, date("2026-05-17T15:00:06Z"))
        XCTAssertEqual(event.durationMilliseconds, 4_000)
        XCTAssertEqual(event.timeToFirstTokenMilliseconds, 900)
    }

    func testSessionTokenImportMetadataMigratesFromExistingDatabase() async throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createLegacyTokenHistoryDatabase(at: databaseURL)
        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let metadata = CodexSessionTokenImportFileMetadata(path: "/tmp/session.jsonl", fileSize: 123, modifiedAt: 456)

        try store.recordCodexSessionTokenImportFile(metadata, importedAt: 789, status: .imported)

        XCTAssertEqual(
            try store.codexSessionTokenImportFileRecord(path: "/tmp/session.jsonl"),
            CodexSessionTokenImportFileRecord(metadata: metadata, importedAt: 789, status: .imported)
        )
    }

}
