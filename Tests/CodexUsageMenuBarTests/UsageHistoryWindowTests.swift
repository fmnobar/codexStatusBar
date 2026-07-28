import AppKit
import CoreGraphics
import SQLite3
import SwiftUI
import XCTest
@testable import CodexUsageCore

extension UsageHistoryStoreTests {
    @MainActor
    func testUsageCollectionModeDefaultsToLightweightAndPersistsDetailedOptIn() throws {
        let suiteName = "UsageCollectionModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(UsageCollectionModeStore.load(from: defaults), .lightweight)

        defaults.set("future-invalid-value", forKey: UsageCollectionModeStore.key)
        XCTAssertEqual(UsageCollectionModeStore.load(from: defaults), .lightweight)

        let controller = UsageCollectionModeController(defaults: defaults)
        XCTAssertEqual(controller.mode, .lightweight)

        controller.setMode(.detailedAnalytics)
        XCTAssertEqual(controller.mode, .detailedAnalytics)
        XCTAssertEqual(UsageCollectionModeStore.load(from: defaults), .detailedAnalytics)

        controller.setMode(.lightweight)
        XCTAssertEqual(UsageCollectionModeStore.load(from: defaults), .lightweight)
    }

    func testUsageCollectionPlansFreezeLightweightAndDetailedCollectorBehavior() {
        XCTAssertEqual(
            UsageCollectionPlan.plan(for: .lightweight),
            UsageCollectionPlan(
                mode: .lightweight,
                liveTokenCaptureInterval: 300,
                capturesDetailedTokenContext: false,
                capturesAdvancedMetadata: false
            )
        )
        XCTAssertEqual(
            UsageCollectionPlan.plan(for: .detailedAnalytics),
            UsageCollectionPlan(
                mode: .detailedAnalytics,
                liveTokenCaptureInterval: 30,
                capturesDetailedTokenContext: true,
                capturesAdvancedMetadata: true
            )
        )
    }

    func testUsageCollectionDetailGateUpdatesSynchronously() {
        let gate = UsageCollectionDetailGate(mode: .lightweight)
        XCTAssertFalse(gate.capturesDetailedTokenContext)

        gate.update(mode: .detailedAnalytics)
        XCTAssertTrue(gate.capturesDetailedTokenContext)

        gate.update(mode: .lightweight)
        XCTAssertFalse(gate.capturesDetailedTokenContext)
    }

    func testStorageReplacementGateIsBalancedAndReportsRetryableState() {
        let gate = UsageHistoryStoreReplacementGate()
        XCTAssertFalse(gate.isActive)
        gate.begin()
        gate.begin()
        XCTAssertTrue(gate.isActive)
        gate.end()
        XCTAssertTrue(gate.isActive)
        gate.end()
        XCTAssertFalse(gate.isActive)
        gate.end()
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(
            UsageHistoryStoreError.storageMaintenanceInProgress.localizedDescription
                .contains("retried shortly")
        )
    }

