import Foundation

struct MenuBarStatusPresentation: Equatable {
    let menuBarPercentText: String
    let fiveHourLine: String
    let sevenDayLine: String
}

enum MenuBarStatusFormatter {
    static func presentation(
        snapshot: CodexRateLimitSnapshot?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> MenuBarStatusPresentation {
        MenuBarStatusPresentation(
            menuBarPercentText: menuBarPercentText(for: snapshot?.secondary),
            fiveHourLine: line(
                title: "5h limit",
                window: snapshot?.primary,
                now: now,
                calendar: calendar,
                locale: locale
            ),
            sevenDayLine: line(
                title: "7d limit",
                window: snapshot?.secondary,
                now: now,
                calendar: calendar,
                locale: locale
            )
        )
    }

    static func menuBarPercentText(for window: CodexRateLimitWindow?) -> String {
        guard let window else {
            return "--"
        }

        return "\(window.remainingPercent)%"
    }

    static func line(
        title: String,
        window: CodexRateLimitWindow?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let remainingText = window.map { String($0.remainingPercent) } ?? "--"
        let resetText = resetText(for: window?.resetsAt, now: now, calendar: calendar, locale: locale)
        return "\(title): \(remainingText)% left (resets \(resetText))"
    }

    static func resetText(
        for resetDate: Date?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let resetDate else {
            return "--"
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone

        if calendar.isDate(resetDate, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d jm")
        }

        return formatter.string(from: resetDate)
    }
}

enum RefreshPolicy {
    static func shouldRefreshOnPopover(
        lastRefreshAt: Date?,
        now: Date,
        staleAfter: TimeInterval = 30
    ) -> Bool {
        guard let lastRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastRefreshAt) >= staleAfter
    }
}
