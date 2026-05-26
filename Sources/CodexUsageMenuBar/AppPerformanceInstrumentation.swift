import Combine
import Foundation

enum AppPerformanceEventKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case appLaunchToFirstMenuBarTitle
    case menuPopoverOpenToContent
    case historyReload
    case tokenDashboardOpen
    case tokenDashboardReload
    case tokenDashboardPeriodChange
    case tokenDashboardBreakdownChange
    case performanceDashboardOpen
    case performanceDashboardReload
    case performanceDashboardModeChange
    case performanceDashboardPeriodChange
    case performanceDashboardBreakdownChange

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .appLaunchToFirstMenuBarTitle:
            return "Launch to menu title"
        case .menuPopoverOpenToContent:
            return "Menu popover open"
        case .historyReload:
            return "History reload"
        case .tokenDashboardOpen:
            return "Token dashboard open"
        case .tokenDashboardReload:
            return "Token dashboard reload"
        case .tokenDashboardPeriodChange:
            return "Token dashboard period"
        case .tokenDashboardBreakdownChange:
            return "Token dashboard breakdown"
        case .performanceDashboardOpen:
            return "Performance dashboard open"
        case .performanceDashboardReload:
            return "Performance dashboard reload"
        case .performanceDashboardModeChange:
            return "Performance dashboard mode"
        case .performanceDashboardPeriodChange:
            return "Performance dashboard period"
        case .performanceDashboardBreakdownChange:
            return "Performance dashboard breakdown"
        }
    }
}

enum AppPerformanceEventStatus: String, Codable, Sendable {
    case success
    case failed
    case cancelled
    case noData

    var displayText: String {
        switch self {
        case .success:
            return "Success"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .noData:
            return "No data"
        }
    }
}

struct AppPerformanceSpan: Equatable, Sendable {
    let id: UUID
    let kind: AppPerformanceEventKind
    let startedAt: Date
    let metadata: [String: String]
}

struct AppPerformanceEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: AppPerformanceEventKind
    let startedAt: Date
    let endedAt: Date
    let durationMilliseconds: Double
    let status: AppPerformanceEventStatus
    let metadata: [String: String]

    var displayTitle: String {
        kind.displayTitle
    }
}

struct AppPerformanceInstrumentationSummaryRow: Equatable, Identifiable, Sendable {
    let kind: AppPerformanceEventKind
    let eventCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let slowestMilliseconds: Double

    var id: AppPerformanceEventKind { kind }
}

struct AppPerformanceInstrumentationSummary: Equatable, Sendable {
    let generatedAt: Date
    let events: [AppPerformanceEvent]
    let lastEvent: AppPerformanceEvent?
    let slowestEvent: AppPerformanceEvent?
    let rows: [AppPerformanceInstrumentationSummaryRow]
    let lastErrorText: String?

    var eventCount: Int {
        events.count
    }
}

