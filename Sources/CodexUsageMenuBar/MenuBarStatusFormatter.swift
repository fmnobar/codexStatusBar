import AppKit
import Foundation

@MainActor
enum StatusItemContextMenuFactory {
    static func makeMenu(target: AnyObject?, quitAction: Selector) -> NSMenu {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit", action: quitAction, keyEquivalent: "")
        quitItem.target = target
        menu.addItem(quitItem)
        return menu
    }
}

enum StatusItemTitleLayout {
    static let minimumLength: CGFloat = 34
    static let maximumLength: CGFloat = 230
    private static let horizontalPadding: CGFloat = 16

    static func visibleText(_ text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? "--" : trimmedText
    }

    static func length(for text: String, font: NSFont) -> CGFloat {
        let visibleText = visibleText(text)
        let textWidth = ceil((visibleText as NSString).size(withAttributes: [.font: font]).width)
        return min(max(textWidth + horizontalPadding, minimumLength), maximumLength)
    }
}

@MainActor
enum StatusItemVisibility {
    static func forceVisible(_ statusItem: NSStatusItem) {
        statusItem.isVisible = true
    }
}

@MainActor
enum StatusItemToolTipPolicy {
    static func apply(to button: NSStatusBarButton) {
        button.toolTip = nil
    }
}

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
            return .tightest
        }

        return selection
    }

    static func save(_ selection: MenuBarDisplayWindow, to defaults: UserDefaults = .standard) {
        defaults.set(selection.rawValue, forKey: defaultsKey)
    }
}

struct MenuBarDisplayOptions: Equatable {
    var showsLimitLabel: Bool
    var showsResetDate: Bool
    var showsResetTime: Bool
    var showsTokens: Bool

    init(
        showsLimitLabel: Bool,
        showsResetDate: Bool,
        showsResetTime: Bool,
        showsTokens: Bool = false
    ) {
        self.showsLimitLabel = showsLimitLabel
        self.showsResetDate = showsResetDate
        self.showsResetTime = showsResetTime
        self.showsTokens = showsTokens
    }

    static let defaultValue = MenuBarDisplayOptions(
        showsLimitLabel: true,
        showsResetDate: false,
        showsResetTime: false,
        showsTokens: false
    )
}

enum MenuBarDisplayOptionsStore {
    private static let showsLimitLabelKey = "MenuBarDisplayOptionsShowsLimitLabel"
    private static let showsResetDateKey = "MenuBarDisplayOptionsShowsResetDate"
    private static let showsResetTimeKey = "MenuBarDisplayOptionsShowsResetTime"
    private static let showsTokensKey = "MenuBarDisplayOptionsShowsTokens"

    static func load(from defaults: UserDefaults = .standard) -> MenuBarDisplayOptions {
        MenuBarDisplayOptions(
            showsLimitLabel: bool(forKey: showsLimitLabelKey, defaultValue: MenuBarDisplayOptions.defaultValue.showsLimitLabel, from: defaults),
            showsResetDate: bool(forKey: showsResetDateKey, defaultValue: MenuBarDisplayOptions.defaultValue.showsResetDate, from: defaults),
            showsResetTime: bool(forKey: showsResetTimeKey, defaultValue: MenuBarDisplayOptions.defaultValue.showsResetTime, from: defaults),
            showsTokens: bool(forKey: showsTokensKey, defaultValue: MenuBarDisplayOptions.defaultValue.showsTokens, from: defaults)
        )
    }

    static func save(_ options: MenuBarDisplayOptions, to defaults: UserDefaults = .standard) {
        defaults.set(options.showsLimitLabel, forKey: showsLimitLabelKey)
        defaults.set(options.showsResetDate, forKey: showsResetDateKey)
        defaults.set(options.showsResetTime, forKey: showsResetTimeKey)
        defaults.set(options.showsTokens, forKey: showsTokensKey)
    }

    private static func bool(forKey key: String, defaultValue: Bool, from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }

