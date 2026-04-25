import CryptoKit
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
            installedBundleIdentifier: "com.farzad.codexstatusbar"
        )

        XCTAssertEqual(package.release, release)
        XCTAssertEqual(package.asset, asset)
        XCTAssertEqual(package.appURL.lastPathComponent, "CodexStatusBar.app")
        XCTAssertTrue(commandRunner.commands.contains { $0.executablePath == "/usr/bin/codesign" })
        XCTAssertTrue(commandRunner.commands.contains { $0.executablePath == "/usr/sbin/spctl" })
    }

    func testPackageVerifierRejectsChecksumMismatch() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(.checksumMismatch) {
            _ = try await verifier.verify(
                zipURL: zipURL,
                release: release(tagName: "v1.2.3"),
                asset: asset(digest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
                installedBundleIdentifier: "com.farzad.codexstatusbar"
            )
        }
    }

    func testPackageVerifierAllowsMissingChecksum() async throws {
        let zipURL = try makeUpdateZip(version: "1.2.3")
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        let package = try await verifier.verify(
            zipURL: zipURL,
            release: release(tagName: "v1.2.3"),
            asset: asset(digest: nil),
            installedBundleIdentifier: "com.farzad.codexstatusbar"
        )

        XCTAssertEqual(package.appURL.lastPathComponent, "CodexStatusBar.app")
    }

    func testPackageVerifierRejectsInvalidZip() async throws {
        let invalidZipURL = temporaryDirectory().appendingPathComponent("invalid.zip")
        try Data("not a zip".utf8).write(to: invalidZipURL)
        let verifier = AppUpdatePackageVerifier(commandRunner: RecordingCommandRunner())

        await assertPackageVerificationError(.unzipFailed) {
            _ = try await verifier.verify(
                zipURL: invalidZipURL,
                release: release(tagName: "v1.2.3"),
                asset: asset(),
                installedBundleIdentifier: "com.farzad.codexstatusbar"
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
                asset: asset(),
                installedBundleIdentifier: "com.farzad.codexstatusbar"
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
                asset: asset(),
                installedBundleIdentifier: "com.farzad.codexstatusbar"
            )
        }
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
                asset: asset(),
                installedBundleIdentifier: "com.farzad.codexstatusbar"
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
                asset: asset(),
                installedBundleIdentifier: "com.farzad.codexstatusbar"
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
        let launcher = RecordingProcessLauncher()
        let installer = AppUpdateInstaller(
            processLauncher: launcher,
            scriptDirectory: directory.appendingPathComponent("Scripts", isDirectory: true),
            writableDirectoryCheck: { _ in true }
        )
        let package = AppUpdatePackage(
            release: release(tagName: "v1.2.3"),
            asset: asset(),
            zipURL: directory.appendingPathComponent("Update Zip.zip"),
            appURL: directory.appendingPathComponent("Staged App/CodexStatusBar.app", isDirectory: true)
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

        let script = try String(contentsOf: launch.scriptURL)
        XCTAssertTrue(script.contains("while kill -0 \"$CURRENT_PID\""))
        XCTAssertTrue(script.contains("open \"$TARGET_APP\""))
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
        name: String = "CodexStatusBar-v1.2.3-build4.zip",
        digest: String? = nil
    ) -> AppUpdateReleaseAsset {
        AppUpdateReleaseAsset(
            name: name,
            browserDownloadURL: URL(string: "https://github.com/fmnobar/codexStatusBar/releases/download/v1.2.3/\(name)")!,
            contentType: "application/zip",
            size: 1234,
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
                "CFBundleVersion": "7",
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
        progress: @escaping (Double?) -> Void
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
        installedBundleIdentifier: String
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
    struct Command {
        let executablePath: String
        let arguments: [String]
    }

    var failures: [String: Error] = [:]
    private(set) var commands: [Command] = []
    private let processRunner = AppUpdateProcessCommandRunner()

    func run(executablePath: String, arguments: [String]) async throws -> AppUpdateCommandResult {
        commands.append(Command(executablePath: executablePath, arguments: arguments))
        if let failure = failures[executablePath] {
            throw failure
        }

        if executablePath == "/usr/bin/ditto" {
            return try await processRunner.run(executablePath: executablePath, arguments: arguments)
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
