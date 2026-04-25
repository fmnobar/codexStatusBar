import XCTest

final class MenuBarStatusFormatterTests: XCTestCase {
    func testMenuBarDisplayWindowStoreDefaultsToTightest() {
        let suiteName = "MenuBarStatusFormatterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(MenuBarDisplayWindowStore.load(from: defaults), .tightest)
    }

    func testMenuBarDisplayOptionsStoreDefaultsToLimitOnly() {
        let suiteName = "MenuBarStatusFormatterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(MenuBarDisplayOptionsStore.load(from: defaults), .defaultValue)
    }

    func testMenuBarDisplayOptionsStorePersistsSelection() {
        let suiteName = "MenuBarStatusFormatterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let options = MenuBarDisplayOptions(
            showsLimitLabel: false,
            showsResetDate: true,
            showsResetTime: true
        )

        MenuBarDisplayOptionsStore.save(options, to: defaults)

        XCTAssertEqual(MenuBarDisplayOptionsStore.load(from: defaults), options)
    }

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(CodexRateLimitWindow.clampedRemainingPercent(from: 2), 98)
        XCTAssertEqual(CodexRateLimitWindow.clampedRemainingPercent(from: -5), 100)
        XCTAssertEqual(CodexRateLimitWindow.clampedRemainingPercent(from: 150), 0)
    }

    func testResetFormattingUsesTimeOnlyForSameDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = ISO8601DateFormatter().date(from: "2026-04-07T16:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-07T21:20:00Z")!

        let formatted = MenuBarStatusFormatter.resetText(
            for: resetDate,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertFalse(formatted.contains("Apr"))
    }

    func testResetFormattingUsesMonthDayForDifferentDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = ISO8601DateFormatter().date(from: "2026-04-07T16:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-14T21:20:00Z")!

        let formatted = MenuBarStatusFormatter.resetText(
            for: resetDate,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertTrue(formatted.contains("Apr"))
        XCTAssertTrue(formatted.contains("14"))
    }

    func testPresentationUsesPlaceholderWhenSevenDayWindowIsMissing() {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 6, windowDurationMinutes: 300, resetsAt: nil),
            secondary: nil
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 0),
            selectedMenuBarDisplayWindow: .sevenDay,
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "--")
        XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "--% left")
        XCTAssertEqual(presentation.sevenDayRow.detailText, "Resets --")
    }

    func testPresentationKeepsSevenDayLineWhenFiveHourWindowIsMissing() {
        let snapshot = CodexRateLimitSnapshot(
            primary: nil,
            secondary: CodexRateLimitWindow(usedPercent: 2, windowDurationMinutes: 10080, resetsAt: nil)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 0),
            selectedMenuBarDisplayWindow: .sevenDay,
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "7d: 98%")
        XCTAssertEqual(presentation.fiveHourRow.remainingPercentText, "--% left")
        XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "98% left")
    }

    func testTightestRowShowsActiveLimitSource() {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 81, windowDurationMinutes: 10080, resetsAt: nil)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 0),
            selectedMenuBarDisplayWindow: .tightest,
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "7d: 19%")
        XCTAssertEqual(presentation.tightestRow.title, "Tightest: 7d")
        XCTAssertEqual(presentation.tightestRow.remainingPercentText, "")
        XCTAssertEqual(presentation.tightestRow.detailText, "")
        XCTAssertTrue(presentation.tightestRow.isSelected)
    }

    func testMenuBarSelectionCanUseFiveHourWindow() {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 5, windowDurationMinutes: 10080, resetsAt: nil)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 0),
            selectedMenuBarDisplayWindow: .fiveHour,
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "5h: 84%")
    }

    func testTightestSelectionUsesLowerRemainingPercent() {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 16, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 5, windowDurationMinutes: 10080, resetsAt: nil)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 0),
            selectedMenuBarDisplayWindow: .tightest,
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "5h: 84%")
    }

    func testMenuBarTextCanShowResetDateAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-04-25T16:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-28T19:58:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 37, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: resetDate)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: now,
            selectedMenuBarDisplayWindow: .tightest,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: true,
                showsResetDate: true,
                showsResetTime: true
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "7d: 39% 4/28 7:58PM")
    }

    func testMenuBarTextCanHideLimitLabelAndShowResetTimeOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-04-25T16:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-25T19:58:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 37, windowDurationMinutes: 300, resetsAt: resetDate),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: nil)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: now,
            selectedMenuBarDisplayWindow: .fiveHour,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsLimitLabel: false,
                showsResetDate: false,
                showsResetTime: true
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "63% 7:58PM")
    }

    func testCrossDayResetFormattingOmitsAt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = ISO8601DateFormatter().date(from: "2026-04-07T16:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-14T21:20:00Z")!

        let formatted = MenuBarStatusFormatter.resetText(
            for: resetDate,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertTrue(formatted.contains("Apr 14"))
        XCTAssertTrue(formatted.contains("9:20"))
        XCTAssertTrue(formatted.contains("PM"))
        XCTAssertFalse(formatted.contains(" at "))
    }

    func testFreshnessTextCanDescribeOfflineCachedSnapshot() {
        let now = ISO8601DateFormatter().date(from: "2026-04-14T20:00:00Z")!
        let updatedAt = ISO8601DateFormatter().date(from: "2026-04-14T19:57:00Z")!

        let freshnessText = MenuBarStatusFormatter.freshnessText(
            lastUpdatedAt: updatedAt,
            now: now,
            isOffline: true
        )

        XCTAssertEqual(freshnessText, "Offline, showing last update from 3m ago")
    }
}