@MainActor
final class AppPerformanceInstrumentationStore: ObservableObject {
    static let defaultRetentionLimit = 500
    static let defaultRetentionAge: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var events: [AppPerformanceEvent]
    @Published private(set) var lastErrorText: String?

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let retentionLimit: Int
    private let retentionAge: TimeInterval

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        retentionLimit: Int = AppPerformanceInstrumentationStore.defaultRetentionLimit,
        retentionAge: TimeInterval = AppPerformanceInstrumentationStore.defaultRetentionAge
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.now = now
        self.makeUUID = makeUUID
        self.retentionLimit = retentionLimit
        self.retentionAge = retentionAge
        events = (try? Self.loadEvents(from: fileURL)) ?? []
        pruneAndPersist()
    }

    static let shared = AppPerformanceInstrumentationStore.applicationSupportStore()

    static func applicationSupportStore() -> AppPerformanceInstrumentationStore {
        let directoryURL = (try? UsageHistoryStore.applicationSupportDirectoryURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CodexStatusBar", isDirectory: true)
        return AppPerformanceInstrumentationStore(
            fileURL: directoryURL.appendingPathComponent("performance-diagnostics.json")
        )
    }

    func begin(
        _ kind: AppPerformanceEventKind,
        metadata: [String: String] = [:]
    ) -> AppPerformanceSpan {
        AppPerformanceSpan(
            id: makeUUID(),
            kind: kind,
            startedAt: now(),
            metadata: Self.sanitizedMetadata(metadata)
        )
    }

    func finish(
        _ span: AppPerformanceSpan?,
        status: AppPerformanceEventStatus = .success,
        metadata: [String: String] = [:]
    ) {
        guard let span else {
            return
        }

        let endedAt = now()
        let durationMilliseconds = max(endedAt.timeIntervalSince(span.startedAt) * 1_000, 0)
        var combinedMetadata = span.metadata
        for (key, value) in Self.sanitizedMetadata(metadata) {
            combinedMetadata[key] = value
        }

        record(
            AppPerformanceEvent(
                id: span.id,
                kind: span.kind,
                startedAt: span.startedAt,
                endedAt: endedAt,
                durationMilliseconds: durationMilliseconds,
                status: status,
                metadata: combinedMetadata
            )
        )
    }

    func record(
        kind: AppPerformanceEventKind,
        status: AppPerformanceEventStatus = .success,
        durationMilliseconds: Double,
        metadata: [String: String] = [:]
    ) {
        let endedAt = now()
        let startedAt = endedAt.addingTimeInterval(-max(durationMilliseconds, 0) / 1_000)
        record(
            AppPerformanceEvent(
                id: makeUUID(),
                kind: kind,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMilliseconds: max(durationMilliseconds, 0),
                status: status,
                metadata: Self.sanitizedMetadata(metadata)
            )
        )
    }

    func summary() -> AppPerformanceInstrumentationSummary {
        let currentEvents = pruned(events, now: now())
        let sortedEvents = currentEvents.sorted { $0.endedAt < $1.endedAt }
        let rows = Dictionary(grouping: sortedEvents, by: \.kind)
            .map { kind, events in
                let durations = events.map(\.durationMilliseconds).sorted()
                return AppPerformanceInstrumentationSummaryRow(
                    kind: kind,
                    eventCount: events.count,
                    p50Milliseconds: Self.percentile(durations, percentile: 0.50) ?? 0,
                    p95Milliseconds: Self.percentile(durations, percentile: 0.95) ?? 0,
                    slowestMilliseconds: durations.last ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.slowestMilliseconds == rhs.slowestMilliseconds {
                    return lhs.kind.displayTitle.localizedStandardCompare(rhs.kind.displayTitle) == .orderedAscending
                }

                return lhs.slowestMilliseconds > rhs.slowestMilliseconds
            }

        return AppPerformanceInstrumentationSummary(
            generatedAt: now(),
            events: sortedEvents,
            lastEvent: sortedEvents.last,
            slowestEvent: sortedEvents.max { $0.durationMilliseconds < $1.durationMilliseconds },
            rows: rows,
            lastErrorText: lastErrorText
        )
    }

    func exportData() throws -> Data? {
        guard !events.isEmpty else {
            return nil
        }

        return try Self.encodedData(for: pruned(events, now: now()))
    }

    func clear() {
        events = []
        lastErrorText = nil
        try? fileManager.removeItem(at: fileURL)
    }

    private func record(_ event: AppPerformanceEvent) {
        events.append(event)
        pruneAndPersist()
    }

    private func pruneAndPersist() {
        events = pruned(events, now: now())
        persist()
    }

    private func pruned(_ events: [AppPerformanceEvent], now: Date) -> [AppPerformanceEvent] {
        let cutoff = now.addingTimeInterval(-retentionAge)
        let retainedByAge = events
            .filter { $0.endedAt >= cutoff }
            .sorted { $0.endedAt < $1.endedAt }
        guard retainedByAge.count > retentionLimit else {
            return retainedByAge
        }

        return Array(retainedByAge.suffix(retentionLimit))
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encodedData(for: events).write(to: fileURL, options: .atomic)
            lastErrorText = nil
        } catch {
            lastErrorText = error.localizedDescription
        }
    }

    private static func loadEvents(from fileURL: URL) throws -> [AppPerformanceEvent] {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AppPerformanceEvent].self, from: data)
    }

    private static func encodedData(for events: [AppPerformanceEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(events)
    }

    static func sanitizedMetadata(_ metadata: [String: String]) -> [String: String] {
        let allowedKeys: Set<String> = [
            "dashboard",
            "mode",
            "range",
            "breakdown",
            "surface",
            "trigger",
            "cacheHit",
            "status",
            "rowCount",
            "pointCount",
            "seriesCount",
            "windowState",
            "chartKind",
            "window",
        ]

        return metadata.reduce(into: [:]) { partial, entry in
            guard allowedKeys.contains(entry.key),
                  let value = sanitizedMetadataValue(entry.value)
            else {
                return
            }

            partial[entry.key] = value
        }
    }

    private static func sanitizedMetadataValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              trimmed.range(of: "/") == nil,
              trimmed.range(of: "\\") == nil
        else {
            return nil
        }

        let allowedScalars = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "._-%:"))

        guard trimmed.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }) else {
            return nil
        }

        return trimmed
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        let clampedPercentile = min(max(percentile, 0), 1)
        let rank = Int(ceil(clampedPercentile * Double(values.count))) - 1
        return values[min(max(rank, 0), values.count - 1)]
    }
}
