import CryptoKit
import XCTest
@testable import CodexUsageCore

@MainActor
final class AppUpdateCheckTests: XCTestCase {
    func testLatestReleaseClientDecodesSuccessfulPayload() async throws {
        let publishedAt = date("2026-04-24T18:00:00Z")
        let data = Data("""
        {
          "tag_name": "v1.2.3",
          "name": "Codex Status Bar 1.2.3",
          "html_url": "https://github.com/fmnobar/codexStatusBar/releases/tag/v1.2.3",
          "published_at": "2026-04-24T18:00:00Z",
          "assets": [
            {
              "name": "CodexStatusBar-v1.2.3-build7.zip",
              "browser_download_url": "https://github.com/fmnobar/codexStatusBar/releases/download/v1.2.3/CodexStatusBar-v1.2.3-build7.zip",
              "content_type": "application/zip",
              "size": 1234,
              "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }
          ]
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
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets[0].name, "CodexStatusBar-v1.2.3-build7.zip")
        XCTAssertEqual(release.assets[0].contentType, "application/zip")
        XCTAssertEqual(release.assets[0].size, 1234)
        XCTAssertEqual(release.assets[0].digest, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(release.matchingCodexStatusBarZipAsset?.name, "CodexStatusBar-v1.2.3-build7.zip")
    }

    func testReleaseAssetSelectionIgnoresNonMatchingAssets() {
        let release = release(tagName: "v1.2.3", assets: [
            asset(name: "Source.zip"),
            asset(name: "CodexStatusBar-v1.2.2-build7.zip"),
            asset(name: "CodexStatusBar-v1.2.3-build.zip"),
        ])

        XCTAssertNil(release.matchingCodexStatusBarZipAsset)
    }

    func testReleaseAssetSelectionRequiresCanonicalTagAndExactlyOneAsset() {
        let matchingAsset = asset(name: "CodexStatusBar-v1.2.3-build7.zip")

        XCTAssertNil(release(tagName: "1.2.3", assets: [matchingAsset]).matchingCodexStatusBarZipAsset)
        XCTAssertNil(release(tagName: "V1.2.3", assets: [matchingAsset]).matchingCodexStatusBarZipAsset)
        XCTAssertNil(release(tagName: "v1.2.3", assets: [
            matchingAsset,
            asset(name: "CodexStatusBar-v1.2.3-build8.zip"),
        ]).matchingCodexStatusBarZipAsset)
        XCTAssertNil(release(
            tagName: "v1.2.3",
            assets: [asset(name: "CodexStatusBar-v1.2.3-build0.zip")]
        ).matchingCodexStatusBarZipAsset)
    }

    func testLatestReleaseClientMapsMalformedAssetPayload() async {
        let data = Data("""
        {
          "tag_name": "v1.2.3",
          "html_url": "https://github.com/fmnobar/codexStatusBar/releases/tag/v1.2.3",
          "assets": [
            {
              "name": "CodexStatusBar-v1.2.3-build7.zip",
              "browser_download_url": "not a url",
              "size": "large"
            }
          ]
        }
        """.utf8)
        let client = GitHubLatestReleaseClient { _ in
            (data, Self.response(statusCode: 200))
        }

        await assertUpdateClientError(.decodingFailed) {
            _ = try await client.latestRelease()
        }
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

    func testDownloadClientRejectsOversizedAssetBeforeStartingNetworkWork() async {
        var loaderWasCalled = false
        let client = AppUpdateDownloadClient(
            maximumArchiveBytes: 4,
            responseLoader: { _, _, _, _ in
                loaderWasCalled = true
                return Self.response(statusCode: 200)
            }
        )

        do {
            _ = try await client.download(
                asset: asset(size: 5),
                to: temporaryDirectory().appendingPathComponent("update.zip"),
                progress: { _ in }
            )
            XCTFail("Expected oversized asset rejection")
        } catch AppUpdateDownloadError.responseTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 4)
            XCTAssertFalse(loaderWasCalled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloadClientRemovesPartialFileWhenStreamExceedsLimit() async {
        let destinationURL = temporaryDirectory().appendingPathComponent("update.zip")
        let client = AppUpdateDownloadClient(
            maximumArchiveBytes: 4,
            responseLoader: { _, destinationURL, maximumBytes, _ in
                XCTAssertEqual(maximumBytes, 4)
                try Data("12345".utf8).write(to: destinationURL)
                return Self.response(statusCode: 200)
            }
        )

        do {
            _ = try await client.download(
                asset: asset(size: 0),
                to: destinationURL,
                progress: { _ in }
            )
            XCTFail("Expected streamed size rejection")
        } catch AppUpdateDownloadError.responseTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 4)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProcessCommandRunnerDrainsStdoutAndStderrConcurrently() async throws {
        let runner = AppUpdateProcessCommandRunner(timeout: 2, maximumOutputBytes: 512 * 1024)
        let result = try await runner.run(
            executablePath: "/bin/bash",
            arguments: [
                "-c",
                "/usr/bin/yes stdout | /usr/bin/head -c 131072; /usr/bin/yes stderr | /usr/bin/head -c 131072 >&2",
            ]
        )

        XCTAssertEqual(result.output.utf8.count, 131_072)
        XCTAssertEqual(result.errorOutput.utf8.count, 131_072)
    }

    func testProcessCommandRunnerBoundsCapturedOutput() async {
        let runner = AppUpdateProcessCommandRunner(timeout: 2, maximumOutputBytes: 1024)
        do {
            _ = try await runner.run(
                executablePath: "/bin/bash",
                arguments: ["-c", "/usr/bin/yes output | /usr/bin/head -c 131072"]
            )
            XCTFail("Expected output limit failure")
        } catch AppUpdateCommandError.outputLimitExceeded {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProcessCommandRunnerTimesOutAndKillsStubbornProcess() async {
        let runner = AppUpdateProcessCommandRunner(timeout: 0.1, maximumOutputBytes: 1024)
        let startedAt = Date()
        do {
            _ = try await runner.run(
                executablePath: "/bin/bash",
                arguments: ["-c", "trap '' TERM; while :; do :; done"]
            )
            XCTFail("Expected command timeout")
        } catch AppUpdateCommandError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProcessCommandRunnerRespondsToTaskCancellation() async {
        let runner = AppUpdateProcessCommandRunner(timeout: 5, maximumOutputBytes: 1024)
        let task = Task {
            try await runner.run(
                executablePath: "/bin/bash",
                arguments: ["-c", "trap '' TERM; while :; do :; done"]
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch AppUpdateCommandError.cancelled {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
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
        XCTAssertEqual(viewModel.installState, .idle)
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

    func testUpdateMonitorChecksOnceUntilCacheExpires() async {
        let currentTime = MutableDate(date("2026-05-18T12:00:00Z"))
        let firstRelease = release(tagName: "v1.0.1")
        let secondRelease = release(tagName: "v1.0.2")
        let client = MockAppUpdateCheckClient(responses: [
            .success(firstRelease),
            .success(secondRelease),
        ])
        let monitor = AppUpdateMonitor(
            versionInfo: appVersionInfo(version: "1.0.0"),
            updateClient: client,
            preferences: makeNotificationPreferences(),
            now: { currentTime.date },
            checkCacheDuration: 12 * 60 * 60
        )

        await monitor.checkIfNeeded()
        await monitor.checkIfNeeded()

        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(monitor.updateState, .updateAvailable(firstRelease))
        XCTAssertEqual(monitor.promptPresentation?.titleText, "Update v1.0.1 available")

        currentTime.date = currentTime.date.addingTimeInterval(12 * 60 * 60 + 1)
        await monitor.checkIfNeeded()

        XCTAssertEqual(client.callCount, 2)
        XCTAssertEqual(monitor.updateState, .updateAvailable(secondRelease))
    }

    func testUpdateMonitorForceCheckBypassesCache() async {
        let firstRelease = release(tagName: "v1.0.1")
        let secondRelease = release(tagName: "v1.0.2")
        let client = MockAppUpdateCheckClient(responses: [
            .success(firstRelease),
            .success(secondRelease),
        ])
        let monitor = AppUpdateMonitor(
            versionInfo: appVersionInfo(version: "1.0.0"),
            updateClient: client,
            preferences: makeNotificationPreferences(),
            checkCacheDuration: 12 * 60 * 60
        )

        await monitor.checkIfNeeded()
        await monitor.check(force: true)

        XCTAssertEqual(client.callCount, 2)
        XCTAssertEqual(monitor.updateState, .updateAvailable(secondRelease))
    }

    func testUpdateMonitorPromptOnlyShowsForAvailableUpdates() async {
        let hiddenStates: [Result<AppUpdateRelease, Error>] = [
            .success(release(tagName: "v1.0.0")),
            .success(release(tagName: "release-1")),
            .failure(AppUpdateCheckClientError.noPublishedRelease),
            .failure(MockUpdateError.sample),
        ]

        for response in hiddenStates {
            let monitor = AppUpdateMonitor(
                versionInfo: appVersionInfo(version: "1.0.0"),
                updateClient: MockAppUpdateCheckClient(responses: [response]),
                preferences: makeNotificationPreferences()
            )

            await monitor.checkIfNeeded()

            XCTAssertNil(monitor.promptPresentation)
        }
    }

    func testUpdateMonitorSnoozesCurrentReleaseForTwentyFourHours() async {
        let currentTime = MutableDate(date("2026-05-18T12:00:00Z"))
        let release = release(tagName: "v1.0.1")
        let monitor = AppUpdateMonitor(
            versionInfo: appVersionInfo(version: "1.0.0"),
            updateClient: MockAppUpdateCheckClient(responses: [.success(release)]),
            preferences: makeNotificationPreferences(),
            now: { currentTime.date },
            snoozeDuration: 24 * 60 * 60
        )

        await monitor.checkIfNeeded()
        XCTAssertNotNil(monitor.promptPresentation)

        monitor.snoozeCurrentPrompt()
        XCTAssertNil(monitor.promptPresentation)

        currentTime.date = currentTime.date.addingTimeInterval(24 * 60 * 60 + 1)
        XCTAssertNotNil(monitor.promptPresentation)
    }

    func testSettingsTabSelectionStoreTargetsUpdatesTab() {
        let suiteName = "CodexUsageMenuBarTests.SettingsTab.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        SettingsTabSelectionStore.select(.updates, defaults: defaults)

        XCTAssertEqual(
            SettingsTabSelectionStore.selectedTab(from: defaults.string(forKey: SettingsTabSelectionStore.key) ?? ""),
            .updates
        )
    }

    func testUpdatesViewModelUsesSharedUpdateMonitorState() async {
        let firstRelease = release(tagName: "v1.0.1")
        let secondRelease = release(tagName: "v1.0.2")
        let client = MockAppUpdateCheckClient(responses: [
            .success(firstRelease),
            .success(secondRelease),
        ])
        let monitor = AppUpdateMonitor(
            versionInfo: appVersionInfo(version: "1.0.0"),
            updateClient: client,
            preferences: makeNotificationPreferences()
        )
        let viewModel = makeViewModel(
            updateClient: MockAppUpdateCheckClient(),
            updateMonitor: monitor
        )

        await monitor.checkIfNeeded()

        XCTAssertEqual(viewModel.updateState, .updateAvailable(firstRelease))
        XCTAssertEqual(viewModel.latestReleaseText, "v1.0.1")

        await viewModel.checkForUpdates(force: true)

        XCTAssertEqual(client.callCount, 2)
        XCTAssertEqual(viewModel.updateState, .updateAvailable(secondRelease))
    }

    func testPackageVerifierAcceptsValidPackageWithChecksum() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let digest = try sha256Digest(for: zipURL)
        let release = release(tagName: "v1.2.3")
        let asset = asset(digest: "sha256:\(digest)")
        let commandRunner = RecordingCommandRunner()
        let verifier = AppUpdatePackageVerifier(commandRunner: commandRunner)

        let package = try await verifier.verify(
            zipURL: zipURL,
            release: release,
            asset: asset,
            installedBundleIdentifier: "com.farzad.codexstatusbar",
            installedAppURL: installedAppURL()
        )

        XCTAssertEqual(package.release, release)
        XCTAssertEqual(package.asset, asset)
        XCTAssertEqual(package.appURL.lastPathComponent, "CodexStatusBar.app")
        XCTAssertEqual(package.cleanupRootURL, zipURL.deletingLastPathComponent())
        XCTAssertEqual(package.bundleIdentifier, "com.farzad.codexstatusbar")
        XCTAssertEqual(package.immutableContentSHA256?.count, 64)
        XCTAssertTrue(commandRunner.commands.contains { $0.executablePath == "/usr/bin/codesign" })
        XCTAssertTrue(commandRunner.commands.contains { $0.executablePath == "/usr/sbin/spctl" })
        XCTAssertEqual(package.signingRequirement?.teamIdentifier, commandRunner.installedTeamIdentifier)
        XCTAssertTrue(commandRunner.commands.contains { command in
            command.executablePath == "/usr/bin/codesign"
                && command.arguments.contains("-R=\(commandRunner.designatedRequirement)")
                && !command.arguments.contains("-R")
        })
    }

    func testPackageVerifierRejectsChecksumMismatch() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(.checksumMismatch) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: asset(digest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsOversizedArchiveBeforeExtraction() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let verifier = AppUpdatePackageVerifier(
            maximumArchiveBytes: 1,
            commandRunner: RecordingCommandRunner()
        )

        await assertPackageVerificationError(.archiveTooLarge) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
        XCTAssertTrue(try expandedDirectories(nextTo: zipURL).isEmpty)
    }

    func testPackageVerifierRejectsMissingChecksum() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(.checksumMissing) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: asset(digest: nil),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsMalformedChecksum() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(.checksumMalformed) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: asset(digest: "sha512:not-supported"),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsNonCanonicalDigestFormatting() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let digest = try sha256Digest(for: zipURL)
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        for malformedDigest in ["SHA256:\(digest)", " sha256:\(digest)"] {
            await assertPackageVerificationError(.checksumMalformed) {
                _ = try await verifier.verify(
                    zipURL: zipURL,
                    release: release(tagName: "v1.2.3"),
                    asset: asset(digest: malformedDigest),
                    installedBundleIdentifier: "com.farzad.codexstatusbar",
                    installedAppURL: installedAppURL()
                )
            }
        }
    }

    func testPackageVerifierRejectsNonCanonicalOrAmbiguousAssetName() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())
        let selectedAsset = try verifiedAsset(for: zipURL)

        await assertPackageVerificationError(.assetNameMismatch) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3", assets: [
                    selectedAsset,
                    asset(name: "CodexStatusBar-v1.2.3-build8.zip", digest: selectedAsset.digest),
                ]),
                asset: selectedAsset,
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsInvalidZip() async throws {
        let invalidZipURL = temporaryDirectory().appendingPathComponent("invalid.zip")
        try Data("not a zip".utf8).write(to: invalidZipURL)
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(.unzipFailed) {
            _ = try await verifier.verify(
                zipURL: invalidZipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: invalidZipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsMissingAppBundle() async throws {
        let zipURL = try makeUpdateZip(includeApp: false)
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(.missingAppBundle) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsBundleIdentifierMismatch() async throws {
        let zipURL = try makeUpdateZip(bundleIdentifier: "com.example.other", version: "1.2.3")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(
            .bundleIdentifierMismatch(expected: "com.farzad.codexstatusbar", actual: "com.example.other")
        ) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
        XCTAssertTrue(try expandedDirectories(nextTo: zipURL).isEmpty)
    }

    func testPackageVerifierRejectsVersionMismatch() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.2")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(
            .versionMismatch(expected: "1.2.3", actual: "1.2.2")
        ) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsBuildMismatch() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3", build: "7")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(.buildMismatch(expected: "8", actual: "7")) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL, name: "CodexStatusBar-v1.2.3-build8.zip"),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsMissingExpectedDeveloperIDSigner() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let commandRunner = RecordingCommandRunner()
        commandRunner.installedTeamIdentifier = nil
        let verifier = AppUpdatePackageVerifier(commandRunner: commandRunner)

        await assertPackageVerificationError(.expectedSignerUnavailable) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsWrongSignerTeam() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let commandRunner = RecordingCommandRunner()
        commandRunner.stagedTeamIdentifier = "WRONG12345"
        let verifier = AppUpdatePackageVerifier(commandRunner: commandRunner)

        await assertPackageVerificationError(
            .signingTeamMismatch(expected: "ABCDE12345", actual: "WRONG12345")
        ) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierRejectsWrongDesignatedRequirement() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let commandRunner = RecordingCommandRunner()
        commandRunner.stagedDesignatedRequirement = "identifier \"com.example.other\""
        let verifier = AppUpdatePackageVerifier(commandRunner: commandRunner)

        await assertPackageVerificationError(.designatedRequirementMismatch) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
        }
    }

    func testPackageVerifierMapsTrustCheckFailure() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let commandRunner = RecordingCommandRunner()
        commandRunner.failures["/usr/sbin/spctl"] = AppUpdateCommandError.nonZeroExit(status: 1, output: "rejected")
        let verifier = AppUpdatePackageVerifier(commandRunner: commandRunner)

        do {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: try verifiedAsset(for: zipURL),
                installedBundleIdentifier: "com.farzad.codexstatusbar",
                installedAppURL: installedAppURL()
            )
            XCTFail("Expected trust check failure")
        } catch AppUpdatePackageVerificationError.verificationCommandFailed(let message) {
            XCTAssertTrue(message.contains("nonZeroExit"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInstallerLaunchesDetachedScriptForWritableTarget() async throws {
        let directory = temporaryDirectory()
        let targetAppURL = directory
            .appendingPathComponent("Current App", isDirectory: true)
            .appendingPathComponent("CodexStatusBar.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetAppURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let cleanupRootURL = directory.appendingPathComponent("Staged App", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanupRootURL, withIntermediateDirectories: true)
        try Data().write(to: cleanupRootURL.appendingPathComponent(".codex-status-bar-update-staging"))
        let launcher = RecordingProcessLauncher()
        let installer = AppUpdateInstaller(
            processLauncher: launcher,
            scriptDirectory: directory.appendingPathComponent("Scripts", isDirectory: true),
            writableDirectoryCheck: { _ in true }
        )
        let package = AppUpdatePackage(
            release: release(tagName: "v1.2.3"),
            asset: asset(),
            zipURL: cleanupRootURL.appendingPathComponent("Update Zip.zip"),
            appURL: cleanupRootURL.appendingPathComponent("CodexStatusBar.app", isDirectory: true),
            cleanupRootURL: cleanupRootURL,
            immutableContentSHA256: String(repeating: "a", count: 64),
            signingRequirement: testSigningRequirement()
        )

        let launch = try await installer.install(
            package: package,
            targetAppURL: targetAppURL,
            currentProcessIdentifier: 123
        )

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches[0].executableURL.path, "/bin/bash")
        XCTAssertEqual(launch.arguments[1], "123")
        XCTAssertEqual(launch.arguments[2], package.appURL.path)
        XCTAssertEqual(launch.arguments[3], targetAppURL.path)
        XCTAssertEqual(launch.arguments[5], "com.farzad.codexstatusbar")
        XCTAssertEqual(launch.arguments[6], "1.2.3")
        XCTAssertEqual(launch.arguments[7], "7")
        XCTAssertEqual(launch.arguments[8], String(repeating: "a", count: 64))
        XCTAssertEqual(launch.arguments[9], "ABCDE12345")
        XCTAssertEqual(launch.arguments[10], testSigningRequirement().designatedRequirement)
        XCTAssertEqual(launch.arguments[11], cleanupRootURL.path)

        let script = try String(contentsOf: launch.scriptURL)
        XCTAssertTrue(script.contains("while kill -0 \"$CURRENT_PID\""))
        XCTAssertTrue(script.contains("MAX_EXIT_WAIT_ATTEMPTS"))
        XCTAssertTrue(script.contains("restore_backup"))
        XCTAssertTrue(script.contains("\"-R=$EXPECTED_REQUIREMENT\""))
        XCTAssertTrue(script.contains("actual_requirement"))
        XCTAssertTrue(script.contains("verify_release_app \"$STAGED_APP\""))
        XCTAssertTrue(script.contains("verify_release_app \"$TARGET_APP\""))
        XCTAssertFalse(script.contains("sudo"))
    }

    func testInstallerRejectsNonWritableTarget() async throws {
        let directory = temporaryDirectory()
        let targetAppURL = directory.appendingPathComponent("CodexStatusBar.app", isDirectory: true)
        let installer = AppUpdateInstaller(
            processLauncher: RecordingProcessLauncher(),
            scriptDirectory: directory.appendingPathComponent("Scripts", isDirectory: true),
            writableDirectoryCheck: { _ in false }
        )

        XCTAssertFalse(installer.canInstall(to: targetAppURL))

        do {
            _ = try await installer.install(
                package: AppUpdatePackage(
                    release: release(tagName: "v1.2.3"),
                    asset: asset(),
                    zipURL: directory.appendingPathComponent("update.zip"),
                    appURL: directory.appendingPathComponent("CodexStatusBar.app", isDirectory: true)
                ),
                targetAppURL: targetAppURL,
                currentProcessIdentifier: 123
            )
            XCTFail("Expected non-writable target failure")
        } catch AppUpdateInstallerError.targetNotWritable(let targetParentURL) {
            XCTAssertEqual(targetParentURL, targetAppURL.deletingLastPathComponent())
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInstallerRejectsPackageWithoutPinnedSigningRequirement() async throws {
        let directory = temporaryDirectory()
        let targetAppURL = directory.appendingPathComponent("CodexStatusBar.app", isDirectory: true)
        let installer = AppUpdateInstaller(
            processLauncher: RecordingProcessLauncher(),
            scriptDirectory: directory.appendingPathComponent("Scripts", isDirectory: true),
            writableDirectoryCheck: { _ in true }
        )

        do {
            _ = try await installer.install(
                package: AppUpdatePackage(
                    release: release(tagName: "v1.2.3"),
                    asset: asset(),
                    zipURL: directory.appendingPathComponent("update.zip"),
                    appURL: directory.appendingPathComponent("Staged/CodexStatusBar.app", isDirectory: true)
                ),
                targetAppURL: targetAppURL,
                currentProcessIdentifier: 123
            )
            XCTFail("Expected missing signing requirement failure")
        } catch AppUpdateInstallerError.missingSigningRequirement {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInstallerRejectsPackageWithoutImmutableContentDigest() async throws {
        let directory = temporaryDirectory()
        let targetAppURL = directory.appendingPathComponent("CodexStatusBar.app", isDirectory: true)
        let installer = AppUpdateInstaller(
            processLauncher: RecordingProcessLauncher(),
            scriptDirectory: directory.appendingPathComponent("Scripts", isDirectory: true),
            writableDirectoryCheck: { _ in true }
        )

        do {
            _ = try await installer.install(
                package: AppUpdatePackage(
                    release: release(tagName: "v1.2.3"),
                    asset: asset(),
                    zipURL: directory.appendingPathComponent("update.zip"),
                    appURL: directory.appendingPathComponent("Staged/CodexStatusBar.app", isDirectory: true),
                    signingRequirement: testSigningRequirement()
                ),
                targetAppURL: targetAppURL,
                currentProcessIdentifier: 123
            )
            XCTFail("Expected missing immutable content digest failure")
        } catch AppUpdateInstallerError.missingImmutableContentDigest {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDetachedInstallerExecutesTransactionalSwapAgainstFixtureBundles() async throws {
        let fixture = try makeInstallerFixture()
        let launch = try await makeInstallerLaunch(
            fixture: fixture,
            currentProcessIdentifier: 999_999
        )

        let result = try executeInstallerScript(
            launch,
            fixture: fixture,
            shouldReportRelaunch: true
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("new.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("old.txt").path))
        XCTAssertEqual(try String(contentsOf: fixture.openMarker), fixture.targetApp.path)
        XCTAssertTrue(try siblingBackups(in: fixture.targetApp.deletingLastPathComponent()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot.path))
    }

    func testDetachedInstallerRollsBackFixtureWhenRelaunchCannotBeConfirmed() async throws {
        let fixture = try makeInstallerFixture()
        let launch = try await makeInstallerLaunch(
            fixture: fixture,
            currentProcessIdentifier: 999_999
        )

        let result = try executeInstallerScript(
            launch,
            fixture: fixture,
            shouldReportRelaunch: false
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("did not relaunch"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("new.txt").path))
        XCTAssertTrue(try siblingBackups(in: fixture.targetApp.deletingLastPathComponent()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot.path))
    }

    func testDetachedInstallerLeavesOriginalWhenStagingCopyFails() async throws {
        let fixture = try makeInstallerFixture()
        let launch = try await makeInstallerLaunch(
            fixture: fixture,
            currentProcessIdentifier: 999_999
        )

        let result = try executeInstallerScript(
            launch,
            fixture: fixture,
            shouldReportRelaunch: true,
            shouldFailStagingCopy: true
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("new.txt").path))
        XCTAssertTrue(try siblingBackups(in: fixture.targetApp.deletingLastPathComponent()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot.path))
    }

    func testDetachedInstallerRejectsChangedStagedContentBeforeSwap() async throws {
        let fixture = try makeInstallerFixture()
        let launch = try await makeInstallerLaunch(
            fixture: fixture,
            currentProcessIdentifier: 999_999
        )
        try FileManager.default.createDirectory(
            at: fixture.stagedApp.appendingPathComponent("injected-empty-directory", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = try executeInstallerScript(
            launch,
            fixture: fixture,
            shouldReportRelaunch: true
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("content changed"), result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("new.txt").path))
        XCTAssertTrue(try siblingBackups(in: fixture.targetApp.deletingLastPathComponent()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot.path))
    }

    func testDetachedInstallerLeavesOriginalWhenPreSwapIdentityValidationFails() async throws {
        let fixture = try makeInstallerFixture()
        let launch = try await makeInstallerLaunch(
            fixture: fixture,
            currentProcessIdentifier: 999_999
        )

        let result = try executeInstallerScript(
            launch,
            fixture: fixture,
            shouldReportRelaunch: true,
            validationFailurePathSubstring: "/.CodexStatusBar.update."
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("injected identity validation failure"), result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("new.txt").path))
        XCTAssertTrue(try siblingBackups(in: fixture.targetApp.deletingLastPathComponent()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.killMarker.path))
    }

    func testDetachedInstallerRollsBackWhenPostSwapIdentityValidationFails() async throws {
        let fixture = try makeInstallerFixture()
        let launch = try await makeInstallerLaunch(
            fixture: fixture,
            currentProcessIdentifier: 999_999
        )

        let result = try executeInstallerScript(
            launch,
            fixture: fixture,
            shouldReportRelaunch: true,
            validationFailurePath: fixture.targetApp
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("injected identity validation failure"), result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("new.txt").path))
        XCTAssertTrue(try siblingBackups(in: fixture.targetApp.deletingLastPathComponent()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot.path))
        let killedProcesses = try String(contentsOf: fixture.killMarker)
        XCTAssertTrue(killedProcesses.contains("4242"))
        XCTAssertFalse(killedProcesses.contains("4343"), "Rollback must preserve the foreign same-name canary.")
    }

    func testDetachedInstallerRollsBackFixtureWhenReplacementRenameFails() async throws {
        let fixture = try makeInstallerFixture()
        let launch = try await makeInstallerLaunch(
            fixture: fixture,
            currentProcessIdentifier: 999_999
        )

        let result = try executeInstallerScript(
            launch,
            fixture: fixture,
            shouldReportRelaunch: true,
            shouldFailReplacementRename: true
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("new.txt").path))
        XCTAssertTrue(try siblingBackups(in: fixture.targetApp.deletingLastPathComponent()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot.path))
    }

    func testDetachedInstallerRollsBackFixtureWhenLaunchFails() async throws {
        let fixture = try makeInstallerFixture()
        let launch = try await makeInstallerLaunch(
            fixture: fixture,
            currentProcessIdentifier: 999_999
        )

        let result = try executeInstallerScript(
            launch,
            fixture: fixture,
            shouldReportRelaunch: true,
            shouldFailLaunch: true
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("new.txt").path))
        XCTAssertTrue(try siblingBackups(in: fixture.targetApp.deletingLastPathComponent()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingRoot.path))
    }

    func testUpdatesViewModelDownloadsVerifiesAndPreparesInstall() async {
        let release = release(tagName: "v1.0.1", assets: [asset(name: "CodexStatusBar-v1.0.1-build2.zip")])
        let downloadClient = MockAppUpdateDownloadClient()
        let verifier = MockPackageVerifier()
        let installer = MockInstaller(canInstall: true)
        let viewModel = makeViewModel(
            updateClient: MockAppUpdateCheckClient(responses: [.success(release)]),
            downloadClient: downloadClient,
            packageVerifier: verifier,
            installer: installer
        )

        await viewModel.checkForUpdatesIfNeeded()
        await viewModel.downloadUpdate()

        XCTAssertEqual(downloadClient.downloadedAssets.map(\.name), ["CodexStatusBar-v1.0.1-build2.zip"])
        XCTAssertEqual(verifier.verifiedZipURLs.count, 1)
        XCTAssertEqual(viewModel.installState, .ready(verifier.package))
        XCTAssertEqual(viewModel.installStatusText, "Update downloaded and verified.")
        XCTAssertTrue(viewModel.canInstallPreparedUpdate)
    }

    func testUpdatesViewModelReportsDownloadFailure() async {
        let release = release(tagName: "v1.0.1", assets: [asset(name: "CodexStatusBar-v1.0.1-build2.zip")])
        let downloadClient = MockAppUpdateDownloadClient(error: MockUpdateError.sample)
        let viewModel = makeViewModel(
            updateClient: MockAppUpdateCheckClient(responses: [.success(release)]),
            downloadClient: downloadClient
        )

        await viewModel.checkForUpdatesIfNeeded()
        await viewModel.downloadUpdate()

        XCTAssertEqual(viewModel.installState, .failed("Update could not be downloaded."))
    }

    func testUpdatesViewModelReportsVerificationFailure() async {
        let release = release(tagName: "v1.0.1", assets: [asset(name: "CodexStatusBar-v1.0.1-build2.zip")])
        let verifier = MockPackageVerifier(error: AppUpdatePackageVerificationError.checksumMismatch)
        let viewModel = makeViewModel(
            updateClient: MockAppUpdateCheckClient(responses: [.success(release)]),
            packageVerifier: verifier
        )

        await viewModel.checkForUpdatesIfNeeded()
        await viewModel.downloadUpdate()

        XCTAssertEqual(viewModel.installState, .failed("Downloaded update could not be verified."))
    }

    func testUpdatesViewModelReportsUnavailableInstallLocationButCanRevealDownload() async {
        let release = release(tagName: "v1.0.1", assets: [asset(name: "CodexStatusBar-v1.0.1-build2.zip")])
        let verifier = MockPackageVerifier()
        let viewModel = makeViewModel(
            updateClient: MockAppUpdateCheckClient(responses: [.success(release)]),
            packageVerifier: verifier,
            installer: MockInstaller(canInstall: false)
        )

        await viewModel.checkForUpdatesIfNeeded()
        await viewModel.downloadUpdate()

        XCTAssertEqual(
            viewModel.installState,
            .unavailable("The installed app location is not writable. Reveal the verified download and replace it manually.", verifier.package)
        )
        XCTAssertTrue(viewModel.canRevealDownloadedUpdate)
        XCTAssertEqual(viewModel.downloadedUpdateURL, verifier.package.appURL)
    }

    func testUpdatesViewModelInstallsPreparedUpdateAndTerminates() async {
        let release = release(tagName: "v1.0.1", assets: [asset(name: "CodexStatusBar-v1.0.1-build2.zip")])
        let verifier = MockPackageVerifier()
        let installer = MockInstaller(canInstall: true)
        var didTerminate = false
        let viewModel = makeViewModel(
            updateClient: MockAppUpdateCheckClient(responses: [.success(release)]),
            packageVerifier: verifier,
            installer: installer,
            terminateApplication: { didTerminate = true }
        )

        await viewModel.checkForUpdatesIfNeeded()
        await viewModel.downloadUpdate()
        await viewModel.installPreparedUpdate()

        XCTAssertEqual(installer.installCallCount, 1)
        XCTAssertTrue(didTerminate)
        XCTAssertEqual(viewModel.installState, .installing(verifier.package))
    }

    private func makeViewModel(
        updateClient: AppUpdateCheckClientProtocol,
        updateMonitor: AppUpdateMonitor? = nil,
        downloadClient: AppUpdateDownloadClientProtocol = MockAppUpdateDownloadClient(),
        packageVerifier: AppUpdatePackageVerifierProtocol = MockPackageVerifier(),
        installer: AppUpdateInstallerProtocol = MockInstaller(canInstall: true),
        stagingDirectory: URL? = nil,
        terminateApplication: @escaping () -> Void = {},
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 0) },
        checkCacheDuration: TimeInterval = 300
    ) -> InstallUpdateSettingsViewModel {
        let resolvedStagingDirectory = stagingDirectory ?? temporaryDirectory()
        return InstallUpdateSettingsViewModel(
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
            updateMonitor: updateMonitor,
            updateClient: updateClient,
            downloadClient: downloadClient,
            packageVerifier: packageVerifier,
            installer: installer,
            stagingDirectoryProvider: { release in
                resolvedStagingDirectory.appendingPathComponent(release.tagName, isDirectory: true)
            },
            processIdentifier: { 123 },
            terminateApplication: terminateApplication,
            now: now,
            checkCacheDuration: checkCacheDuration
        )
    }

    private func appVersionInfo(version: String) -> AppVersionInfo {
        AppVersionInfo(
            infoDictionary: [
                "CFBundleDisplayName": "Codex Status Bar",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": "1",
            ],
            bundleIdentifier: "com.farzad.codexstatusbar",
            bundleURL: URL(fileURLWithPath: "/Applications/CodexStatusBar.app")
        )
    }

    private func makeNotificationPreferences(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AppUpdateNotificationPreferences {
        let suiteName = "CodexUsageMenuBarTests.AppUpdate.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults", file: file, line: line)
            return AppUpdateNotificationPreferences(defaults: .standard)
        }

        defaults.removePersistentDomain(forName: suiteName)
        return AppUpdateNotificationPreferences(defaults: defaults)
    }

    private func release(
        tagName: String,
        assets: [AppUpdateReleaseAsset] = []
    ) -> AppUpdateRelease {
        AppUpdateRelease(
            tagName: tagName,
            name: "Codex Status Bar \(tagName)",
            htmlURL: URL(string: "https://github.com/fmnobar/codexStatusBar/releases/tag/\(tagName)")!,
            publishedAt: date("2026-04-24T18:00:00Z"),
            assets: assets
        )
    }

    private func asset(
        name: String = "CodexStatusBar-v1.2.3-build7.zip",
        size: Int64 = 1234,
        digest: String? = nil
    ) -> AppUpdateReleaseAsset {
        AppUpdateReleaseAsset(
            name: name,
            browserDownloadURL: URL(string: "https://github.com/fmnobar/codexStatusBar/releases/download/v1.2.3/\(name)")!,
            contentType: "application/zip",
            size: size,
            digest: digest
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

    private func assertPackageVerificationError(
        _ expectedError: AppUpdatePackageVerificationError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expectedError)")
        } catch let error as AppUpdatePackageVerificationError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeUpdateZip(
        bundleIdentifier: String = "com.farzad.codexstatusbar",
        version: String = "1.2.3",
        build: String = "7",
        includeApp: Bool = true
    ) throws -> URL {
        let directory = temporaryDirectory()
        let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let zipURL = directory.appendingPathComponent("update.zip")
        if includeApp {
            let appURL = sourceDirectory.appendingPathComponent("CodexStatusBar.app", isDirectory: true)
            let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
            try runProcess("/usr/bin/ditto", ["-c", "-k", "--keepParent", "CodexStatusBar.app", zipURL.path], currentDirectory: sourceDirectory)
        } else {
            let textURL = sourceDirectory.appendingPathComponent("Readme.txt")
            try Data("no app".utf8).write(to: textURL)
            try runProcess("/usr/bin/ditto", ["-c", "-k", "--keepParent", "Readme.txt", zipURL.path], currentDirectory: sourceDirectory)
        }

        return zipURL
    }

    private func sha256Digest(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func verifiedAsset(
        for zipURL: URL,
        name: String = "CodexStatusBar-v1.2.3-build7.zip"
    ) throws -> AppUpdateReleaseAsset {
        asset(name: name, digest: "sha256:\(try sha256Digest(for: zipURL))")
    }

    private func installedAppURL() -> URL {
        URL(fileURLWithPath: "/Applications/CodexStatusBar.app", isDirectory: true)
    }

    private func testSigningRequirement() -> AppUpdateSigningRequirement {
        AppUpdateSigningRequirement(
            teamIdentifier: "ABCDE12345",
            designatedRequirement: RecordingCommandRunner.defaultDesignatedRequirement
        )
    }

    private struct InstallerFixture {
        let root: URL
        let stagingRoot: URL
        let stagedApp: URL
        let targetApp: URL
        let toolsDirectory: URL
        let openMarker: URL
        let killMarker: URL
        let canaryExecutable: URL
    }

    private func makeInstallerFixture() throws -> InstallerFixture {
        let temporaryRoot = temporaryDirectory()
        let canonicalRoot = try XCTUnwrap(
            temporaryRoot.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        )
        let root = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
        let stagingRoot = root.appendingPathComponent("Staging-UUID", isDirectory: true)
        let stagedApp = stagingRoot.appendingPathComponent("Expanded/CodexStatusBar.app", isDirectory: true)
        let targetApp = root.appendingPathComponent("Installed/CodexStatusBar.app", isDirectory: true)
        let toolsDirectory = root.appendingPathComponent("Tools", isDirectory: true)
        let openMarker = root.appendingPathComponent("opened.txt")
        let killMarker = root.appendingPathComponent("killed.txt")
        let canaryExecutable = root.appendingPathComponent("Canary/CodexStatusBar")
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: canaryExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: stagingRoot.appendingPathComponent(".codex-status-bar-update-staging"))
        try Data("new".utf8).write(to: stagedApp.appendingPathComponent("new.txt"))
        try Data("old".utf8).write(to: targetApp.appendingPathComponent("old.txt"))
        try makeInstallerAppIdentity(at: stagedApp)

        try writeExecutable(
            at: toolsDirectory.appendingPathComponent("codesign"),
            contents: """
            #!/bin/bash
            app_path="${!#}"
            if [[ -n "${CODEX_TEST_FAIL_VALIDATION_PATH:-}" && "$app_path" == "$CODEX_TEST_FAIL_VALIDATION_PATH" ]]; then
              echo 'injected identity validation failure' >&2
              exit 94
            fi
            if [[ -n "${CODEX_TEST_FAIL_VALIDATION_SUBSTRING:-}" && "$app_path" == *"$CODEX_TEST_FAIL_VALIDATION_SUBSTRING"* ]]; then
              echo 'injected identity validation failure' >&2
              exit 94
            fi
            if [[ " $* " == *" --requirements "* ]]; then
              echo 'designated => \(RecordingCommandRunner.defaultDesignatedRequirement)' >&2
            elif [[ " $* " == *" --display "* ]]; then
              echo "TeamIdentifier=ABCDE12345" >&2
            fi
            exit 0
            """
        )
        try writeExecutable(at: toolsDirectory.appendingPathComponent("spctl"), contents: "#!/bin/bash\nexit 0\n")
        try writeExecutable(
            at: toolsDirectory.appendingPathComponent("open"),
            contents: "#!/bin/bash\nprintf '%s' \"$1\" > \"$CODEX_TEST_OPEN_MARKER\"\n"
        )
        try writeExecutable(
            at: toolsDirectory.appendingPathComponent("kill"),
            contents: "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$CODEX_TEST_KILL_MARKER\"\n"
        )

        return InstallerFixture(
            root: root,
            stagingRoot: stagingRoot,
            stagedApp: stagedApp,
            targetApp: targetApp,
            toolsDirectory: toolsDirectory,
            openMarker: openMarker,
            killMarker: killMarker,
            canaryExecutable: canaryExecutable
        )
    }

    private func makeInstallerLaunch(
        fixture: InstallerFixture,
        currentProcessIdentifier: Int32
    ) async throws -> AppUpdateInstallLaunch {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.stagingRoot.appendingPathComponent(".codex-status-bar-update-staging").path
        ), "Staging ownership marker is missing before installer launch.")
        let installer = AppUpdateInstaller(
            processLauncher: RecordingProcessLauncher(),
            scriptDirectory: fixture.root.appendingPathComponent("Scripts", isDirectory: true),
            writableDirectoryCheck: { _ in true }
        )
        return try await installer.install(
            package: AppUpdatePackage(
                release: release(tagName: "v1.2.3"),
                asset: asset(),
                zipURL: fixture.stagingRoot.appendingPathComponent("update.zip"),
                appURL: fixture.stagedApp,
                cleanupRootURL: fixture.stagingRoot,
                immutableContentSHA256: try await AppUpdateImmutableContentDigest.digest(
                    for: fixture.stagedApp,
                    commandRunner: AppUpdateProcessCommandRunner()
                ),
                signingRequirement: testSigningRequirement()
            ),
            targetAppURL: fixture.targetApp,
            currentProcessIdentifier: currentProcessIdentifier
        )
    }

    private func executeInstallerScript(
        _ launch: AppUpdateInstallLaunch,
        fixture: InstallerFixture,
        shouldReportRelaunch: Bool,
        shouldFailStagingCopy: Bool = false,
        shouldFailReplacementRename: Bool = false,
        shouldFailLaunch: Bool = false,
        validationFailurePath: URL? = nil,
        validationFailurePathSubstring: String? = nil
    ) throws -> (status: Int32, output: String) {
        let pgrepURL = fixture.toolsDirectory.appendingPathComponent("pgrep")
        let psURL = fixture.toolsDirectory.appendingPathComponent("ps")
        let dittoURL = fixture.toolsDirectory.appendingPathComponent("ditto")
        let moveURL = fixture.toolsDirectory.appendingPathComponent("mv")
        let openURL = fixture.toolsDirectory.appendingPathComponent("open")
        try writeExecutable(
            at: pgrepURL,
            contents: shouldReportRelaunch ? "#!/bin/bash\nprintf '4242\\n4343\\n'\n" : "#!/bin/bash\nexit 1\n"
        )
        try writeExecutable(
            at: psURL,
            contents: """
            #!/bin/bash
            if [[ "${2:-}" == "4242" ]]; then
              printf '%s\n' "$CODEX_TEST_PROCESS_PATH"
            else
              printf '%s\n' "$CODEX_TEST_CANARY_PATH"
            fi
            """
        )
        try writeExecutable(
            at: dittoURL,
            contents: shouldFailStagingCopy
                ? "#!/bin/bash\necho 'injected staging copy failure' >&2\nexit 92\n"
                : "#!/bin/bash\nexec /usr/bin/ditto \"$@\"\n"
        )
        try writeExecutable(
            at: moveURL,
            contents: shouldFailReplacementRename
                ? """
                  #!/bin/bash
                  if [[ "$1" == *"/.CodexStatusBar.update."* && "$2" == */CodexStatusBar.app ]]; then
                    echo "injected replacement rename failure" >&2
                    exit 91
                  fi
                  exec /bin/mv "$@"
                  """
                : "#!/bin/bash\nexec /bin/mv \"$@\"\n"
        )
        try writeExecutable(
            at: openURL,
            contents: shouldFailLaunch
                ? "#!/bin/bash\necho 'injected launch failure' >&2\nexit 93\n"
                : "#!/bin/bash\nprintf '%s' \"$1\" > \"$CODEX_TEST_OPEN_MARKER\"\n"
        )

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = launch.arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CODEX_UPDATE_CODESIGN_BIN": fixture.toolsDirectory.appendingPathComponent("codesign").path,
            "CODEX_UPDATE_DITTO_BIN": dittoURL.path,
            "CODEX_UPDATE_MV_BIN": moveURL.path,
            "CODEX_UPDATE_SPCTL_BIN": fixture.toolsDirectory.appendingPathComponent("spctl").path,
            "CODEX_UPDATE_OPEN_BIN": openURL.path,
            "CODEX_UPDATE_PGREP_BIN": pgrepURL.path,
            "CODEX_UPDATE_PS_BIN": psURL.path,
            "CODEX_UPDATE_KILL_BIN": fixture.toolsDirectory.appendingPathComponent("kill").path,
            "CODEX_UPDATE_MAX_EXIT_WAIT_ATTEMPTS": "1",
            "CODEX_UPDATE_MAX_LAUNCH_WAIT_ATTEMPTS": "1",
            "CODEX_UPDATE_WAIT_INTERVAL": "0.01",
            "CODEX_TEST_OPEN_MARKER": fixture.openMarker.path,
            "CODEX_TEST_PROCESS_PATH": fixture.targetApp.appendingPathComponent("Contents/MacOS/CodexStatusBar").path,
            "CODEX_TEST_CANARY_PATH": fixture.canaryExecutable.path,
            "CODEX_TEST_KILL_MARKER": fixture.killMarker.path,
            "CODEX_TEST_FAIL_VALIDATION_PATH": validationFailurePath?.path ?? "",
            "CODEX_TEST_FAIL_VALIDATION_SUBSTRING": validationFailurePathSubstring ?? "",
        ]) { _, new in new }
        try process.run()
        process.waitUntilExit()

        let logURL = URL(fileURLWithPath: launch.arguments[4])
        let output = (try? String(contentsOf: logURL))
            ?? String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        return (process.terminationStatus, output)
    }

    private func makeInstallerAppIdentity(at appURL: URL) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let executableURL = contentsURL.appendingPathComponent("MacOS/CodexStatusBar")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeExecutable(at: executableURL, contents: "#!/bin/bash\nexit 0\n")
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.farzad.codexstatusbar",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "7",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func siblingBackups(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".CodexStatusBar.") }
    }

    private func expandedDirectories(nextTo zipURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: zipURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Expanded-") }
    }

    private func runProcess(_ executablePath: String, _ arguments: [String], currentDirectory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexStatusBarTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

@MainActor
private final class MockAppUpdateDownloadClient: AppUpdateDownloadClientProtocol {
    private let error: Error?
    private(set) var downloadedAssets: [AppUpdateReleaseAsset] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func download(
        asset: AppUpdateReleaseAsset,
        to destinationURL: URL,
        progress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL {
        if let error {
            throw error
        }

        downloadedAssets.append(asset)
        progress(0.25)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("zip".utf8).write(to: destinationURL)
        progress(1)
        return destinationURL
    }
}

@MainActor
private final class MockPackageVerifier: AppUpdatePackageVerifierProtocol {
    private let error: Error?
    private(set) var verifiedZipURLs: [URL] = []
    let package: AppUpdatePackage

    init(error: Error? = nil) {
        self.error = error
        let release = AppUpdateRelease(
            tagName: "v1.0.1",
            name: "Codex Status Bar v1.0.1",
            htmlURL: URL(string: "https://github.com/fmnobar/codexStatusBar/releases/tag/v1.0.1")!,
            publishedAt: nil,
            assets: []
        )
        let asset = AppUpdateReleaseAsset(
            name: "CodexStatusBar-v1.0.1-build2.zip",
            browserDownloadURL: URL(string: "https://github.com/fmnobar/codexStatusBar/releases/download/v1.0.1/CodexStatusBar-v1.0.1-build2.zip")!,
            contentType: "application/zip",
            size: 1234,
            digest: nil
        )
        package = AppUpdatePackage(
            release: release,
            asset: asset,
            zipURL: URL(fileURLWithPath: "/tmp/update.zip"),
            appURL: URL(fileURLWithPath: "/tmp/CodexStatusBar.app")
        )
    }

    func verify(
        zipURL: URL,
        release: AppUpdateRelease,
        asset: AppUpdateReleaseAsset,
        installedBundleIdentifier: String,
        installedAppURL: URL
    ) async throws -> AppUpdatePackage {
        if let error {
            throw error
        }

        verifiedZipURLs.append(zipURL)
        return package
    }
}

@MainActor
private final class MockInstaller: AppUpdateInstallerProtocol {
    private let canInstallValue: Bool
    private(set) var installCallCount = 0

    init(canInstall: Bool) {
        canInstallValue = canInstall
    }

    func canInstall(to targetAppURL: URL) -> Bool {
        canInstallValue
    }

    func install(
        package: AppUpdatePackage,
        targetAppURL: URL,
        currentProcessIdentifier: Int32
    ) async throws -> AppUpdateInstallLaunch {
        installCallCount += 1
        return AppUpdateInstallLaunch(
            scriptURL: URL(fileURLWithPath: "/tmp/install.sh"),
            arguments: ["/tmp/install.sh", "\(currentProcessIdentifier)", package.appURL.path, targetAppURL.path]
        )
    }
}

private final class RecordingCommandRunner: AppUpdateCommandRunning {
    static let defaultDesignatedRequirement = "anchor apple generic and identifier \"com.farzad.codexstatusbar\" and certificate leaf[subject.OU] = \"ABCDE12345\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    struct Command {
        let executablePath: String
        let arguments: [String]
    }

    var failures: [String: Error] = [:]
    var installedTeamIdentifier: String? = "ABCDE12345"
    var stagedTeamIdentifier: String? = "ABCDE12345"
    var designatedRequirement = RecordingCommandRunner.defaultDesignatedRequirement
    var stagedDesignatedRequirement = RecordingCommandRunner.defaultDesignatedRequirement
    private(set) var commands: [Command] = []
    private let processRunner = AppUpdateProcessCommandRunner()

    func run(executablePath: String, arguments: [String]) async throws -> AppUpdateCommandResult {
        commands.append(Command(executablePath: executablePath, arguments: arguments))
        if let failure = failures[executablePath] {
            throw failure
        }

        if executablePath == "/usr/bin/ditto" || executablePath == "/bin/bash" {
            return try await processRunner.run(executablePath: executablePath, arguments: arguments)
        }

        if executablePath == "/usr/bin/codesign", arguments.contains("--display") {
            if arguments.contains("--requirements") {
                let isInstalledApp = arguments.last == "/Applications/CodexStatusBar.app"
                return AppUpdateCommandResult(
                    output: "",
                    errorOutput: "designated => \(isInstalledApp ? designatedRequirement : stagedDesignatedRequirement)\n"
                )
            }

            let isInstalledApp = arguments.last == "/Applications/CodexStatusBar.app"
            let teamIdentifier = isInstalledApp ? installedTeamIdentifier : stagedTeamIdentifier
            let teamLine = teamIdentifier.map { "TeamIdentifier=\($0)\n" } ?? "TeamIdentifier=not set\n"
            let authorityLine = isInstalledApp ? "Authority=Developer ID Application: Example (ABCDE12345)\n" : ""
            return AppUpdateCommandResult(output: "", errorOutput: teamLine + authorityLine)
        }

        return AppUpdateCommandResult(output: "", errorOutput: "")
    }
}

private final class RecordingProcessLauncher: AppUpdateProcessLaunching {
    private(set) var launches: [(executableURL: URL, arguments: [String])] = []

    func launch(executableURL: URL, arguments: [String]) throws {
        launches.append((executableURL, arguments))
    }
}
