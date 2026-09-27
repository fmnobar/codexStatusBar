import Darwin
import XCTest
@testable import CodexUsageCore

final class CodexRateLimitDecodingTests: XCTestCase {
    func testAppServerListenSupportDetectsWebSocketSupport() {
        let legacyHelp = """
        --listen <URL>
            Supported values: `stdio://`, `unix://`, `unix://PATH`, `ws://IP:PORT`, `off`
        """
        let currentHelp = """
        --stdio
            Use stdio as the transport (equivalent to `--listen stdio://`)
        --listen <URL>
            Supported values: `stdio://`, `unix://`, `unix://PATH`, `ws://IP:PORT`, `off`
        """
        let standardIOOnlyHelp = "--listen <URL> stdio:// unix://PATH off"

        XCTAssertTrue(CodexAppServerListenSupport.supportsWebSocket(helpText: legacyHelp))
        XCTAssertFalse(CodexAppServerListenSupport.supportsWebSocket(helpText: standardIOOnlyHelp))
        XCTAssertEqual(
            CodexAppServerListenSupport.capabilities(helpText: legacyHelp).preferredTransport,
            .legacyWebSocket
        )
        XCTAssertEqual(
            CodexAppServerListenSupport.capabilities(helpText: currentHelp).preferredTransport,
            .standardIO
        )
        XCTAssertEqual(
            CodexAppServerListenSupport.capabilities(helpText: standardIOOnlyHelp).preferredTransport,
            .standardIO
        )
    }

    func testExecutableCandidateManifestIsCanonicalWithSafeFallback() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let manifestURL = temporaryDirectory.appendingPathComponent("CodexExecutableCandidates.txt")
        try Data(
            """
            # Ordered fixture

            /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
            /Applications/ChatGPT.app/Contents/Resources/codex
            /opt/homebrew/bin/codex
            /custom/bin/codex
            """.utf8
        ).write(to: manifestURL)

        let manifestCandidates = CodexExecutableCandidateProvider.fixedCandidates(manifestURL: manifestURL)
        XCTAssertEqual(
            manifestCandidates.map(\.url.path),
            [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/custom/bin/codex",
            ]
        )
        XCTAssertEqual(manifestCandidates.map(\.kind), [.appBundled, .appBundled, .homebrew, .path])

