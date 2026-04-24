import Foundation

enum UsageLimitWindow: String, CaseIterable, Identifiable, Equatable {
    case fiveHour
    case sevenDay

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .sevenDay:
            return "7d"
        }
    }
}

enum UsageHistoryRange: String, CaseIterable, Identifiable, Equatable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .day:
            return "Day"
        case .week:
            return "Week"
        case .month:
            return "Month"
        case .year:
            return "Year"
        }
    }

    var storageGranularity: UsageHistoryGranularity {
        switch self {
        case .day:
            return .raw
        case .week:
            return .hour
        case .month, .year:
            return .day
        }
    }

    func startDate(before date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        switch self {
        case .day:
            return calendar.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-86_400)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: date) ?? date.addingTimeInterval(-604_800)
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: date) ?? date.addingTimeInterval(-2_592_000)
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: date) ?? date.addingTimeInterval(-31_536_000)
        }
    }
}

enum UsageHistoryGranularity: String, Equatable {
    case raw
    case hour
    case day
}

struct UsageHistoryPoint: Equatable, Identifiable {
    let id: String
    let timestamp: Date
    let bucketID: String
    let bucketName: String
    let bucketKind: CodexUsageBucketKind
    let window: UsageLimitWindow
    let usedPercent: Double

    init(
        timestamp: Date,
        bucketID: String,
        bucketName: String,
        bucketKind: CodexUsageBucketKind,
        window: UsageLimitWindow,
        usedPercent: Double
    ) {
        self.timestamp = timestamp
        self.bucketID = bucketID
        self.bucketName = bucketName
        self.bucketKind = bucketKind
        self.window = window
        self.usedPercent = usedPercent
        id = "\(bucketID)-\(window.rawValue)-\(Int(timestamp.timeIntervalSince1970))"
    }
}

struct UsageHistorySeries: Equatable, Identifiable {
    let id: String
    let name: String
    let kind: CodexUsageBucketKind
}
