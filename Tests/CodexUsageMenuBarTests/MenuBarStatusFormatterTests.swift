import XCTest

final class MenuBarStatusFormatterTests: XCTestCase {
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
        XCTAssertEqual(presentation.sevenDayRow.resetText, "Resets --")
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

        XCTAssertEqual(presentation.menuBarPercentText, "98%")
        XCTAssertEqual(presentation.fiveHourRow.remainingPercentText, "--% left")
        XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "98% left")
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

        XCTAssertEqual(presentation.menuBarPercentText, "84%")
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

        XCTAssertEqual(presentation.menuBarPercentText, "84%")
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
