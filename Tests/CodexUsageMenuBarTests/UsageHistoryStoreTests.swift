import XCTest

final class UsageHistoryStoreTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    func testRecordsAggregateAndModelSamples() throws {
        let store = try makeStore()
        let now = date("2026-04-14T20:00:10Z")

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: now)

        let points = try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(points.map(\.bucketName), ["All models", "GPT-5.5"])
        XCTAssertEqual(points.map(\.usedPercent), [20, 7])
        XCTAssertEqual(points.map(\.timestamp), [date("2026-04-14T20:00:00Z"), date("2026-04-14T20:00:00Z")])
    }

    func testUpsertsDuplicateMinuteSamples() throws {
        let store = try makeStore()
        let first = date("2026-04-14T20:00:10Z")
        let second = date("2026-04-14T20:00:50Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: first)
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: second)

        let points = try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.usedPercent, 25)
        XCTAssertEqual(points.first?.timestamp, date("2026-04-14T20:00:00Z"))
    }

    func testWeekMonthAndYearQueriesUseRollups() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T20:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T20:40:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 45)), at: date("2026-04-15T08:00:00Z"))

        let weekPoints = try store.points(range: .week, window: .sevenDay, now: date("2026-04-15T09:00:00Z"), calendar: calendar)
        let monthPoints = try store.points(range: .month, window: .sevenDay, now: date("2026-04-15T09:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: date("2026-04-15T09:00:00Z"), calendar: calendar)

        XCTAssertEqual(weekPoints.map(\.usedPercent), [30, 45])
        XCTAssertEqual(monthPoints.map(\.usedPercent), [30, 45])
        XCTAssertEqual(yearPoints.map(\.usedPercent), [30, 45])
    }

    func testRawSamplesCompactButRollupsRemain() throws {
        let store = try makeStore()
        let oldDate = date("2026-01-10T12:00:00Z")
        let currentDate = date("2026-04-14T20:00:00Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: oldDate)
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: currentDate)

        let oldRawPoints = try store.points(range: .day, window: .sevenDay, now: date("2026-01-10T13:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: currentDate, calendar: calendar)

        XCTAssertTrue(oldRawPoints.isEmpty)
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 12 })
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 40 })
    }

    func testClearHistoryDeletesSamplesAndRollups() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        try store.clearHistory()

        XCTAssertTrue(try store.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar).isEmpty)
        XCTAssertTrue(try store.points(range: .year, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar).isEmpty)
    }

    func testExportsCSVRows() throws {
        let store = try makeStore()

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))

        let csv = try store.csv(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertTrue(csv.contains("timestamp,bucket_id,bucket_name,bucket_kind,window,used_percent"))
        XCTAssertTrue(csv.contains("2026-04-14T20:00:00Z,codex,All models,aggregate,sevenDay,20.000"))
        XCTAssertTrue(csv.contains("2026-04-14T20:00:00Z,codex_gpt55,GPT-5.5,model,sevenDay,7.000"))
    }

    private func makeStore() throws -> UsageHistoryStore {
        try UsageHistoryStore.inMemory(notificationCenter: NotificationCenter(), calendar: calendar)
    }

    private func usageSnapshot(aggregateSevenDay: Int, modelSevenDay: Int) -> CodexUsageSnapshot {
        let aggregateSnapshot = rateLimitSnapshot(sevenDayUsedPercent: aggregateSevenDay)
        let modelSnapshot = rateLimitSnapshot(sevenDayUsedPercent: modelSevenDay)

        return CodexUsageSnapshot(
            displaySnapshot: aggregateSnapshot,
            buckets: [
                CodexUsageBucket(id: "codex", name: "All models", kind: .aggregate, snapshot: aggregateSnapshot),
                CodexUsageBucket(id: "codex_gpt55", name: "GPT-5.5", kind: .model, snapshot: modelSnapshot),
            ]
        )
    }

    private func rateLimitSnapshot(sevenDayUsedPercent: Int) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 5, windowDurationMinutes: 300, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: sevenDayUsedPercent, windowDurationMinutes: 10080, resetsAt: nil)
        )
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
