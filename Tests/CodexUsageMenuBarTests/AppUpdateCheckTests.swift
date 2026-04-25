import XCTest

@MainActor
final class AppUpdateCheckTests: XCTestCase {
    func testLatestReleaseClientDecodesSuccessfulPayload() async throws {
        let publishedAt = date("2026-04-24T18:00:00Z")
        let data = Data("""
        {
          "tag_name": "v1.2.3",
          "name": "Codex Status Bar 1.2.3",
          "html_url": "https://github.com/fmnobar/codexStatusBar/releases/tag/v1.2.3",
          "published_at": "2026-04-24T18:00:00Z"
        }
        """.utf8)
        let client = GitHubLatestReleaseClient { request in
            XCTAssertEqual(request.url?.absoluteString, GitHubLatestReleaseClient.defaultEndpoint.absoluteString)
            return (data, Self.response(statusCode: 200))
        }

        let release = try await client.latestRelease()

        XCTAssertEqual(release.tagName, "v1.2.3")
        XCTAssertEqual(release.name, "Codex Status Bar 1.2.3")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/fmnobar/codexStatusBar/releases/tag/v1.2.3")
        XCTAssertEqual(release.publishedAt, publishedAt)
    }

    func testLatestReleaseClientMaps404ToNoPublishedRelease() async {
        let client = GitHubLatestReleaseClient { _ in
            (Data(), Self.response(statusCode: 404))
        }

        await assertUpdateClientError(.noPublishedRelease) {
            _ = try await client.latestRelease()
        }
    }

    func testLatestReleaseClientMapsNonSuccessStatus() async {
        let client = GitHubLatestReleaseClient { _ in
            (Data(), Self.response(statusCode: 500))
        }

        await assertUpdateClientError(.requestFailed(statusCode: 500)) {
            _ = try await client.latestRelease()
        }
    }

