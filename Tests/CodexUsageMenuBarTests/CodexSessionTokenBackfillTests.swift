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
