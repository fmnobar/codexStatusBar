import AppKit
import Foundation
import SwiftUI

@MainActor
protocol CodexRateLimitClientProtocol: AnyObject {
    var onSnapshot: ((CodexRateLimitSnapshot) -> Void)? { get set }

    func start() async throws -> CodexRateLimitSnapshot
    func refresh() async throws -> CodexRateLimitSnapshot
    func stop()
}

@MainActor
final class MenuBarStatusViewModel: ObservableObject {
    @Published private(set) var menuBarPercentText = "--"
    @Published private(set) var fiveHourRow = MenuBarLimitRowPresentation(
        title: "5h limit",
        remainingPercentText: "--% left",
        detailText: "Resets --",
        displayWindow: .fiveHour,
        isSelected: false
    )
    @Published private(set) var sevenDayRow = MenuBarLimitRowPresentation(
        title: "7d limit",
        remainingPercentText: "--% left",
        detailText: "Resets --",
        displayWindow: .sevenDay,
        isSelected: true
    )
    @Published private(set) var tightestRow = MenuBarLimitRowPresentation(
        title: "Tightest",
        remainingPercentText: "--% left",
        detailText: "Resets --",
        displayWindow: .tightest,
        isSelected: false
    )
    @Published private(set) var selectedMenuBarDisplayWindow: MenuBarDisplayWindow
    @Published private(set) var statusItemVisualState: StatusItemVisualState = .normal
    @Published private(set) var footerStatusText: String?
    @Published private(set) var isStaleSnapshot = false
    @Published private(set) var isLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasSnapshot = false
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?

    private let client: CodexRateLimitClientProtocol
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let loadPersistedSelection: () -> MenuBarDisplayWindow
    private let persistSelection: (MenuBarDisplayWindow) -> Void
    private let loadLaunchAtLoginEnabled: () -> Bool
    private let setLaunchAtLoginEnabledAction: (Bool) throws -> Void