    func testLatestReleaseClientMapsMalformedJSON() async {
        let client = GitHubLatestReleaseClient { _ in
            (Data(#"{"tag_name": 7}"#.utf8), Self.response(statusCode: 200))
        }

        await assertUpdateClientError(.decodingFailed) {
            _ = try await client.latestRelease()
        }
    }

    func testVersionComparisonDetectsNewerRelease() {
        XCTAssertEqual(
            AppVersionComparison.compare(installedVersion: "1.0", latestTag: "v1.0.1"),
            .updateAvailable
        )
    }

    func testVersionComparisonTreatsEqualVersionsAsUpToDate() {
        XCTAssertEqual(
            AppVersionComparison.compare(installedVersion: "1.0", latestTag: "v1.0.0"),
            .upToDate
        )
        XCTAssertEqual(
            AppVersionComparison.compare(installedVersion: "1.0.0", latestTag: "1.0"),
            .upToDate
        )
    }

    func testVersionComparisonTreatsLowerReleaseAsUpToDate() {
        XCTAssertEqual(
            AppVersionComparison.compare(installedVersion: "1.2.0", latestTag: "v1.1.9"),
            .upToDate
        )
    }

    func testVersionComparisonReturnsInconclusiveForUnparseableVersions() {
        XCTAssertEqual(
            AppVersionComparison.compare(installedVersion: "Unknown", latestTag: "v1.0.1"),
            .inconclusive
        )
        XCTAssertEqual(
            AppVersionComparison.compare(installedVersion: "1.0", latestTag: "release-1.0.1"),
            .inconclusive
        )
    }

    func testUpdatesViewModelStartsIdle() {
        let client = MockAppUpdateCheckClient()
        let viewModel = makeViewModel(updateClient: client)

        XCTAssertEqual(viewModel.updateState, .idle)
        XCTAssertEqual(viewModel.updateStatusText, "Update status has not been checked yet.")
        XCTAssertEqual(viewModel.latestReleaseText, "--")
        XCTAssertEqual(viewModel.publishedDateText, "--")
        XCTAssertEqual(viewModel.lastCheckedText, "--")
        XCTAssertFalse(viewModel.canOpenReleasePage)
    }

    func testUpdatesViewModelChecksOnAppearOnceAndManualRefreshBypassesCache() async {
        let currentTime = MutableDate(date("2026-04-24T19:00:00Z"))
        let firstRelease = release(tagName: "v1.0.1")
        let secondRelease = release(tagName: "v1.0.2")
        let client = MockAppUpdateCheckClient(responses: [
            .success(firstRelease),
            .success(secondRelease),
        ])
        let viewModel = makeViewModel(
            updateClient: client,
            now: { currentTime.date },
            checkCacheDuration: 300
        )

        await viewModel.checkForUpdatesIfNeeded()
        await viewModel.checkForUpdatesIfNeeded()

        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(viewModel.updateState, .updateAvailable(firstRelease))
        XCTAssertEqual(viewModel.latestReleaseText, "v1.0.1")
        XCTAssertEqual(viewModel.publishedDateText, "2026-04-24")
        XCTAssertEqual(viewModel.lastCheckedText, "2026-04-24")
        XCTAssertTrue(viewModel.canOpenReleasePage)

        await viewModel.checkForUpdates(force: true)

        XCTAssertEqual(client.callCount, 2)
        XCTAssertEqual(viewModel.updateState, .updateAvailable(secondRelease))
    }

    func testUpdatesViewModelShowsUpToDateState() async {
        let latestRelease = release(tagName: "v1.0.0")
        let client = MockAppUpdateCheckClient(responses: [.success(latestRelease)])
        let viewModel = makeViewModel(updateClient: client)

        await viewModel.checkForUpdatesIfNeeded()

        XCTAssertEqual(viewModel.updateState, .upToDate(latestRelease))
        XCTAssertEqual(viewModel.updateStatusText, "Codex Status Bar is up to date.")
    }

    func testUpdatesViewModelShowsNoPublishedReleaseState() async {
        let client = MockAppUpdateCheckClient(responses: [.failure(AppUpdateCheckClientError.noPublishedRelease)])
        let viewModel = makeViewModel(updateClient: client)

        await viewModel.checkForUpdatesIfNeeded()

        XCTAssertEqual(viewModel.updateState, .noPublishedRelease)
        XCTAssertEqual(viewModel.updateStatusText, "No published release found.")
    }

    func testUpdatesViewModelShowsFailureState() async {
        let client = MockAppUpdateCheckClient(responses: [.failure(MockUpdateError.sample)])
        let viewModel = makeViewModel(updateClient: client)

        await viewModel.checkForUpdatesIfNeeded()

        XCTAssertEqual(viewModel.updateState, .failed)
        XCTAssertEqual(viewModel.updateStatusText, "Could not check for updates.")
    }

    func testUpdatesViewModelShowsInconclusiveStateForUnparseableRemoteTag() async {
        let latestRelease = release(tagName: "release-1")
        let client = MockAppUpdateCheckClient(responses: [.success(latestRelease)])
        let viewModel = makeViewModel(updateClient: client)

        await viewModel.checkForUpdatesIfNeeded()

        XCTAssertEqual(viewModel.updateState, .inconclusive(latestRelease))
        XCTAssertEqual(viewModel.updateStatusText, "Latest release found, but the version could not be compared.")
    }

    private func makeViewModel(
        updateClient: AppUpdateCheckClientProtocol,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 0) },
        checkCacheDuration: TimeInterval = 300
    ) -> InstallUpdateSettingsViewModel {
        InstallUpdateSettingsViewModel(
            versionInfo: AppVersionInfo(
                infoDictionary: [
                    "CFBundleDisplayName": "Codex Status Bar",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                ],
                bundleIdentifier: "com.farzad.codexstatusbar",
                bundleURL: URL(fileURLWithPath: "/Applications/CodexStatusBar.app")
            ),
            releaseNotes: [
                AppReleaseNote(id: "test", title: "Test Note", detail: "Test detail."),
            ],
            updateClient: updateClient,
            now: now,
            checkCacheDuration: checkCacheDuration
        )
    }

    private func release(tagName: String) -> AppUpdateRelease {
        AppUpdateRelease(
            tagName: tagName,
            name: "Codex Status Bar \(tagName)",
            htmlURL: URL(string: "https://github.com/fmnobar/codexStatusBar/releases/tag/\(tagName)")!,
            publishedAt: date("2026-04-24T18:00:00Z")
        )
    }

    private func date(_ isoString: String) -> Date {
        ISO8601DateFormatter().date(from: isoString)!
    }

    private static func response(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: GitHubLatestReleaseClient.defaultEndpoint,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func assertUpdateClientError(
        _ expectedError: AppUpdateCheckClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expectedError)")
        } catch let error as AppUpdateCheckClientError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class MockAppUpdateCheckClient: AppUpdateCheckClientProtocol {
    private var responses: [Result<AppUpdateRelease, Error>]
    private(set) var callCount = 0

    init(responses: [Result<AppUpdateRelease, Error>] = []) {
        self.responses = responses
    }

    func latestRelease() async throws -> AppUpdateRelease {
        callCount += 1
        guard !responses.isEmpty else {
            throw MockUpdateError.sample
        }

        return try responses.removeFirst().get()
    }
}

private final class MutableDate {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

private enum MockUpdateError: Error {
    case sample
}
