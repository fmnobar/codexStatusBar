import XCTest

@MainActor
final class MenuBarStatusViewModelTests: XCTestCase {
    func testPopoverAlwaysRefreshesToPickUpLatestUsage() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 6, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 2, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(client.startCallCount, 1)
        XCTAssertEqual(client.refreshCallCount, 0)

        await viewModel.popoverDidAppear()
        await viewModel.popoverDidAppear()
        XCTAssertEqual(client.refreshCallCount, 2)

        viewModel.stop()
    }

    func testSelectingFiveHourUpdatesMenuBarText() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 5, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 95%")

        viewModel.selectMenuBarDisplayWindow(.fiveHour)
        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84%")

        viewModel.stop()
    }

    func testFailedRefreshWithCachedSnapshotShowsStaleOfflineState() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-04-14T20:00:00Z")!)
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 35, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 11, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(
            startResponses: [.success(snapshot)],
            refreshResponses: [.failure(MockClientError.sample)]
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { currentTime.date },
            refreshInterval: 60,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        currentTime.date = currentTime.date.addingTimeInterval(180)
        await viewModel.manualRefresh()

        XCTAssertTrue(viewModel.hasSnapshot)
        XCTAssertTrue(viewModel.isStaleSnapshot)
        XCTAssertEqual(viewModel.statusItemVisualState, .stale)
        XCTAssertEqual(viewModel.footerStatusText, "Offline, showing last update from 3m ago")
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 89%")

        viewModel.stop()
    }

    func testSuccessfulRefreshClearsStaleState() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-04-14T20:00:00Z")!)
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 35, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 11, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(
            startResponses: [.success(snapshot)],
            refreshResponses: [.failure(MockClientError.sample), .success(snapshot)]
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { currentTime.date },
            refreshInterval: 60,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        currentTime.date = currentTime.date.addingTimeInterval(180)
        await viewModel.manualRefresh()
        XCTAssertEqual(viewModel.statusItemVisualState, .stale)

        currentTime.date = currentTime.date.addingTimeInterval(20)
        await viewModel.manualRefresh()
        XCTAssertFalse(viewModel.isStaleSnapshot)
        XCTAssertEqual(viewModel.statusItemVisualState, .normal)
        XCTAssertEqual(viewModel.footerStatusText, "Updated just now")

        viewModel.stop()
    }

    func testFailedInitialLoadShowsErrorState() async {
        let client = MockCodexRateLimitClient(
            startResponses: [Result<CodexRateLimitSnapshot, Error>.failure(MockClientError.sample)],
            refreshResponses: [Result<CodexRateLimitSnapshot, Error>]()
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 60,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertFalse(viewModel.hasSnapshot)
        XCTAssertEqual(viewModel.errorMessage, "Unable to load Codex usage.")
        XCTAssertEqual(viewModel.statusItemVisualState, StatusItemVisualState.error)
        XCTAssertEqual(viewModel.menuBarPercentText, "--")

        viewModel.stop()
    }

    func testPersistedSelectionChangesSyncBackIntoViewModel() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 35, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 11, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let persistedSelection = SelectionBox(selection: .sevenDay)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 60,
            selectedMenuBarDisplayWindow: persistedSelection.selection,
            loadPersistedSelection: { persistedSelection.selection },
            persistSelection: { persistedSelection.selection = $0 },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.selectedMenuBarDisplayWindow, .sevenDay)
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 89%")

        persistedSelection.selection = .tightest
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(viewModel.selectedMenuBarDisplayWindow, .tightest)
        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 65%")

        viewModel.selectMenuBarDisplayWindow(.fiveHour)
        XCTAssertEqual(persistedSelection.selection, .fiveHour)

        viewModel.stop()
    }

    func testLaunchAtLoginToggleUpdatesStateAndClearsError() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 20, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let launchAtLogin = LaunchAtLoginBox(isEnabled: false)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 60,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { launchAtLogin.isEnabled },
            setLaunchAtLoginEnabledAction: { launchAtLogin.isEnabled = $0 }
        )

        await viewModel.start()
        XCTAssertFalse(viewModel.launchAtLoginEnabled)

        viewModel.setLaunchAtLoginEnabled(true)
        XCTAssertTrue(viewModel.launchAtLoginEnabled)
        XCTAssertNil(viewModel.launchAtLoginError)

        viewModel.stop()
    }

    func testSuccessfulSnapshotsAreRecordedInHistory() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-04-14T20:00:00Z")!)
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 20, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let historyRecorder = MockUsageHistoryRecorder()

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { currentTime.date },
            refreshInterval: 3_600,
            historyRecorder: historyRecorder,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        currentTime.date = currentTime.date.addingTimeInterval(60)
        await viewModel.manualRefresh()

        XCTAssertEqual(historyRecorder.records.count, 2)
        XCTAssertEqual(historyRecorder.records[0].snapshot.displaySnapshot.secondary?.usedPercent, 20)
        XCTAssertEqual(historyRecorder.records[1].date, currentTime.date)

        viewModel.stop()
    }

    func testUsageDiagnosticsExportReturnsJSONAndClearsError() async throws {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 20, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let diagnostics = Self.diagnosticsSnapshot(classification: .comparableCandidate)
        let client = MockCodexRateLimitClient(
            snapshot: snapshot,
            diagnosticsResponses: [.success(diagnostics)]
        )
        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        let maybeData = await viewModel.usageDiagnosticsJSONData()
        let data = try XCTUnwrap(maybeData)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains("\"classification\" : \"comparableCandidate\""))
        XCTAssertNil(viewModel.diagnosticsExportError)
        XCTAssertEqual(client.diagnosticsCallCount, 1)
    }

    func testFailedUsageDiagnosticsExportPublishesError() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 20, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(
            snapshot: snapshot,
            diagnosticsResponses: [.failure(MockClientError.sample)]
        )
        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        let data = await viewModel.usageDiagnosticsJSONData()

        XCTAssertNil(data)
        XCTAssertEqual(viewModel.diagnosticsExportError, "Diagnostics could not be exported.")
        XCTAssertEqual(client.diagnosticsCallCount, 1)
    }

    private static func diagnosticsSnapshot(
        classification: CodexUsageDiagnosticsClassification
    ) -> CodexUsageDiagnosticsSnapshot {
        CodexUsageDiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            buckets: [
                CodexUsageDiagnosticsBucket(
                    id: "codex",
                    name: "All models",
                    kind: .aggregate,
                    planType: "pro",
                    primary: CodexUsageDiagnosticsWindow(usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil),
                    secondary: CodexUsageDiagnosticsWindow(usedPercent: 20, windowDurationMinutes: 10080, resetsAt: nil)
                ),
            ],
            summaries: [
                CodexUsageDiagnosticsWindowSummary(
                    window: .fiveHour,
                    classification: classification,
                    aggregateBucketID: "codex",
                    aggregateUsedPercent: 10,
                    modelBucketCount: 0,
                    modelUsedPercentSum: nil,
                    durationsAligned: true,
                    resetsAligned: true,
                    modelValuesWithinAggregate: true,
                    notes: []
                ),
            ]
        )
    }
}

