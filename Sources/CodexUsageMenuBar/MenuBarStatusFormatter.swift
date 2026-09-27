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

    static func length(for text: String, font: NSFont, hasRing: Bool = false) -> CGFloat {
        let title = hasRing ? text.trimmingCharacters(in: .whitespacesAndNewlines) : visibleText(text)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let ringWidth: CGFloat = hasRing ? (title.isEmpty ? 19 : 24) : 0
        return min(max(textWidth + horizontalPadding + ringWidth, minimumLength), maximumLength)
    }
}

enum StatusItemRingImage {
    static func make(remainingPercent: Int, trailingSpacing: CGFloat = 0) -> NSImage {
        let side: CGFloat = 15
        let lineWidth: CGFloat = 2.2
        let ringRect = NSRect(x: 0, y: 0, width: side, height: side)
        let image = NSImage(size: NSSize(width: side + trailingSpacing, height: side), flipped: false) { _ in
            let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
            let radius = (side - lineWidth) / 2

            let track = NSBezierPath(ovalIn: ringRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let progress = NSBezierPath()
            progress.lineWidth = lineWidth
            progress.lineCapStyle = .round
            progress.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * CGFloat(min(max(remainingPercent, 0), 100)) / 100,
                clockwise: true
            )
            NSColor.labelColor.setStroke()
            progress.stroke()
            return true
        }
        image.isTemplate = true
        return image
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

struct AppAccessibilityPresentation: Equatable {
    let label: String
    let value: String
}

enum AppAccessibilitySemantics {
    static func limitRow(_ row: MenuBarLimitRowPresentation) -> AppAccessibilityPresentation {
        AppAccessibilityPresentation(
            label: row.title,
            value: [row.remainingPercentText, row.detailText]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
    }

    static func statusItemLabel(visibleText: String) -> String {
        "Codex usage \(visibleText)"
    }
}

struct MenuBarDisplayOptions: Equatable {
    var showsRemainingPercentage: Bool
    var showsResetDate: Bool
    var showsResetTime: Bool

    init(
        showsResetDate: Bool,
        showsResetTime: Bool,
        showsRemainingPercentage: Bool = true
    ) {
        self.showsRemainingPercentage = showsRemainingPercentage
        self.showsResetDate = showsResetDate
        self.showsResetTime = showsResetTime
    }

    static let defaultValue = MenuBarDisplayOptions(
        showsResetDate: false,
        showsResetTime: false
    )
}

enum MenuBarDisplayOptionsStore {
    private static let showsRemainingPercentageKey = "MenuBarDisplayOptionsShowsRemainingPercentage"
    private static let showsResetDateKey = "MenuBarDisplayOptionsShowsResetDate"
    private static let showsResetTimeKey = "MenuBarDisplayOptionsShowsResetTime"

    static func load(from defaults: UserDefaults = .standard) -> MenuBarDisplayOptions {
        MenuBarDisplayOptions(
            showsResetDate: bool(forKey: showsResetDateKey, defaultValue: MenuBarDisplayOptions.defaultValue.showsResetDate, from: defaults),
            showsResetTime: bool(forKey: showsResetTimeKey, defaultValue: MenuBarDisplayOptions.defaultValue.showsResetTime, from: defaults),
            showsRemainingPercentage: bool(forKey: showsRemainingPercentageKey, defaultValue: MenuBarDisplayOptions.defaultValue.showsRemainingPercentage, from: defaults)
        )
    }

    static func save(_ options: MenuBarDisplayOptions, to defaults: UserDefaults = .standard) {
        defaults.set(options.showsRemainingPercentage, forKey: showsRemainingPercentageKey)
        defaults.set(options.showsResetDate, forKey: showsResetDateKey)
        defaults.set(options.showsResetTime, forKey: showsResetTimeKey)
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
}

struct MenuBarStatusPresentation: Equatable {
    let menuBarPercentText: String
    let weeklyRemainingPercent: Int?
    let menuBarToolTipText: String?
    let sevenDayRow: MenuBarLimitRowPresentation
}

enum MenuBarStatusFormatter {
    static func presentation(
        snapshot: CodexRateLimitSnapshot?,
        now: Date,
        menuBarDisplayOptions: MenuBarDisplayOptions = .defaultValue,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> MenuBarStatusPresentation {
        let sevenDayWindow = snapshot?.classifiedWindow(for: .sevenDay)

        return MenuBarStatusPresentation(
            menuBarPercentText: menuBarPercentText(
                for: sevenDayWindow,
                hasAnyLimitWindow: snapshot?.primary != nil || snapshot?.secondary != nil,
                options: menuBarDisplayOptions,
                now: now,
                calendar: calendar
            ),
            weeklyRemainingPercent: sevenDayWindow?.remainingPercent,
            menuBarToolTipText: nil,
            sevenDayRow: row(
                title: "7d limit",
                window: sevenDayWindow,
                now: now,
                calendar: calendar,
                locale: locale
            )
        )
    }

    static func menuBarPercentText(
        for window: CodexRateLimitWindow?,
        hasAnyLimitWindow: Bool = true,
        options: MenuBarDisplayOptions = .defaultValue,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard let window else {
            guard !hasAnyLimitWindow else {
                return "--"
            }

            return "No limit data"
        }

        var components = options.showsRemainingPercentage ? ["\(window.remainingPercent)%"] : []

        if let resetText = menuBarResetText(
            for: window.resetsAt,
            options: options,
            now: now,
            calendar: calendar
        ) {
            components.append(resetText)
        }

        return components.joined(separator: " ")
    }

    static func row(
        title: String,
        window: CodexRateLimitWindow?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> MenuBarLimitRowPresentation {
        let remainingText = window.map { "\($0.remainingPercent)% left" } ?? "--% left"
        let resetText = resetText(for: window?.resetsAt, now: now, calendar: calendar, locale: locale)
        return MenuBarLimitRowPresentation(
            title: title,
            remainingPercentText: remainingText,
            detailText: "Resets \(resetText)"
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

            if calendar.isDate(resetDate, inSameDayAs: now) && !options.showsResetTime {
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
}
