import AppKit
import XCTest
@testable import CodexUsageCore

final class MenuBarStatusFormatterTests: XCTestCase {
    func testStatusItemControllerRoutesRightClickOnlyToContextMenu() {
        XCTAssertEqual(StatusItemController.clickIntent(for: .rightMouseUp), .showContextMenu)
        XCTAssertEqual(StatusItemController.clickIntent(for: .leftMouseUp), .togglePopover)
        XCTAssertEqual(StatusItemController.clickIntent(for: nil), .togglePopover)
    }

    @MainActor
    func testStatusItemContextMenuContainsOnlyQuit() {
        let menu = StatusItemContextMenuFactory.makeMenu(
            target: nil,
            quitAction: NSSelectorFromString("quit")
        )

        XCTAssertEqual(menu.items.map(\.title), ["Quit"])
        XCTAssertEqual(menu.items.first?.keyEquivalent, "")
        XCTAssertEqual(menu.items.first?.action.map { NSStringFromSelector($0) }, "quit")
        XCTAssertEqual(menu.items.first?.isEnabled, true)
    }

    func testStatusItemTitleLayoutKeepsTextVisibleAndBounded() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        XCTAssertEqual(StatusItemTitleLayout.visibleText(""), "--")
        XCTAssertEqual(StatusItemTitleLayout.visibleText("   "), "--")
        XCTAssertEqual(StatusItemTitleLayout.visibleText("91% 5/17 10:28AM"), "91% 5/17 10:28AM")
        XCTAssertEqual(StatusItemTitleLayout.length(for: "", font: font, hasRing: true), 25)
        let fullTitle = "68% 10/3"
        let fullTitleWidth = ceil((fullTitle as NSString).size(withAttributes: [.font: font]).width)
        XCTAssertEqual(
            StatusItemTitleLayout.length(for: fullTitle, font: font, hasRing: true),
            fullTitleWidth + 30
        )
        XCTAssertEqual(
            StatusItemTitleLayout.length(for: "67%", font: font, hasRing: true)
                - StatusItemTitleLayout.length(for: "67%", font: font),
            24
        )