private final class MockCodexRateLimitClient: CodexRateLimitClientProtocol {
    var onSnapshot: ((CodexUsageSnapshot) -> Void)?

    private(set) var startCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var diagnosticsCallCount = 0
    private var startResponses: [Result<CodexUsageSnapshot, Error>]
    private var refreshResponses: [Result<CodexUsageSnapshot, Error>]
    private var diagnosticsResponses: [Result<CodexUsageDiagnosticsSnapshot, Error>]

    convenience init(
        snapshot: CodexRateLimitSnapshot,
        diagnosticsResponses: [Result<CodexUsageDiagnosticsSnapshot, Error>] = []
    ) {
        self.init(
            startResponses: [.success(CodexUsageSnapshot.aggregateOnly(displaySnapshot: snapshot))],
            refreshResponses: [.success(CodexUsageSnapshot.aggregateOnly(displaySnapshot: snapshot))],
            diagnosticsResponses: diagnosticsResponses
        )
    }

    init(
        startResponses: [Result<CodexRateLimitSnapshot, Error>],
        refreshResponses: [Result<CodexRateLimitSnapshot, Error>],
        diagnosticsResponses: [Result<CodexUsageDiagnosticsSnapshot, Error>] = []
    ) {
        self.startResponses = startResponses.map { $0.map(CodexUsageSnapshot.aggregateOnly(displaySnapshot:)) }
        self.refreshResponses = refreshResponses.map { $0.map(CodexUsageSnapshot.aggregateOnly(displaySnapshot:)) }
        self.diagnosticsResponses = diagnosticsResponses
    }

    init(
        startResponses: [Result<CodexUsageSnapshot, Error>],
        refreshResponses: [Result<CodexUsageSnapshot, Error>],
        diagnosticsResponses: [Result<CodexUsageDiagnosticsSnapshot, Error>] = []
    ) {
        self.startResponses = startResponses
        self.refreshResponses = refreshResponses
        self.diagnosticsResponses = diagnosticsResponses
    }

    func start() async throws -> CodexUsageSnapshot {
        startCallCount += 1
        return try nextResponse(from: &startResponses)
    }

    func refresh() async throws -> CodexUsageSnapshot {
        refreshCallCount += 1
        return try nextResponse(from: &refreshResponses)
    }

    func usageDiagnostics() async throws -> CodexUsageDiagnosticsSnapshot {
        diagnosticsCallCount += 1
        guard !diagnosticsResponses.isEmpty else {
            throw MockClientError.sample
        }

        return try diagnosticsResponses.removeFirst().get()
    }

    func stop() {}

    private func nextResponse(from responses: inout [Result<CodexUsageSnapshot, Error>]) throws -> CodexUsageSnapshot {
        guard !responses.isEmpty else {
            throw MockClientError.sample
        }

        return try responses.removeFirst().get()
    }
}

private final class MutableNow {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}

private final class SelectionBox {
    var selection: MenuBarDisplayWindow

    init(selection: MenuBarDisplayWindow) {
        self.selection = selection
    }
}

private final class LaunchAtLoginBox {
    var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
}

private final class MockUsageHistoryRecorder: UsageHistoryRecording {
    private(set) var records: [(snapshot: CodexUsageSnapshot, date: Date)] = []

    func record(snapshot: CodexUsageSnapshot, at date: Date) {
        records.append((snapshot, date))
    }
}

private enum MockClientError: Error {
    case sample
}