        try Data("relative/codex\nrelative/codex\n".utf8).write(to: manifestURL)
        XCTAssertEqual(
            CodexExecutableCandidateProvider.fixedCandidates(manifestURL: manifestURL).map(\.url.path),
            [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]
        )
    }

    func testExecutableCandidatesUseLexicalAppOrderPathAndCanonicalSymlinkDeduplication() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let applicationsURL = temporaryDirectory.appendingPathComponent("Applications", isDirectory: true)
        let codex10URL = applicationsURL.appendingPathComponent("Codex10.app", isDirectory: true)
        let codex2URL = applicationsURL.appendingPathComponent("Codex2.app", isDirectory: true)
        for appURL in [codex10URL, codex2URL] {
            for relativePath in [
                "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "Contents/Resources/codex",
            ] {
                let executableURL = appURL.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: executableURL)
            }
        }
        try FileManager.default.createSymbolicLink(
            at: applicationsURL.appendingPathComponent("Codex05.app"),
            withDestinationURL: codex10URL
        )

        let pathDirectoryURL = temporaryDirectory.appendingPathComponent("path-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathDirectoryURL, withIntermediateDirectories: true)
        let pathExecutableURL = pathDirectoryURL.appendingPathComponent("codex")
        try Data().write(to: pathExecutableURL)

        let manifestURL = temporaryDirectory.appendingPathComponent("CodexExecutableCandidates.txt")
        try Data("/opt/homebrew/bin/codex\n/usr/local/bin/codex\n".utf8).write(to: manifestURL)

        let candidates = CodexExecutableCandidateProvider.orderedCandidates(
            environment: ["PATH": ":\(pathDirectoryURL.path)::"],
            manifestURL: manifestURL,
            applicationsURL: applicationsURL
        )

        XCTAssertEqual(candidates.prefix(2).map(\.url.path), [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])
        let discoveredAppNames = candidates
            .filter { $0.kind == .discoveredApp }
            .compactMap { candidate in
                candidate.url.pathComponents.first { $0.hasSuffix(".app") }
            }
        XCTAssertEqual(discoveredAppNames, ["Codex05.app", "Codex05.app", "Codex2.app", "Codex2.app"])
        XCTAssertEqual(candidates.filter { $0.kind == .discoveredApp }.map(\.url.standardizedFileURL.path), [
            applicationsURL.appendingPathComponent("Codex05.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").standardizedFileURL.path,
            applicationsURL.appendingPathComponent("Codex05.app/Contents/Resources/codex").standardizedFileURL.path,
            applicationsURL.appendingPathComponent("Codex2.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").standardizedFileURL.path,
            applicationsURL.appendingPathComponent("Codex2.app/Contents/Resources/codex").standardizedFileURL.path,
        ])
        XCTAssertEqual(
            candidates.last?.url.resolvingSymlinksInPath().path,
            pathExecutableURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(candidates.map(\.kind), [.homebrew, .usrLocal, .discoveredApp, .discoveredApp, .discoveredApp, .discoveredApp, .path])
    }

    @MainActor
    func testExecutableResolverFindsNestedBundleWhenLegacyExecutableIsMissingAndHomebrewIsBroken() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let applicationsURL = temporaryDirectory.appendingPathComponent("Applications", isDirectory: true)
        let nestedExecutable = applicationsURL.appendingPathComponent(
            "Codex Preview.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        let legacyExecutable = applicationsURL.appendingPathComponent("Codex Preview.app/Contents/Resources/codex")
        let brokenHomebrew = temporaryDirectory.appendingPathComponent("homebrew/codex")
        for executable in [nestedExecutable, brokenHomebrew] {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let manifestURL = temporaryDirectory.appendingPathComponent("CodexExecutableCandidates.txt")
        try Data("\(legacyExecutable.path)\n\(brokenHomebrew.path)\n".utf8).write(to: manifestURL)
        let candidates = CodexExecutableCandidateProvider.orderedCandidates(
            environment: ["PATH": ""],
            manifestURL: manifestURL,
            applicationsURL: applicationsURL
        )
        let discoveredExecutable = try XCTUnwrap(candidates.first {
            $0.url.standardizedFileURL == nestedExecutable.standardizedFileURL
        }?.url)
        let resolver = CodexExecutableResolver(
            versionRunner: StubCodexExecutableVersionRunner(
                outputs: [discoveredExecutable.path: "codex-cli 0.158.0-alpha.2.1"],
                failingPaths: [brokenHomebrew.path]
            ),
            capabilityProber: StubCodexAppServerCapabilityProber(
                capabilitiesByPath: [discoveredExecutable.path: standardIOCapabilities]
            ),
            candidates: candidates
        )

        let resolvedExecutable = try await resolver.resolve()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyExecutable.path))
        XCTAssertEqual(resolvedExecutable?.url.standardizedFileURL, nestedExecutable.standardizedFileURL)
        XCTAssertEqual(resolvedExecutable?.version, "0.158.0-alpha.2.1")
        XCTAssertEqual(resolvedExecutable?.capabilities.preferredTransport, .standardIO)
    }

    @MainActor
    func testExecutableResolverSkipsFailedVersionAndCapabilityProbes() async throws {
        let brokenWrapper = URL(fileURLWithPath: "/usr/bin/true")
        let unsupportedExecutable = URL(fileURLWithPath: "/usr/bin/false")
        let usableExecutable = URL(fileURLWithPath: "/bin/echo")
        let currentCapabilities = CodexAppServerListenSupport.capabilities(helpText: """
        --stdio
        --listen <URL> stdio:// ws://IP:PORT
        """)
        let resolver = CodexExecutableResolver(
            versionRunner: StubCodexExecutableVersionRunner(
                outputs: [
                    unsupportedExecutable.path: "codex-cli 0.143.0",
                    usableExecutable.path: "codex-cli 0.144.0-alpha.4",
                ],
                failingPaths: [brokenWrapper.path]
            ),
            capabilityProber: StubCodexAppServerCapabilityProber(
                capabilitiesByPath: [usableExecutable.path: currentCapabilities]
            ),
            candidates: [
                CodexExecutableCandidate(url: brokenWrapper, kind: .homebrew),
                CodexExecutableCandidate(url: unsupportedExecutable, kind: .usrLocal),
                CodexExecutableCandidate(url: usableExecutable, kind: .appBundled),
            ]
        )

        let resolvedExecutable = try await resolver.resolve()
        let resolution = try XCTUnwrap(resolvedExecutable)

        XCTAssertEqual(resolution.url, usableExecutable)
        XCTAssertEqual(resolution.version, "0.144.0-alpha.4")
        XCTAssertEqual(resolution.capabilities.preferredTransport, .standardIO)
    }

    @MainActor
    func testJSONRPCRequestTrackerTimesOutAndIgnoresLateResponse() async {
        let tracker = CodexJSONRPCRequestTracker()

        do {
            _ = try await tracker.response(for: 41, timeout: 0.02, send: {})
            XCTFail("Expected request timeout")
        } catch {
            XCTAssertEqual(error as? CodexClientError, .requestTimedOut)
        }

        XCTAssertEqual(tracker.pendingRequestCount, 0)
        XCTAssertFalse(tracker.succeed(requestID: 41, resultData: Data(#"{"late":true}"#.utf8)))
    }

    @MainActor
    func testJSONRPCRequestTrackerCancellationCleansUpContinuation() async {
        let tracker = CodexJSONRPCRequestTracker()
        let requestSent = expectation(description: "request sent")
        let task = Task { @MainActor () throws -> Data in
            try await tracker.response(for: 42, timeout: 10, send: {
                requestSent.fulfill()
            })
        }

        await fulfillment(of: [requestSent], timeout: 1)
        XCTAssertEqual(tracker.pendingRequestCount, 1)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(tracker.pendingRequestCount, 0)
    }

    @MainActor
    func testJSONRPCRequestTrackerDisconnectThenAcceptsNewRequest() async throws {
        let tracker = CodexJSONRPCRequestTracker()
        let firstRequestSent = expectation(description: "first request sent")
        let disconnectedTask = Task { @MainActor () throws -> Data in
            try await tracker.response(for: 43, timeout: 10, send: {
                firstRequestSent.fulfill()
            })
        }
        await fulfillment(of: [firstRequestSent], timeout: 1)

        tracker.failAll(with: CodexClientError.appServerUnavailable)
        do {
            _ = try await disconnectedTask.value
            XCTFail("Expected disconnect failure")
        } catch {
            XCTAssertEqual(error as? CodexClientError, .appServerUnavailable)
        }

        let secondRequestSent = expectation(description: "second request sent")
        let reconnectedTask = Task { @MainActor () throws -> Data in
            try await tracker.response(for: 44, timeout: 10, send: {
                secondRequestSent.fulfill()
            })
        }
        await fulfillment(of: [secondRequestSent], timeout: 1)
        let responseData = Data(#"{"ok":true}"#.utf8)
        XCTAssertTrue(tracker.succeed(requestID: 44, resultData: responseData))
        let receivedData = try await reconnectedTask.value
        XCTAssertEqual(receivedData, responseData)
        XCTAssertEqual(tracker.pendingRequestCount, 0)
    }

    @MainActor
    func testFailedStandardIOInitializationTerminatesManagedProcess() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFileURL = temporaryDirectory.appendingPathComponent("pid")
        let executableURL = try makeSilentStubbornCodexExecutable(
            in: temporaryDirectory,
            pidFileURL: pidFileURL
        )
        let capabilities = CodexAppServerListenSupport.Capabilities(
            supportsStandardIO: true,
            supportsWebSocket: false,
            explicitlyPrefersStandardIO: true
        )
        let client = CodexAppServerClient(
            requestTimeout: 0.5,
            initializationTimeout: 0.5,
            executableResolver: StubResolvedCodexExecutableResolver(
                resolution: ResolvedCodexExecutable(
                    url: executableURL,
                    version: "0.144.0",
                    capabilities: capabilities
                )
            )
        )

        do {
            _ = try await client.start()
            XCTFail("Expected initialization failure")
        } catch {
            XCTAssertEqual(error as? CodexClientError, .appServerUnavailable)
        }
        XCTAssertFalse(client.hasManagedProcessForTesting)
        // On a heavily loaded host, the 0.5-second failure deadline can retire and
        // reap the launched Process before its shell body is ever scheduled. When
        // the fixture did run, retain the stronger operating-system exit proof.
        if let processIdentifier = readProcessIdentifiers(from: pidFileURL).first {
            let processExited = await waitForProcessExit(processIdentifier)
            XCTAssertTrue(processExited)
        }
    }

    @MainActor
    func testStandardIOInitializationHasSeparateDeadlineFromLaterRequests() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFileURL = temporaryDirectory.appendingPathComponent("pid")
        let methodFileURL = temporaryDirectory.appendingPathComponent("methods")
        let executableURL = try makeResponsiveStubbornCodexExecutable(
            in: temporaryDirectory,
            pidFileURL: pidFileURL,
            methodFileURL: methodFileURL,
            initializationDelay: 1,
            rateLimitDelay: 1.5
        )
        let client = CodexAppServerClient(
            requestTimeout: 0.5,
            initializationTimeout: 5,
            executableResolver: StubResolvedCodexExecutableResolver(
                resolution: ResolvedCodexExecutable(
                    url: executableURL,
                    version: "0.158.0",
                    capabilities: standardIOCapabilities
                )
            )
        )
        defer { client.stop() }

        do {
            _ = try await client.start()
            XCTFail("Expected the ordinary rate-limit request to time out")
        } catch {
            XCTAssertEqual(error as? CodexClientError, .requestTimedOut)
        }

        // Reaching the account request proves initialize completed after a delay
        // twice the ordinary deadline. The later 1.5-second response must still
        // exceed that ordinary deadline, rather than inherit initialization's budget.
        XCTAssertEqual(readLines(from: methodFileURL), [
            "initialize", "getAuthStatus", "account/rateLimits/read",
        ])
        let processIdentifier = try XCTUnwrap(client.managedProcessIdentifierForTesting)
        client.stop()
        let processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)
        XCTAssertFalse(client.hasManagedProcessForTesting)
    }

    @MainActor
    func testCancellingStandardIOInitializationPreservesCancellationAndTerminatesChild() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFileURL = temporaryDirectory.appendingPathComponent("pid")
        let executableURL = try makeSilentStubbornCodexExecutable(
            in: temporaryDirectory,
            pidFileURL: pidFileURL
        )
        let client = CodexAppServerClient(
            requestTimeout: 10,
            initializationTimeout: 10,
            executableResolver: StubResolvedCodexExecutableResolver(
                resolution: ResolvedCodexExecutable(
                    url: executableURL,
                    version: "0.144.0",
                    capabilities: standardIOCapabilities
                )
            )
        )
        let task = Task { @MainActor in
            try await client.start()
        }

        let processIdentifier = try await waitForProcessIdentifier(in: pidFileURL)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)
        XCTAssertFalse(client.hasManagedProcessForTesting)
    }

    @MainActor
    func testStandardIOReceiveFailureRetiresStubbornChildBeforeReconnect() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFileURL = temporaryDirectory.appendingPathComponent("pids")
        let executableURL = try makeResponsiveStubbornCodexExecutable(
            in: temporaryDirectory,
            pidFileURL: pidFileURL
        )
        let client = CodexAppServerClient(
            // This fixture validates process retirement/reconnect, not request deadlines.
            // Keep fixture deadlines bounded while allowing the external interpreter to launch.
            requestTimeout: 10,
            initializationTimeout: 10,
            executableResolver: StubResolvedCodexExecutableResolver(
                resolution: ResolvedCodexExecutable(
                    url: executableURL,
                    version: "0.144.0",
                    capabilities: standardIOCapabilities
                )
            )
        )

        _ = try await client.start()
        let firstProcessIdentifier = try XCTUnwrap(client.managedProcessIdentifierForTesting)
        client.handleStandardOutputData(Data())

        _ = try await client.refresh()
        let secondProcessIdentifier = try XCTUnwrap(client.managedProcessIdentifierForTesting)
        XCTAssertNotEqual(firstProcessIdentifier, secondProcessIdentifier)
        let firstProcessExited = await waitForProcessExit(firstProcessIdentifier)
        XCTAssertTrue(firstProcessExited)

        client.stop()
        let secondProcessExited = await waitForProcessExit(secondProcessIdentifier)
        XCTAssertTrue(secondProcessExited)
    }

    @MainActor
    func testConcurrentColdStartCoalescesAndStaleGenerationCannotRetireReconnect() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFileURL = temporaryDirectory.appendingPathComponent("pids")
        let methodFileURL = temporaryDirectory.appendingPathComponent("methods")
        let executableURL = try makeResponsiveStubbornCodexExecutable(
            in: temporaryDirectory,
            pidFileURL: pidFileURL,
            methodFileURL: methodFileURL
        )
        let client = CodexAppServerClient(
            // This fixture validates connection coalescing, not request deadlines.
            // Keep fixture deadlines bounded while allowing the external interpreter to launch.
            requestTimeout: 10,
            initializationTimeout: 10,
            executableResolver: StubResolvedCodexExecutableResolver(
                resolution: ResolvedCodexExecutable(
                    url: executableURL,
                    version: "0.144.0",
                    capabilities: standardIOCapabilities
                )
            )
        )
        defer { client.stop() }

        async let firstSnapshot: CodexUsageSnapshot = client.start()
        async let secondSnapshot: CodexUsageSnapshot = client.start()
        _ = try await (firstSnapshot, secondSnapshot)

        let firstProcessIdentifier = try XCTUnwrap(client.managedProcessIdentifierForTesting)
        let firstGeneration = client.transportGenerationForTesting
        XCTAssertEqual(readProcessIdentifiers(from: pidFileURL), [firstProcessIdentifier])
        XCTAssertEqual(readLines(from: methodFileURL).filter { $0 == "initialize" }.count, 1)

        client.handleStandardOutputData(Data())
        _ = try await client.refresh()

        let secondProcessIdentifier = try XCTUnwrap(client.managedProcessIdentifierForTesting)
        XCTAssertNotEqual(firstProcessIdentifier, secondProcessIdentifier)
        XCTAssertNotEqual(firstGeneration, client.transportGenerationForTesting)

        client.retireConnectionForTesting(transportGeneration: firstGeneration)
        XCTAssertEqual(client.managedProcessIdentifierForTesting, secondProcessIdentifier)
        XCTAssertTrue(processIsAlive(secondProcessIdentifier))
        _ = try await client.refresh()

        client.stop()
        let firstProcessExited = await waitForProcessExit(firstProcessIdentifier)
        let secondProcessExited = await waitForProcessExit(secondProcessIdentifier)
        XCTAssertTrue(firstProcessExited)
        XCTAssertTrue(secondProcessExited)
        XCTAssertEqual(readProcessIdentifiers(from: pidFileURL).count, 2)
        XCTAssertEqual(readLines(from: methodFileURL).filter { $0 == "initialize" }.count, 2)
    }

    @MainActor
    func testStandardIOOwnedLaunchUsesProbedInvocationForm() async throws {
        let cases: [(CodexAppServerListenSupport.Capabilities, String)] = [
            (standardIOCapabilities, "app-server --stdio"),
            (
                CodexAppServerListenSupport.Capabilities(
                    supportsStandardIO: true,
                    supportsWebSocket: false,
                    explicitlyPrefersStandardIO: false
                ),
                "app-server --listen stdio://"
            ),
        ]

        for (capabilities, expectedArguments) in cases {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let pidFileURL = temporaryDirectory.appendingPathComponent("pid")
            let argumentFileURL = temporaryDirectory.appendingPathComponent("arguments")
            let executableURL = try makeResponsiveStubbornCodexExecutable(
                in: temporaryDirectory,
                pidFileURL: pidFileURL,
                argumentFileURL: argumentFileURL
            )
            let client = CodexAppServerClient(
                // This fixture validates invocation selection, not request deadlines.
                // Keep fixture deadlines bounded while allowing the external interpreter to launch.
                requestTimeout: 10,
                initializationTimeout: 10,
                executableResolver: StubResolvedCodexExecutableResolver(
                    resolution: ResolvedCodexExecutable(
                        url: executableURL,
                        version: "0.144.0",
                        capabilities: capabilities
                    )
                )
            )
            defer { client.stop() }

            _ = try await client.start()
            let processIdentifier = try XCTUnwrap(client.managedProcessIdentifierForTesting)
            XCTAssertEqual(readLines(from: argumentFileURL), [expectedArguments])

            client.stop()
            let processExited = await waitForProcessExit(processIdentifier)
            XCTAssertTrue(processExited)
        }
    }

    @MainActor
    func testLegacyWebSocketRejectsTakeoverBeforeSendingInitialize() async throws {
        let listener = try makeLoopbackListener()
        defer { Darwin.close(listener.descriptor) }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFileURL = temporaryDirectory.appendingPathComponent("pid")
        let executableURL = try makeSilentStubbornCodexExecutable(
            in: temporaryDirectory,
            pidFileURL: pidFileURL
        )
        let ownershipProber = StubWebSocketConnectionOwnershipProber(result: false)
        let legacyCapabilities = CodexAppServerListenSupport.Capabilities(
            supportsStandardIO: true,
            supportsWebSocket: true,
            explicitlyPrefersStandardIO: false
        )
        let client = CodexAppServerClient(
            portRange: listener.port...listener.port,
            readyTimeout: 0.1,
            readyPollInterval: 0.01,
            requestTimeout: 0.1,
            initializationTimeout: 0.1,
            executableResolver: StubResolvedCodexExecutableResolver(
                resolution: ResolvedCodexExecutable(
                    url: executableURL,
                    version: "0.143.0",
                    capabilities: legacyCapabilities
                )
            ),
            webSocketConnectionOwnershipProber: ownershipProber,
            webSocketHandshakeOverride: { _ in
                _ = try await waitForProcessIdentifier(in: pidFileURL)
            }
        )
        defer { client.stop() }

        do {
            _ = try await client.start()
            XCTFail("Expected listener not owned by the launched child to be rejected")
        } catch {
            XCTAssertEqual(error as? CodexClientError, .appServerUnavailable)
        }
        XCTAssertEqual(ownershipProber.callCount, 1)
        XCTAssertFalse(client.hasManagedProcessForTesting)
        let processIdentifier = try XCTUnwrap(readProcessIdentifiers(from: pidFileURL).first)
        let processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)

        let takeoverTraffic = await readAvailableListenerData(listener.descriptor)
        let takeoverText = String(decoding: takeoverTraffic, as: UTF8.self)
        XCTAssertFalse(takeoverText.contains("initialize"))
        XCTAssertFalse(takeoverText.contains("clientInfo"))
    }

    @MainActor
    func testLsofOwnershipProbeRequiresExactEstablishedServerSocket() async throws {
        let listener = try makeLoopbackListener()
        defer { Darwin.close(listener.descriptor) }
        let connection = try makeConnectedLoopbackPair(listener: listener)
        defer {
            Darwin.close(connection.clientDescriptor)
            Darwin.close(connection.serverDescriptor)
        }

        let prober = CodexLsofWebSocketConnectionOwnershipProber()
        let ownsConnection = try await prober.processOwnsEstablishedConnection(
            processIdentifier: getpid(),
            port: listener.port
        )
        let wrongProcessOwnsConnection = try await prober.processOwnsEstablishedConnection(
            processIdentifier: Int32.max,
            port: listener.port
        )

        XCTAssertTrue(ownsConnection)
        XCTAssertFalse(wrongProcessOwnsConnection)
    }

    @MainActor
    func testCancellingExecutableProbeEscalatesAndReapsStubbornChild() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFileURL = temporaryDirectory.appendingPathComponent("pid")
        let executableURL = try makeStubbornVersionProbeExecutable(
            in: temporaryDirectory,
            pidFileURL: pidFileURL
        )
        let resolver = CodexExecutableResolver(
            commandTimeout: 10,
            candidates: [CodexExecutableCandidate(url: executableURL, kind: .path)]
        )
        let task = Task { @MainActor in
            try await resolver.resolve()
        }

        let processIdentifier = try await waitForProcessIdentifier(in: pidFileURL)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected resolver cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)
    }

    @MainActor
    func testExecutableResolverRejectsOversizedProbeAndReapsChild() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pidFileURL = temporaryDirectory.appendingPathComponent("pid")
        let executableURL = try makeOversizedVersionProbeExecutable(
            in: temporaryDirectory,
            pidFileURL: pidFileURL
        )
        let resolver = CodexExecutableResolver(
            commandTimeout: 5,
            candidates: [CodexExecutableCandidate(url: executableURL, kind: .path)]
        )

        let resolvedExecutable = try await resolver.resolve()
        XCTAssertNil(resolvedExecutable)

        let processIdentifier = try XCTUnwrap(readProcessIdentifiers(from: pidFileURL).first)
        let processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)
    }

    @MainActor
    func testStandardIOWriterKeepsMainActorResponsiveUnderPipeBackpressure() async throws {
        let pipe = Pipe()
        let writeStarted = expectation(description: "write started")
        let writer = try CodexStandardIOWriter(
            fileHandle: pipe.fileHandleForWriting,
            onWriteStarted: { writeStarted.fulfill() }
        )
        XCTAssertTrue(writer.suppressesSIGPIPEForTesting)
        let writeTask = Task {
            try await writer.write(Data(repeating: 0x41, count: 8 * 1_024 * 1_024))
        }
        await fulfillment(of: [writeStarted], timeout: 1)

        // Teardown is invoked while the pipe is still backpressured. It must enqueue the close
        // without blocking MainActor behind the in-flight write.
        writer.close()
        let mainActorAdvanced = expectation(description: "main actor advanced")
        Task { @MainActor in
            mainActorAdvanced.fulfill()
        }

        await fulfillment(of: [mainActorAdvanced], timeout: 1)
        try pipe.fileHandleForReading.close()
        do {
            try await writeTask.value
            XCTFail("Expected the closed reader to fail the backpressured write")
        } catch {
            // Expected: F_SETNOSIGPIPE converts the closed-reader signal into a write error.
        }
    }

    @MainActor
    func testAppServerClientBoundsMessagesAndUnframedStandardIOBuffer() throws {
        let client = CodexAppServerClient(maximumIncomingMessageBytes: 16)
        let originalGeneration = client.transportGenerationForTesting

        XCTAssertThrowsError(
            try client.handleIncomingMessage(data: Data(repeating: 0x20, count: 17))
        ) { error in
            XCTAssertEqual(error as? CodexClientError, .responseTooLarge)
        }

        client.handleStandardOutputData(Data(repeating: 0x7B, count: 10))
        XCTAssertEqual(client.transportGenerationForTesting, originalGeneration)
        client.handleStandardOutputData(Data(repeating: 0x7B, count: 10))
        XCTAssertEqual(client.transportGenerationForTesting, originalGeneration + 1)
    }

    @MainActor
    func testCurrentMonitorIgnoresUnrelatedAndMalformedNotificationsWithoutRetiringTransport() throws {
        let client = CodexAppServerClient()
        var receivedSnapshotCount = 0
        client.onSnapshot = { _ in receivedSnapshotCount += 1 }
        let originalGeneration = client.transportGenerationForTesting
        let methods = [
            "thread/tokenUsage/updated",
            "remoteControl/status/changed",
            "thread/started",
            "unknown/notification",
            "account/rateLimits/updated",
        ]

        for method in methods {
            let data = try JSONSerialization.data(withJSONObject: [
                "method": method,
                "params": ["privateContent": "Do not retain", "tokenUsage": ["totalTokens": 123]],
            ])
            try client.handleIncomingMessage(data: data)
        }

        XCTAssertEqual(receivedSnapshotCount, 0)
        XCTAssertEqual(client.transportGenerationForTesting, originalGeneration)
    }

    func testDecodesPayloadAndPrefersMainCodexBucket() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": null,
                "primary": {
                  "usedPercent": 6,
                  "windowDurationMins": 300,
                  "resetsAt": 1775622013
                },
                "secondary": {
                  "usedPercent": 2,
                  "windowDurationMins": 10080,
                  "resetsAt": 1776208813
                },
                "planType": "pro"
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "limitName": null,
                  "primary": {
                    "usedPercent": 6,
                    "windowDurationMins": 300,
                    "resetsAt": 1775622013
                  },
                  "secondary": {
                    "usedPercent": 2,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776208813
                  },
                  "planType": "pro"
                },
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox",
                  "limitName": "GPT-5.3-Codex-Spark",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 0,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776211494
                  },
                  "planType": "pro"
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
        let snapshot = response.selectedSnapshot()

        XCTAssertEqual(snapshot.primary?.usedPercent, 6)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 2)
        XCTAssertEqual(snapshot.secondary?.windowDurationMinutes, 10080)
    }

    func testAccountPayloadClassifiesPrimaryOnlySevenDayByDuration() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 43,
                  "windowDurationMins": 10080,
                  "resetsAt": 1776208813
                },
                "secondary": null,
                "planType": "pro"
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
        let snapshot = response.selectedSnapshot()

        XCTAssertNil(snapshot.classifiedWindow(for: .fiveHour))
        XCTAssertEqual(snapshot.classifiedWindow(for: .sevenDay)?.usedPercent, 43)
        XCTAssertEqual(snapshot.windowReferences.map(\.slot), [.primary])
    }

    func testAccountPayloadPreservesNonstandardAndMissingDurationWindows() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 80,
                  "windowDurationMins": 90,
                  "resetsAt": 1775622013
                },
                "secondary": {
                  "usedPercent": 35,
                  "resetsAt": 1775624694
                },
                "planType": "pro"
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
        let snapshot = response.selectedSnapshot()

        XCTAssertNil(snapshot.classifiedWindow(for: .fiveHour))
        XCTAssertNil(snapshot.classifiedWindow(for: .sevenDay))
        XCTAssertEqual(snapshot.windowReferences.map(\.sourceTitle), ["90m", "Secondary"])
        XCTAssertEqual(snapshot.windowReferences.map(\.window.usedPercent), [80, 35])
    }

    func testDecodesWhamUsagePayloadIntoSnapshot() throws {
        let data = Data(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 25,
                  "limit_window_seconds": 18000,
                  "reset_at": 1775622013
                },
                "secondary_window": {
                  "used_percent": 8,
                  "limit_window_seconds": 604800,
                  "reset_at": 1776208813
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(WhamUsageResponse.self, from: data)
        let snapshot = try XCTUnwrap(response.selectedSnapshot())

        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 8)
        XCTAssertEqual(snapshot.secondary?.windowDurationMinutes, 10080)
    }

    func testWhamPayloadClassifiesSecondaryOnlySevenDayByDuration() throws {
        let data = Data(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": null,
                "secondary_window": {
                  "used_percent": 43,
                  "limit_window_seconds": 604800,
                  "reset_at": 1776208813
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(WhamUsageResponse.self, from: data)
        let snapshot = try XCTUnwrap(response.selectedSnapshot())

        XCTAssertNil(snapshot.classifiedWindow(for: .fiveHour))
        XCTAssertEqual(snapshot.classifiedWindow(for: .sevenDay)?.usedPercent, 43)
        XCTAssertEqual(snapshot.windowReferences.map(\.slot), [.secondary])
    }

    func testWhamFractionalMinuteBoundariesRemainUnclassifiedAndDoNotBecomeWeeklyUsage() throws {
        let fixtures: [(json: String, expectedSlot: CodexRateLimitWindowSlot, expectedPercent: Int)] = [
            (
                """
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 25,
                      "limit_window_seconds": 18001,
                      "reset_at": 1775622013
                    },
                    "secondary_window": null
                  }
                }
                """,
                .primary,
                75
            ),
            (
                """
                {
                  "rate_limit": {
                    "primary_window": null,
                    "secondary_window": {
                      "used_percent": 43,
                      "limit_window_seconds": 604801,
                      "reset_at": 1776208813
                    }
                  }
                }
                """,
                .secondary,
                57
            ),
        ]

        for fixture in fixtures {
            let response = try JSONDecoder().decode(
                WhamUsageResponse.self,
                from: Data(fixture.json.utf8)
            )
            let snapshot = try XCTUnwrap(response.selectedSnapshot())

            XCTAssertNil(snapshot.classifiedWindow(for: .fiveHour))
            XCTAssertNil(snapshot.classifiedWindow(for: .sevenDay))
            XCTAssertEqual(snapshot.windowReferences.count, 1)
            XCTAssertNil(snapshot.windowReferences.first?.window.windowDurationMinutes)
            XCTAssertEqual(snapshot.windowReferences.first?.slot, fixture.expectedSlot)
            XCTAssertEqual(snapshot.windowReferences.first?.window.remainingPercent, fixture.expectedPercent)

            let presentation = MenuBarStatusFormatter.presentation(
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 0)
            )

            XCTAssertEqual(presentation.menuBarPercentText, "--")
            XCTAssertEqual(presentation.sevenDayRow.remainingPercentText, "--% left")
        }
    }

    func testResetCreditsResponseDecodesAvailableCreditsOnlyAndIgnoresPrivateFields() throws {
        let response = try JSONDecoder().decode(
            CodexResetCreditsResponse.self,
            from: Data(
                """
                {
                  "available_count": 2,
                  "total_earned_count": 10,
                  "credits": [
                    {
                      "id": "credit-private-id",
                      "profile_user_id": "user-private",
                      "profile_image_url": "https://example.com/private.png",
                      "description": "do not store this",
                      "title": "Full reset (Weekly + 5 hr)",
                      "reset_type": "codex_rate_limits",
                      "status": "available",
                      "granted_at": "2026-06-26T23:58:05.557369Z",
                      "expires_at": "2026-07-26T23:58:05.557369Z",
                      "redeemed_at": null
                    },
                    {
                      "title": "Used reset",
                      "reset_type": "codex_rate_limits",
                      "status": "redeemed",
                      "granted_at": "2026-06-01T00:00:00Z",
                      "expires_at": "2026-07-01T00:00:00Z",
                      "redeemed_at": "2026-06-03T00:00:00Z"
                    },
                    {
                      "title": "https://private.example/reset",
                      "reset_type": "bad value",
                      "status": "available",
                      "granted_at": "not a date",
                      "expires_at": "2026-07-01T00:00:00Z"
                    }
                  ]
                }
                """.utf8
            )
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.credits.count, 1)
        XCTAssertEqual(snapshot.credits[0].title, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(snapshot.credits[0].resetType, "codex_rate_limits")
        XCTAssertEqual(snapshot.credits[0].status, "available")
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            snapshot.credits[0].grantedAt,
            fractionalFormatter.date(from: "2026-06-26T23:58:05.557369Z")
        )
        XCTAssertNil(snapshot.credits[0].redeemedAt)

        let encodedSnapshot = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encodedSnapshot.contains("credit-private-id"))
        XCTAssertFalse(encodedSnapshot.contains("user-private"))
        XCTAssertFalse(encodedSnapshot.contains("profile_image_url"))
        XCTAssertFalse(encodedSnapshot.contains("do not store"))
        XCTAssertFalse(encodedSnapshot.contains("Used reset"))
    }

    @MainActor
    func testResetCreditHTTPClientRetriesUnauthorizedWithRefreshedAuth() async throws {
        let endpoint = URL(string: "https://example.com/wham/rate-limit-reset-credits")!
        var refreshRequests: [Bool] = []
        var authorizationHeaders: [String?] = []
        var loadCount = 0
        let client = CodexResetCreditHTTPClient(
            endpoint: endpoint,
            responseLoader: { request in
                loadCount += 1
                authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
                if loadCount == 1 {
                    return (
                        Data(),
                        HTTPURLResponse(url: endpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    )
                }

                return (
                    Data(
                        """
                        {
                          "available_count": 1,
                          "credits": [
                            {
                              "title": "Usage reset",
                              "reset_type": "codex_rate_limits",
                              "status": "available",
                              "granted_at": "2026-06-26T23:58:05Z",
                              "expires_at": "2026-07-26T23:58:05Z"
                            }
                          ]
                        }
                        """.utf8
                    ),
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = try await client.fetch { refreshToken in
            refreshRequests.append(refreshToken)
            return refreshToken ? "new-token" : "old-token"
        }

        XCTAssertEqual(refreshRequests, [false, true])
        XCTAssertEqual(authorizationHeaders, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(snapshot.availableCount, 1)
        XCTAssertEqual(snapshot.credits.map(\.title), ["Usage reset"])
    }

    @MainActor
    func testAppServerClientFetchesResetCreditsThroughAuthStatus() async throws {
        let endpoint = URL(string: "https://example.com/wham/rate-limit-reset-credits")!
        var requestedMethods: [String] = []
        var authorizationHeaders: [String?] = []
        let resetClient = CodexResetCreditHTTPClient(
            endpoint: endpoint,
            responseLoader: { request in
                authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
                return (
                    Data(
                        """
                        {
                          "available_count": 1,
                          "credits": [
                            {
                              "title": "Full reset",
                              "reset_type": "codex_rate_limits",
                              "status": "available",
                              "granted_at": "2026-07-01T20:16:33Z",
                              "expires_at": "2026-07-31T20:16:33Z"
                            }
                          ]
                        }
                        """.utf8
                    ),
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let client = CodexAppServerClient(
            ensureConnectedOverride: {},
            sendRequestOverride: { method, _ in
                requestedMethods.append(method)
                XCTAssertEqual(method, "getAuthStatus")
                return [
                    "authMethod": "chatgpt",
                    "authToken": "reset-token",
                    "requiresOpenaiAuth": true,
                ]
            },
            resetCreditHTTPClient: resetClient
        )

        let snapshot = try await client.resetCreditSnapshot()

        XCTAssertEqual(requestedMethods, ["getAuthStatus"])
        XCTAssertEqual(authorizationHeaders, ["Bearer reset-token"])
        XCTAssertEqual(snapshot.credits.map(\.title), ["Full reset"])
    }

}

@MainActor
private struct StubCodexExecutableVersionRunner: CodexSourceVersionCommandRunning {
    let outputs: [String: String]
    let failingPaths: Set<String>

    init(outputs: [String: String], failingPaths: Set<String> = []) {
        self.outputs = outputs
        self.failingPaths = failingPaths
    }

    func versionOutput(for executableURL: URL, timeout: TimeInterval) async throws -> String {
        if failingPaths.contains(executableURL.path) {
            throw CodexExecutableProbeError.versionCommandFailed
        }
        guard let output = outputs[executableURL.path] else {
            throw CodexExecutableProbeError.versionCommandFailed
        }
        return output
    }
}

@MainActor
private struct StubCodexAppServerCapabilityProber: CodexAppServerCapabilityProbing {
    let capabilitiesByPath: [String: CodexAppServerListenSupport.Capabilities]

    func capabilities(
        for executableURL: URL,
        timeout: TimeInterval
    ) async throws -> CodexAppServerListenSupport.Capabilities {
        guard let capabilities = capabilitiesByPath[executableURL.path] else {
            throw CodexExecutableProbeError.versionCommandFailed
        }
        return capabilities
    }
}

@MainActor
private struct StubResolvedCodexExecutableResolver: CodexExecutableResolving {
    let resolution: ResolvedCodexExecutable?

    func resolve() async throws -> ResolvedCodexExecutable? {
        resolution
    }
}

@MainActor
private final class StubWebSocketConnectionOwnershipProber: CodexWebSocketConnectionOwnershipProbing {
    let result: Bool
    private(set) var callCount = 0

    init(result: Bool) {
        self.result = result
    }

    func processOwnsEstablishedConnection(processIdentifier: pid_t, port: Int) async throws -> Bool {
        callCount += 1
        return result
    }
}

private let standardIOCapabilities = CodexAppServerListenSupport.Capabilities(
    supportsStandardIO: true,
    supportsWebSocket: false,
    explicitlyPrefersStandardIO: true
)

private enum ProcessFixtureError: Error {
    case processDidNotStart
}

private func makeSilentStubbornCodexExecutable(
    in directoryURL: URL,
    pidFileURL: URL
) throws -> URL {
    let executableURL = directoryURL.appendingPathComponent("silent-codex")
    let serverURL = directoryURL.appendingPathComponent("silent-server.py")
    let serverScript = """
    #!/usr/bin/python3
    import signal
    import sys
    import time

    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    for _ in sys.stdin:
        pass
    while True:
        time.sleep(1)
    """
    try Data(serverScript.utf8).write(to: serverURL)
    let wrapper = """
    #!/bin/sh
    printf '%s\\n' "$$" >> \(shellSingleQuoted(pidFileURL.path))
    exec /usr/bin/python3 \(shellSingleQuoted(serverURL.path)) "$@"
    """
    try Data(wrapper.utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    return executableURL
}

private func makeResponsiveStubbornCodexExecutable(
    in directoryURL: URL,
    pidFileURL: URL,
    methodFileURL: URL? = nil,
    argumentFileURL: URL? = nil,
    initializationDelay: TimeInterval = 0,
    rateLimitDelay: TimeInterval = 0
) throws -> URL {
    let executableURL = directoryURL.appendingPathComponent("responsive-codex")
    let serverURL = directoryURL.appendingPathComponent("responsive-server.py")
    let serverScript = """
    #!/usr/bin/python3
    import json
    import signal
    import sys
    import time

    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    method_file = sys.argv[1] or None

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except Exception:
            continue
        method = request.get("method")
        if method_file:
            with open(method_file, "a", encoding="utf-8") as handle:
                handle.write(str(method) + "\\n")
        if method == "initialize":
            time.sleep(\(initializationDelay))
            result = {}
        elif method == "getAuthStatus":
            result = {
                "authMethod": "chatgpt",
                "authToken": None,
                "requiresOpenaiAuth": True,
            }
        elif method == "account/rateLimits/read":
            time.sleep(\(rateLimitDelay))
            result = {
                "rateLimits": {
                    "limitId": "codex",
                    "primary": {
                        "usedPercent": 10,
                        "windowDurationMins": 300,
                        "resetsAt": 1800000000,
                    },
                    "secondary": {
                        "usedPercent": 20,
                        "windowDurationMins": 10080,
                        "resetsAt": 1800600000,
                    },
                }
            }
        else:
            result = {}
        print(json.dumps({"id": request.get("id"), "result": result}), flush=True)

    while True:
        time.sleep(1)
    """
    try Data(serverScript.utf8).write(to: serverURL)
    let methodFilePath = methodFileURL?.path ?? ""
    let recordArguments = argumentFileURL.map {
        "printf '%s\\n' \"$*\" >> \(shellSingleQuoted($0.path))\n"
    } ?? ""
    let wrapper = """
    #!/bin/sh
    printf '%s\\n' "$$" >> \(shellSingleQuoted(pidFileURL.path))
    \(recordArguments)
    exec /usr/bin/python3 \(shellSingleQuoted(serverURL.path)) \(shellSingleQuoted(methodFilePath)) "$@"
    """
    try Data(wrapper.utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    return executableURL
}

private func makeStubbornVersionProbeExecutable(
    in directoryURL: URL,
    pidFileURL: URL
) throws -> URL {
    let executableURL = directoryURL.appendingPathComponent("stubborn-probe-codex")
    let serverURL = directoryURL.appendingPathComponent("stubborn-probe.py")
    let serverScript = """
    #!/usr/bin/python3
    import signal
    import time

    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)
    """
    try Data(serverScript.utf8).write(to: serverURL)
    let wrapper = """
    #!/bin/sh
    printf '%s\\n' "$$" >> \(shellSingleQuoted(pidFileURL.path))
    exec /usr/bin/python3 \(shellSingleQuoted(serverURL.path))
    """
    try Data(wrapper.utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    return executableURL
}

private func makeOversizedVersionProbeExecutable(
    in directoryURL: URL,
    pidFileURL: URL
) throws -> URL {
    let executableURL = directoryURL.appendingPathComponent("oversized-probe-codex")
    let serverURL = directoryURL.appendingPathComponent("oversized-probe.py")
    let serverScript = """
    #!/usr/bin/python3
    import signal
    import sys
    import time

    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    sys.stdout.buffer.write(b"x" * 300000)
    sys.stdout.buffer.flush()
    while True:
        time.sleep(1)
    """
    try Data(serverScript.utf8).write(to: serverURL)
    let wrapper = """
    #!/bin/sh
    printf '%s\\n' "$$" >> \(shellSingleQuoted(pidFileURL.path))
    exec /usr/bin/python3 \(shellSingleQuoted(serverURL.path))
    """
    try Data(wrapper.utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    return executableURL
}

private func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func readProcessIdentifiers(from fileURL: URL) -> [pid_t] {
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
        return []
    }
    return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
}

private func readLines(from fileURL: URL) -> [String] {
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
        return []
    }
    return text.split(whereSeparator: \.isNewline).map(String.init)
}

private func processIsAlive(_ processIdentifier: pid_t) -> Bool {
    errno = 0
    return kill(processIdentifier, 0) == 0 || errno != ESRCH
}

private func makeLoopbackListener() throws -> (descriptor: Int32, port: Int) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    do {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return (descriptor, Int(in_port_t(bigEndian: boundAddress.sin_port)))
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func makeConnectedLoopbackPair(
    listener: (descriptor: Int32, port: Int)
) throws -> (clientDescriptor: Int32, serverDescriptor: Int32) {
    let clientDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard clientDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    do {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(listener.port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    clientDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let serverDescriptor = Darwin.accept(listener.descriptor, nil, nil)
        guard serverDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (clientDescriptor, serverDescriptor)
    } catch {
        Darwin.close(clientDescriptor)
        throw error
    }
}

private func readAvailableListenerData(
    _ listenerDescriptor: Int32,
    timeout: TimeInterval = 0.5
) async -> Data {
    _ = fcntl(listenerDescriptor, F_SETFL, O_NONBLOCK)
    let acceptDeadline = Date().addingTimeInterval(timeout)
    var acceptedDescriptor: Int32 = -1
    while Date() < acceptDeadline {
        acceptedDescriptor = Darwin.accept(listenerDescriptor, nil, nil)
        if acceptedDescriptor >= 0 {
            break
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    guard acceptedDescriptor >= 0 else {
        return Data()
    }
    defer { Darwin.close(acceptedDescriptor) }

    _ = fcntl(acceptedDescriptor, F_SETFL, O_NONBLOCK)
    let readDeadline = Date().addingTimeInterval(timeout)
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
    while Date() < readDeadline {
        let count = recv(acceptedDescriptor, &buffer, buffer.count, 0)
        if count > 0 {
            result.append(contentsOf: buffer.prefix(count))
        } else if count == 0 {
            break
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            break
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return result
}

private func waitForProcessIdentifier(
    in fileURL: URL,
    timeout: TimeInterval = 5
) async throws -> pid_t {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let processIdentifier = readProcessIdentifiers(from: fileURL).last {
            return processIdentifier
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw ProcessFixtureError.processDidNotStart
}

private func waitForProcessExit(
    _ processIdentifier: pid_t,
    timeout: TimeInterval = 3
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        errno = 0
        if kill(processIdentifier, 0) == -1, errno == ESRCH {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}
