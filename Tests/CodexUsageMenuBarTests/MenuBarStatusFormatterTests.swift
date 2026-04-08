import XCTest
@testable import CodexUsageMenuBar

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
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "--")
        XCTAssertEqual(presentation.sevenDayLine, "7d limit: --% left (resets --)")
    }

    func testPresentationKeepsSevenDayLineWhenFiveHourWindowIsMissing() {
        let snapshot = CodexRateLimitSnapshot(
            primary: nil,
            secondary: CodexRateLimitWindow(usedPercent: 2, windowDurationMinutes: 10080, resetsAt: nil)
        )

        let presentation = MenuBarStatusFormatter.presentation(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 0),
            calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.menuBarPercentText, "98%")
        XCTAssertEqual(presentation.fiveHourLine, "5h limit: --% left (resets --)")
        XCTAssertEqual(presentation.sevenDayLine, "7d limit: 98% left (resets --)")
    }
}