    private var snapshot: CodexRateLimitSnapshot?
    private var lastUpdatedAt: Date?
    private var didStart = false
    private var didBootstrapClient = false
    private var isUsingCachedSnapshotAfterFailure = false
    private var refreshInProgress = false
    private var periodicRefreshTask: Task<Void, Never>?
    private var resetRefreshTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    init(
        client: CodexRateLimitClientProtocol,
        now: @escaping () -> Date = Date.init,
        refreshInterval: TimeInterval = 60,
        selectedMenuBarDisplayWindow: MenuBarDisplayWindow = MenuBarDisplayWindowStore.load(),
        loadPersistedSelection: @escaping () -> MenuBarDisplayWindow = { MenuBarDisplayWindowStore.load() },
        persistSelection: @escaping (MenuBarDisplayWindow) -> Void = { MenuBarDisplayWindowStore.save($0) },
        loadLaunchAtLoginEnabled: @escaping () -> Bool = { LaunchAtLoginController.isEnabled },
        setLaunchAtLoginEnabledAction: @escaping (Bool) throws -> Void = { try LaunchAtLoginController.setEnabled($0) }
    ) {
        self.client = client
        self.now = now
        self.refreshInterval = refreshInterval
        self.selectedMenuBarDisplayWindow = selectedMenuBarDisplayWindow
        self.loadPersistedSelection = loadPersistedSelection
        self.persistSelection = persistSelection
        self.loadLaunchAtLoginEnabled = loadLaunchAtLoginEnabled
        self.setLaunchAtLoginEnabledAction = setLaunchAtLoginEnabledAction
        self.launchAtLoginEnabled = loadLaunchAtLoginEnabled()

        client.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.apply(snapshot: snapshot)
            }
        }
    }

    func start() async {
        guard !didStart else {
            return
        }

        didStart = true
        refreshLaunchAtLoginState()
        installDefaultsObserver()
        installTerminationObserver()
        schedulePeriodicRefresh()
        await refresh(showLoading: true)
    }

    func popoverDidAppear() async {
        refreshLaunchAtLoginState()
        await refresh(showLoading: !hasSnapshot)
    }

    func manualRefresh() async {
        await refresh(showLoading: !hasSnapshot)
    }

    func selectMenuBarDisplayWindow(_ displayWindow: MenuBarDisplayWindow) {
        guard selectedMenuBarDisplayWindow != displayWindow else {
            return
        }

        selectedMenuBarDisplayWindow = displayWindow
        persistSelection(displayWindow)
        applyPresentation()
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            try setLaunchAtLoginEnabledAction(isEnabled)
            launchAtLoginEnabled = loadLaunchAtLoginEnabled()
            launchAtLoginError = nil
        } catch {
            launchAtLoginEnabled = loadLaunchAtLoginEnabled()
            launchAtLoginError = "Launch at login could not be updated."
        }
    }

    func stop() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        periodicRefreshTask?.cancel()
        resetRefreshTask?.cancel()
        client.stop()
    }

    private func refresh(showLoading: Bool) async {
        guard !refreshInProgress else {
            return
        }

        refreshInProgress = true
        isRefreshing = true
        defer {
            refreshInProgress = false
            isRefreshing = false
        }

        if showLoading && !hasSnapshot {
            isLoading = true
            errorMessage = nil
        }

        do {
            let latestSnapshot: CodexRateLimitSnapshot

            if didBootstrapClient {
                latestSnapshot = try await client.refresh()
            } else {
                latestSnapshot = try await client.start()
                didBootstrapClient = true
            }

            apply(snapshot: latestSnapshot)
        } catch {
            isLoading = false
            isUsingCachedSnapshotAfterFailure = hasSnapshot

            if !hasSnapshot {
                errorMessage = "Unable to load Codex usage."
            } else {
                errorMessage = nil
            }

            applyPresentation()
        }
    }

    private func apply(snapshot: CodexRateLimitSnapshot) {
        self.snapshot = snapshot
        lastUpdatedAt = now()
        isUsingCachedSnapshotAfterFailure = false
        hasSnapshot = true
        isLoading = false
        errorMessage = nil
        applyPresentation()
        scheduleResetRefresh(for: snapshot)
    }

    private func applyPresentation() {
        let currentNow = now()
        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: currentNow,
            selectedMenuBarDisplayWindow: selectedMenuBarDisplayWindow
        )
        menuBarPercentText = presentation.menuBarPercentText
        fiveHourRow = presentation.fiveHourRow
        sevenDayRow = presentation.sevenDayRow
        tightestRow = presentation.tightestRow
        isStaleSnapshot = hasSnapshot && (
            isUsingCachedSnapshotAfterFailure || isPastStaleThreshold(at: currentNow)
        )
        footerStatusText = MenuBarStatusFormatter.freshnessText(
            lastUpdatedAt: lastUpdatedAt,
            now: currentNow,
            isOffline: isUsingCachedSnapshotAfterFailure
        )
        statusItemVisualState = if !hasSnapshot && errorMessage != nil {
            .error
        } else if isStaleSnapshot {
            .stale
        } else {
            .normal
        }
    }

    private func schedulePeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let sleepDuration = UInt64(refreshInterval * 1_000_000_000)

                do {
                    try await Task.sleep(nanoseconds: sleepDuration)
                } catch {
                    return
                }

                await self.refresh(showLoading: false)
            }
        }
    }

    private func scheduleResetRefresh(for snapshot: CodexRateLimitSnapshot) {
        resetRefreshTask?.cancel()

        let refreshDate = [snapshot.primary?.resetsAt, snapshot.secondary?.resetsAt]
            .compactMap { $0 }
            .filter { $0 > now() }
            .min()
            .map { $0.addingTimeInterval(5) }

        guard let refreshDate else {
            return
        }

        let interval = refreshDate.timeIntervalSince(now())
        guard interval > 0 else {
            return
        }

        resetRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }

            await self?.refresh(showLoading: false)
        }
    }

    private func installTerminationObserver() {
        guard terminationObserver == nil else {
            return
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    private func installDefaultsObserver() {
        guard defaultsObserver == nil else {
            return
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncSelectionFromDefaults()
            }
        }
    }

    private func syncSelectionFromDefaults() {
        let persistedSelection = loadPersistedSelection()
        guard persistedSelection != selectedMenuBarDisplayWindow else {
            return
        }

        selectedMenuBarDisplayWindow = persistedSelection
        applyPresentation()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = loadLaunchAtLoginEnabled()
        launchAtLoginError = nil
    }

    private func isPastStaleThreshold(at now: Date) -> Bool {
        guard let lastUpdatedAt else {
            return false
        }

        return now.timeIntervalSince(lastUpdatedAt) > (refreshInterval * 2)
    }
}
