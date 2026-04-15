import Foundation

enum MenuBarDisplayWindow: String, CaseIterable, Equatable {
    case fiveHour
    case sevenDay
    case tightest

    var displayTitle: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .sevenDay:
            return "7d"
        case .tightest:
            return "Tightest"
        }
    }
}

enum MenuBarDisplayWindowStore {
    static let defaultsKey = "MenuBarDisplayWindow"

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

enum StatusItemVisualState: Equatable {
    case normal
    case stale
    case error
}

struct MenuBarLimitRowPresentation: Equatable {
    let title: String
    let remainingPercentText: String
    let detailText: String
    let displayWindow: MenuBarDisplayWindow
    let isSelected: Bool
}

struct MenuBarStatusPresentation: Equatable {
    let menuBarPercentText: String
    let fiveHourRow: MenuBarLimitRowPresentation
    let sevenDayRow: MenuBarLimitRowPresentation
    let tightestRow: MenuBarLimitRowPresentation
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
        case .tightest:
            tightestWindow(primary: snapshot?.primary, secondary: snapshot?.secondary)
        }

        return MenuBarStatusPresentation(
            menuBarPercentText: menuBarPercentText(for: menuBarWindow),
            fiveHourRow: row(
                title: "5h limit",
                window: snapshot?.primary,
                displayWindow: .fiveHour,
                isSelected: selectedMenuBarDisplayWindow == .fiveHour,
                now: now,
                calendar: calendar,
                locale: locale
            ),
            sevenDayRow: row(
                title: "7d limit",
                window: snapshot?.secondary,
                displayWindow: .sevenDay,
                isSelected: selectedMenuBarDisplayWindow == .sevenDay,
                now: now,
                calendar: calendar,
                locale: locale
            ),
            tightestRow: tightestRow(
                primary: snapshot?.primary,
                secondary: snapshot?.secondary,
                isSelected: selectedMenuBarDisplayWindow == .tightest
            )
        )
    }

    static func menuBarPercentText(for window: CodexRateLimitWindow?) -> String {
        guard let window else {
            return "--"
        }

        return "\(window.remainingPercent)%"
    }

    static func row(
        title: String,
        window: CodexRateLimitWindow?,
        displayWindow: MenuBarDisplayWindow,
        isSelected: Bool,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> MenuBarLimitRowPresentation {
        let remainingText = window.map { "\($0.remainingPercent)% left" } ?? "--% left"
        let resetText = resetText(for: window?.resetsAt, now: now, calendar: calendar, locale: locale)
        return MenuBarLimitRowPresentation(
            title: title,
            remainingPercentText: remainingText,
            detailText: "Resets \(resetText)",
            displayWindow: displayWindow,
            isSelected: isSelected
        )
    }

    static func tightestRow(
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?,
        isSelected: Bool
    ) -> MenuBarLimitRowPresentation {
        let resolvedWindow = tightestWindow(primary: primary, secondary: secondary)
        let sourceTitle: String? = switch (primary, secondary) {
        case (.none, .none):
            nil
        case (.some(let primary), .none):
            primary == resolvedWindow ? "5h" : nil
        case (.none, .some(let secondary)):
            secondary == resolvedWindow ? "7d" : nil
        case (.some(let primary), .some(let secondary)):
            primary.remainingPercent <= secondary.remainingPercent ? "5h" : "7d"
        }

        return MenuBarLimitRowPresentation(
            title: "Tightest",
            remainingPercentText: resolvedWindow.map { "\($0.remainingPercent)% left" } ?? "--% left",
            detailText: "Tightest: \(sourceTitle ?? "--")",
            displayWindow: .tightest,
            isSelected: isSelected
        )
    }

    static func freshnessText(lastUpdatedAt: Date?, now: Date, isOffline: Bool) -> String? {
        guard let lastUpdatedAt else {
            return nil
        }

        let ageText = relativeAgeText(since: lastUpdatedAt, now: now)
        if isOffline {
            return "Offline, showing last update from \(ageText)"
        }

        return "Updated \(ageText)"
    }

    static func relativeAgeText(since date: Date, now: Date) -> String {
        let interval = max(0, Int(now.timeIntervalSince(date)))

        switch interval {
        case 0..<60:
            return "just now"
        case 60..<3_600:
            return "\(interval / 60)m ago"
        case 3_600..<86_400:
            return "\(interval / 3_600)h ago"
        default:
            return "\(interval / 86_400)d ago"
        }
    }

    static func tightestWindow(primary: CodexRateLimitWindow?, secondary: CodexRateLimitWindow?) -> CodexRateLimitWindow? {
        switch (primary, secondary) {
        case (.none, .none):
            return nil
        case (.some(let primary), .none):
            return primary
        case (.none, .some(let secondary)):
            return secondary
        case (.some(let primary), .some(let secondary)):
            return primary.remainingPercent <= secondary.remainingPercent ? primary : secondary
        }
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
