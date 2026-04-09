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
            persistSelection: { _ in }
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
            persistSelection: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "95%")

        viewModel.selectMenuBarDisplayWindow(.fiveHour)
        XCTAssertEqual(viewModel.menuBarPercentText, "84%")

        viewModel.stop()
    }
}

private final class MockCodexRateLimitClient: CodexRateLimitClientProtocol {
    var onSnapshot: ((CodexRateLimitSnapshot) -> Void)?

    private let snapshot: CodexRateLimitSnapshot

    private(set) var startCallCount = 0
    private(set) var refreshCallCount = 0

    init(snapshot: CodexRateLimitSnapshot) {
        self.snapshot = snapshot
    }

    func start() async throws -> CodexRateLimitSnapshot {
        startCallCount += 1
        return snapshot
    }

    func refresh() async throws -> CodexRateLimitSnapshot {
        refreshCallCount += 1
        return snapshot
    }

    func stop() {}
}
