import Foundation

enum UsageLimitWindow: String, CaseIterable, Codable, Identifiable, Equatable {
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

    var chartBucketComponent: Calendar.Component {
        switch self {
        case .day:
            return .hour
        case .week, .month:
            return .day
        case .year:
            return .month
        }
    }

    var chartBucketTitle: String {
        switch self {
        case .day:
            return "hour"
        case .week, .month:
            return "day"
        case .year:
            return "month"
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

enum UsageHistoryMetric: String, CaseIterable, Identifiable, Equatable {
    case capacityLeft
    case usage

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .capacityLeft:
            return "Capacity left"
        case .usage:
            return "Usage"
        }
    }

    var axisTitle: String {
        switch self {
        case .capacityLeft:
            return "Left %"
        case .usage:
            return "Consumed %"
        }
    }

    func subtitle(for range: UsageHistoryRange) -> String {
        switch self {
        case .capacityLeft:
            return "Capacity left by \(range.chartBucketTitle)"
        case .usage:
            return "Usage consumed by \(range.chartBucketTitle)"
        }
    }
}

struct UsageHistoryPoint: Equatable, Identifiable {
    let id: String
    let timestamp: Date
    let bucketID: String
    let bucketName: String
    let bucketKind: CodexUsageBucketKind
    let window: UsageLimitWindow
    let usedPercent: Double
    let peakUsedPercent: Double
    let consumedPercent: Double

    init(
        timestamp: Date,
        bucketID: String,
        bucketName: String,
        bucketKind: CodexUsageBucketKind,
        window: UsageLimitWindow,
        usedPercent: Double,
        peakUsedPercent: Double? = nil,
        consumedPercent: Double = 0
    ) {
        self.timestamp = timestamp
        self.bucketID = bucketID
        self.bucketName = bucketName
        self.bucketKind = bucketKind
        self.window = window
        self.usedPercent = usedPercent
        self.peakUsedPercent = peakUsedPercent ?? usedPercent
        self.consumedPercent = consumedPercent
        id = "\(bucketID)-\(window.rawValue)-\(Int(timestamp.timeIntervalSince1970))"
    }
}

struct UsageHistorySeries: Equatable, Identifiable {
    let id: String
    let name: String
    let kind: CodexUsageBucketKind
}

struct UsageHistoryChartPoint: Equatable, Identifiable {
    let id: String
    let bucketStart: Date
    let bucketEnd: Date
    let sampleTimestamp: Date
    let bucketID: String
    let bucketName: String
    let bucketKind: CodexUsageBucketKind
    let window: UsageLimitWindow
    let latestUsedPercent: Double
    let peakUsedPercent: Double
    let consumedPercent: Double

    init(
        bucketStart: Date,
        bucketEnd: Date,
        sampleTimestamp: Date,
        bucketID: String,
        bucketName: String,
        bucketKind: CodexUsageBucketKind,
        window: UsageLimitWindow,
        latestUsedPercent: Double,
        peakUsedPercent: Double,
        consumedPercent: Double
    ) {
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        self.sampleTimestamp = sampleTimestamp
        self.bucketID = bucketID
        self.bucketName = bucketName
        self.bucketKind = bucketKind
        self.window = window
        self.latestUsedPercent = latestUsedPercent
        self.peakUsedPercent = peakUsedPercent
        self.consumedPercent = consumedPercent
        id = "\(bucketID)-\(window.rawValue)-\(Int(bucketStart.timeIntervalSince1970))"
    }

    func value(for metric: UsageHistoryMetric) -> Double {
        switch metric {
        case .capacityLeft:
            return Self.clampedPercent(100 - latestUsedPercent)
        case .usage:
            return Self.clampedPercent(consumedPercent)
        }
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