    @MainActor
    func testAppDelegateForwardsLaunchAndTerminationToRuntime() {
        let runtime = AppDelegateRuntimeSpy()
        let delegate = AppDelegate(runtime: runtime)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.stopCount, 0)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    @MainActor
    func testMenuBarContentInteractionLoadsHistoryOnlyOnExpansionAndRoutesFullWindows() async throws {
        let store = try UsageHistoryStore.inMemory(
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let database = UsageHistoryDatabaseWorker(store: store)
        let historySnapshotSpy = UsageHistorySnapshotSpy()
        var historyRouteCount = 0
        var settingsRouteCount = 0
        let historyViewModel = UsageHistoryViewModel(
            database: historySnapshotSpy,
            calendar: calendar
        )
        let client = CodexAppServerClient(
            ensureConnectedOverride: {},
            sendRequestOverride: { _, _ in [String: Any]() }
        )
        let statusViewModel = MenuBarStatusViewModel(client: client)
        let view = MenuBarContentView(
            viewModel: statusViewModel,
            historyDatabase: database,
            updateMonitor: AppUpdateMonitor(),
            onOpenHistory: {
                historyRouteCount += 1
            },
            onOpenDataSettings: {
                settingsRouteCount += 1
            },
            historyViewModel: historyViewModel
        )
        let model = view.interactionModelForTesting

        XCTAssertNil(model.expandedSection)
        var requestCount = await historySnapshotSpy.requestCount()
        XCTAssertEqual(requestCount, 0)

        model.toggle(.settings)
        await Task.yield()
        XCTAssertEqual(model.expandedSection, .settings)
        requestCount = await historySnapshotSpy.requestCount()
        XCTAssertEqual(requestCount, 0)

        model.toggle(.history)
        for _ in 0..<100 {
            if await historySnapshotSpy.requestCount() > 0 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(model.expandedSection, .history)
        requestCount = await historySnapshotSpy.requestCount()
        XCTAssertEqual(requestCount, 1)

        model.toggle(.history)
        await Task.yield()
        XCTAssertNil(model.expandedSection)
        requestCount = await historySnapshotSpy.requestCount()
        XCTAssertEqual(requestCount, 1)

        model.openFullHistory()
        model.openFullSettings()
        XCTAssertEqual(historyRouteCount, 1)
        XCTAssertEqual(settingsRouteCount, 1)
    }

    @MainActor
    func testStatusItemControllerRoutesProductionDestinationsAndSelectsSettingsTab() throws {
        let suiteName = "StatusItemControllerRoutes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try UsageHistoryStore.inMemory(
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let database = UsageHistoryDatabaseWorker(store: store)
        let client = CodexAppServerClient(
            ensureConnectedOverride: {},
            sendRequestOverride: { _, _ in [String: Any]() }
        )
        let statusViewModel = MenuBarStatusViewModel(client: client)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var destinations: [StatusItemDestination] = []
        let controller = StatusItemController(
            viewModel: statusViewModel,
            historyDatabase: database,
            updateMonitor: AppUpdateMonitor(),
            appServerDiagnosticsStore: CodexAppServerAuditDiagnosticsStore(
                fileURL: temporaryDirectory.appendingPathComponent("diagnostics.json")
            ),
            resetCreditStore: CodexResetCreditStore(
                fileURL: temporaryDirectory.appendingPathComponent("reset-credits.json")
            ),
            routeHandlerOverride: { destination in
                destinations.append(destination)
            },
            settingsDefaults: defaults
        )

        controller.route(to: .history)
        controller.route(to: .tokenDashboard)
        controller.route(to: .performanceDashboard)
        controller.route(to: .settings(.updates))
        XCTAssertEqual(
            SettingsTabSelectionStore.selectedTab(
                from: defaults.string(forKey: SettingsTabSelectionStore.key) ?? ""
            ),
            .updates
        )
        controller.route(to: .settings(.data))

        XCTAssertEqual(
            destinations,
            [.history, .tokenDashboard, .performanceDashboard, .settings(.updates), .settings(.data)]
        )
        XCTAssertEqual(
            SettingsTabSelectionStore.selectedTab(
                from: defaults.string(forKey: SettingsTabSelectionStore.key) ?? ""
            ),
            .data
        )
    }

    @MainActor
    func testAccessibilitySemanticsCoverNormalAndWarningStatusAndInteractiveControls() async throws {
        let selectedRow = MenuBarLimitRowPresentation(
            title: "7d limit",
            remainingPercentText: "61% left",
            detailText: "Resets Sunday",
            displayWindow: .sevenDay,
            isSelected: true
        )
        XCTAssertEqual(
            AppAccessibilitySemantics.limitRow(selectedRow),
            AppAccessibilityPresentation(
                label: "7d limit",
                value: "61% left, Resets Sunday",
                isSelected: true
            )
        )
        XCTAssertEqual(
            AppAccessibilitySemantics.expandableSection(title: "History", isExpanded: false),
            AppAccessibilityPresentation(label: "History", value: "Collapsed", isSelected: false)
        )
        XCTAssertEqual(
            AppAccessibilitySemantics.expandableSection(title: "History", isExpanded: true),
            AppAccessibilityPresentation(label: "History", value: "Expanded", isSelected: false)
        )
        XCTAssertEqual(
            AppAccessibilitySemantics.selectableSeries(name: "GPT-5", isSelected: true),
            AppAccessibilityPresentation(label: "GPT-5", value: "Selected", isSelected: true)
        )
        XCTAssertEqual(AppAccessibilitySemantics.openFullHistoryLabel, "Open full history")
        XCTAssertEqual(AppAccessibilitySemantics.openFullSettingsLabel, "Open full settings")
        XCTAssertEqual(AppAccessibilitySemantics.exportCSVLabel, "Export CSV")

        let store = try UsageHistoryStore.inMemory(
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let database = UsageHistoryDatabaseWorker(store: store)
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 39, windowDurationMinutes: 10_080, resetsAt: nil)
        )
        let client = AccessibilityStatusClient(snapshot: snapshot)
        let viewModel = MenuBarStatusViewModel(
            client: client,
            refreshInterval: 3_600,
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )
        let controller = StatusItemController(
            viewModel: viewModel,
            historyDatabase: database,
            updateMonitor: AppUpdateMonitor()
        )
        let button = try XCTUnwrap(controller.statusButtonForTesting)

        await viewModel.start()
        try await waitForStatusButton(button, title: "7d: 61%")
        XCTAssertEqual(button.accessibilityLabel(), "Codex usage 7d: 61%")
        XCTAssertNil(button.accessibilityHelp())

        await viewModel.popoverDidAppear()
        try await waitForStatusButton(button, title: "Offline")
        XCTAssertEqual(button.accessibilityLabel(), "Codex usage Offline")
        XCTAssertTrue(try XCTUnwrap(button.accessibilityHelp()).hasPrefix("Offline"))
        XCTAssertNil(button.toolTip, "Status detail must remain accessibility help, not a visual tooltip")

        viewModel.stop()
    }

    func testMenuBarAppDoesNotTerminateAfterClosingAuxiliaryWindow() async {
        XCTAssertFalse(MenuBarApplicationLifecycle.shouldTerminateAfterLastWindowClosed)
    }

    func testHistoryWindowFrameClampsOffscreenSavedFrame() async {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let restoredFrame = CGRect(x: -320, y: -80, width: 880, height: 640)

        let frame = UsageHistoryWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 700, height: 520),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 880, height: 640))
    }

    func testHistoryWindowFrameFitsVisibleScreenBeforeMinimumSize() async {
        let visibleFrame = CGRect(x: 100, y: 50, width: 640, height: 480)
        let restoredFrame = CGRect(x: 80, y: 20, width: 500, height: 300)

        let frame = UsageHistoryWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 700, height: 520),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
    }

    func testTokenDashboardWindowFrameClampsLikeHistoryWindow() async {
        let visibleFrame = CGRect(x: 100, y: 50, width: 900, height: 620)
        let restoredFrame = CGRect(x: 20, y: -40, width: 1040, height: 700)

        let frame = TokenDashboardWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 780, height: 560),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
    }

    @MainActor
    func testTokenDashboardFitsItsDeclaredMinimumContentSize() throws {
        XCTAssertEqual(
            TokenDashboardLayout.minimumRequiredWidth,
            TokenDashboardLayout.minimumSize.width
        )

        let store = try UsageHistoryStore.inMemory(
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )
        let database = UsageHistoryDatabaseWorker(store: store)
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: TokenDashboardLayout.minimumSize
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(
            rootView: TokenDashboardView(database: database)
        )
        window.setContentSize(TokenDashboardLayout.minimumSize)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(window.contentLayoutRect.size, TokenDashboardLayout.minimumSize)
    }

    func testPerformanceDashboardWindowFrameClampsLikeHistoryWindow() async {
        let visibleFrame = CGRect(x: 100, y: 50, width: 900, height: 620)
        let restoredFrame = CGRect(x: 20, y: -40, width: 1040, height: 700)

        let frame = PerformanceDashboardWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 780, height: 560),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
    }
}

