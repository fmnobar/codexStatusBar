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
    @Published private(set) var fiveHourLine = "5h limit: --% left (resets --)"
    @Published private(set) var sevenDayLine = "7d limit: --% left (resets --)"
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasSnapshot = false

    private let client: CodexRateLimitClientProtocol
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let staleAfter: TimeInterval

    private var snapshot: CodexRateLimitSnapshot?
    private var didStart = false
    private var didBootstrapClient = false
    private var refreshInProgress = false
    private var periodicRefreshTask: Task<Void, Never>?
    private var resetRefreshTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    private(set) var lastRefreshAt: Date?

    init(
        client: CodexRateLimitClientProtocol,
        now: @escaping () -> Date = Date.init,
        refreshInterval: TimeInterval = 60,
        staleAfter: TimeInterval = 30
    ) {
        self.client = client
        self.now = now
        self.refreshInterval = refreshInterval
        self.staleAfter = staleAfter

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
        installTerminationObserver()
        schedulePeriodicRefresh()
        await refresh(showLoading: true)
    }

    func popoverDidAppear() async {
        let shouldRefresh = RefreshPolicy.shouldRefreshOnPopover(
            lastRefreshAt: lastRefreshAt,
            now: now(),
            staleAfter: staleAfter
        )

        if shouldRefresh {
            await refresh(showLoading: !hasSnapshot)
        }
    }

    func retry() async {
        await refresh(showLoading: true)
    }

    func stop() {
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
        defer { refreshInProgress = false }

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

            if !hasSnapshot {
                errorMessage = "Unable to load Codex usage."
                applyPresentation()
            }
        }
    }

    private func apply(snapshot: CodexRateLimitSnapshot) {
        self.snapshot = snapshot
        hasSnapshot = true
        isLoading = false
        errorMessage = nil
        lastRefreshAt = now()
        applyPresentation()
        scheduleResetRefresh(for: snapshot)
    }

    private func applyPresentation() {
        let presentation = MenuBarStatusFormatter.presentation(snapshot: snapshot, now: now())
        menuBarPercentText = presentation.menuBarPercentText
        fiveHourLine = presentation.fiveHourLine
        sevenDayLine = presentation.sevenDayLine
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
}
