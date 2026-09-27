import AppKit
import XCTest
@testable import CodexUsageCore

@MainActor
final class MenuBarStatusViewModelTests: XCTestCase {
    func testStatusItemRingAndHoverFollowPercentageDisplayOption() async throws {
        let resetDate = ISO8601DateFormatter().date(from: "2026-10-03T16:58:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 33, windowDurationMinutes: 10_080, resetsAt: resetDate),
            secondary: nil
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let viewModel = MenuBarStatusViewModel(
            client: client,
            refreshInterval: 3_600,
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )
        let resetStore = CodexResetCreditStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let controller = StatusItemController(
            viewModel: viewModel,
            updateMonitor: AppUpdateMonitor(),
            resetCreditStore: resetStore
        )
        defer { viewModel.stop() }

        await viewModel.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        let button = try XCTUnwrap(controller.statusButtonForTesting)
        XCTAssertEqual(button.title, "67%")
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.image?.size.width, 20)
        XCTAssertNil(controller.ringToolTipTag)

        viewModel.setMenuBarShowsRemainingPercentage(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(button.title, "")
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.image?.size.width, 15)
        XCTAssertNil(button.toolTip)
        let toolTipTag = try XCTUnwrap(controller.ringToolTipTag)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        XCTAssertEqual(
            controller.view(button, stringForToolTip: toolTipTag, point: .zero, userData: nil),
            "67% left\nResets \(formatter.string(from: resetDate))"
        )
        XCTAssertEqual(button.accessibilityLabel(), "Codex usage 67% remaining")

        viewModel.setMenuBarShowsResetDate(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(button.title.isEmpty)
        XCTAssertEqual(button.image?.size.width, 20)
        XCTAssertNil(controller.ringToolTipTag)

        viewModel.setMenuBarShowsResetDate(false)
        viewModel.setMenuBarShowsResetTime(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(button.title.isEmpty)
        XCTAssertNil(controller.ringToolTipTag)

        viewModel.setMenuBarShowsResetTime(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(button.title, "")
        XCTAssertNotNil(controller.ringToolTipTag)

        viewModel.setMenuBarShowsRemainingPercentage(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(button.title, "67%")
        XCTAssertNil(controller.ringToolTipTag)
    }

    func testPopoverAlwaysRefreshesToPickUpLatestUsage() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 6, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 2, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let latestSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 95, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 12, windowDurationMinutes: 10_080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(
            startResponses: [.success(snapshot)],
            refreshResponses: [.success(snapshot), .success(latestSnapshot)]
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(client.startCallCount, 1)
        XCTAssertEqual(client.refreshCallCount, 0)
        XCTAssertEqual(viewModel.menuBarPercentText, "98%")
        XCTAssertEqual(viewModel.weeklyRemainingPercent, 98)
        XCTAssertEqual(viewModel.sevenDayRow.remainingPercentText, "98% left")

        await viewModel.popoverDidAppear()
        await viewModel.popoverDidAppear()
        XCTAssertEqual(client.refreshCallCount, 2)
        XCTAssertEqual(viewModel.menuBarPercentText, "88%")
        XCTAssertEqual(viewModel.weeklyRemainingPercent, 88)
        XCTAssertEqual(viewModel.sevenDayRow.remainingPercentText, "88% left")

        viewModel.stop()
    }

    func testPrimaryOnlyWeeklyLimitDrivesViewModel() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 43, windowDurationMinutes: 10_080, resetsAt: nil),
            secondary: nil
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "57%")
        XCTAssertEqual(viewModel.sevenDayRow.remainingPercentText, "57% left")

        viewModel.stop()
    }

    func testFiveHourOnlyDoesNotBecomeWeeklyUsage() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: nil,
            secondary: CodexRateLimitWindow(usedPercent: 6, windowDurationMinutes: 300, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "--")
        XCTAssertNil(viewModel.weeklyRemainingPercent)
        XCTAssertEqual(viewModel.sevenDayRow.remainingPercentText, "--% left")

        viewModel.stop()
    }

    func testStartFailureShowsExplicitOfflineStateWithoutUsageValues() async {
        let now = ISO8601DateFormatter().date(from: "2026-05-19T14:18:00Z")!
        let client = MockCodexRateLimitClient(
            startResponses: [Result<CodexUsageSnapshot, Error>.failure(MockClientError.sample)],
            refreshResponses: [Result<CodexUsageSnapshot, Error>]()
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { now },
            refreshInterval: 3_600,
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "Offline")
        XCTAssertNil(viewModel.weeklyRemainingPercent)
        XCTAssertEqual(viewModel.footerStatusText, "Offline")
        XCTAssertFalse(viewModel.hasSnapshot)
        XCTAssertFalse(viewModel.isStaleSnapshot)
        XCTAssertEqual(viewModel.errorMessage, "Unable to load Codex usage.")
        XCTAssertEqual(viewModel.statusItemVisualState, StatusItemVisualState.error)

        viewModel.stop()
    }