@MainActor
final class AppVersionInfoTests: XCTestCase {
    func testVersionInfoReadsBundleValues() {
        let bundleURL = URL(fileURLWithPath: "/Applications/CodexStatusBar.app")
        let versionInfo = AppVersionInfo(
            infoDictionary: [
                "CFBundleDisplayName": "Codex Status Bar",
                "CFBundleName": "CodexStatusBar",
                "CFBundleShortVersionString": "1.2",
                "CFBundleVersion": "45",
                "CFBundleIdentifier": "com.example.fallback",
            ],
            bundleIdentifier: "com.example.codexstatusbar",
            bundleURL: bundleURL
        )

        XCTAssertEqual(versionInfo.appName, "Codex Status Bar")
        XCTAssertEqual(versionInfo.version, "1.2")
        XCTAssertEqual(versionInfo.build, "45")
        XCTAssertEqual(versionInfo.bundleIdentifier, "com.example.codexstatusbar")
        XCTAssertEqual(versionInfo.bundleURL, bundleURL)
        XCTAssertEqual(versionInfo.versionBuildText, "Version 1.2 (45)")
    }

    func testVersionInfoFallsBackToUnknownValues() {
        let versionInfo = AppVersionInfo(
            infoDictionary: [
                "CFBundleDisplayName": " ",
                "CFBundleName": "",
            ],
            bundleIdentifier: nil,
            bundleURL: nil
        )

        XCTAssertEqual(versionInfo.appName, "Unknown")
        XCTAssertEqual(versionInfo.version, "Unknown")
        XCTAssertEqual(versionInfo.build, "Unknown")
        XCTAssertEqual(versionInfo.bundleIdentifier, "Unknown")
        XCTAssertNil(versionInfo.bundleURL)
        XCTAssertEqual(versionInfo.versionBuildText, "Version Unknown (Unknown)")
    }

    func testVersionInfoFallsBackToBundleIdentifierFromInfoDictionary() {
        let versionInfo = AppVersionInfo(
            infoDictionary: [
                "CFBundleName": "CodexStatusBar",
                "CFBundleIdentifier": "com.example.fromInfo",
            ],
            bundleIdentifier: nil,
            bundleURL: nil
        )

        XCTAssertEqual(versionInfo.bundleIdentifier, "com.example.fromInfo")
    }

    func testInstallUpdateSettingsViewModelDisplaysLocalUpdateInfo() {
        let bundleURL = URL(fileURLWithPath: "/Applications/CodexStatusBar.app")
        let releaseNotes = [
            AppReleaseNote(id: "history", title: "History", detail: "Charts local usage."),
        ]
        let viewModel = InstallUpdateSettingsViewModel(
            versionInfo: AppVersionInfo(
                infoDictionary: [
                    "CFBundleDisplayName": "Codex Status Bar",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                ],
                bundleIdentifier: "com.farzad.codexstatusbar",
                bundleURL: bundleURL
            ),
            releaseNotes: releaseNotes
        )

        XCTAssertEqual(viewModel.appNameText, "Codex Status Bar")
        XCTAssertEqual(viewModel.versionText, "Version 1.0 (1)")
        XCTAssertEqual(viewModel.bundleIdentifierText, "com.farzad.codexstatusbar")
        XCTAssertEqual(viewModel.installedPathText, bundleURL.path)
        XCTAssertEqual(viewModel.updateCommandText, "git pull\n./install.sh")
        XCTAssertEqual(viewModel.projectURL.absoluteString, "https://github.com/fmnobar/codexStatusBar")
        XCTAssertEqual(viewModel.releaseNotes, releaseNotes)
        XCTAssertTrue(viewModel.canRevealApp)
    }

    func testInstallUpdateSettingsViewModelHandlesMissingBundleURL() {
        let viewModel = InstallUpdateSettingsViewModel(
            versionInfo: AppVersionInfo(
                infoDictionary: [
                    "CFBundleName": "CodexStatusBar",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                ],
                bundleIdentifier: "com.farzad.codexstatusbar",
                bundleURL: nil
            )
        )

        XCTAssertEqual(viewModel.installedPathText, "Unavailable")
        XCTAssertFalse(viewModel.canRevealApp)
        XCTAssertNil(viewModel.appBundleURL)
    }
}
