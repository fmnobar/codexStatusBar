import CoreGraphics
import SQLite3
import XCTest

final class UsageHistoryStoreTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
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

    func testMigratesExistingRollupsWithoutPeakColumn() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("usage-history.sqlite3")
        try createLegacyHistoryDatabase(at: databaseURL)

        let store = try UsageHistoryStore(
            databaseURL: databaseURL,
            notificationCenter: NotificationCenter(),
            calendar: calendar
        )

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [42])
        XCTAssertEqual(points.map(\.peakUsedPercent), [42])
    }

    func testRollupsTrackLatestAndPeakUsedPercent() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T20:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T20:40:00Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [10])
        XCTAssertEqual(points.map(\.peakUsedPercent), [30])
    }

    func testDuplicateMinuteRollupsPreservePeakWhileUpdatingLatest() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T20:00:10Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: date("2026-04-14T20:00:50Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [25])
        XCTAssertEqual(points.map(\.peakUsedPercent), [30])
    }

    func testDuplicateMinuteConsumptionAdjustsRollupsWithoutDoubleCounting() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T19:50:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:10Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: date("2026-04-14T20:00:50Z"))

        let points = try store.points(range: .week, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [10, 25])
        XCTAssertEqual(points.map(\.consumedPercent), [0, 15])
    }

    func testRawSamplesCompactButRollupsRemain() throws {
        let store = try makeStore()
        let oldDate = date("2026-01-10T12:00:00Z")
        let currentDate = date("2026-04-14T20:00:00Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: oldDate)
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: currentDate)

        let oldDayPoints = try store.points(range: .day, window: .sevenDay, now: date("2026-01-10T13:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: currentDate, calendar: calendar)

        XCTAssertEqual(oldDayPoints.map(\.usedPercent), [12])
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

    func testHasAnyHistoryReflectsSamplesAndClear() throws {
        let store = try makeStore()

        XCTAssertFalse(try store.hasAnyHistory())

        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        XCTAssertTrue(try store.hasAnyHistory())

        try store.clearHistory()
        XCTAssertFalse(try store.hasAnyHistory())
    }

    func testDatabaseInfoReportsURLAndByteSize() throws {
        let (store, databaseURL) = try makeTemporaryStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))

        let info = try store.databaseInfo()

        XCTAssertEqual(info.databaseURL, databaseURL)
        XCTAssertGreaterThan(info.totalByteSize, 0)
    }

    func testRawRetentionDefaultsAndPersists() throws {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .fourteenDays)

        UsageHistoryRawRetentionStore.save(.ninetyDays, to: defaults)

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .ninetyDays)
    }

    func testRecordUsesUpdatedRawRetentionProvider() throws {
        var retention = UsageHistoryRawRetention.thirtyDays.timeInterval
        let store = try UsageHistoryStore.inMemory(
            notificationCenter: NotificationCenter(),
            calendar: calendar,
            rawRetentionProvider: { retention }
        )
        let oldDate = date("2026-04-01T12:00:00Z")
        let currentDate = date("2026-04-14T20:00:00Z")

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: oldDate)
        retention = UsageHistoryRawRetention.sevenDays.timeInterval
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: currentDate)

        let oldDayPoints = try store.points(range: .day, window: .sevenDay, now: date("2026-04-01T13:00:00Z"), calendar: calendar)
        let yearPoints = try store.points(range: .year, window: .sevenDay, now: currentDate, calendar: calendar)

        XCTAssertEqual(oldDayPoints.map(\.usedPercent), [12])
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 12 })
        XCTAssertTrue(yearPoints.contains { $0.usedPercent == 40 })
    }

    func testHistoryBoundsUseRequestedRollupGranularity() throws {
        let store = try makeStore()

        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-01T12:30:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-14T20:00:00Z"))

        let hourlyBounds = try store.historyBounds(window: .sevenDay, granularity: .hour)
        let dailyBounds = try store.historyBounds(window: .sevenDay, granularity: .day)

        XCTAssertEqual(hourlyBounds?.earliest, date("2026-04-01T12:30:00Z"))
        XCTAssertEqual(hourlyBounds?.latest, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(dailyBounds?.earliest, date("2026-04-01T12:30:00Z"))
        XCTAssertEqual(dailyBounds?.latest, date("2026-04-14T20:00:00Z"))
    }

    func testBackupExportProducesImportableDatabase() throws {
        let (sourceStore, _) = try makeTemporaryStore()
        try sourceStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")

        try sourceStore.exportBackup(to: backupURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let (destinationStore, _) = try makeTemporaryStore()
        try destinationStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 80)), at: date("2026-04-14T20:00:00Z"))

        try destinationStore.importBackup(from: backupURL)
        let points = try destinationStore.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [20])
    }

    func testImportBackupReplacesHistoryAndNotifies() throws {
        let (sourceStore, _) = try makeTemporaryStore()
        try sourceStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")
        try sourceStore.exportBackup(to: backupURL)
        let notificationCenter = NotificationCenter()
        let (destinationStore, _) = try makeTemporaryStore(notificationCenter: notificationCenter)
        try destinationStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 80)), at: date("2026-04-14T20:00:00Z"))
        let expectation = expectation(description: "Import posts history change notification")
        let observer = notificationCenter.addObserver(
            forName: UsageHistoryStore.didChangeNotification,
            object: destinationStore,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        try destinationStore.importBackup(from: backupURL)
        wait(for: [expectation], timeout: 1)
        let points = try destinationStore.points(range: .day, window: .sevenDay, now: date("2026-04-14T21:00:00Z"), calendar: calendar)

        XCTAssertEqual(points.map(\.usedPercent), [20])
    }

    func testInvalidBackupImportThrowsUserFacingFailure() throws {
        let (store, _) = try makeTemporaryStore()
        let invalidURL = try makeTemporaryDirectory().appendingPathComponent("invalid.sqlite3")
        try Data("not a sqlite backup".utf8).write(to: invalidURL)

        XCTAssertThrowsError(try store.importBackup(from: invalidURL)) { error in
            XCTAssertEqual(error.localizedDescription, UsageHistoryStoreError.invalidBackup.localizedDescription)
        }
    }

    @MainActor
    func testSettingsViewModelFormatsDatabaseInfoAndPersistsRetention() throws {
        let defaults = makeIsolatedDefaults()
        let (store, databaseURL) = try makeTemporaryStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))

        let viewModel = DataManagementSettingsViewModel(store: store, defaults: defaults)

        XCTAssertEqual(viewModel.databasePathText, databaseURL.path)
        XCTAssertNotEqual(viewModel.databaseSizeText, "--")

        viewModel.selectedRetention = .ninetyDays

        XCTAssertEqual(UsageHistoryRawRetentionStore.load(from: defaults), .ninetyDays)
        XCTAssertEqual(viewModel.statusMessage, "Raw sample retention updated.")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testSettingsViewModelExportImportClearAndFailureMessages() throws {
        let (store, _) = try makeTemporaryStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let viewModel = DataManagementSettingsViewModel(store: store, defaults: makeIsolatedDefaults())
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("backup.sqlite3")

        viewModel.exportBackup(to: backupURL)

        XCTAssertEqual(viewModel.statusMessage, "Backup exported.")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        viewModel.clearHistory()

        XCTAssertEqual(viewModel.statusMessage, "History cleared.")
        XCTAssertFalse(try store.hasAnyHistory())

        viewModel.importBackup(from: backupURL)

        XCTAssertEqual(viewModel.statusMessage, "Backup imported.")
        XCTAssertTrue(try store.hasAnyHistory())

        let invalidURL = try makeTemporaryDirectory().appendingPathComponent("invalid.sqlite3")
        try Data("not a sqlite backup".utf8).write(to: invalidURL)
        viewModel.importBackup(from: invalidURL)

        XCTAssertEqual(viewModel.errorMessage, "Backup could not be imported.")
        XCTAssertNil(viewModel.statusMessage)
    }

    @MainActor
    func testHistoryPresentationDefaultsToIndependentSignals() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.reload()

        XCTAssertEqual(viewModel.chartSemantics, .independentSignals)
        XCTAssertEqual(viewModel.selectedRange, .month)
        XCTAssertEqual(viewModel.selectedMetric, .capacityLeft)
        XCTAssertEqual(viewModel.chartSubtitle, "Capacity left by day")
        XCTAssertEqual(viewModel.chartYAxisTitle, "Left %")
        XCTAssertEqual(viewModel.chartYDomain, 0...100)
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(viewModel.visibleBarPoints.map { $0.value(for: viewModel.selectedMetric) }, [80, 93])
        XCTAssertTrue(viewModel.visibleContributorPoints.isEmpty)

        viewModel.selectedMetric = .usage

        XCTAssertEqual(viewModel.chartSubtitle, "Usage consumed by day")
        XCTAssertEqual(viewModel.chartYAxisTitle, "Consumed %")
        XCTAssertEqual(viewModel.chartYDomain, 0...50)
        XCTAssertEqual(viewModel.visibleBarPoints.map { $0.value(for: viewModel.selectedMetric) }, [0, 0])
    }

    @MainActor
    func testHistoryPeriodDefaultsUseCalendarBoundaries() throws {
        var mondayCalendar = calendar!
        mondayCalendar.firstWeekday = 2
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-15T14:45:00Z") },
            calendar: mondayCalendar
        )

        viewModel.selectedRange = .day

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-15T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedPeriod.end, date("2026-04-16T00:00:00Z"))

        viewModel.selectedRange = .week

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-13T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedPeriod.end, date("2026-04-20T00:00:00Z"))

        viewModel.selectedRange = .month

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-04-01T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedPeriod.end, date("2026-05-01T00:00:00Z"))

        viewModel.selectedRange = .year

        XCTAssertEqual(viewModel.selectedPeriod.start, date("2026-01-01T00:00:00Z"))
        XCTAssertEqual(viewModel.selectedPeriod.end, date("2027-01-01T00:00:00Z"))
    }

    @MainActor
    func testHistoryPeriodNavigationRespectsBoundsAndCurrentPeriod() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-12T09:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.reload()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-14T00:00:00Z"))
        XCTAssertFalse(viewModel.canGoToNextPeriod)
        XCTAssertTrue(viewModel.canGoToPreviousPeriod)

        viewModel.goToPreviousPeriod()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-13T00:00:00Z"))
        XCTAssertTrue(viewModel.canGoToNextPeriod)
        XCTAssertTrue(viewModel.canGoToPreviousPeriod)

        viewModel.goToPreviousPeriod()

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-12T00:00:00Z"))
        XCTAssertFalse(viewModel.canGoToPreviousPeriod)

        viewModel.selectedRange = .month

        XCTAssertEqual(viewModel.selectedPeriodStart, date("2026-04-01T00:00:00Z"))
    }

    @MainActor
    func testHistoryPeriodJumpToCurrentAndNavigationHints() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2025-12-31T09:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-28T10:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-28T15:00:00Z") },
            calendar: calendar
        )

        for range in UsageHistoryRange.allCases {
            viewModel.selectedRange = range
            viewModel.reload()

            let periodName = range.displayTitle.lowercased()
            XCTAssertTrue(viewModel.isCurrentPeriod)
            XCTAssertFalse(viewModel.canJumpToCurrentPeriod)
            XCTAssertFalse(viewModel.canGoToNextPeriod)
            XCTAssertEqual(viewModel.currentPeriodHelpText, "Already showing the current \(periodName)")
            XCTAssertEqual(viewModel.currentPeriodAccessibilityLabel, "Already showing the current \(periodName)")
            XCTAssertEqual(viewModel.nextPeriodHelpText, "Already showing the current \(periodName)")
            XCTAssertEqual(viewModel.nextPeriodAccessibilityLabel, "Already showing the current \(periodName)")

            XCTAssertTrue(viewModel.canGoToPreviousPeriod)
            XCTAssertEqual(viewModel.previousPeriodHelpText, "Show previous \(periodName)")
            XCTAssertEqual(viewModel.previousPeriodAccessibilityLabel, "Previous \(range.displayTitle)")

            viewModel.goToPreviousPeriod()

            XCTAssertFalse(viewModel.isCurrentPeriod)
            XCTAssertTrue(viewModel.canJumpToCurrentPeriod)
            XCTAssertTrue(viewModel.canGoToNextPeriod)
            XCTAssertEqual(viewModel.currentPeriodHelpText, "Jump to current \(periodName)")
            XCTAssertEqual(viewModel.currentPeriodAccessibilityLabel, "Jump to current \(periodName)")
            XCTAssertEqual(viewModel.nextPeriodHelpText, "Show next \(periodName)")
            XCTAssertEqual(viewModel.nextPeriodAccessibilityLabel, "Next \(range.displayTitle)")

            viewModel.jumpToCurrentPeriod()

            XCTAssertTrue(viewModel.isCurrentPeriod)
            XCTAssertEqual(viewModel.selectedPeriodStart, range.period(containing: date("2026-04-28T15:00:00Z"), calendar: calendar).start)
        }
    }

    @MainActor
    func testHistoryPeriodPreviousHintExplainsNoEarlierHistory() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-28T10:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-28T15:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.reload()

        XCTAssertFalse(viewModel.canGoToPreviousPeriod)
        XCTAssertEqual(viewModel.previousPeriodHelpText, "No earlier history for this limit")
        XCTAssertEqual(viewModel.previousPeriodAccessibilityLabel, "No earlier history for this limit")
    }

    @MainActor
    func testHistoryExportFilenameUsesSelectedPeriodWindowAndMetric() throws {
        var sundayCalendar = calendar!
        sundayCalendar.firstWeekday = 1
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-28T15:00:00Z") },
            calendar: sundayCalendar
        )

        let periodExpectations: [(UsageHistoryRange, String)] = [
            (.day, "2026-04-28"),
            (.week, "2026-04-26"),
            (.month, "2026-04"),
            (.year, "2026"),
        ]
        let windowExpectations: [(UsageLimitWindow, String)] = [
            (.fiveHour, "5h"),
            (.sevenDay, "7d"),
        ]
        let metricExpectations: [(UsageHistoryMetric, String)] = [
            (.capacityLeft, "capacity-left"),
            (.usage, "usage"),
        ]

        for (range, periodToken) in periodExpectations {
            viewModel.selectedRange = range
            for (window, windowToken) in windowExpectations {
                viewModel.selectedWindow = window
                for (metric, metricToken) in metricExpectations {
                    viewModel.selectedMetric = metric

                    XCTAssertEqual(
                        viewModel.exportFilename,
                        "codex-usage-\(range.rawValue)-\(periodToken)-\(windowToken)-\(metricToken).csv"
                    )
                }
            }
        }
    }

    @MainActor
    func testHistoryXAxisLabelsUseSelectedRangeFormats() throws {
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-14T17:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        let dayLabel = viewModel.chartXAxisLabel(for: date("2026-04-14T17:00:00Z"))

        XCTAssertTrue(dayLabel.contains("PM"))
        XCTAssertFalse(dayLabel.contains("Apr"))
        XCTAssertFalse(dayLabel.contains("14"))

        viewModel.selectedRange = .week
        XCTAssertEqual(viewModel.chartXAxisLabel(for: date("2026-04-14T00:00:00Z")), "Tue")

        viewModel.selectedRange = .month
        XCTAssertEqual(viewModel.chartXAxisLabel(for: date("2026-04-14T00:00:00Z")), "14")

        viewModel.selectedRange = .year
        XCTAssertEqual(viewModel.chartXAxisLabel(for: date("2026-04-01T00:00:00Z")), "Apr")
    }

    @MainActor
    func testHistoryXAxisLabelValuesAreCenteredInBucketsForAllRanges() throws {
        var sundayCalendar = calendar!
        sundayCalendar.firstWeekday = 1
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-14T17:00:00Z") },
            calendar: sundayCalendar
        )

        viewModel.selectedRange = .day
        XCTAssertEqual(
            viewModel.chartXAxisLabelValues,
            [
                date("2026-04-14T00:30:00Z"),
                date("2026-04-14T04:30:00Z"),
                date("2026-04-14T08:30:00Z"),
                date("2026-04-14T12:30:00Z"),
                date("2026-04-14T16:30:00Z"),
                date("2026-04-14T20:30:00Z"),
            ]
        )

        viewModel.selectedRange = .week
        XCTAssertEqual(
            viewModel.chartXAxisLabelValues,
            [
                date("2026-04-12T12:00:00Z"),
                date("2026-04-13T12:00:00Z"),
                date("2026-04-14T12:00:00Z"),
                date("2026-04-15T12:00:00Z"),
                date("2026-04-16T12:00:00Z"),
                date("2026-04-17T12:00:00Z"),
                date("2026-04-18T12:00:00Z"),
            ]
        )

        viewModel.selectedRange = .month
        XCTAssertEqual(
            viewModel.chartXAxisLabelValues,
            [
                date("2026-04-01T12:00:00Z"),
                date("2026-04-06T12:00:00Z"),
                date("2026-04-11T12:00:00Z"),
                date("2026-04-16T12:00:00Z"),
                date("2026-04-21T12:00:00Z"),
                date("2026-04-26T12:00:00Z"),
            ]
        )

        viewModel.selectedRange = .year
        let monthStarts = (1...12).compactMap { month in
            sundayCalendar.date(from: DateComponents(
                calendar: sundayCalendar,
                timeZone: sundayCalendar.timeZone,
                year: 2026,
                month: month,
                day: 1
            ))
        }
        let expectedYearLabelValues = monthStarts.map { monthStart in
            let monthEnd = sundayCalendar.date(byAdding: .month, value: 1, to: monthStart)!
            return monthStart.addingTimeInterval(monthEnd.timeIntervalSince(monthStart) / 2)
        }
        XCTAssertEqual(viewModel.chartXAxisLabelValues, expectedYearLabelValues)
    }

    @MainActor
    func testHistoryChartDomainAddsHalfBucketPaddingForEdgeLabels() throws {
        var sundayCalendar = calendar!
        sundayCalendar.firstWeekday = 1
        let viewModel = UsageHistoryViewModel(
            store: try makeStore(),
            now: { self.date("2026-04-14T17:00:00Z") },
            calendar: sundayCalendar
        )

        viewModel.selectedRange = .day
        XCTAssertEqual(viewModel.chartDomainStart, date("2026-04-13T23:30:00Z"))
        XCTAssertEqual(viewModel.chartDomainEnd, date("2026-04-15T00:30:00Z"))

        viewModel.selectedRange = .week
        XCTAssertEqual(viewModel.chartDomainStart, date("2026-04-11T12:00:00Z"))
        XCTAssertEqual(viewModel.chartDomainEnd, date("2026-04-19T12:00:00Z"))

        viewModel.selectedRange = .month
        XCTAssertEqual(viewModel.chartDomainStart, date("2026-03-31T12:00:00Z"))
        XCTAssertEqual(viewModel.chartDomainEnd, date("2026-05-01T12:00:00Z"))

        viewModel.selectedRange = .year
        XCTAssertEqual(viewModel.chartDomainStart, date("2025-12-16T12:00:00Z"))
        XCTAssertEqual(viewModel.chartDomainEnd, date("2027-01-16T12:00:00Z"))
    }

    @MainActor
    func testComparableHistoryPresentationUsesContributorsAndAggregateReference() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            chartSemantics: .comparableContributors,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedMetric = .usage
        viewModel.reload()

        XCTAssertEqual(viewModel.chartSubtitle, "Usage consumed by hour")
        XCTAssertEqual(viewModel.visibleContributorPoints.map(\.bucketID), ["codex_gpt55"])
        XCTAssertEqual(viewModel.visibleAggregateReferencePoints.map(\.bucketID), ["codex"])
        XCTAssertEqual(viewModel.visibleBarPoints.map(\.bucketID), ["codex_gpt55"])
    }

    @MainActor
    func testDayChartGroupsHourlyRollupsIntoHourlyBuckets() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 5)), at: date("2026-04-14T17:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 9)), at: date("2026-04-14T17:55:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-14T18:10:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T20:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T17:00:00Z"),
            date("2026-04-14T18:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [9, 12])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .capacityLeft) }, [91, 88])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .usage) }, [4, 3])
    }

    @MainActor
    func testWeekChartGroupsHourlyRollupsIntoDailyBucketsAndShowsResetCapacity() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 90)), at: date("2026-04-12T17:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 70)), at: date("2026-04-13T18:10:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-16T09:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-17T20:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .week
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-12T00:00:00Z"),
            date("2026-04-13T00:00:00Z"),
            date("2026-04-16T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .capacityLeft) }, [10, 30, 90])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: .usage) }, [0, 70, 10])
    }

    @MainActor
    func testMonthAndYearChartBucketGranularity() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 15)), at: date("2026-01-10T12:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 50)), at: date("2026-04-14T12:00:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 60)), at: date("2026-04-15T12:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-30T20:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .month
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-04-14T00:00:00Z"),
            date("2026-04-15T00:00:00Z"),
        ])

        viewModel.selectedRange = .year
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.bucketStart), [
            date("2026-01-01T00:00:00Z"),
            date("2026-04-01T00:00:00Z"),
        ])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [15, 60])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.peakUsedPercent), [15, 60])
    }

    @MainActor
    func testUsageMetricUsesObservedConsumptionWithinBucket() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 30)), at: date("2026-04-14T19:55:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 40)), at: date("2026-04-14T20:05:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 42)), at: date("2026-04-14T20:45:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedMetric = .usage
        viewModel.reload()

        XCTAssertEqual(viewModel.visibleChartPoints.map(\.latestUsedPercent), [30, 42])
        XCTAssertEqual(viewModel.visibleChartPoints.map(\.peakUsedPercent), [30, 42])
        XCTAssertEqual(viewModel.visibleChartPoints.map { $0.value(for: viewModel.selectedMetric) }, [0, 12])
    }

    @MainActor
    func testChartCSVUsesVisibleBucketedDatasetAndSelectedMetric() throws {
        let store = try makeStore()
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 12)), at: date("2026-04-14T19:30:00Z"))
        try store.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 20)), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.selectedRange = .day
        viewModel.selectedMetric = .usage
        viewModel.reload()
        let csv = viewModel.chartCSV()

        XCTAssertTrue(csv.contains("range,limit,metric,bucket_start,bucket_end,bucket_id,bucket_name,bucket_kind,percent_value"))
        XCTAssertTrue(csv.contains("day,sevenDay,usage,2026-04-14T20:00:00Z,2026-04-14T21:00:00Z,codex,All models,aggregate,8.000"))
    }

    @MainActor
    func testHoverSelectionChoosesNearestTimestampAndGroupsVisiblePoints() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 25, modelSevenDay: 9), at: date("2026-04-14T20:10:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        viewModel.reload()

        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:07:00Z"), xPosition: 180)

        XCTAssertEqual(viewModel.hoverSelection?.bucketStart, date("2026-04-14T20:00:00Z"))
        XCTAssertEqual(viewModel.hoverSelection?.points.map(\.bucketID), ["codex", "codex_gpt55"])
        XCTAssertEqual(viewModel.hoverSelection?.xPosition, 180)
    }

    @MainActor
    func testHoverSelectionClearsWhenVisibleSeriesChanges() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        viewModel.reload()
        viewModel.updateHoverSelection(nearestTo: date("2026-04-14T20:00:00Z"), xPosition: 80)

        viewModel.setSeries("codex_gpt55", isSelected: false)

        XCTAssertNil(viewModel.hoverSelection)
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])
    }

    @MainActor
    func testSeriesSelectorKeepsAggregateSelectedAndFiltersModels() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7, extraModelSevenDay: 4), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()

        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertTrue(viewModel.selectedSeriesIDs.contains("codex"))

        viewModel.setSeries("codex", isSelected: false)
        XCTAssertTrue(viewModel.selectedSeriesIDs.contains("codex"))

        viewModel.seriesSearchText = "5.5"
        XCTAssertEqual(viewModel.filteredSeries.map(\.id), ["codex", "codex_gpt55"])
    }

    @MainActor
    func testSparkModelIsHiddenByDefault() throws {
        let store = try makeStore()
        try store.record(
            snapshot: sparkUsageSnapshot(aggregateSevenDay: 20, sparkSevenDay: 2),
            at: date("2026-04-14T20:00:00Z")
        )
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )

        viewModel.reload()

        XCTAssertEqual(viewModel.sortedSeries.map(\.id), ["codex", "codex_gpt53_spark"])
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])

        viewModel.selectAllSeries()

        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex", "codex_gpt53_spark"])
    }

    @MainActor
    func testSeriesSelectorSelectAllAndClearModels() throws {
        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7, extraModelSevenDay: 4), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()

        viewModel.clearModelSeries()
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex"])
        XCTAssertEqual(viewModel.visiblePoints.map(\.bucketID), ["codex"])
        XCTAssertFalse(viewModel.hasSelectedModels)

        viewModel.selectAllSeries()
        XCTAssertEqual(viewModel.selectedSeriesIDs, ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertEqual(viewModel.seriesSelectionSummary, "3 of 3 selected")
    }

    @MainActor
    func testEmptyStateDistinguishesNoHistoryAndNoDataForSelection() throws {
        let emptyStore = try makeStore()
        let emptyViewModel = UsageHistoryViewModel(
            store: emptyStore,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        emptyViewModel.reload()

        XCTAssertEqual(emptyViewModel.emptyStatePresentation.kind, .noHistory)

        let store = try makeStore()
        try store.record(snapshot: usageSnapshot(aggregateSevenDay: 20, modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-16T21:00:00Z") },
            calendar: calendar
        )
        viewModel.selectedRange = .day
        viewModel.reload()

        XCTAssertTrue(viewModel.hasAnyRecordedHistory)
        XCTAssertEqual(viewModel.emptyStatePresentation.kind, .noDataForSelection)
    }

    @MainActor
    func testUsageAxisDefaultsToFiftyAndExpandsForHighConsumption() throws {
        let lowUsageStore = try makeStore()
        try lowUsageStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T19:55:00Z"))
        try lowUsageStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 25)), at: date("2026-04-14T20:05:00Z"))
        let lowUsageViewModel = UsageHistoryViewModel(
            store: lowUsageStore,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        lowUsageViewModel.selectedRange = .day
        lowUsageViewModel.selectedMetric = .usage
        lowUsageViewModel.reload()

        XCTAssertEqual(lowUsageViewModel.chartYDomain, 0...50)

        let highUsageStore = try makeStore()
        try highUsageStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 10)), at: date("2026-04-14T19:55:00Z"))
        try highUsageStore.record(snapshot: CodexUsageSnapshot.aggregateOnly(displaySnapshot: rateLimitSnapshot(sevenDayUsedPercent: 70)), at: date("2026-04-14T20:05:00Z"))
        let highUsageViewModel = UsageHistoryViewModel(
            store: highUsageStore,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        highUsageViewModel.selectedRange = .day
        highUsageViewModel.selectedMetric = .usage
        highUsageViewModel.reload()

        XCTAssertEqual(highUsageViewModel.chartYDomain, 0...100)
    }

    @MainActor
    func testHiddenSeriesStateWhenVisiblePointsAreEmpty() throws {
        let store = try makeStore()
        try store.record(snapshot: modelOnlyUsageSnapshot(modelSevenDay: 7), at: date("2026-04-14T20:00:00Z"))
        let viewModel = UsageHistoryViewModel(
            store: store,
            now: { self.date("2026-04-14T21:00:00Z") },
            calendar: calendar
        )
        viewModel.reload()

        viewModel.clearModelSeries()

        XCTAssertTrue(viewModel.hasHistory)
        XCTAssertTrue(viewModel.visiblePoints.isEmpty)
        XCTAssertEqual(viewModel.emptyStatePresentation.kind, .hiddenSeries)
    }

    func testHistoryWindowFrameClampsOffscreenSavedFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let restoredFrame = CGRect(x: -320, y: -80, width: 880, height: 640)

        let frame = UsageHistoryWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 700, height: 520),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 880, height: 640))
    }

    func testHistoryWindowFrameFitsVisibleScreenBeforeMinimumSize() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 640, height: 480)
        let restoredFrame = CGRect(x: 80, y: 20, width: 500, height: 300)

        let frame = UsageHistoryWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 700, height: 520),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
    }

    private func makeStore() throws -> UsageHistoryStore {
        try UsageHistoryStore.inMemory(notificationCenter: NotificationCenter(), calendar: calendar)
    }

    private func makeTemporaryStore(
        notificationCenter: NotificationCenter = NotificationCenter()
    ) throws -> (store: UsageHistoryStore, databaseURL: URL) {
        let directoryURL = try makeTemporaryDirectory()
        let databaseURL = directoryURL.appendingPathComponent("usage-history.sqlite3")
        return (
            try UsageHistoryStore(
                databaseURL: databaseURL,
                notificationCenter: notificationCenter,
                calendar: calendar
            ),
            databaseURL
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL
    }

    private func createLegacyHistoryDatabase(at databaseURL: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let database else {
            XCTFail("Expected legacy database to open")
            return
        }
        defer { sqlite3_close(database) }

        let legacyTimestamp = Int64(date("2026-04-14T20:30:00Z").timeIntervalSince1970)
        let legacyPeriodStart = Int64(date("2026-04-14T20:00:00Z").timeIntervalSince1970)
        let sql = """
        CREATE TABLE usage_samples (
            bucket_id TEXT NOT NULL,
            bucket_name TEXT NOT NULL,
            bucket_kind TEXT NOT NULL,
            window TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            used_percent INTEGER NOT NULL,
            reset_at INTEGER,
            PRIMARY KEY (bucket_id, window, timestamp)
        );
        CREATE TABLE usage_rollups (
            granularity TEXT NOT NULL,
            bucket_id TEXT NOT NULL,
            bucket_name TEXT NOT NULL,
            bucket_kind TEXT NOT NULL,
            window TEXT NOT NULL,
            period_start INTEGER NOT NULL,
            sample_timestamp INTEGER NOT NULL,
            used_percent INTEGER NOT NULL,
            reset_at INTEGER,
            PRIMARY KEY (granularity, bucket_id, window, period_start)
        );
        INSERT INTO usage_rollups (
            granularity, bucket_id, bucket_name, bucket_kind, window,
            period_start, sample_timestamp, used_percent, reset_at
        ) VALUES (
            'hour', 'codex', 'All models', 'aggregate', 'sevenDay',
            \(legacyPeriodStart), \(legacyTimestamp), 42, NULL
        );
        """

        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            XCTFail(message)
        }
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "CodexUsageMenuBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func usageSnapshot(
        aggregateSevenDay: Int,
        modelSevenDay: Int,
        extraModelSevenDay: Int? = nil
    ) -> CodexUsageSnapshot {
        let aggregateSnapshot = rateLimitSnapshot(sevenDayUsedPercent: aggregateSevenDay)
        let modelSnapshot = rateLimitSnapshot(sevenDayUsedPercent: modelSevenDay)
        var buckets = [
            CodexUsageBucket(id: "codex", name: "All models", kind: .aggregate, snapshot: aggregateSnapshot),
            CodexUsageBucket(id: "codex_gpt55", name: "GPT-5.5", kind: .model, snapshot: modelSnapshot),
        ]

        if let extraModelSevenDay {
            buckets.append(
                CodexUsageBucket(
                    id: "codex_gpt54",
                    name: "GPT-5.4",
                    kind: .model,
                    snapshot: rateLimitSnapshot(sevenDayUsedPercent: extraModelSevenDay)
                )
            )
        }

        return CodexUsageSnapshot(
            displaySnapshot: aggregateSnapshot,
            buckets: buckets
        )
    }

    private func sparkUsageSnapshot(aggregateSevenDay: Int, sparkSevenDay: Int) -> CodexUsageSnapshot {
        let aggregateSnapshot = rateLimitSnapshot(sevenDayUsedPercent: aggregateSevenDay)
        let sparkSnapshot = rateLimitSnapshot(sevenDayUsedPercent: sparkSevenDay)
        return CodexUsageSnapshot(
            displaySnapshot: aggregateSnapshot,
            buckets: [
                CodexUsageBucket(id: "codex", name: "All models", kind: .aggregate, snapshot: aggregateSnapshot),
                CodexUsageBucket(
                    id: "codex_gpt53_spark",
                    name: "GPT-5.3-Codex-Spark",
                    kind: .model,
                    snapshot: sparkSnapshot
                ),
            ]
        )
    }

    private func modelOnlyUsageSnapshot(modelSevenDay: Int) -> CodexUsageSnapshot {
        let snapshot = rateLimitSnapshot(sevenDayUsedPercent: modelSevenDay)
        return CodexUsageSnapshot(
            displaySnapshot: CodexRateLimitSnapshot(
                primary: snapshot.primary,
                secondary: nil
            ),
            buckets: [
                CodexUsageBucket(id: "codex_gpt55", name: "GPT-5.5", kind: .model, snapshot: snapshot),
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
