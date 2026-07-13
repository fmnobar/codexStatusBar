import XCTest
@testable import CodexUsageCore

final class AppBuildFreshnessTests: XCTestCase {
    nonisolated(unsafe) private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testFingerprintEncodingAndDecodingWithCompleteMetadata() throws {
        let fingerprint = AppBuildFingerprint(
            schemaVersion: 1,
            sourceRoot: "/tmp/codex",
            gitCommit: "abcdef1234567890",
            gitBranch: "main",
            isDirty: false,
            buildTime: "2026-05-17T12:00:00Z",
            installedBundlePath: "/Users/example/Applications/CodexStatusBar.app",
            executableSHA256: "1234567890abcdef"
        )

        let data = try JSONEncoder().encode(fingerprint)
        let decoded = try JSONDecoder().decode(AppBuildFingerprint.self, from: data)

        XCTAssertEqual(decoded, fingerprint)
        XCTAssertEqual(decoded.shortCommitText, "abcdef1")
        XCTAssertEqual(decoded.executableHashText, "1234567890ab")
    }

    func testFingerprintDecodingAllowsMissingOptionalMetadata() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "gitCommit": "unknown"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppBuildFingerprint.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(AppBuildFingerprint.knownValue(decoded.gitCommit))
        XCTAssertEqual(decoded.shortCommitText, "Unknown")
        XCTAssertEqual(decoded.sourceRootText, "Unknown")
    }

    func testPublicReleaseFingerprintDoesNotRequireLocalPaths() throws {
        let data = Data("""
        {
          "schemaVersion": 2,
          "provenanceKind": "public-release",
          "appVersion": "1.2.3",
          "appBuild": "7",
          "architectures": "arm64",
          "gitCommit": "abcdef1234567890",
          "buildTime": "2026-07-10T20:00:00Z"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppBuildFingerprint.self, from: data)

        XCTAssertTrue(decoded.isPublicRelease)
        XCTAssertNil(decoded.sourceRootURL)
        XCTAssertNil(decoded.installedBundleURL)
        XCTAssertEqual(decoded.shortCommitText, "abcdef1")
    }

    func testPublicReleaseFreshnessDoesNotProbeForSourceCheckout() throws {
        let publicFingerprint = AppBuildFingerprint(
            schemaVersion: 2,
            provenanceKind: "public-release",
            appVersion: "1.2.3",
            appBuild: "7",
            architectures: "arm64",
            gitCommit: "abcdef1234567890",
            buildTime: "2026-07-10T20:00:00Z"
        )
        let bundleURL = try makeBundleFixture(fingerprint: publicFingerprint)
        let checker = AppFreshnessChecker(
            runningFingerprint: publicFingerprint,
            bundleURL: bundleURL,
            sourceHeadReader: { _ in
                XCTFail("Public release freshness must not probe a local source checkout.")
                return nil
            }
        )

        guard case .current(let running, let installed, let sourceCommit) = checker.check(includeSourceCheckout: true) else {
            return XCTFail("Expected public release freshness to remain current without local paths.")
        }
        XCTAssertTrue(running?.isPublicRelease == true)
        XCTAssertTrue(installed?.isPublicRelease == true)
        XCTAssertNil(sourceCommit)
        XCTAssertEqual(checker.check(includeSourceCheckout: true).statusText, "Installed release is current.")
    }

    func testFreshnessIsCurrentWhenRunningInstalledAndSourceCommitsMatch() throws {
        let sourceRoot = try makeSourceCheckout(commit: "abc123456789")
        let bundleURL = try makeBundleFixture(fingerprint: fingerprint(
            sourceRoot: sourceRoot.path,
            gitCommit: "abc123456789"
        ))
        let runningFingerprint = fingerprint(sourceRoot: sourceRoot.path, gitCommit: "abc123456789")
        let checker = AppFreshnessChecker(
            runningFingerprint: runningFingerprint,
            bundleURL: bundleURL,
            sourceHeadReader: { _ in "abc123456789" }
        )

        guard case .current(let running, let installed, let sourceCommit) = checker.check(includeSourceCheckout: true) else {
            return XCTFail("Expected current freshness state.")
        }

        XCTAssertEqual(running?.gitCommit, "abc123456789")
        XCTAssertEqual(installed?.gitCommit, "abc123456789")
        XCTAssertEqual(sourceCommit, "abc123456789")
    }

    func testFreshnessDoesNotReadSourceCheckoutByDefault() throws {
        let sourceRoot = try makeSourceCheckout(commit: "newer123456789")
        let installedFingerprint = fingerprint(sourceRoot: sourceRoot.path, gitCommit: "older123456789")
        let bundleURL = try makeBundleFixture(fingerprint: installedFingerprint)
        var didReadSourceHead = false
        let checker = AppFreshnessChecker(
            runningFingerprint: installedFingerprint,
            bundleURL: bundleURL,
            sourceHeadReader: { _ in
                didReadSourceHead = true
                return "newer123456789"
            }
        )

        guard case .current(_, _, let sourceCommit) = checker.check() else {
            return XCTFail("Expected installed-only current state.")
        }

        XCTAssertFalse(didReadSourceHead)
        XCTAssertNil(sourceCommit)
    }

    func testFreshnessDetectsSourceNewerThanInstalled() throws {
        let sourceRoot = try makeSourceCheckout(commit: "newer123456789")
        let installedFingerprint = fingerprint(sourceRoot: sourceRoot.path, gitCommit: "older123456789")
        let bundleURL = try makeBundleFixture(fingerprint: installedFingerprint)
        let checker = AppFreshnessChecker(
            runningFingerprint: installedFingerprint,
            bundleURL: bundleURL,
            sourceHeadReader: { _ in "newer123456789" }
        )

        guard case .sourceNewerThanInstalled(_, let installed, let sourceCommit, let sourceRootURL) = checker.check(includeSourceCheckout: true) else {
            return XCTFail("Expected source-newer freshness state.")
        }

        XCTAssertEqual(installed.gitCommit, "older123456789")
        XCTAssertEqual(sourceCommit, "newer123456789")
        XCTAssertEqual(sourceRootURL?.path, sourceRoot.path)
    }

    func testFreshnessDetectsInstalledBundleNewerThanRunning() throws {
        let sourceRoot = try makeSourceCheckout(commit: "newer123456789")
        let runningFingerprint = fingerprint(sourceRoot: sourceRoot.path, gitCommit: "older123456789")
        let installedFingerprint = fingerprint(sourceRoot: sourceRoot.path, gitCommit: "newer123456789")
        let bundleURL = try makeBundleFixture(fingerprint: installedFingerprint)
        let checker = AppFreshnessChecker(
            runningFingerprint: runningFingerprint,
            bundleURL: bundleURL,
            sourceHeadReader: { _ in "newer123456789" }
        )

        guard case .installedBundleNewerThanRunning(let running, let installed, let sourceCommit) = checker.check(includeSourceCheckout: true) else {
            return XCTFail("Expected installed-newer freshness state.")
        }

        XCTAssertEqual(running.gitCommit, "older123456789")
        XCTAssertEqual(installed.gitCommit, "newer123456789")
        XCTAssertEqual(sourceCommit, "newer123456789")
    }

    func testFreshnessUnknownWhenFingerprintIsUnavailable() throws {
        let bundleURL = temporaryDirectory.appendingPathComponent("MissingFingerprint.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        let checker = AppFreshnessChecker(runningFingerprint: nil, bundleURL: bundleURL)

        guard case .unknown(let reason) = checker.check() else {
            return XCTFail("Expected unknown freshness state.")
        }

        XCTAssertTrue(reason.contains("fingerprint"))
    }

    func testFreshnessUnknownWhenSourceCheckoutIsUnavailable() throws {
        let missingSourceRoot = temporaryDirectory.appendingPathComponent("MissingSource", isDirectory: true)
        let installedFingerprint = fingerprint(sourceRoot: missingSourceRoot.path, gitCommit: "abc123456789")
        let bundleURL = try makeBundleFixture(fingerprint: installedFingerprint)
        let checker = AppFreshnessChecker(
            runningFingerprint: installedFingerprint,
            bundleURL: bundleURL,
            sourceHeadReader: { _ in nil }
        )

        guard case .unknown(let reason) = checker.check(includeSourceCheckout: true) else {
            return XCTFail("Expected unknown freshness state.")
        }

        XCTAssertTrue(reason.contains("Source checkout"))
    }

    @MainActor
    func testFreshnessViewModelExposesStatusAndRelaunchAction() throws {
        let bundleURL = temporaryDirectory.appendingPathComponent("CodexStatusBar.app", isDirectory: true)
        let runningFingerprint = fingerprint(gitCommit: "oldcommit")
        let installedFingerprint = fingerprint(
            gitCommit: "newcommit",
            installedBundlePath: bundleURL.path
        )
        let state = AppFreshnessState.installedBundleNewerThanRunning(
            running: runningFingerprint,
            installed: installedFingerprint,
            sourceCommit: "newcommit"
        )
        var relaunchedURL: URL?
        let viewModel = AppFreshnessStatusViewModel(
            initialState: state,
            stateProvider: { state },
            relaunchAction: { relaunchedURL = $0 }
        )

        XCTAssertTrue(viewModel.shouldShowWarning)
        XCTAssertTrue(viewModel.canRelaunchLatestInstalledApp)
        XCTAssertEqual(viewModel.runningCommitText, "oldcomm")
        XCTAssertEqual(viewModel.installedCommitText, "newcomm")
        XCTAssertEqual(viewModel.popoverWarningText, "A newer installed app is available. Relaunch to use it.")

        viewModel.relaunchLatestInstalledApp()

        XCTAssertEqual(relaunchedURL?.path, bundleURL.path)
    }

    @MainActor
    func testFreshnessViewModelReadsSourceOnlyAfterExplicitCheck() throws {
        let installedState = AppFreshnessState.current(
            running: nil,
            installed: fingerprint(sourceRoot: "/tmp/codex", gitCommit: "oldcommit"),
            sourceCommit: nil
        )
        let sourceState = AppFreshnessState.sourceNewerThanInstalled(
            running: nil,
            installed: fingerprint(sourceRoot: "/tmp/codex", gitCommit: "oldcommit"),
            sourceCommit: "newcommit",
            sourceRoot: URL(fileURLWithPath: "/tmp/codex", isDirectory: true)
        )
        var sourceCheckCount = 0
        let viewModel = AppFreshnessStatusViewModel(
            initialState: installedState,
            stateProvider: { installedState },
            sourceStateProvider: {
                sourceCheckCount += 1
                return sourceState
            },
            relaunchAction: { _ in }
        )

        XCTAssertEqual(viewModel.sourceCommitText, "Not checked")
        XCTAssertEqual(sourceCheckCount, 0)

        viewModel.refresh()

        XCTAssertEqual(sourceCheckCount, 0)
        XCTAssertEqual(viewModel.sourceCommitText, "Not checked")

        viewModel.checkSourceCheckout()

        XCTAssertEqual(sourceCheckCount, 1)
        XCTAssertEqual(viewModel.sourceCommitText, "newcomm")
        XCTAssertTrue(viewModel.shouldShowWarning)
    }

    private func fingerprint(
        sourceRoot: String? = nil,
        gitCommit: String,
        installedBundlePath: String? = nil
    ) -> AppBuildFingerprint {
        AppBuildFingerprint(
            schemaVersion: 1,
            sourceRoot: sourceRoot,
            gitCommit: gitCommit,
            gitBranch: "main",
            isDirty: false,
            buildTime: "2026-05-17T12:00:00Z",
            installedBundlePath: installedBundlePath ?? temporaryDirectory.appendingPathComponent("CodexStatusBar.app").path,
            executableSHA256: "1234567890abcdef"
        )
    }

    private func makeBundleFixture(fingerprint: AppBuildFingerprint) throws -> URL {
        let bundleURL = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app", isDirectory: true)
        let resourcesURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(fingerprint)
        try data.write(to: resourcesURL.appendingPathComponent(AppBuildFingerprint.fileName, isDirectory: false))
        return bundleURL
    }

    private func makeSourceCheckout(commit: String) throws -> URL {
        let sourceRoot = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let refsURL = sourceRoot
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent("heads", isDirectory: true)
        try FileManager.default.createDirectory(at: refsURL, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: sourceRoot.appendingPathComponent(".git/HEAD", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "\(commit)\n".write(
            to: refsURL.appendingPathComponent("main", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        return sourceRoot
    }
}