    func testMenuBarDisplayOptionsUpdateAndPersistMenuBarText() async {
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-28T19:58:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: resetDate)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let persistedOptions = MenuBarDisplayOptionsBox(options: .defaultValue)
        let now = ISO8601DateFormatter().date(from: "2026-04-25T16:00:00Z")!

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { now },
            refreshInterval: 3_600,
            menuBarDisplayOptions: persistedOptions.options,
            loadMenuBarDisplayOptions: { persistedOptions.options },
            persistMenuBarDisplayOptions: { persistedOptions.options = $0 },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "39%")

        viewModel.setMenuBarShowsResetDate(true)
        viewModel.setMenuBarShowsResetTime(true)

        XCTAssertEqual(persistedOptions.options.showsResetDate, true)
        XCTAssertEqual(persistedOptions.options.showsResetTime, true)
        XCTAssertTrue(viewModel.menuBarPercentText.contains("4/28"))
        XCTAssertTrue(viewModel.menuBarPercentText.contains("PM"))

        viewModel.setMenuBarShowsRemainingPercentage(false)
        XCTAssertFalse(persistedOptions.options.showsRemainingPercentage)
        XCTAssertEqual(viewModel.weeklyRemainingPercent, 39)
        XCTAssertTrue(viewModel.menuBarPercentText.contains("4/28"))
        XCTAssertTrue(viewModel.menuBarPercentText.contains("PM"))
        XCTAssertFalse(viewModel.menuBarPercentText.contains("%"))

        viewModel.setMenuBarShowsResetDate(false)
        viewModel.setMenuBarShowsResetTime(false)
        XCTAssertEqual(viewModel.menuBarPercentText, "")

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
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
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
        XCTAssertEqual(viewModel.menuBarPercentText, "Offline")
        XCTAssertNil(viewModel.weeklyRemainingPercent)

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
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
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
        XCTAssertEqual(viewModel.menuBarPercentText, "89%")

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
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertFalse(viewModel.hasSnapshot)
        XCTAssertEqual(viewModel.errorMessage, "Unable to load Codex usage.")
        XCTAssertEqual(viewModel.statusItemVisualState, StatusItemVisualState.error)
        XCTAssertEqual(viewModel.menuBarPercentText, "Offline")
        XCTAssertEqual(viewModel.footerStatusText, "Offline")

        viewModel.stop()
    }

    func testPersistedMenuBarDisplayOptionsSyncBackIntoViewModel() async {
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-28T19:58:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 35, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: resetDate)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let persistedOptions = MenuBarDisplayOptionsBox(options: .defaultValue)
        let now = ISO8601DateFormatter().date(from: "2026-04-25T16:00:00Z")!

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { now },
            refreshInterval: 60,
            menuBarDisplayOptions: persistedOptions.options,
            loadMenuBarDisplayOptions: { persistedOptions.options },
            persistMenuBarDisplayOptions: { persistedOptions.options = $0 },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "39%")

        persistedOptions.options = MenuBarDisplayOptions(
            showsResetDate: true,
            showsResetTime: false
        )
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(viewModel.menuBarDisplayOptions, persistedOptions.options)
        XCTAssertTrue(viewModel.menuBarPercentText.contains("4/28"))

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
            menuBarDisplayOptions: .defaultValue,
            loadMenuBarDisplayOptions: { .defaultValue },
            persistMenuBarDisplayOptions: { _ in },
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
    var onSnapshot: ((CodexUsageSnapshot) -> Void)?
    private(set) var startCallCount = 0
    private(set) var refreshCallCount = 0
    private var startResponses: [Result<CodexUsageSnapshot, Error>]
    private var refreshResponses: [Result<CodexUsageSnapshot, Error>]

    convenience init(snapshot: CodexRateLimitSnapshot) {
        self.init(
            startResponses: [.success(CodexUsageSnapshot.aggregateOnly(displaySnapshot: snapshot))],
            refreshResponses: [.success(CodexUsageSnapshot.aggregateOnly(displaySnapshot: snapshot))]
        )
    }

    convenience init(startResponses: [Result<CodexRateLimitSnapshot, Error>], refreshResponses: [Result<CodexRateLimitSnapshot, Error>]) {
        self.init(
            startResponses: startResponses.map { $0.map(CodexUsageSnapshot.aggregateOnly(displaySnapshot:)) },
            refreshResponses: refreshResponses.map { $0.map(CodexUsageSnapshot.aggregateOnly(displaySnapshot:)) }
        )
    }

    init(startResponses: [Result<CodexUsageSnapshot, Error>], refreshResponses: [Result<CodexUsageSnapshot, Error>]) {
        self.startResponses = startResponses
        self.refreshResponses = refreshResponses
    }

    func start() async throws -> CodexUsageSnapshot {
        startCallCount += 1
        return try nextResponse(from: &startResponses)
    }

    func refresh() async throws -> CodexUsageSnapshot {
        refreshCallCount += 1
        return try nextResponse(from: &refreshResponses)
    }

    func stop() {}

    private func nextResponse(from responses: inout [Result<CodexUsageSnapshot, Error>]) throws -> CodexUsageSnapshot {
        guard !responses.isEmpty else { throw MockClientError.sample }
        return try responses.removeFirst().get()
    }
}

private final class MutableNow {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}

private final class MenuBarDisplayOptionsBox {
    var options: MenuBarDisplayOptions

    init(options: MenuBarDisplayOptions) {
        self.options = options
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
