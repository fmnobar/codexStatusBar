import Foundation

enum MenuBarDisplayWindow: String, Equatable {
    case fiveHour
    case sevenDay
}

enum MenuBarDisplayWindowStore {
    private static let defaultsKey = "MenuBarDisplayWindow"

    static func load(from defaults: UserDefaults = .standard) -> MenuBarDisplayWindow {
        guard
            let rawValue = defaults.string(forKey: defaultsKey),
            let selection = MenuBarDisplayWindow(rawValue: rawValue)
        else {
            return .sevenDay
        }

        return selection
    }

    static func save(_ selection: MenuBarDisplayWindow, to defaults: UserDefaults = .standard) {
        defaults.set(selection.rawValue, forKey: defaultsKey)
    }
}

struct MenuBarStatusPresentation: Equatable {
    let menuBarPercentText: String
    let fiveHourLine: String
    let sevenDayLine: String
}

enum MenuBarStatusFormatter {
    static func presentation(
        snapshot: CodexRateLimitSnapshot?,
        now: Date,
        selectedMenuBarDisplayWindow: MenuBarDisplayWindow,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> MenuBarStatusPresentation {
        let menuBarWindow: CodexRateLimitWindow? = switch selectedMenuBarDisplayWindow {
        case .fiveHour:
            snapshot?.primary
        case .sevenDay:
            snapshot?.secondary
        }

        return MenuBarStatusPresentation(
            menuBarPercentText: menuBarPercentText(for: menuBarWindow),
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
            return formatter.string(from: resetDate)
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.locale = locale
            dateFormatter.timeZone = calendar.timeZone
            dateFormatter.setLocalizedDateFormatFromTemplate("MMM d")

            let timeFormatter = DateFormatter()
            timeFormatter.locale = locale
            timeFormatter.timeZone = calendar.timeZone
            timeFormatter.setLocalizedDateFormatFromTemplate("jm")

            return "\(dateFormatter.string(from: resetDate)) \(timeFormatter.string(from: resetDate))"
        }
    }
}
