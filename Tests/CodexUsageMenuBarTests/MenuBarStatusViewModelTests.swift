import XCTest
@testable import CodexUsageCore

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

    func testPrimaryOnlySevenDayDrivesViewModelEvenWhenFiveHourWasSelected() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 43, windowDurationMinutes: 10_080, resetsAt: nil),
            secondary: nil
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            selectedMenuBarDisplayWindow: .fiveHour,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.selectedMenuBarDisplayWindow, .fiveHour)
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 57%")
        XCTAssertEqual(viewModel.fiveHourRow.remainingPercentText, "--% left")
        XCTAssertFalse(viewModel.fiveHourRow.isSelected)
        XCTAssertEqual(viewModel.sevenDayRow.remainingPercentText, "57% left")
        XCTAssertTrue(viewModel.sevenDayRow.isSelected)
        XCTAssertEqual(viewModel.tightestRow.title, "Tightest: 7d")

        viewModel.stop()
    }

    func testFiveHourOnlyDrivesViewModelEvenWhenSevenDayWasSelected() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: nil,
            secondary: CodexRateLimitWindow(usedPercent: 6, windowDurationMinutes: 300, resetsAt: nil)
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

        XCTAssertEqual(viewModel.selectedMenuBarDisplayWindow, .sevenDay)
        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 94%")
        XCTAssertEqual(viewModel.fiveHourRow.remainingPercentText, "94% left")
        XCTAssertTrue(viewModel.fiveHourRow.isSelected)
        XCTAssertEqual(viewModel.sevenDayRow.remainingPercentText, "--% left")
        XCTAssertFalse(viewModel.sevenDayRow.isSelected)
        XCTAssertEqual(viewModel.tightestRow.title, "Tightest: 5h")

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
            selectedMenuBarDisplayWindow: .sevenDay,
            persistSelection: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "Offline")
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
            selectedMenuBarDisplayWindow: .sevenDay,
            menuBarDisplayOptions: persistedOptions.options,
            persistSelection: { _ in },
            loadMenuBarDisplayOptions: { persistedOptions.options },
            persistMenuBarDisplayOptions: { persistedOptions.options = $0 },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 39%")

        viewModel.setMenuBarShowsResetDate(true)
        viewModel.setMenuBarShowsResetTime(true)

        XCTAssertEqual(persistedOptions.options.showsResetDate, true)
        XCTAssertEqual(persistedOptions.options.showsResetTime, true)
        XCTAssertTrue(viewModel.menuBarPercentText.contains("4/28"))
        XCTAssertTrue(viewModel.menuBarPercentText.contains("PM"))

        viewModel.setMenuBarShowsLimitLabel(false)

        XCTAssertFalse(persistedOptions.options.showsLimitLabel)
        XCTAssertFalse(viewModel.menuBarPercentText.contains("7d:"))

        viewModel.stop()
    }

    func testMenuBarTokenOptionAppendsLocalCapturedTokenTotalAndPersists() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let persistedOptions = MenuBarDisplayOptionsBox(options: .defaultValue)
        let tokenRecorder = MockTokenUsageRecorder(
            todayTotals: TokenCategoryTotals(
                inputTokens: 3_125_000,
                cachedInputTokens: 1_400_000,
                outputTokens: 240_400,
                reasoningOutputTokens: 18_400,
                totalTokens: 4_783_800
            )
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: MockProfileTokenUsageClient(result: .failure(MockClientError.sample)),
            selectedMenuBarDisplayWindow: .sevenDay,
            menuBarDisplayOptions: persistedOptions.options,
            persistSelection: { _ in },
            loadMenuBarDisplayOptions: { persistedOptions.options },
            persistMenuBarDisplayOptions: { persistedOptions.options = $0 },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 39%")

        viewModel.setMenuBarShowsTokens(true)
        await waitUntil {
            viewModel.menuBarPercentText == "7d: 39% · 4.8M"
        }

        XCTAssertTrue(persistedOptions.options.showsTokens)
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 39% · 4.8M")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Current local day captured tokens: input 3.1M tok, cached input 1.4M tok, output 240k tok, reasoning 18k tok, total 4.8M tok."
        )

        viewModel.stop()
    }

    func testMenuBarTokenOptionLoadsLocalCapturedTokensOnStartupWhenAlreadyEnabled() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let tokenRecorder = MockTokenUsageRecorder(
            todayTotals: TokenCategoryTotals(
                inputTokens: 3_125_000,
                cachedInputTokens: 1_400_000,
                outputTokens: 240_400,
                reasoningOutputTokens: 18_400,
                totalTokens: 4_783_800
            )
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: MockProfileTokenUsageClient(result: .failure(MockClientError.sample)),
            selectedMenuBarDisplayWindow: .sevenDay,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 39% · 4.8M")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Current local day captured tokens: input 3.1M tok, cached input 1.4M tok, output 240k tok, reasoning 18k tok, total 4.8M tok."
        )

        viewModel.stop()
    }

    func testMenuBarTokenOptionPrefersAccountDailyTokensOverLocalWindowZero() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-29T00:37:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let tokenRecorder = MockTokenUsageRecorder(todayTotals: .zero)
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789),
                    ]
                )
            )
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { now },
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 123M")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Codex account tokens for 2026-06-29: 123M tok. Fetched just now."
        )
        XCTAssertEqual(profileClient.fetchCallCount, 1)
        let periodRequests = await tokenRecorder.periodRequestsSnapshot()
        XCTAssertTrue(periodRequests.isEmpty)

        viewModel.stop()
    }

    func testMenuBarTokenOptionLabelsLocalDayBucketAsFallbackAfterUTCDayRollsOver() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-29T03:30:20Z")!
        var pacificCalendar = Calendar(identifier: .gregorian)
        pacificCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 52, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let tokenRecorder = MockTokenUsageRecorder(todayTotals: .zero)
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-06-28", tokens: 278_611_893),
                    ]
                )
            )
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { now },
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: profileClient,
            menuBarTokenCalendar: pacificCalendar,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 48% · 279M")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Latest available Codex account tokens are for 2026-06-28: 279M tok. Fetched just now."
        )
        XCTAssertEqual(profileClient.fetchCallCount, 1)
        let periodRequests = await tokenRecorder.periodRequestsSnapshot()
        XCTAssertTrue(periodRequests.isEmpty)

        viewModel.stop()
    }

    func testSelectingDifferentMenuBarWindowKeepsCachedTokenDisplay() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-29T00:37:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789),
                    ]
                )
            )
        )

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { now },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .sevenDay,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 39% · 123M")

        viewModel.selectMenuBarDisplayWindow(.fiveHour)

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 123M")
        XCTAssertEqual(profileClient.fetchCallCount, 1)

        viewModel.stop()
    }

    func testMenuBarAccountTokensRefreshAfterFiveMinuteCacheInterval() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!)
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(
            startResponses: [.success(rateLimitSnapshot)],
            refreshResponses: [.success(rateLimitSnapshot), .success(rateLimitSnapshot)]
        )
        let profileClient = MockProfileTokenUsageClient(
            results: [
                .success(
                    CodexProfileTokenUsageSnapshot(
                        fetchedAt: currentTime.date,
                        lifetimeTokens: nil,
                        peakDailyTokens: nil,
                        dailyBuckets: [
                            CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789),
                        ]
                    )
                ),
                .success(
                    CodexProfileTokenUsageSnapshot(
                        fetchedAt: currentTime.date.addingTimeInterval(301),
                        lifetimeTokens: nil,
                        peakDailyTokens: nil,
                        dailyBuckets: [
                            CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 234_567_890),
                        ]
                    )
                ),
            ]
        )
        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { currentTime.date },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 123M")
        XCTAssertEqual(profileClient.fetchCallCount, 1)

        currentTime.date = currentTime.date.addingTimeInterval(299)
        await viewModel.popoverDidAppear()
        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 123M")
        XCTAssertEqual(profileClient.fetchCallCount, 1)

        currentTime.date = currentTime.date.addingTimeInterval(2)
        await viewModel.popoverDidAppear()
        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 235M")
        XCTAssertEqual(profileClient.fetchCallCount, 2)
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Codex account tokens for 2026-06-29: 235M tok. Fetched just now."
        )

        viewModel.stop()
    }

    func testManualRefreshBypassesAccountTokenCache() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!)
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let profileClient = MockProfileTokenUsageClient(
            results: [
                .success(
                    CodexProfileTokenUsageSnapshot(
                        fetchedAt: currentTime.date,
                        lifetimeTokens: nil,
                        peakDailyTokens: nil,
                        dailyBuckets: [CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789)]
                    )
                ),
                .success(
                    CodexProfileTokenUsageSnapshot(
                        fetchedAt: currentTime.date.addingTimeInterval(60),
                        lifetimeTokens: nil,
                        peakDailyTokens: nil,
                        dailyBuckets: [CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 234_567_890)]
                    )
                ),
            ]
        )
        let viewModel = MenuBarStatusViewModel(
            client: MockCodexRateLimitClient(
                startResponses: [.success(rateLimitSnapshot)],
                refreshResponses: [.success(rateLimitSnapshot)]
            ),
            now: { currentTime.date },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        currentTime.date = currentTime.date.addingTimeInterval(60)
        await viewModel.manualRefresh()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 235M")
        XCTAssertEqual(profileClient.fetchCallCount, 2)

        viewModel.stop()
    }

    func testFreshAccountSnapshotWithoutUsableBucketRespectsFiveMinuteCache() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!)
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: currentTime.date,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: []
                )
            )
        )
        let viewModel = MenuBarStatusViewModel(
            client: MockCodexRateLimitClient(
                startResponses: [.success(rateLimitSnapshot)],
                refreshResponses: [.success(rateLimitSnapshot)]
            ),
            now: { currentTime.date },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        currentTime.date = currentTime.date.addingTimeInterval(60)
        await viewModel.popoverDidAppear()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · --")
        XCTAssertEqual(profileClient.fetchCallCount, 1)

        viewModel.stop()
    }

    func testConcurrentTokenLoadsCoalesceAccountFetchAndNewestLoadWins() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let profileClient = SuspendedProfileTokenUsageClient()
        let viewModel = MenuBarStatusViewModel(
            client: MockCodexRateLimitClient(snapshot: rateLimitSnapshot),
            now: { now },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: false
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        viewModel.setMenuBarShowsTokens(true)
        await waitUntil { profileClient.fetchCallCount == 1 }
        viewModel.setMenuBarShowsTokens(false)
        viewModel.setMenuBarShowsTokens(true)
        await Task.yield()

        XCTAssertEqual(profileClient.fetchCallCount, 1)
        profileClient.complete(
            with: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789)]
                )
            )
        )
        await waitUntil { viewModel.menuBarPercentText == "5h: 84% · 123M" }

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 123M")
        XCTAssertEqual(profileClient.fetchCallCount, 1)

        viewModel.stop()
    }

    func testLocalTokensAppearWhileAccountRefreshIsSuspended() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let tokenRecorder = MockTokenUsageRecorder(
            todayTotals: TokenCategoryTotals(
                inputTokens: 700,
                cachedInputTokens: 100,
                outputTokens: 200,
                reasoningOutputTokens: 25,
                totalTokens: 1_025
            )
        )
        let profileClient = SuspendedProfileTokenUsageClient()
        let viewModel = MenuBarStatusViewModel(
            client: MockCodexRateLimitClient(snapshot: rateLimitSnapshot),
            now: { now },
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        let startTask = Task { @MainActor in
            await viewModel.start()
        }
        await waitUntil { profileClient.fetchCallCount == 1 }

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 1k")
        XCTAssertTrue(viewModel.menuBarToolTipText?.hasPrefix("Current local day captured tokens:") == true)

        profileClient.complete(
            with: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789)]
                )
            )
        )
        await startTask.value

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 123M")
        XCTAssertEqual(profileClient.fetchCallCount, 1)

        viewModel.stop()
    }

    func testExpiredAccountRefreshFailureUsesLocalCapturedTokensWhenAvailable() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!)
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(
            startResponses: [.success(rateLimitSnapshot)],
            refreshResponses: [.success(rateLimitSnapshot)]
        )
        let tokenRecorder = MockTokenUsageRecorder(
            todayTotals: TokenCategoryTotals(
                inputTokens: 700,
                cachedInputTokens: 100,
                outputTokens: 200,
                reasoningOutputTokens: 25,
                totalTokens: 1_025
            )
        )
        let profileClient = MockProfileTokenUsageClient(
            results: [
                .success(
                    CodexProfileTokenUsageSnapshot(
                        fetchedAt: currentTime.date,
                        lifetimeTokens: nil,
                        peakDailyTokens: nil,
                        dailyBuckets: [
                            CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789),
                        ]
                    )
                ),
                .failure(MockClientError.sample),
            ]
        )
        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { currentTime.date },
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        currentTime.date = currentTime.date.addingTimeInterval(301)
        await viewModel.manualRefresh()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 1k")
        XCTAssertTrue(viewModel.menuBarToolTipText?.hasPrefix("Current local day captured tokens:") == true)
        XCTAssertEqual(profileClient.fetchCallCount, 2)

        viewModel.stop()
    }

    func testExpiredAccountRefreshFailureLabelsCachedFallback() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!)
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(
            startResponses: [.success(rateLimitSnapshot)],
            refreshResponses: [.success(rateLimitSnapshot)]
        )
        let profileClient = MockProfileTokenUsageClient(
            results: [
                .success(
                    CodexProfileTokenUsageSnapshot(
                        fetchedAt: currentTime.date,
                        lifetimeTokens: nil,
                        peakDailyTokens: nil,
                        dailyBuckets: [
                            CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789),
                        ]
                    )
                ),
                .failure(MockClientError.sample),
            ]
        )
        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { currentTime.date },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        currentTime.date = currentTime.date.addingTimeInterval(301)
        await viewModel.manualRefresh()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 123M")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Codex account tokens for 2026-06-29: 123M tok. Refresh failed; showing account data fetched 5m ago."
        )
        XCTAssertEqual(profileClient.fetchCallCount, 2)

        viewModel.stop()
    }

    func testPriorDayAccountFallbackIsExplicitlyLabeled() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-06-28", tokens: 278_611_893),
                    ]
                )
            )
        )
        let viewModel = MenuBarStatusViewModel(
            client: MockCodexRateLimitClient(snapshot: rateLimitSnapshot),
            now: { now },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 279M")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Latest available Codex account tokens are for 2026-06-28: 279M tok. Fetched just now."
        )

        viewModel.stop()
    }

    func testPriorDayAccountFallbackRemainsAvailableThroughFollowingUTCDay() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-29T23:30:00Z")!
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-06-28", tokens: 278_611_893),
                    ]
                )
            )
        )
        let viewModel = MenuBarStatusViewModel(
            client: MockCodexRateLimitClient(snapshot: rateLimitSnapshot),
            now: { now },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 279M")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Latest available Codex account tokens are for 2026-06-28: 279M tok. Fetched just now."
        )

        viewModel.stop()
    }

    func testAccountFallbackRejectsBucketOlderThanPreviousUTCDay() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-30T00:01:00Z")!
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-06-28", tokens: 278_611_893),
                    ]
                )
            )
        )
        let viewModel = MenuBarStatusViewModel(
            client: MockCodexRateLimitClient(snapshot: rateLimitSnapshot),
            now: { now },
            refreshInterval: 3_600,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · --")
        XCTAssertEqual(viewModel.menuBarToolTipText, "No token usage data is available for the menu bar.")

        viewModel.stop()
    }

    func testLocalTokenNotificationKeepsFreshAccountSourceUntilRefreshIsDue() async {
        let now = ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: rateLimitSnapshot)
        let tokenRecorder = MockTokenUsageRecorder(todayTotals: nil)
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: now,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789),
                    ]
                )
            )
        )
        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: { now },
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        client.onTokenUsage?(
            Self.tokenNotification(
                lastInput: 900,
                lastCached: 100,
                lastOutput: 250,
                lastReasoning: 50,
                lastTotal: 1_200,
                totalInput: 900,
                totalCached: 100,
                totalOutput: 250,
                totalReasoning: 50,
                totalTotal: 1_200
            )
        )
        await waitUntil { await tokenRecorder.recordCount == 1 }

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 123M")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "Codex account tokens for 2026-06-29: 123M tok. Fetched just now."
        )
        XCTAssertEqual(profileClient.fetchCallCount, 1)

        viewModel.stop()
    }

    func testLiveCaptureRefreshUsesLocalTokensWithoutAccountNetworkCallWhenCacheExpires() async {
        let currentTime = MutableNow(date: ISO8601DateFormatter().date(from: "2026-06-29T12:00:00Z")!)
        let rateLimitSnapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let tokenRecorder = MockTokenUsageRecorder(
            todayTotals: TokenCategoryTotals(
                inputTokens: 700,
                cachedInputTokens: 100,
                outputTokens: 200,
                reasoningOutputTokens: 25,
                totalTokens: 1_025
            )
        )
        let profileClient = MockProfileTokenUsageClient(
            result: .success(
                CodexProfileTokenUsageSnapshot(
                    fetchedAt: currentTime.date,
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    dailyBuckets: [
                        CodexProfileTokenDailyBucket(date: "2026-06-29", tokens: 123_456_789),
                    ]
                )
            )
        )
        let viewModel = MenuBarStatusViewModel(
            client: MockCodexRateLimitClient(snapshot: rateLimitSnapshot),
            now: { currentTime.date },
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: profileClient,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        currentTime.date = currentTime.date.addingTimeInterval(301)
        viewModel.refreshMenuBarTokenDisplayIfDisplayed()
        await waitUntil { viewModel.menuBarPercentText == "5h: 84% · 1k" }

        XCTAssertEqual(viewModel.menuBarPercentText, "5h: 84% · 1k")
        XCTAssertTrue(viewModel.menuBarToolTipText?.hasPrefix("Current local day captured tokens:") == true)
        XCTAssertEqual(profileClient.fetchCallCount, 1)

        viewModel.stop()
    }

    func testMenuBarTokenOptionShowsPlaceholderWithoutTokenData() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            selectedMenuBarDisplayWindow: .sevenDay,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 39% · --")

        viewModel.stop()
    }

    func testMenuBarTokenOptionShowsPlaceholderWhenLocalTotalsAreEmptyAndAccountUnavailable() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let tokenRecorder = MockTokenUsageRecorder(todayTotals: .zero)

        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            accountTokenUsageClient: MockProfileTokenUsageClient(result: .failure(MockClientError.sample)),
            selectedMenuBarDisplayWindow: .sevenDay,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 39% · --")
        XCTAssertEqual(
            viewModel.menuBarToolTipText,
            "No token usage data is available for the menu bar."
        )

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
        XCTAssertEqual(viewModel.menuBarPercentText, "Offline")

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
        XCTAssertEqual(viewModel.menuBarPercentText, "Offline")
        XCTAssertEqual(viewModel.footerStatusText, "Offline")

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
            selectedMenuBarDisplayWindow: .sevenDay,
            menuBarDisplayOptions: persistedOptions.options,
            persistSelection: { _ in },
            loadMenuBarDisplayOptions: { persistedOptions.options },
            persistMenuBarDisplayOptions: { persistedOptions.options = $0 },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 39%")

        persistedOptions.options = MenuBarDisplayOptions(
            showsLimitLabel: true,
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
        await waitUntil {
            await historyRecorder.recordCount == 2
        }
        let records = await historyRecorder.recordsSnapshot()

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].snapshot.displaySnapshot.secondary?.usedPercent, 20)
        XCTAssertEqual(records[1].date, currentTime.date)

        viewModel.stop()
    }

    func testTokenUsageNotificationUpdatesMenuBarWithoutRefreshingRateLimits() async {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 20, windowDurationMinutes: 10080, resetsAt: nil)
        )
        let client = MockCodexRateLimitClient(snapshot: snapshot)
        let tokenRecorder = MockTokenUsageRecorder(todayTotals: nil)
        let viewModel = MenuBarStatusViewModel(
            client: client,
            now: Date.init,
            refreshInterval: 3_600,
            tokenUsageRecorder: tokenRecorder,
            selectedMenuBarDisplayWindow: .sevenDay,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: false,
                showsResetTime: false,
                showsTokens: true
            ),
            persistSelection: { _ in },
            persistMenuBarDisplayOptions: { _ in },
            loadLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabledAction: { _ in }
        )

        await viewModel.start()
        XCTAssertEqual(client.refreshCallCount, 0)

        client.onTokenUsage?(
            Self.tokenNotification(
                lastInput: 900,
                lastCached: 100,
                lastOutput: 250,
                lastReasoning: 50,
                lastTotal: 1_200,
                totalInput: 900,
                totalCached: 100,
                totalOutput: 250,
                totalReasoning: 50,
                totalTotal: 1_200
            )
        )
        await waitUntil {
            await tokenRecorder.recordCount == 1 && viewModel.menuBarPercentText == "7d: 80% · 1.3k"
        }
        let records = await tokenRecorder.recordsSnapshot()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(client.refreshCallCount, 0)
        XCTAssertEqual(viewModel.menuBarPercentText, "7d: 80% · 1.3k")

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

    private static func tokenNotification(
        lastInput: Int64 = 0,
        lastCached: Int64 = 0,
        lastOutput: Int64 = 0,
        lastReasoning: Int64 = 0,
        lastTotal: Int64,
        totalInput: Int64 = 0,
        totalCached: Int64 = 0,
        totalOutput: Int64 = 0,
        totalReasoning: Int64 = 0,
        totalTotal: Int64
    ) -> CodexTokenUsageNotification {
        CodexTokenUsageNotification(
            threadID: "thread-a",
            turnID: "turn-a",
            model: nil,
            tokenUsage: CodexThreadTokenUsage(
                last: CodexTokenUsageBreakdown(
                    inputTokens: lastInput,
                    cachedInputTokens: lastCached,
                    outputTokens: lastOutput,
                    reasoningOutputTokens: lastReasoning,
                    totalTokens: lastTotal
                ),
                total: CodexTokenUsageBreakdown(
                    inputTokens: totalInput,
                    cachedInputTokens: totalCached,
                    outputTokens: totalOutput,
                    reasoningOutputTokens: totalReasoning,
                    totalTokens: totalTotal
                ),
                modelContextWindow: nil
            )
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class MockCodexRateLimitClient: CodexRateLimitClientProtocol {
    var onSnapshot: ((CodexUsageSnapshot) -> Void)?
    var onTokenUsage: ((CodexTokenUsageNotification) -> Void)?
    var onTokenUsagePayloadAudit: ((CodexTokenUsagePayloadAudit) -> Void)?
    var onAppServerAuditDiagnosticEvent: ((CodexAppServerAuditDiagnosticEvent) -> Void)?

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

private actor MockUsageHistoryRecorder: UsageHistoryRecording {
    private var records: [(snapshot: CodexUsageSnapshot, date: Date)] = []

    func record(snapshot: CodexUsageSnapshot, at date: Date) async {
        records.append((snapshot, date))
    }

    var recordCount: Int {
        records.count
    }

    func recordsSnapshot() -> [(snapshot: CodexUsageSnapshot, date: Date)] {
        records
    }
}

private actor MockTokenUsageRecorder: TokenUsageRecording {
    private var records: [(tokenUsage: CodexTokenUsageNotification, date: Date)] = []
    private var todayTotals: TokenCategoryTotals?
    private var todayTotalsRequestTimeZoneOffsets: [Int?] = []
    private var periodRequests: [(start: Date, end: Date)] = []

    init(todayTotals: TokenCategoryTotals?) {
        self.todayTotals = todayTotals
    }

    func record(tokenUsage: CodexTokenUsageNotification, at date: Date) async -> TokenCategoryTotals? {
        let componentTotal = tokenUsage.tokenUsage.last.inputTokens
            + tokenUsage.tokenUsage.last.cachedInputTokens
            + tokenUsage.tokenUsage.last.outputTokens
            + tokenUsage.tokenUsage.last.reasoningOutputTokens
        let totals = TokenCategoryTotals(
            inputTokens: tokenUsage.tokenUsage.last.inputTokens,
            cachedInputTokens: tokenUsage.tokenUsage.last.cachedInputTokens,
            outputTokens: tokenUsage.tokenUsage.last.outputTokens,
            reasoningOutputTokens: tokenUsage.tokenUsage.last.reasoningOutputTokens,
            totalTokens: componentTotal
        )
        records.append((tokenUsage, date))
        todayTotals = totals
        return totals
    }

    func tokenCategoryTotals(periodStart: Date, periodEnd: Date) async -> TokenCategoryTotals? {
        periodRequests.append((periodStart, periodEnd))
        return todayTotals
    }

    func todayTokenCategoryTotals(at date: Date, calendar: Calendar) async -> TokenCategoryTotals? {
        todayTotalsRequestTimeZoneOffsets.append(calendar.timeZone.secondsFromGMT(for: date))
        return todayTotals
    }

    func todayTotalTokens(at date: Date, calendar: Calendar) async -> Int64? {
        return todayTotals?.totalTokens
    }

    var recordCount: Int {
        records.count
    }

    func recordsSnapshot() -> [(tokenUsage: CodexTokenUsageNotification, date: Date)] {
        records
    }

    func todayTotalsRequestTimeZoneOffsetsSnapshot() -> [Int?] {
        todayTotalsRequestTimeZoneOffsets
    }

    func periodRequestsSnapshot() -> [(start: Date, end: Date)] {
        periodRequests
    }
}

private final class MockProfileTokenUsageClient: CodexProfileTokenUsageFetching {
    private var results: [Result<CodexProfileTokenUsageSnapshot, Error>]
    private(set) var fetchCallCount = 0

    init(result: Result<CodexProfileTokenUsageSnapshot, Error>) {
        results = [result]
    }

    init(results: [Result<CodexProfileTokenUsageSnapshot, Error>]) {
        self.results = results
    }

    func profileTokenUsageSnapshot() async throws -> CodexProfileTokenUsageSnapshot {
        fetchCallCount += 1
        guard !results.isEmpty else {
            throw MockClientError.sample
        }

        if results.count == 1 {
            return try results[0].get()
        }

        return try results.removeFirst().get()
    }
}

private final class SuspendedProfileTokenUsageClient: CodexProfileTokenUsageFetching {
    private var continuation: CheckedContinuation<CodexProfileTokenUsageSnapshot, Error>?
    private(set) var fetchCallCount = 0

    func profileTokenUsageSnapshot() async throws -> CodexProfileTokenUsageSnapshot {
        fetchCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(with result: Result<CodexProfileTokenUsageSnapshot, Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

private enum MockClientError: Error {
    case sample
}