        return defaults.bool(forKey: key)
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
    let menuBarToolTipText: String?
    let fiveHourRow: MenuBarLimitRowPresentation
    let sevenDayRow: MenuBarLimitRowPresentation
    let tightestRow: MenuBarLimitRowPresentation
}

enum MenuBarStatusFormatter {
    static func presentation(
        snapshot: CodexRateLimitSnapshot?,
        now: Date,
        selectedMenuBarDisplayWindow: MenuBarDisplayWindow,
        menuBarDisplayOptions: MenuBarDisplayOptions = .defaultValue,
        todayTokenTotals: TokenCategoryTotals? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> MenuBarStatusPresentation {
        let menuBarWindow = resolvedMenuBarWindow(
            snapshot: snapshot,
            selectedMenuBarDisplayWindow: selectedMenuBarDisplayWindow
        )

        return MenuBarStatusPresentation(
            menuBarPercentText: menuBarPercentText(
                for: menuBarWindow.window,
                sourceTitle: menuBarWindow.sourceTitle,
                hasAnyLimitWindow: snapshot?.primary != nil || snapshot?.secondary != nil,
                options: menuBarDisplayOptions,
                todayTokenTotals: todayTokenTotals,
                now: now,
                calendar: calendar
            ),
            menuBarToolTipText: menuBarToolTipText(
                options: menuBarDisplayOptions,
                todayTokenTotals: todayTokenTotals
            ),
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

    static func menuBarPercentText(
        for window: CodexRateLimitWindow?,
        sourceTitle: String? = nil,
        hasAnyLimitWindow: Bool = true,
        options: MenuBarDisplayOptions = .defaultValue,
        todayTokenTotals: TokenCategoryTotals? = nil,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard let window else {
            guard !hasAnyLimitWindow else {
                return "--"
            }

            var components = ["No limit data"]
            if options.showsTokens {
                components.append("· \(compactMenuBarTokenText(todayTokenTotals?.totalTokens))")
            }

            return components.joined(separator: " ")
        }

        var components = [String]()
        let percentText = "\(window.remainingPercent)%"

        if options.showsLimitLabel, let sourceTitle {
            components.append("\(sourceTitle): \(percentText)")
        } else {
            components.append(percentText)
        }

        if let resetText = menuBarResetText(
            for: window.resetsAt,
            window: window,
            options: options,
            now: now,
            calendar: calendar
        ) {
            components.append(resetText)
        }

        if options.showsTokens {
            components.append("· \(compactMenuBarTokenText(todayTokenTotals?.totalTokens))")
        }

        return components.joined(separator: " ")
    }

    static func compactMenuBarTokenText(_ tokenCount: Int64?) -> String {
        guard let tokenCount else {
            return "--"
        }

        return compactTokenValue(tokenCount)
    }

    static func compactTokenCategoryText(_ totals: TokenCategoryTotals?) -> String {
        guard let totals else {
            return "-- tok"
        }

        return [
            "in \(compactTokenValue(totals.inputTokens))",
            "cache \(compactTokenValue(totals.cachedInputTokens))",
            "out \(compactTokenValue(totals.outputTokens))",
            "reason \(compactTokenValue(totals.reasoningOutputTokens))",
        ].joined(separator: " ")
    }

    static func compactTokenText(_ tokenCount: Int64?) -> String {
        guard let tokenCount else {
            return "-- tok"
        }

        return "\(compactTokenValue(tokenCount)) tok"
    }

    private static func compactTokenValue(_ tokenCount: Int64) -> String {
        let count = max(tokenCount, 0)
        switch count {
        case 0..<1_000:
            return "\(count)"
        case 1_000..<10_000:
            return "\(compactNumber(Double(count) / 1_000))k"
        case 10_000..<1_000_000:
            return "\(Int((Double(count) / 1_000).rounded()))k"
        case 1_000_000..<10_000_000:
            return "\(compactNumber(Double(count) / 1_000_000))M"
        default:
            return "\(Int((Double(count) / 1_000_000).rounded()))M"
        }
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
        let sourceTitle = tightestWindowWithSource(primary: primary, secondary: secondary)?.sourceTitle

        return MenuBarLimitRowPresentation(
            title: "Tightest: \(sourceTitle ?? "--")",
            remainingPercentText: "",
            detailText: "",
            displayWindow: .tightest,
            isSelected: isSelected
        )
    }

    static func freshnessText(lastUpdatedAt: Date?, now: Date, isOffline: Bool) -> String? {
        guard let lastUpdatedAt else {
            return isOffline ? "Offline" : nil
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
        tightestWindowWithSource(primary: primary, secondary: secondary)?.window
    }

    static func menuBarToolTipText(
        options: MenuBarDisplayOptions,
        todayTokenTotals: TokenCategoryTotals?
    ) -> String? {
        guard options.showsTokens else {
            return nil
        }

        guard let totals = todayTokenTotals else {
            return "No local captured token data today."
        }

        return [
            "Today's local captured tokens:",
            "input \(compactTokenText(totals.inputTokens)),",
            "cached input \(compactTokenText(totals.cachedInputTokens)),",
            "output \(compactTokenText(totals.outputTokens)),",
            "reasoning \(compactTokenText(totals.reasoningOutputTokens)),",
            "total \(compactTokenText(totals.totalTokens)).",
        ].joined(separator: " ")
    }

    private static func resolvedMenuBarWindow(
        snapshot: CodexRateLimitSnapshot?,
        selectedMenuBarDisplayWindow: MenuBarDisplayWindow
    ) -> (sourceTitle: String?, window: CodexRateLimitWindow?) {
        switch selectedMenuBarDisplayWindow {
        case .fiveHour:
            return ("5h", snapshot?.primary)
        case .sevenDay:
            return ("7d", snapshot?.secondary)
        case .tightest:
            let tightest = tightestWindowWithSource(primary: snapshot?.primary, secondary: snapshot?.secondary)
            return (tightest?.sourceTitle, tightest?.window)
        }
    }

    private static func tightestWindowWithSource(
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?
    ) -> (sourceTitle: String, window: CodexRateLimitWindow)? {
        switch (primary, secondary) {
        case (.none, .none):
            return nil
        case (.some(let primary), .none):
            return ("5h", primary)
        case (.none, .some(let secondary)):
            return ("7d", secondary)
        case (.some(let primary), .some(let secondary)):
            if primary.remainingPercent <= secondary.remainingPercent {
                return ("5h", primary)
            }

            return ("7d", secondary)
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

    private static func menuBarResetText(
        for resetDate: Date?,
        window: CodexRateLimitWindow,
        options: MenuBarDisplayOptions,
        now: Date,
        calendar: Calendar
    ) -> String? {
        guard options.showsResetDate || options.showsResetTime else {
            return nil
        }
        guard let resetDate else {
            return "--"
        }

        var components = [String]()

        if options.showsResetDate {
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = calendar.timeZone

            if shouldShowSameDayResetAsTime(for: resetDate, window: window, options: options, now: now, calendar: calendar) {
                dateFormatter.dateFormat = "h:mma"
            } else {
                dateFormatter.dateFormat = "M/d"
            }

            components.append(dateFormatter.string(from: resetDate))
        }

        if options.showsResetTime {
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.timeZone = calendar.timeZone
            timeFormatter.dateFormat = "h:mma"
            components.append(timeFormatter.string(from: resetDate))
        }

        return components.joined(separator: " ")
    }

    private static func shouldShowSameDayResetAsTime(
        for resetDate: Date,
        window: CodexRateLimitWindow,
        options: MenuBarDisplayOptions,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        window.windowDurationMinutes == 10_080
            && calendar.isDate(resetDate, inSameDayAs: now)
            && !options.showsResetTime
    }

    private static func compactNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return "\(Int(rounded))"
        }

        return String(format: "%.1f", rounded)
    }
}