        XCTAssertEqual(
            StatusItemTitleLayout.length(for: "", font: font),
            StatusItemTitleLayout.minimumLength
        )
        XCTAssertLessThanOrEqual(
            StatusItemTitleLayout.length(
                for: "85% 5/17 10:28AM long reset text long reset text long reset text long reset text long reset text",
                font: font
            ),
            StatusItemTitleLayout.maximumLength
        )
    }

    @MainActor
    func testStatusItemVisibilityCanRestoreHiddenItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer {
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        statusItem.isVisible = false
        XCTAssertFalse(statusItem.isVisible)

        StatusItemVisibility.forceVisible(statusItem)

        XCTAssertTrue(statusItem.isVisible)
    }

    @MainActor
    func testStatusItemTooltipPolicyClearsHoverTooltip() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer {
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        statusItem.button?.toolTip = "Detailed status text"

        if let button = statusItem.button {
            StatusItemToolTipPolicy.apply(to: button)
        }

        XCTAssertNil(statusItem.button?.toolTip)
    }

    func testMenuBarDisplayOptionsStoreDefaultsToPercentOnly() {
        let suiteName = "MenuBarStatusFormatterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(MenuBarDisplayOptionsStore.load(from: defaults), .defaultValue)
        XCTAssertTrue(MenuBarDisplayOptionsStore.load(from: defaults).showsRemainingPercentage)
    }

    func testRemainingPercentagePreferencePersistsWithoutChangingResetOptions() throws {
        let suiteName = "MenuBarStatusFormatterTests.RemainingPercentage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let options = MenuBarDisplayOptions(
            showsResetDate: true,
            showsResetTime: false,
            showsRemainingPercentage: false
        )
        MenuBarDisplayOptionsStore.save(options, to: defaults)
        XCTAssertEqual(MenuBarDisplayOptionsStore.load(from: defaults), options)
        XCTAssertFalse(defaults.bool(forKey: "MenuBarDisplayOptionsShowsRemainingPercentage"))
    }

    func testHiddenPercentageKeepsWeeklyRingValueAndIndependentResetText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-04-25T16:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-28T19:58:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 32, windowDurationMinutes: 10_080, resetsAt: resetDate),
            secondary: nil
        )

        let ringOnly = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: now,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsResetDate: false,
                showsResetTime: false,
                showsRemainingPercentage: false
            ),
            calendar: calendar
        )
        XCTAssertEqual(ringOnly.weeklyRemainingPercent, 68)
        XCTAssertEqual(ringOnly.menuBarPercentText, "")

        let withDate = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: now,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsResetDate: true,
                showsResetTime: false,
                showsRemainingPercentage: false
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(withDate.weeklyRemainingPercent, 68)
        XCTAssertEqual(withDate.menuBarPercentText, "4/28")
    }

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(CodexRateLimitWindow.clampedRemainingPercent(from: 2), 98)
        XCTAssertEqual(CodexRateLimitWindow.clampedRemainingPercent(from: -5), 100)
        XCTAssertEqual(CodexRateLimitWindow.clampedRemainingPercent(from: 150), 0)
    }

    func testLegacyTokenPreferenceDoesNotChangeCurrentUsageOptions() throws {
        let suite = "CodexUsageMenuBarTests.LegacyAnalytics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "MenuBarDisplayOptionsShowsTokens")
        defaults.set("detailed_analytics", forKey: "Usage.collectionMode")

        XCTAssertEqual(MenuBarDisplayOptionsStore.load(from: defaults), .defaultValue)
        XCTAssertEqual(SettingsTabSelectionStore.selectedTab(from: "data"), .general)

        let options = MenuBarDisplayOptions(showsResetDate: true, showsResetTime: true)
        MenuBarDisplayOptionsStore.save(options, to: defaults)
        XCTAssertEqual(MenuBarDisplayOptionsStore.load(from: defaults), options)
        XCTAssertTrue(defaults.bool(forKey: "MenuBarDisplayOptionsShowsTokens"))
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

    func testPresentationUsesWeeklyLimitEvenWhenFiveHourLimitIsMoreRestrictive() {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 95, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 25, windowDurationMinutes: 10_080, resetsAt: nil)
        )

        let presentation = MenuBarStatusFormatter.presentation(snapshot: snapshot, now: Date())

        XCTAssertEqual(presentation.menuBarPercentText, "75%")
        XCTAssertEqual(presentation.sevenDayRow.title, "7d limit")
        XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "75% left")
        XCTAssertNil(presentation.menuBarToolTipText)
    }

    func testPresentationDoesNotFallBackToFiveHourWhenWeeklyLimitIsMissing() {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 6, windowDurationMinutes: 300, resetsAt: Date()),
            secondary: nil
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: Date(),
            menuBarDisplayOptions: MenuBarDisplayOptions(showsResetDate: true, showsResetTime: true)
        )

        XCTAssertEqual(presentation.menuBarPercentText, "--")
        XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "--% left")
        XCTAssertEqual(presentation.sevenDayRow.detailText, "Resets --")
    }

    func testPresentationShowsExplicitTextWhenAllLimitWindowsAreMissing() {
        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: CodexRateLimitSnapshot(primary: nil, secondary: nil),
            now: Date()
        )

        XCTAssertEqual(presentation.menuBarPercentText, "No limit data")
        XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "--% left")
    }

    func testPrimaryOnlyWeeklyLimitDrivesPresentation() {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 43, windowDurationMinutes: 10_080, resetsAt: nil),
            secondary: nil
        )

        let presentation = MenuBarStatusFormatter.presentation(snapshot: snapshot, now: Date())

        XCTAssertEqual(presentation.menuBarPercentText, "57%")
        XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "57% left")
    }

    func testReversedSlotsClassifyWeeklyLimitByDuration() {
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 70, windowDurationMinutes: 10_080, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 90, windowDurationMinutes: 300, resetsAt: nil)
        )

        let presentation = MenuBarStatusFormatter.presentation(snapshot: snapshot, now: Date())

        XCTAssertEqual(presentation.menuBarPercentText, "30%")
        XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "30% left")
    }

    func testUnclassifiedWindowsDoNotBecomeWeeklyUsage() {
        for duration in [90, nil] as [Int?] {
            let snapshot = CodexRateLimitSnapshot(
                primary: CodexRateLimitWindow(usedPercent: 80, windowDurationMinutes: duration, resetsAt: nil),
                secondary: nil
            )
            let presentation = MenuBarStatusFormatter.presentation(snapshot: snapshot, now: Date())

            XCTAssertEqual(presentation.menuBarPercentText, "--")
            XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "--% left")
        }
    }

    func testRetiredWindowAndLabelPreferencesAreIgnoredAndPreserved() throws {
        let suite = "CodexUsageMenuBarTests.RetiredWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fiveHour", forKey: "MenuBarDisplayWindow")
        defaults.set(true, forKey: "MenuBarDisplayOptionsShowsLimitLabel")
        defaults.set(true, forKey: "MenuBarDisplayOptionsShowsResetDate")
        defaults.set(false, forKey: "MenuBarDisplayOptionsShowsResetTime")

        XCTAssertEqual(
            MenuBarDisplayOptionsStore.load(from: defaults),
            MenuBarDisplayOptions(showsResetDate: true, showsResetTime: false)
        )

        let options = MenuBarDisplayOptions(showsResetDate: false, showsResetTime: true)
        MenuBarDisplayOptionsStore.save(options, to: defaults)

        XCTAssertEqual(MenuBarDisplayOptionsStore.load(from: defaults), options)
        XCTAssertEqual(defaults.string(forKey: "MenuBarDisplayWindow"), "fiveHour")
        XCTAssertTrue(defaults.bool(forKey: "MenuBarDisplayOptionsShowsLimitLabel"))
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
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsResetDate: true,
                showsResetTime: true
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "39% 4/28 7:58PM")
    }

    func testMenuBarResetDateShowsTimeWhenResetIsLaterToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-04-28T15:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-28T17:00:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 37, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 65, windowDurationMinutes: 10080, resetsAt: resetDate)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: now,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsResetDate: true,
                showsResetTime: false
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "35% 5:00PM")
    }

    func testMenuBarResetDateStillShowsDateBeforeResetDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-04-27T15:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-28T17:00:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 37, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 65, windowDurationMinutes: 10080, resetsAt: resetDate)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: now,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsResetDate: true,
                showsResetTime: false
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "35% 4/28")
    }

    func testMenuBarTextCanShowWeeklyResetTimeOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-04-25T16:00:00Z")!
        let resetDate = ISO8601DateFormatter().date(from: "2026-04-25T19:58:00Z")!
        let snapshot = CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 37, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 61, windowDurationMinutes: 10080, resetsAt: resetDate)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: now,
            menuBarDisplayOptions: MenuBarDisplayOptions(
                showsResetDate: false,
                showsResetTime: true
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "39% 7:58PM")
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

    func testFreshnessTextCanDescribeOfflineWithoutPriorSnapshot() {
        let now = ISO8601DateFormatter().date(from: "2026-04-14T20:00:00Z")!

        XCTAssertEqual(
            MenuBarStatusFormatter.freshnessText(lastUpdatedAt: nil, now: now, isOffline: true),
            "Offline"
        )
        XCTAssertNil(MenuBarStatusFormatter.freshnessText(lastUpdatedAt: nil, now: now, isOffline: false))
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
            AppReleaseNote(id: "usage", title: "Usage", detail: "Shows weekly usage."),
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
