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
        XCTAssertEqual(viewModel.menuBarPercentText, "95%")

        viewModel.selectMenuBarDisplayWindow(.fiveHour)
        XCTAssertEqual(viewModel.menuBarPercentText, "84%")

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
        XCTAssertEqual(viewModel.menuBarPercentText, "89%")

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
            startResponses: [.failure(MockClientError.sample)],
            refreshResponses: []
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
        XCTAssertEqual(viewModel.statusItemVisualState, .error)
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
        XCTAssertEqual(viewModel.menuBarPercentText, "89%")

        persistedSelection.selection = .tightest
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(viewModel.selectedMenuBarDisplayWindow, .tightest)
        XCTAssertEqual(viewModel.menuBarPercentText, "65%")

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
}

private final class MockCodexRateLimitClient: CodexRateLimitClientProtocol {
    var onSnapshot: ((CodexRateLimitSnapshot) -> Void)?

    private(set) var startCallCount = 0
    private(set) var refreshCallCount = 0
    private var startResponses: [Result<CodexRateLimitSnapshot, Error>]
    private var refreshResponses: [Result<CodexRateLimitSnapshot, Error>]

    convenience init(snapshot: CodexRateLimitSnapshot) {
        self.init(
            startResponses: [.success(snapshot)],
            refreshResponses: [.success(snapshot)]
        )
    }

    init(
        startResponses: [Result<CodexRateLimitSnapshot, Error>],
        refreshResponses: [Result<CodexRateLimitSnapshot, Error>]
    ) {
        self.startResponses = startResponses
        self.refreshResponses = refreshResponses
    }

    func start() async throws -> CodexRateLimitSnapshot {
        startCallCount += 1
        return try nextResponse(from: &startResponses)
    }

    func refresh() async throws -> CodexRateLimitSnapshot {
        refreshCallCount += 1
        return try nextResponse(from: &refreshResponses)
    }

    func stop() {}

    private func nextResponse(from responses: inout [Result<CodexRateLimitSnapshot, Error>]) throws -> CodexRateLimitSnapshot {
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

private enum MockClientError: Error {
    case sample
}