@MainActor
private func waitForStatusButton(
    _ button: NSStatusBarButton,
    title: String,
    timeout: TimeInterval = 1
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while button.title != title, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(button.title, title)
}

@MainActor
private final class AccessibilityStatusClient: CodexRateLimitClientProtocol {
    var onSnapshot: ((CodexUsageSnapshot) -> Void)?
    var onTokenUsage: ((CodexTokenUsageNotification) -> Void)?
    var onTokenUsagePayloadAudit: ((CodexTokenUsagePayloadAudit) -> Void)?
    var onAppServerAuditDiagnosticEvent: ((CodexAppServerAuditDiagnosticEvent) -> Void)?

    private let snapshot: CodexUsageSnapshot

    init(snapshot: CodexRateLimitSnapshot) {
        self.snapshot = .aggregateOnly(displaySnapshot: snapshot)
    }

    func start() async throws -> CodexUsageSnapshot {
        snapshot
    }

    func refresh() async throws -> CodexUsageSnapshot {
        throw AccessibilityStatusError.offline
    }

    func usageDiagnostics() async throws -> CodexUsageDiagnosticsSnapshot {
        throw AccessibilityStatusError.offline
    }

    func stop() {}
}

private enum AccessibilityStatusError: Error {
    case offline
}

@MainActor
private final class AppDelegateRuntimeSpy: CodexUsageApplicationRuntime {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var settingsView: AnyView {
        AnyView(EmptyView())
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private actor UsageHistorySnapshotSpy: UsageHistoryViewModelDatabaseWorking {
    private var count = 0

    func usageHistorySnapshot(for request: UsageHistoryLoadRequest) async throws -> UsageHistoryLoadResult {
        count += 1
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

    func requestCount() -> Int {
        count
    }

    func clearHistory() async throws {}
}
