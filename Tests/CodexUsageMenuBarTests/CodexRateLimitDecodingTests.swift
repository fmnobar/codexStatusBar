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

            /Applications/ChatGPT.app/Contents/Resources/codex
            /opt/homebrew/bin/codex
            /custom/bin/codex
            """.utf8
        ).write(to: manifestURL)

        let manifestCandidates = CodexExecutableCandidateProvider.fixedCandidates(manifestURL: manifestURL)
        XCTAssertEqual(
            manifestCandidates.map(\.url.path),
            [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/custom/bin/codex",
            ]
        )
        XCTAssertEqual(manifestCandidates.map(\.kind), [.appBundled, .homebrew, .path])

        try Data("relative/codex\nrelative/codex\n".utf8).write(to: manifestURL)
        XCTAssertEqual(
            CodexExecutableCandidateProvider.fixedCandidates(manifestURL: manifestURL).map(\.url.path),
            [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
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
            let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
            try Data().write(to: resourcesURL.appendingPathComponent("codex"))
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
        XCTAssertEqual(discoveredAppNames, ["Codex05.app", "Codex2.app"])
        XCTAssertEqual(
            candidates.last?.url.resolvingSymlinksInPath().path,
            pathExecutableURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(candidates.map(\.kind), [.homebrew, .usrLocal, .discoveredApp, .discoveredApp, .path])
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
    func testSourceHealthSelectsSameCapabilityViableCandidateAsResolver() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let unsupportedExecutable = URL(fileURLWithPath: "/usr/bin/true")
        let usableExecutable = URL(fileURLWithPath: "/bin/echo")
        let versionRunner = StubCodexExecutableVersionRunner(outputs: [
            unsupportedExecutable.path: "codex-cli 0.143.0",
            usableExecutable.path: "codex-cli 0.144.0",
        ])
        let capabilityProber = StubCodexAppServerCapabilityProber(capabilitiesByPath: [
            usableExecutable.path: standardIOCapabilities,
        ])
        let candidates = [
            CodexExecutableCandidate(url: unsupportedExecutable, kind: .usrLocal),
            CodexExecutableCandidate(url: usableExecutable, kind: .appBundled),
        ]
        let resolver = CodexExecutableResolver(
            versionRunner: versionRunner,
            capabilityProber: capabilityProber,
            candidates: candidates
        )
        let reader = CodexSourceHealthReader(
            homeDirectory: temporaryDirectory,
            commandRunner: versionRunner,
            capabilityProber: capabilityProber,
            executableCandidates: candidates,
            pathCandidates: []
        )

        let resolvedExecutable = try await resolver.resolve()
        let resolution = try XCTUnwrap(resolvedExecutable)
        let healthSnapshot = try await reader.sourceHealthSnapshot()

        XCTAssertEqual(resolution.url, usableExecutable)
        XCTAssertEqual(healthSnapshot.activeExecutablePath, usableExecutable.path)
        XCTAssertEqual(healthSnapshot.activeSignal?.version, resolution.version)
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
        let processIdentifier = try XCTUnwrap(readProcessIdentifiers(from: pidFileURL).first)
        let processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)
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

        XCTAssertFalse(client.hasManagedProcessForTesting)
        let processExited = await waitForProcessExit(processIdentifier)
        XCTAssertTrue(processExited)
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
            requestTimeout: 2,
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
            requestTimeout: 2,
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
                requestTimeout: 2,
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
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        XCTAssertThrowsError(
            try client.handleIncomingMessage(data: Data(repeating: 0x20, count: 17))
        ) { error in
            XCTAssertEqual(error as? CodexClientError, .responseTooLarge)
        }

        client.handleStandardOutputData(Data(repeating: 0x7B, count: 10))
        XCTAssertFalse(diagnosticEvents.contains { event in
            if case .receiveError = event { return true }
            return false
        })
        client.handleStandardOutputData(Data(repeating: 0x7B, count: 10))
        XCTAssertTrue(diagnosticEvents.contains(.receiveError(
            CodexClientError.responseTooLarge.localizedDescription
        )))
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

    func testBuildsUsageSnapshotWithAggregateAndModelBuckets() throws {
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
                "codex_gpt55": {
                  "limitId": "codex_gpt55",
                  "limitName": "GPT-5.5",
                  "primary": {
                    "usedPercent": 9,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 4,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776211494
                  },
                  "planType": "pro"
                },
                "codex_gpt54": {
                  "limitId": "codex_gpt54",
                  "limitName": "GPT-5.4",
                  "primary": {
                    "usedPercent": 3,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 1,
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
        let usageSnapshot = response.usageSnapshot()

        XCTAssertEqual(usageSnapshot.displaySnapshot.primary?.usedPercent, 6)
        XCTAssertEqual(usageSnapshot.buckets.map(\.id), ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertEqual(usageSnapshot.buckets.map(\.name), ["All models", "GPT-5.4", "GPT-5.5"])
        XCTAssertEqual(usageSnapshot.buckets.map(\.kind), [.aggregate, .model, .model])
        XCTAssertEqual(usageSnapshot.buckets.first { $0.id == "codex_gpt55" }?.snapshot.secondary?.usedPercent, 4)
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

    func testDecodesThreadTokenUsageNotification() throws {
        let data = Data(
            """
            {
              "threadId": "thread-123",
              "turnId": "turn-456",
              "tokenUsage": {
                "last": {
                  "inputTokens": 1200,
                  "cachedInputTokens": 900,
                  "outputTokens": 300,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1500
                },
                "total": {
                  "inputTokens": 10000,
                  "cachedInputTokens": 7000,
                  "outputTokens": 2000,
                  "reasoningOutputTokens": 400,
                  "totalTokens": 12000
                },
                "modelContextWindow": 258400
              }
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(ThreadTokenUsageUpdatedNotificationPayload.self, from: data)
        let notification = payload.toDomainNotification()

        XCTAssertEqual(notification.threadID, "thread-123")
        XCTAssertEqual(notification.turnID, "turn-456")
        XCTAssertNil(notification.model)
        XCTAssertEqual(notification.tokenUsage.modelContextWindow, 258400)
        XCTAssertEqual(notification.tokenUsage.last.cachedInputTokens, 900)
        XCTAssertEqual(notification.tokenUsage.last.reasoningOutputTokens, 40)
        XCTAssertEqual(notification.tokenUsage.total.inputTokens, 10000)
        XCTAssertEqual(notification.tokenUsage.total.totalTokens, 12000)
    }

    func testDecodesThreadTokenUsageNotificationSafeDimensions() throws {
        let data = Data(
            """
            {
              "thread_id": "thread-123",
              "turn_id": "turn-456",
              "originator": "vscode",
              "source": {
                "subagent": {
                  "thread_spawn": {
                    "parent_thread_id": "019c-parent-thread",
                    "depth": 2,
                    "agent_role": "explorer",
                    "agent_nickname": "Raman"
                  }
                }
              },
              "thread_source": "cli",
              "cli_version": "0.78.0",
              "model_provider": "openai",
              "memory_mode": "enabled",
              "approval_policy": "never",
              "sandbox_policy": {"type": "danger-full-access"},
              "permission_profile": {"type": "full"},
              "realtime_active": true,
              "truncation_policy": {"mode": "auto", "limit": 10000},
              "usage_mode": "/fast",
              "token_usage": {
                "last": {
                  "inputTokens": 1200,
                  "cachedInputTokens": 900,
                  "outputTokens": 300,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1500
                },
                "total": {
                  "inputTokens": 10000,
                  "cachedInputTokens": 7000,
                  "outputTokens": 2000,
                  "reasoningOutputTokens": 400,
                  "totalTokens": 12000
                },
                "model_context_window": 258400
              }
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(ThreadTokenUsageUpdatedNotificationPayload.self, from: data)
        let notification = payload.toDomainNotification()
        let dimensionPairs = notification.dimensions.map { "\($0.key.rawValue)=\($0.value)" }

        XCTAssertEqual(notification.threadID, "thread-123")
        XCTAssertEqual(notification.turnID, "turn-456")
        XCTAssertEqual(notification.tokenUsage.modelContextWindow, 258400)
        XCTAssertEqual(
            dimensionPairs,
            [
                "agent_nickname=Raman",
                "agent_role=explorer",
                "approval_policy=never",
                "cli_version=0.78.0",
                "is_subagent=true",
                "memory_mode=enabled",
                "model_provider=openai",
                "originator=vscode",
                "permission_profile=full",
                "realtime_active=true",
                "sandbox_type=danger-full-access",
                "source_kind=subagent",
                "subagent_depth=2",
                "subagent_parent_thread_id=019c-parent-thread",
                "thread_source=cli",
                "truncation_policy=auto",
                "usage_mode=fast",
            ]
        )
    }

    func testDecodesThreadTokenUsageNotificationModelIdentifiers() throws {
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","model":" codex-future-1 ""#),
            "codex-future-1"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","slug":"gpt-5.4""#),
            "gpt-5.4"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraTokenUsage: #","modelSlug":"o-series-next""#),
            "o-series-next"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraTokenUsage: #","info":{"slug":"model-from-info"}"#),
            "model-from-info"
        )
        XCTAssertNil(try decodeTokenUsageModel())
    }

    func testNormalizesThreadTokenUsageNotificationModelIdentifiers() throws {
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","model":"gpt-5.5\nTests/CodexUsageMenuBarTests/UsageHistoryStoreTests.swift:611:""#),
            "gpt-5.5"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","model":"o-series-next""#),
            "o-series-next"
        )
        XCTAssertEqual(
            try decodeTokenUsageModel(extraRoot: #","model":"gpt-5.4-mini""#),
            "gpt-5.4-mini"
        )
        XCTAssertNil(
            try decodeTokenUsageModel(extraRoot: #","model":"/Users/example/.codex/sessions/session.jsonl""#)
        )
        XCTAssertNil(
            try decodeTokenUsageModel(extraRoot: #","model":"event.name=codex.sse_event""#)
        )
    }

    func testTokenPayloadAuditorCapturesOnlySafeMetadata() throws {
        let params = try jsonObject(
            """
            {
              "thread_id": "thread-123",
              "turn_id": "turn-456",
              "modelSlug": "gpt-5.5",
              "source": {
                "subagent": {
                  "thread_spawn": {
                    "parent_thread_id": "parent-1",
                    "depth": 2,
                    "agent_role": "worker",
                    "agent_nickname": "Build"
                  }
                }
              },
              "approval_policy": {"type": "never"},
              "sandbox_policy": {"type": "danger-full-access"},
              "prompt": "do not store this text",
              "auth_token": "secret-token",
              "tool_payload": {"command": "rm -rf /"},
              "token_usage": {
                "last": {
                  "inputTokens": 120,
                  "cachedInputTokens": 90,
                  "outputTokens": 30,
                  "reasoningOutputTokens": 4,
                  "totalTokens": 150
                },
                "total": {
                  "inputTokens": 1000,
                  "cachedInputTokens": 700,
                  "outputTokens": 200,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1200
                },
                "info": {
                  "cwd": "/Users/example/Project",
                  "reasoning_effort": "xhigh",
                  "usage_mode": "/fast",
                  "cli_version": "0.78.0"
                }
              }
            }
            """
        )

        let audit = try XCTUnwrap(CodexTokenPayloadAuditor.audit(params: params, capturedAt: Date(timeIntervalSince1970: 1_777_000_000)))

        XCTAssertEqual(audit.threadID, "thread-123")
        XCTAssertEqual(audit.turnID, "turn-456")
        XCTAssertEqual(try auditField("modelSlug", in: audit).normalizedValue, "gpt-5.5")
        XCTAssertEqual(try auditField("tokenUsage.info.cwd", in: audit).normalizedValue, "/Users/example/Project")
        XCTAssertEqual(try auditField("tokenUsage.info.reasoningEffort", in: audit).normalizedValue, "xhigh")
        XCTAssertEqual(try auditField("source", in: audit).dimensionValue, "subagent")
        XCTAssertEqual(try auditField("approvalPolicy", in: audit).dimensionValue, "never")
        XCTAssertEqual(try auditField("sandboxPolicy", in: audit).dimensionValue, "danger-full-access")
        XCTAssertEqual(try auditField("tokenUsage.info.usageMode", in: audit).dimensionValue, "fast")
        XCTAssertEqual(try auditField("tokenUsage.info.cliVersion", in: audit).dimensionValue, "0.78.0")
        XCTAssertTrue(audit.hasModelMetadata)
        XCTAssertTrue(audit.hasProjectMetadata)
        XCTAssertTrue(audit.hasEffortMetadata)
        XCTAssertTrue(audit.hasSourceMetadata)
        XCTAssertTrue(audit.hasRuntimePolicyMetadata)
        XCTAssertFalse(audit.fields.contains { $0.keyPath.contains("prompt") || $0.keyPath.contains("auth") || $0.keyPath.contains("tool") })
        XCTAssertFalse(audit.fields.compactMap(\.sanitizedValue).contains { $0.contains("do not store") || $0.contains("secret-token") || $0.contains("rm -rf") })
    }

    @MainActor
    func testAppServerClientEmitsAuditAndTokenUsageIndependently() throws {
        let client = CodexAppServerClient()
        var receivedAudit: CodexTokenUsagePayloadAudit?
        var receivedNotification: CodexTokenUsageNotification?
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onTokenUsagePayloadAudit = { receivedAudit = $0 }
        client.onTokenUsage = { receivedNotification = $0 }
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "thread/tokenUsage/updated",
              "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "model": "gpt-5.5",
                "source": {"unsupported": {"message": "ignored"}},
                "tokenUsage": {
                  "last": {
                    "inputTokens": 120,
                    "cachedInputTokens": 90,
                    "outputTokens": 30,
                    "reasoningOutputTokens": 4,
                    "totalTokens": 150
                  },
                  "total": {
                    "inputTokens": 1000,
                    "cachedInputTokens": 700,
                    "outputTokens": 200,
                    "reasoningOutputTokens": 40,
                    "totalTokens": 1200
                  }
                }
              }
            }
            """.utf8
        ))

        let audit = try XCTUnwrap(receivedAudit)
        let notification = try XCTUnwrap(receivedNotification)

        XCTAssertEqual(notification.threadID, "thread-1")
        XCTAssertEqual(notification.model, "gpt-5.5")
        XCTAssertEqual(notification.tokenUsage.total.totalTokens, 1200)
        XCTAssertEqual(try auditField("model", in: audit).normalizedValue, "gpt-5.5")
        XCTAssertEqual(try auditField("source", in: audit).presence, .unsupported)
        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("thread/tokenUsage/updated")))
        XCTAssertTrue(diagnosticEvents.contains(.tokenUsageNotification))
        XCTAssertTrue(diagnosticEvents.contains(.auditSanitizeAttempt(success: true)))
    }

    @MainActor
    func testAppServerClientEmitsAuditAndSkipsMalformedTokenPayload() throws {
        let client = CodexAppServerClient()
        var receivedAudit: CodexTokenUsagePayloadAudit?
        var receivedNotification: CodexTokenUsageNotification?
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onTokenUsagePayloadAudit = { receivedAudit = $0 }
        client.onTokenUsage = { receivedNotification = $0 }
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        XCTAssertNoThrow(try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "thread/tokenUsage/updated",
              "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "model": "gpt-5.5"
              }
            }
            """.utf8
        )))

        XCTAssertEqual(receivedAudit?.threadID, "thread-1")
        XCTAssertEqual(try auditField("model", in: XCTUnwrap(receivedAudit)).normalizedValue, "gpt-5.5")
        XCTAssertNil(receivedNotification)
        XCTAssertTrue(diagnosticEvents.contains(.tokenUsageNotification))
        XCTAssertTrue(diagnosticEvents.contains(.auditSanitizeAttempt(success: true)))
        XCTAssertTrue(diagnosticEvents.contains { event in
            if case .receiveError = event {
                return true
            }
            return false
        })
    }

    @MainActor
    func testAppServerClientEmitsDiagnosticsForGenericAndRateLimitNotifications() throws {
        let client = CodexAppServerClient()
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "example/notification",
              "params": {}
            }
            """.utf8
        ))

        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("example/notification")))

        XCTAssertNoThrow(try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "account/rateLimits/updated",
              "params": {}
            }
            """.utf8
        )))

        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("account/rateLimits/updated")))
        XCTAssertTrue(diagnosticEvents.contains(.rateLimitNotification))
        XCTAssertTrue(diagnosticEvents.contains { event in
            if case .receiveError = event {
                return true
            }
            return false
        })
    }

    @MainActor
    func testAppServerClientEmitsSanitizedRemoteControlDiagnostics() throws {
        let client = CodexAppServerClient()
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "remoteControl/status/changed",
              "params": {
                "status": "connected",
                "websocket_url": "wss://secret.example/ws",
                "account_id": "acct-secret",
                "server_id": "server-secret",
                "environment_id": "environment-secret",
                "message": "do not store this",
                "auth": "secret-token"
              }
            }
            """.utf8
        ))

        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("remoteControl/status/changed")))
        XCTAssertTrue(diagnosticEvents.contains(.remoteControlNotification(status: .connected, warningText: nil)))
        XCTAssertFalse(diagnosticEvents.contains { event in
            if case .receiveError(let text) = event {
                return text.contains("secret") || text.contains("wss://")
            }
            if case .remoteControlNotification(_, let warningText) = event {
                return warningText?.contains("secret") == true || warningText?.contains("wss://") == true
            }
            return false
        })
    }

    func testNotificationAuditSanitizerCapturesSupportedSafeFieldsOnly() throws {
        let settingsRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "thread/settings/updated",
            params: [
                "threadId": "thread-secret",
                "threadSettings": [
                    "cwd": "/Users/private/project",
                    "approvalPolicy": ["granular": ["rules": true, "skill_approval": true]],
                    "approvalsReviewer": "guardian_subagent",
                    "sandboxPolicy": [
                        "type": "workspaceWrite",
                        "writableRoots": ["/Users/private/project"],
                        "networkAccess": true,
                    ],
                    "activePermissionProfile": ["id": ":workspace", "extends": "default"],
                    "model": "gpt-5.5 extra text is ignored",
                    "modelProvider": "openai",
                    "serviceTier": "priority",
                    "effort": "xhigh",
                    "summary": "detailed",
                    "collaborationMode": ["mode": "plan", "settings": ["reasoning_effort": "xhigh"]],
                    "personality": "pragmatic",
                ],
            ] as [String: Any]
        ))

        XCTAssertTrue(settingsRecord.isSupported)
        XCTAssertEqual(settingsRecord.safeValues["model"], "gpt-5.5")
        XCTAssertEqual(settingsRecord.safeValues["modelProvider"], "openai")
        XCTAssertEqual(settingsRecord.safeValues["effort"], "xhigh")
        XCTAssertEqual(settingsRecord.safeValues["approvalPolicy"], "granular")
        XCTAssertEqual(settingsRecord.safeValues["approvalsReviewer"], "guardian_subagent")
        XCTAssertEqual(settingsRecord.safeValues["sandboxPolicy"], "workspaceWrite")
        XCTAssertEqual(settingsRecord.safeValues["collaborationMode"], "plan")
        XCTAssertEqual(settingsRecord.safeValues["hasCwd"], "true")
        XCTAssertEqual(settingsRecord.safeValues["hasServiceTier"], "true")
        XCTAssertEqual(settingsRecord.safeValues["hasPermissionProfile"], "true")
        XCTAssertNil(settingsRecord.safeValues["cwd"])
        XCTAssertNil(settingsRecord.safeValues["serviceTier"])
        XCTAssertGreaterThan(settingsRecord.rejectedUnsafeFieldCount, 0)

        let rerouteRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "model/rerouted",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "fromModel": "gpt-5.4",
                "toModel": "gpt-5.5",
                "reason": "highRiskCyberActivity",
            ] as [String: Any]
        ))

        XCTAssertEqual(rerouteRecord.safeValues["fromModel"], "gpt-5.4")
        XCTAssertEqual(rerouteRecord.safeValues["toModel"], "gpt-5.5")
        XCTAssertEqual(rerouteRecord.safeValues["reason"], "highRiskCyberActivity")
        XCTAssertEqual(rerouteRecord.presenceFlags, ["threadId", "turnId"])

        let turnRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "turn/completed",
            params: [
                "threadId": "thread-secret",
                "turn": [
                    "id": "turn-secret",
                    "status": "completed",
                    "items": [["message": "do not store"]],
                    "startedAt": 1_777_100_000,
                    "completedAt": 1_777_100_010,
                    "durationMs": 10_000,
                    "error": NSNull(),
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(turnRecord.safeValues["turnStatus"], "completed")
        XCTAssertEqual(turnRecord.safeValues["itemCount"], "1")
        XCTAssertEqual(turnRecord.safeValues["hasStartedAt"], "true")
        XCTAssertEqual(turnRecord.safeValues["hasCompletedAt"], "true")
        XCTAssertEqual(turnRecord.safeValues["hasDuration"], "true")
        XCTAssertNil(turnRecord.safeValues["items"])
    }

    func testNotificationAuditSanitizerRejectsContentAndUnknownValues() throws {
        let warningRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "warning",
            params: [
                "threadId": "thread-secret",
                "message": "do not store this warning",
                "account_id": "acct-secret",
                "websocket_url": "wss://secret.example/ws",
                "auth": "secret-token",
                "tool": ["payload": "rm -rf"],
            ] as [String: Any]
        ))

        XCTAssertTrue(warningRecord.isSupported)
        XCTAssertEqual(warningRecord.safeValues["hasMessage"], "true")
        XCTAssertEqual(warningRecord.presenceFlags, ["threadId"])
        XCTAssertGreaterThanOrEqual(warningRecord.rejectedUnsafeFieldCount, 5)

        let unknownRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "future/notification",
            params: [
                "message": "do not store",
                "account_id": "acct-secret",
            ] as [String: Any]
        ))

        XCTAssertFalse(unknownRecord.isSupported)
        XCTAssertEqual(unknownRecord.unsupportedShapeCount, 1)

        let encoded = try JSONEncoder().encode(warningRecord)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("do not store"))
        XCTAssertFalse(json.contains("acct-secret"))
        XCTAssertFalse(json.contains("wss://"))
        XCTAssertFalse(json.contains("secret-token"))
        XCTAssertFalse(json.contains("rm -rf"))
        XCTAssertFalse(json.contains("thread-secret"))
    }

    func testGeneratedNotificationSurfaceFixtureContainsMethodNamesOnly() throws {
        let methods = try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            Self.acceptedGeneratedServerNotificationMethodsFixture
        )
        let nonEmptyLines = Self.acceptedGeneratedServerNotificationMethodsFixture
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        XCTAssertEqual(methods.count, 66)
        XCTAssertEqual(methods, nonEmptyLines)
        XCTAssertEqual(Set(methods).count, methods.count)

        for method in methods {
            XCTAssertTrue(CodexAppServerNotificationSurfaceMethodFixture.isMethodNameOnly(method), method)
            XCTAssertFalse(method.contains("://"), method)
            XCTAssertFalse(method.contains("{"), method)
            XCTAssertFalse(method.contains("}"), method)
            XCTAssertFalse(method.contains("\""), method)
            XCTAssertFalse(method.contains(" "), method)
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            #"{"method":"thread/started","params":{"thread":{"id":"private"}}}"#
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .invalidLine(lineNumber: 1)
            )
            XCTAssertFalse(String(describing: error).contains("private"))
            XCTAssertFalse(String(describing: error).contains("thread/started"))
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            "/Users/private/project"
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .invalidLine(lineNumber: 1)
            )
            XCTAssertFalse(String(describing: error).contains("/Users/private"))
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            "../private"
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .invalidLine(lineNumber: 1)
            )
            XCTAssertFalse(String(describing: error).contains("../private"))
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            "example.com/account/123"
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .invalidLine(lineNumber: 1)
            )
            XCTAssertFalse(String(describing: error).contains("example.com"))
        }

        XCTAssertThrowsError(try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            """
            thread/started
            thread/started
            """
        )) { error in
            XCTAssertEqual(
                error as? CodexAppServerNotificationSurfaceMethodFixture.ParseError,
                .duplicateMethod("thread/started")
            )
        }
    }

    func testNotificationAuditCoverageMatchesAcceptedGeneratedSurface() throws {
        let methods = try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            Self.acceptedGeneratedServerNotificationMethodsFixture
        )
        let report = CodexAppServerNotificationAuditSanitizer.surfaceCoverageForDriftCheck
            .driftReport(acceptedGeneratedMethods: methods)

        XCTAssertFalse(
            report.hasDrift,
            "Unsupported generated notification methods: \(report.unsupportedGeneratedMethods.joined(separator: ", "))"
        )
        XCTAssertEqual(report.acceptedMethodCount, 66)
        XCTAssertEqual(report.coveredGeneratedMethodCount, 66)
        XCTAssertEqual(report.skippedGeneratedMethods, [
            "account/rateLimits/updated",
            "remoteControl/status/changed",
            "thread/tokenUsage/updated",
        ])
        XCTAssertTrue(report.supportedGeneratedMethods.contains("thread/started"))
        XCTAssertTrue(report.supportedGeneratedMethods.contains("account/login/completed"))
    }

    func testNotificationAuditCoverageReportsSyntheticGeneratedDrift() throws {
        var methods = try CodexAppServerNotificationSurfaceMethodFixture.parseMethodNames(
            Self.acceptedGeneratedServerNotificationMethodsFixture
        )
        methods.append("future/notification")
        methods.append("/Users/private/project")
        methods.append("example.com/account/123")

        let report = CodexAppServerNotificationAuditSanitizer.surfaceCoverageForDriftCheck
            .driftReport(acceptedGeneratedMethods: methods)

        XCTAssertTrue(report.hasDrift)
        XCTAssertEqual(report.unsupportedGeneratedMethods, ["future/notification"])
        XCTAssertEqual(report.rejectedGeneratedMethodCount, 2)
        XCTAssertEqual(report.acceptedMethodCount, 67)
        XCTAssertEqual(report.coveredGeneratedMethodCount, 66)
        XCTAssertFalse(report.unsupportedGeneratedMethods.contains("/Users/private/project"))
        XCTAssertFalse(report.unsupportedGeneratedMethods.contains("example.com/account/123"))
    }

    func testNotificationAuditUnknownRuntimeMethodRemainsUnsupportedCountOnly() throws {
        let record = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "future/notification",
            params: [
                "message": "do not store",
                "threadId": "thread-secret",
                "path": "/Users/private/project",
            ] as [String: Any]
        ))

        XCTAssertFalse(record.isSupported)
        XCTAssertEqual(record.safeValues, [:])
        XCTAssertEqual(record.presenceFlags, [])
        XCTAssertEqual(record.unsupportedShapeCount, 1)
        XCTAssertAuditJSON(try encodedAuditJSON(record), excludes: [
            "do not store",
            "thread-secret",
            "/Users/private",
        ])
    }

    func testNotificationAuditSanitizerRecognizesCodex0140NotificationMethods() throws {
        let thread: [String: Any] = [
            "id": "thread-secret",
            "sessionId": "session-secret",
            "forkedFromId": NSNull(),
            "parentThreadId": NSNull(),
            "preview": "private prompt preview",
            "ephemeral": true,
            "modelProvider": "openai",
            "createdAt": 1_777_100_000,
            "updatedAt": 1_777_100_010,
            "status": "running",
            "path": "/Users/private/.codex/thread.jsonl",
            "cwd": "/Users/private/project",
            "cliVersion": "0.140.0",
            "source": "app-server",
            "threadSource": "cli",
            "agentNickname": "private agent",
            "agentRole": "private role",
            "gitInfo": ["branch": "secret-branch"],
            "name": "private thread name",
            "turns": [],
        ]
        let hookRun: [String: Any] = [
            "id": "hook-secret",
            "eventName": "postCommand",
            "handlerType": "shell",
            "executionMode": "blocking",
            "scope": "project",
            "sourcePath": "/Users/private/.codex/config.toml",
            "source": "config",
            "displayOrder": 1,
            "status": "success",
            "statusMessage": "private hook output",
            "startedAt": 1_777_100_000,
            "completedAt": 1_777_100_010,
            "durationMs": 10,
            "entries": [["text": "private hook text"]],
        ]
        let item: [String: Any] = [
            "id": "item-secret",
            "type": "commandExecution",
            "command": "print private",
            "cwd": "/Users/private/project",
            "processId": "process-secret",
            "source": "user",
            "status": "completed",
            "commandActions": [["type": "command", "command": "print private"]],
            "aggregatedOutput": "private output",
            "exitCode": 0,
            "durationMs": 100,
        ]
        let review: [String: Any] = [
            "status": "approved",
            "riskLevel": "low",
            "userAuthorization": "private authorization",
            "rationale": "private rationale",
        ]
        let action: [String: Any] = [
            "type": "command",
            "source": "user",
            "command": "print private",
            "cwd": "/Users/private/project",
        ]

        let fixtures: [(String, [String: Any])] = [
            ("error", ["threadId": "thread-secret", "turnId": "turn-secret", "willRetry": false, "error": ["message": "private error"]]),
            ("thread/started", ["thread": thread]),
            ("thread/archived", ["threadId": "thread-secret"]),
            ("thread/unarchived", ["threadId": "thread-secret"]),
            ("thread/closed", ["threadId": "thread-secret"]),
            ("thread/name/updated", ["threadId": "thread-secret", "threadName": "private name"]),
            ("thread/goal/cleared", ["threadId": "thread-secret"]),
            ("thread/compacted", ["threadId": "thread-secret", "turnId": "turn-secret"]),
            ("skills/changed", [:]),
            ("app/list/updated", ["data": [["id": "app-secret", "name": "Private App", "description": "private", "isAccessible": true]]]),
            ("hook/started", ["threadId": "thread-secret", "turnId": "turn-secret", "run": hookRun]),
            ("hook/completed", ["threadId": "thread-secret", "turnId": "turn-secret", "run": hookRun]),
            ("turn/diff/updated", ["threadId": "thread-secret", "turnId": "turn-secret", "diff": "private diff"]),
            ("turn/plan/updated", ["threadId": "thread-secret", "turnId": "turn-secret", "explanation": "private", "plan": [["step": "private", "status": "pending"]]]),
            ("turn/moderationMetadata", ["threadId": "thread-secret", "turnId": "turn-secret", "metadata": ["private": "metadata"]]),
            ("item/started", ["threadId": "thread-secret", "turnId": "turn-secret", "startedAtMs": 1_777_100_000_000, "item": item]),
            ("item/completed", ["threadId": "thread-secret", "turnId": "turn-secret", "completedAtMs": 1_777_100_001_000, "item": item]),
            ("item/autoApprovalReview/started", ["threadId": "thread-secret", "turnId": "turn-secret", "startedAtMs": 1, "reviewId": "review-secret", "targetItemId": "item-secret", "review": review, "action": action]),
            ("item/autoApprovalReview/completed", ["threadId": "thread-secret", "turnId": "turn-secret", "startedAtMs": 1, "completedAtMs": 2, "reviewId": "review-secret", "targetItemId": "item-secret", "decisionSource": "guardian", "review": review, "action": action]),
            ("rawResponseItem/completed", ["threadId": "thread-secret", "turnId": "turn-secret", "item": ["type": "message", "role": "assistant", "content": []]]),
            ("item/agentMessage/delta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "delta": "private delta"]),
            ("item/plan/delta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "delta": "private delta"]),
            ("item/reasoning/summaryTextDelta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "summaryIndex": 0, "delta": "private reasoning"]),
            ("item/reasoning/summaryPartAdded", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "summaryIndex": 0]),
            ("item/reasoning/textDelta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "contentIndex": 0, "delta": "private reasoning"]),
            ("command/exec/outputDelta", ["processId": "process-secret", "stream": "stdout", "deltaBase64": "cHJpdmF0ZQ==", "capReached": false]),
            ("process/outputDelta", ["processHandle": "process-secret", "stream": "stderr", "deltaBase64": "cHJpdmF0ZQ==", "capReached": true]),
            ("process/exited", ["processHandle": "process-secret", "exitCode": 1, "stdout": "private stdout", "stdoutCapReached": false, "stderr": "private stderr", "stderrCapReached": true]),
            ("item/commandExecution/outputDelta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "delta": "private output"]),
            ("item/commandExecution/terminalInteraction", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "processId": "process-secret", "stdin": "private input"]),
            ("item/fileChange/outputDelta", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "delta": "private patch"]),
            ("item/fileChange/patchUpdated", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "changes": [["path": "/Users/private/file.swift", "kind": "update", "diff": "private diff"]]]),
            ("serverRequest/resolved", ["threadId": "thread-secret", "requestId": "request-secret"]),
            ("item/mcpToolCall/progress", ["threadId": "thread-secret", "turnId": "turn-secret", "itemId": "item-secret", "message": "private message"]),
            ("mcpServer/oauthLogin/completed", ["name": "private server", "success": false, "error": "private error"]),
            ("mcpServer/startupStatus/updated", ["threadId": "thread-secret", "name": "private server", "status": "failed", "error": "private error"]),
            ("externalAgentConfig/import/completed", [:]),
            ("fs/changed", ["watchId": "watch-secret", "changedPaths": ["/Users/private/file.swift"]]),
            ("account/login/completed", ["loginId": "login-secret", "success": true, "error": NSNull()]),
            ("fuzzyFileSearch/sessionUpdated", ["sessionId": "session-secret", "query": "private query", "files": [["path": "/Users/private/file.swift"]]]),
            ("fuzzyFileSearch/sessionCompleted", ["sessionId": "session-secret"]),
            ("windows/worldWritableWarning", ["samplePaths": ["/Users/private/world"], "extraCount": 2, "failedScan": false]),
            ("windowsSandbox/setupCompleted", ["mode": "copy", "success": false, "error": "private error"]),
        ]

        for (method, params) in fixtures {
            let record = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(method: method, params: params), method)
            XCTAssertTrue(record.isSupported, method)
        }
    }

    func testNotificationAuditSanitizerCapturesCodex0140LifecycleHookAndMetadataSafely() throws {
        let threadRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "thread/started",
            params: [
                "thread": [
                    "id": "thread-secret",
                    "sessionId": "session-secret",
                    "forkedFromId": "fork-secret",
                    "parentThreadId": "parent-secret",
                    "preview": "private first prompt",
                    "ephemeral": true,
                    "modelProvider": "openai",
                    "createdAt": 1_777_100_000,
                    "updatedAt": 1_777_100_010,
                    "status": "running",
                    "path": "/Users/private/.codex/session.jsonl",
                    "cwd": "/Users/private/project",
                    "source": "app-server",
                    "threadSource": "cli",
                    "agentNickname": "private agent",
                    "agentRole": "private role",
                    "gitInfo": ["branch": "secret-branch"],
                    "name": "private thread",
                    "turns": [["id": "turn-secret"]],
                ],
            ] as [String: Any]
        ))

        XCTAssertTrue(threadRecord.isSupported)
        XCTAssertEqual(threadRecord.safeValues["threadStatus"], "running")
        XCTAssertEqual(threadRecord.safeValues["modelProvider"], "openai")
        XCTAssertEqual(threadRecord.safeValues["source"], "app-server")
        XCTAssertEqual(threadRecord.safeValues["threadSource"], "cli")
        XCTAssertEqual(threadRecord.safeValues["isEphemeral"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasPreview"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasCwd"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasPath"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasGitInfo"], "true")
        XCTAssertEqual(threadRecord.safeValues["hasThreadName"], "true")
        XCTAssertEqual(threadRecord.safeValues["turnCount"], "1")
        XCTAssertEqual(threadRecord.presenceFlags, ["threadId"])
        XCTAssertAuditJSON(try encodedAuditJSON(threadRecord), excludes: [
            "thread-secret",
            "session-secret",
            "private first prompt",
            "/Users/private",
            "secret-branch",
            "private thread",
            "private agent",
            "private role",
        ])

        let hookRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "hook/completed",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "run": [
                    "id": "hook-secret",
                    "eventName": "postCommand",
                    "handlerType": "shell",
                    "executionMode": "blocking",
                    "scope": "project",
                    "sourcePath": "/Users/private/.codex/config.toml",
                    "source": "config",
                    "displayOrder": 1,
                    "status": "success",
                    "statusMessage": "private status message",
                    "startedAt": 1_777_100_000,
                    "completedAt": 1_777_100_010,
                    "durationMs": 10,
                    "entries": [["text": "private hook output"]],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(hookRecord.safeValues["hookEvent"], "postCommand")
        XCTAssertEqual(hookRecord.safeValues["hookHandlerType"], "shell")
        XCTAssertEqual(hookRecord.safeValues["hookExecutionMode"], "blocking")
        XCTAssertEqual(hookRecord.safeValues["hookScope"], "project")
        XCTAssertEqual(hookRecord.safeValues["hookSource"], "config")
        XCTAssertEqual(hookRecord.safeValues["hookStatus"], "success")
        XCTAssertEqual(hookRecord.safeValues["hookEntryCount"], "1")
        XCTAssertEqual(hookRecord.safeValues["hasSourcePath"], "true")
        XCTAssertEqual(hookRecord.safeValues["hasStatusMessage"], "true")
        XCTAssertEqual(hookRecord.safeValues["hasDuration"], "true")
        XCTAssertAuditJSON(try encodedAuditJSON(hookRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "hook-secret",
            "/Users/private",
            "private status message",
            "private hook output",
        ])

        let appRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "app/list/updated",
            params: [
                "data": [
                    [
                        "id": "app-secret-1",
                        "name": "Private App One",
                        "description": "private description",
                        "logoUrl": "https://private.example/logo.png",
                        "installUrl": "https://private.example/install",
                        "isAccessible": true,
                        "isEnabled": true,
                        "pluginDisplayNames": ["Private Plugin"],
                    ],
                    [
                        "id": "app-secret-2",
                        "name": "Private App Two",
                        "description": NSNull(),
                        "isAccessible": false,
                        "isEnabled": false,
                        "pluginDisplayNames": [],
                    ],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(appRecord.safeValues["appCount"], "2")
        XCTAssertEqual(appRecord.safeValues["accessibleAppCount"], "1")
        XCTAssertAuditJSON(try encodedAuditJSON(appRecord), excludes: [
            "app-secret",
            "Private App",
            "private description",
            "https://private.example",
            "Private Plugin",
        ])

        let startupRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "mcpServer/startupStatus/updated",
            params: [
                "threadId": "thread-secret",
                "name": "private server",
                "status": "failed",
                "error": "private startup error",
            ] as [String: Any]
        ))

        XCTAssertEqual(startupRecord.safeValues["status"], "failed")
        XCTAssertEqual(startupRecord.safeValues["hasName"], "true")
        XCTAssertEqual(startupRecord.safeValues["hasError"], "true")
        XCTAssertEqual(startupRecord.presenceFlags, ["threadId"])
        XCTAssertAuditJSON(try encodedAuditJSON(startupRecord), excludes: [
            "thread-secret",
            "private server",
            "private startup error",
        ])

        let windowsRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "windowsSandbox/setupCompleted",
            params: [
                "mode": "copy",
                "success": false,
                "error": "private setup error",
            ] as [String: Any]
        ))

        XCTAssertEqual(windowsRecord.safeValues["mode"], "copy")
        XCTAssertEqual(windowsRecord.safeValues["success"], "false")
        XCTAssertEqual(windowsRecord.safeValues["hasError"], "true")
        XCTAssertAuditJSON(try encodedAuditJSON(windowsRecord), excludes: ["private setup error"])
    }

    func testNotificationAuditSanitizerRecordsCodex0140ContentHeavyMethodsAsPresenceOnly() throws {
        let deltaRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/agentMessage/delta",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "itemId": "item-secret",
                "delta": "private streamed assistant text",
            ] as [String: Any]
        ))

        XCTAssertTrue(deltaRecord.isSupported)
        XCTAssertEqual(deltaRecord.safeValues["hasDelta"], "true")
        XCTAssertEqual(Set(deltaRecord.presenceFlags), Set(["threadId", "turnId", "itemId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(deltaRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "item-secret",
            "private streamed assistant text",
        ])

        let planRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "turn/plan/updated",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "explanation": "private plan explanation",
                "plan": [
                    ["step": "private first step", "status": "pending"],
                    ["step": "private second step", "status": "in_progress"],
                    ["step": "private third step", "status": "completed"],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(planRecord.safeValues["hasExplanation"], "true")
        XCTAssertEqual(planRecord.safeValues["planStepCount"], "3")
        XCTAssertEqual(planRecord.safeValues["pendingStepCount"], "1")
        XCTAssertEqual(planRecord.safeValues["inProgressStepCount"], "1")
        XCTAssertEqual(planRecord.safeValues["completedStepCount"], "1")
        XCTAssertAuditJSON(try encodedAuditJSON(planRecord), excludes: [
            "private plan explanation",
            "private first step",
            "private second step",
            "private third step",
        ])

        let processRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "process/exited",
            params: [
                "processHandle": "process-secret",
                "exitCode": 42,
                "stdout": "private stdout bytes",
                "stdoutCapReached": false,
                "stderr": "private stderr bytes",
                "stderrCapReached": true,
            ] as [String: Any]
        ))

        XCTAssertEqual(processRecord.safeValues["hasExitCode"], "true")
        XCTAssertEqual(processRecord.safeValues["hasStdout"], "true")
        XCTAssertEqual(processRecord.safeValues["hasStderr"], "true")
        XCTAssertEqual(processRecord.safeValues["stdoutCapReached"], "false")
        XCTAssertEqual(processRecord.safeValues["stderrCapReached"], "true")
        XCTAssertEqual(processRecord.presenceFlags, ["processHandle"])
        XCTAssertAuditJSON(try encodedAuditJSON(processRecord), excludes: [
            "process-secret",
            "private stdout bytes",
            "private stderr bytes",
            "\"42\"",
        ])

        let patchRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/fileChange/patchUpdated",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "itemId": "item-secret",
                "changes": [
                    ["path": "/Users/private/One.swift", "kind": "add", "diff": "private add diff"],
                    ["path": "/Users/private/Two.swift", "kind": "update", "diff": "private update diff"],
                    ["path": "/Users/private/Three.swift", "kind": "delete", "diff": "private delete diff"],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(patchRecord.safeValues["changeCount"], "3")
        XCTAssertEqual(patchRecord.safeValues["addedChangeCount"], "1")
        XCTAssertEqual(patchRecord.safeValues["updatedChangeCount"], "1")
        XCTAssertEqual(patchRecord.safeValues["deletedChangeCount"], "1")
        XCTAssertAuditJSON(try encodedAuditJSON(patchRecord), excludes: [
            "/Users/private",
            "private add diff",
            "private update diff",
            "private delete diff",
        ])

        let fuzzyRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "fuzzyFileSearch/sessionUpdated",
            params: [
                "sessionId": "session-secret",
                "query": "private query",
                "files": [
                    ["path": "/Users/private/One.swift", "score": 0.9],
                    ["path": "/Users/private/Two.swift", "score": 0.7],
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(fuzzyRecord.safeValues["hasQuery"], "true")
        XCTAssertEqual(fuzzyRecord.safeValues["fileCount"], "2")
        XCTAssertEqual(fuzzyRecord.presenceFlags, ["sessionId"])
        XCTAssertAuditJSON(try encodedAuditJSON(fuzzyRecord), excludes: [
            "session-secret",
            "private query",
            "/Users/private",
        ])
    }

    func testNotificationAuditSanitizerRejectsPrivateFieldsForCodex0140ApprovalAndToolMethods() throws {
        let approvalRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/autoApprovalReview/completed",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "startedAtMs": 1_777_100_000_000,
                "completedAtMs": 1_777_100_001_000,
                "reviewId": "review-secret",
                "targetItemId": "item-secret",
                "decisionSource": "guardian",
                "review": [
                    "status": "approved",
                    "riskLevel": "medium",
                    "userAuthorization": "private authorization",
                    "rationale": "private approval rationale",
                ],
                "action": [
                    "type": "command",
                    "source": "user",
                    "command": "cat /Users/private/secrets.txt",
                    "cwd": "/Users/private/project",
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(approvalRecord.safeValues["decisionSource"], "guardian")
        XCTAssertEqual(approvalRecord.safeValues["reviewStatus"], "approved")
        XCTAssertEqual(approvalRecord.safeValues["riskLevel"], "medium")
        XCTAssertEqual(approvalRecord.safeValues["hasUserAuthorization"], "true")
        XCTAssertEqual(approvalRecord.safeValues["hasRationale"], "true")
        XCTAssertEqual(approvalRecord.safeValues["actionType"], "command")
        XCTAssertEqual(approvalRecord.safeValues["actionSource"], "user")
        XCTAssertEqual(approvalRecord.safeValues["hasCommand"], "true")
        XCTAssertEqual(approvalRecord.safeValues["hasCwd"], "true")
        XCTAssertEqual(Set(approvalRecord.presenceFlags), Set(["threadId", "turnId", "reviewId", "targetItemId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(approvalRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "review-secret",
            "item-secret",
            "private authorization",
            "private approval rationale",
            "cat /Users/private/secrets.txt",
            "/Users/private/project",
        ])

        let networkApprovalRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/autoApprovalReview/completed",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "startedAtMs": 1,
                "completedAtMs": 2,
                "reviewId": "review-secret",
                "targetItemId": NSNull(),
                "decisionSource": "guardian",
                "review": ["status": "denied", "riskLevel": "high"],
                "action": [
                    "type": "networkAccess",
                    "target": "https://private.example/api",
                    "host": "private.example",
                    "protocol": "https",
                    "port": 443,
                ],
            ] as [String: Any]
        ))

        XCTAssertEqual(networkApprovalRecord.safeValues["actionType"], "networkAccess")
        XCTAssertEqual(networkApprovalRecord.safeValues["protocol"], "https")
        XCTAssertEqual(networkApprovalRecord.safeValues["hasTarget"], "true")
        XCTAssertEqual(networkApprovalRecord.safeValues["hasHost"], "true")
        XCTAssertEqual(networkApprovalRecord.safeValues["hasPort"], "true")
        XCTAssertEqual(Set(networkApprovalRecord.presenceFlags), Set(["threadId", "turnId", "reviewId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(networkApprovalRecord), excludes: [
            "https://private.example",
            "private.example",
            "\"443\"",
        ])

        let progressRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "item/mcpToolCall/progress",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "itemId": "item-secret",
                "message": "private progress message",
            ] as [String: Any]
        ))

        XCTAssertEqual(progressRecord.safeValues["hasMessage"], "true")
        XCTAssertEqual(Set(progressRecord.presenceFlags), Set(["threadId", "turnId", "itemId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(progressRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "item-secret",
            "private progress message",
        ])

        let accountLoginRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "account/login/completed",
            params: [
                "loginId": "login-secret",
                "success": false,
                "error": "private login error",
            ] as [String: Any]
        ))

        XCTAssertEqual(accountLoginRecord.safeValues["success"], "false")
        XCTAssertEqual(accountLoginRecord.safeValues["hasError"], "true")
        XCTAssertEqual(accountLoginRecord.presenceFlags, ["loginId"])
        XCTAssertAuditJSON(try encodedAuditJSON(accountLoginRecord), excludes: [
            "login-secret",
            "private login error",
        ])

        let requestRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "serverRequest/resolved",
            params: [
                "threadId": "thread-secret",
                "requestId": "request-secret",
            ] as [String: Any]
        ))

        XCTAssertEqual(requestRecord.safeValues, [:])
        XCTAssertEqual(Set(requestRecord.presenceFlags), Set(["threadId", "requestId"]))
        XCTAssertAuditJSON(try encodedAuditJSON(requestRecord), excludes: [
            "thread-secret",
            "request-secret",
        ])
    }

    func testNotificationAuditSanitizerRejectsUnknownCodex0140ProviderAndEnumValues() throws {
        let threadRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "thread/started",
            params: [
                "thread": [
                    "id": "thread-secret",
                    "status": "privateThreadStatus",
                    "modelProvider": "privateProvider",
                    "source": "privateSource",
                    "threadSource": "privateThreadSource",
                ],
            ] as [String: Any]
        ))

        XCTAssertNil(threadRecord.safeValues["threadStatus"])
        XCTAssertNil(threadRecord.safeValues["modelProvider"])
        XCTAssertNil(threadRecord.safeValues["source"])
        XCTAssertNil(threadRecord.safeValues["threadSource"])
        XCTAssertEqual(threadRecord.safeValues["hasModelProvider"], "true")
        XCTAssertAuditJSON(try encodedAuditJSON(threadRecord), excludes: [
            "thread-secret",
            "privateThreadStatus",
            "privateProvider",
            "privateSource",
            "privateThreadSource",
        ])

        let hookRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "hook/completed",
            params: [
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "run": [
                    "eventName": "privateHookEvent",
                    "handlerType": "privateHandler",
                    "executionMode": "privateMode",
                    "scope": "privateScope",
                    "source": "privateSource",
                    "status": "privateStatus",
                ],
            ] as [String: Any]
        ))

        XCTAssertNil(hookRecord.safeValues["hookEvent"])
        XCTAssertNil(hookRecord.safeValues["hookHandlerType"])
        XCTAssertNil(hookRecord.safeValues["hookExecutionMode"])
        XCTAssertNil(hookRecord.safeValues["hookScope"])
        XCTAssertNil(hookRecord.safeValues["hookSource"])
        XCTAssertNil(hookRecord.safeValues["hookStatus"])
        XCTAssertAuditJSON(try encodedAuditJSON(hookRecord), excludes: [
            "thread-secret",
            "turn-secret",
            "privateHookEvent",
            "privateHandler",
            "privateMode",
            "privateScope",
            "privateSource",
            "privateStatus",
        ])

        let settingsRecord = try XCTUnwrap(CodexAppServerNotificationAuditSanitizer.audit(
            method: "thread/settings/updated",
            params: [
                "threadId": "thread-secret",
                "threadSettings": [
                    "modelProvider": "privateProvider",
                    "effort": "privateEffort",
                    "approvalPolicy": ["type": "privatePolicy"],
                    "approvalsReviewer": "privateReviewer",
                    "sandboxPolicy": ["type": "privateSandbox"],
                    "collaborationMode": ["mode": "privateMode"],
                ],
            ] as [String: Any]
        ))

        XCTAssertNil(settingsRecord.safeValues["modelProvider"])
        XCTAssertNil(settingsRecord.safeValues["effort"])
        XCTAssertNil(settingsRecord.safeValues["approvalPolicy"])
        XCTAssertNil(settingsRecord.safeValues["approvalsReviewer"])
        XCTAssertNil(settingsRecord.safeValues["sandboxPolicy"])
        XCTAssertNil(settingsRecord.safeValues["collaborationMode"])
        XCTAssertEqual(settingsRecord.safeValues["hasModelProvider"], "true")
        XCTAssertAuditJSON(try encodedAuditJSON(settingsRecord), excludes: [
            "thread-secret",
            "privateProvider",
            "privateEffort",
            "privatePolicy",
            "privateReviewer",
            "privateSandbox",
            "privateMode",
        ])
    }

    @MainActor
    func testAppServerClientEmitsNotificationAuditWithoutDecodingPayload() throws {
        let client = CodexAppServerClient()
        var diagnosticEvents: [CodexAppServerAuditDiagnosticEvent] = []
        client.onAppServerAuditDiagnosticEvent = { diagnosticEvents.append($0) }

        try client.handleIncomingMessage(data: Data(
            """
            {
              "method": "model/rerouted",
              "params": {
                "threadId": "thread-secret",
                "turnId": "turn-secret",
                "fromModel": "gpt-5.4",
                "toModel": "gpt-5.5",
                "reason": "highRiskCyberActivity",
                "message": "do not store"
              }
            }
            """.utf8
        ))

        XCTAssertTrue(diagnosticEvents.contains(.inboundMethod("model/rerouted")))
        let auditEvent = try XCTUnwrap(diagnosticEvents.compactMap { event -> CodexAppServerNotificationAuditRecord? in
            if case .notificationAudit(let record) = event {
                return record
            }
            return nil
        }.first)

        XCTAssertEqual(auditEvent.method, "model/rerouted")
        XCTAssertEqual(auditEvent.safeValues["fromModel"], "gpt-5.4")
        XCTAssertEqual(auditEvent.safeValues["toModel"], "gpt-5.5")
        XCTAssertGreaterThan(auditEvent.rejectedUnsafeFieldCount, 0)
    }

    func testProfileTokenUsageResponseDecodesSanitizedStatsOnly() throws {
        let response = try JSONDecoder().decode(
            CodexProfileTokenUsageResponse.self,
            from: Data(
                """
                {
                  "profile": {
                    "display_name": "Do Not Store",
                    "username": "private-user",
                    "profile_picture_url": "https://example.com/private.png"
                  },
                  "stats": {
                    "lifetime_tokens": 17220508070,
                    "peak_daily_tokens": 987654321,
                    "daily_usage_buckets": [
                      {"start_date": "2026-05-29", "tokens": 123},
                      {"start_date": "2026-05-30", "tokens": 456},
                      {"start_date": "bad value", "tokens": 999}
                    ]
                  }
                }
                """.utf8
            )
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(snapshot.lifetimeTokens, 17_220_508_070)
        XCTAssertEqual(snapshot.peakDailyTokens, 987_654_321)
        XCTAssertEqual(snapshot.dailyBuckets, [
            CodexProfileTokenDailyBucket(date: "2026-05-29", tokens: 123),
            CodexProfileTokenDailyBucket(date: "2026-05-30", tokens: 456),
        ])

        let encodedSnapshot = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encodedSnapshot.contains("Do Not Store"))
        XCTAssertFalse(encodedSnapshot.contains("private-user"))
        XCTAssertFalse(encodedSnapshot.contains("profile_picture_url"))
    }

    func testProfileTokenUsageResponseAllowsMissingStats() throws {
        let response = try JSONDecoder().decode(
            CodexProfileTokenUsageResponse.self,
            from: Data(#"{"profile":{"display_name":"Private"}}"#.utf8)
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertNil(snapshot.lifetimeTokens)
        XCTAssertNil(snapshot.peakDailyTokens)
        XCTAssertTrue(snapshot.dailyBuckets.isEmpty)
    }

    func testAccountTokenUsageResponseDecodesSanitizedStatsOnly() throws {
        let response = try JSONDecoder().decode(
            CodexAccountTokenUsageResponse.self,
            from: Data(
                """
                {
                  "account": {
                    "id": "acct-private",
                    "email": "private@example.com"
                  },
                  "summary": {
                    "lifetimeTokens": 17220508070,
                    "peakDailyTokens": 987654321,
                    "longestRunningTurnSec": 3661,
                    "currentStreakDays": 3,
                    "longestStreakDays": 19
                  },
                  "dailyUsageBuckets": [
                    {"startDate": "2026-05-29", "tokens": 123},
                    {"startDate": "2026-05-30", "tokens": 456},
                    {"startDate": "bad value", "tokens": 999}
                  ]
                }
                """.utf8
            )
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(snapshot.lifetimeTokens, 17_220_508_070)
        XCTAssertEqual(snapshot.peakDailyTokens, 987_654_321)
        XCTAssertEqual(snapshot.longestRunningTurnSeconds, 3_661)
        XCTAssertEqual(snapshot.currentStreakDays, 3)
        XCTAssertEqual(snapshot.longestStreakDays, 19)
        XCTAssertEqual(snapshot.dailyBuckets, [
            CodexProfileTokenDailyBucket(date: "2026-05-29", tokens: 123),
            CodexProfileTokenDailyBucket(date: "2026-05-30", tokens: 456),
        ])

        let encodedSnapshot = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encodedSnapshot.contains("acct-private"))
        XCTAssertFalse(encodedSnapshot.contains("private@example.com"))
        XCTAssertFalse(encodedSnapshot.contains("account"))
    }

    func testAccountTokenUsageResponseAllowsNullSummaryAndBuckets() throws {
        let response = try JSONDecoder().decode(
            CodexAccountTokenUsageResponse.self,
            from: Data(#"{"summary":null,"dailyUsageBuckets":null}"#.utf8)
        )

        let snapshot = response.domainSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertNil(snapshot.lifetimeTokens)
        XCTAssertNil(snapshot.peakDailyTokens)
        XCTAssertNil(snapshot.longestRunningTurnSeconds)
        XCTAssertNil(snapshot.currentStreakDays)
        XCTAssertNil(snapshot.longestStreakDays)
        XCTAssertTrue(snapshot.dailyBuckets.isEmpty)
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
    func testAppServerClientPrefersAccountUsageReadForProfileTokenSnapshot() async throws {
        var requestedMethods: [String] = []
        let client = CodexAppServerClient(
            ensureConnectedOverride: {},
            sendRequestOverride: { method, _ in
                requestedMethods.append(method)
                XCTAssertEqual(method, "account/usage/read")
                return [
                    "summary": [
                        "lifetimeTokens": Int64(1_000),
                        "peakDailyTokens": Int64(250),
                        "longestRunningTurnSec": Int64(90),
                        "currentStreakDays": Int64(2),
                        "longestStreakDays": Int64(5),
                    ],
                    "dailyUsageBuckets": [
                        [
                            "startDate": "2026-05-30",
                            "tokens": Int64(10),
                        ],
                    ],
                ]
            }
        )

        let snapshot = try await client.profileTokenUsageSnapshot()

        XCTAssertEqual(requestedMethods, ["account/usage/read"])
        XCTAssertEqual(snapshot.lifetimeTokens, 1_000)
        XCTAssertEqual(snapshot.peakDailyTokens, 250)
        XCTAssertEqual(snapshot.longestRunningTurnSeconds, 90)
        XCTAssertEqual(snapshot.currentStreakDays, 2)
        XCTAssertEqual(snapshot.longestStreakDays, 5)
        XCTAssertEqual(snapshot.dailyBuckets.map(\.tokens), [10])
    }

    @MainActor
    func testAppServerClientFallsBackToProfileHTTPWhenAccountUsageReadFails() async throws {
        let endpoint = URL(string: "https://example.com/wham/profiles/me")!
        var requestedMethods: [String] = []
        var authorizationHeaders: [String?] = []
        let profileClient = CodexProfileTokenUsageHTTPClient(
            endpoint: endpoint,
            responseLoader: { request in
                authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
                return (
                    Data(
                        """
                        {
                          "stats": {
                            "lifetime_tokens": 1000,
                            "peak_daily_tokens": 250,
                            "daily_usage_buckets": [
                              {"start_date": "2026-05-30", "tokens": 10}
                            ]
                          }
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
                if method == "account/usage/read" {
                    throw CodexClientError.jsonRPCError("Method not found")
                }
                if method == "getAuthStatus" {
                    return [
                        "authMethod": "chatgpt",
                        "authToken": "fallback-token",
                        "requiresOpenaiAuth": true,
                    ]
                }
                throw CodexClientError.invalidResponse
            },
            profileTokenUsageHTTPClient: profileClient
        )

        let snapshot = try await client.profileTokenUsageSnapshot()

        XCTAssertEqual(requestedMethods, ["account/usage/read", "getAuthStatus"])
        XCTAssertEqual(authorizationHeaders, ["Bearer fallback-token"])
        XCTAssertEqual(snapshot.lifetimeTokens, 1_000)
        XCTAssertEqual(snapshot.peakDailyTokens, 250)
        XCTAssertEqual(snapshot.dailyBuckets.map(\.tokens), [10])
        XCTAssertNil(snapshot.longestRunningTurnSeconds)
        XCTAssertNil(snapshot.currentStreakDays)
        XCTAssertNil(snapshot.longestStreakDays)
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

    @MainActor
    func testProfileTokenUsageHTTPClientRetriesUnauthorizedWithRefreshedAuth() async throws {
        let endpoint = URL(string: "https://example.com/wham/profiles/me")!
        var refreshRequests: [Bool] = []
        var authorizationHeaders: [String?] = []
        var loadCount = 0
        let client = CodexProfileTokenUsageHTTPClient(
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
                          "stats": {
                            "lifetime_tokens": 1000,
                            "peak_daily_tokens": 250,
                            "daily_usage_buckets": [
                              {"start_date": "2026-05-30", "tokens": 10}
                            ]
                          }
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
        XCTAssertEqual(snapshot.lifetimeTokens, 1_000)
        XCTAssertEqual(snapshot.peakDailyTokens, 250)
        XCTAssertEqual(snapshot.dailyBuckets.map(\.tokens), [10])
    }

    private static let acceptedGeneratedServerNotificationMethodsFixture = """
    error
    thread/started
    thread/status/changed
    thread/archived
    thread/unarchived
    thread/closed
    skills/changed
    thread/name/updated
    thread/goal/updated
    thread/goal/cleared
    thread/settings/updated
    thread/tokenUsage/updated
    turn/started
    hook/started
    turn/completed
    hook/completed
    turn/diff/updated
    turn/plan/updated
    item/started
    item/autoApprovalReview/started
    item/autoApprovalReview/completed
    item/completed
    rawResponseItem/completed
    item/agentMessage/delta
    item/plan/delta
    command/exec/outputDelta
    process/outputDelta
    process/exited
    item/commandExecution/outputDelta
    item/commandExecution/terminalInteraction
    item/fileChange/outputDelta
    item/fileChange/patchUpdated
    serverRequest/resolved
    item/mcpToolCall/progress
    mcpServer/oauthLogin/completed
    mcpServer/startupStatus/updated
    account/updated
    account/rateLimits/updated
    app/list/updated
    remoteControl/status/changed
    externalAgentConfig/import/completed
    fs/changed
    item/reasoning/summaryTextDelta
    item/reasoning/summaryPartAdded
    item/reasoning/textDelta
    thread/compacted
    model/rerouted
    model/verification
    turn/moderationMetadata
    warning
    guardianWarning
    deprecationNotice
    configWarning
    fuzzyFileSearch/sessionUpdated
    fuzzyFileSearch/sessionCompleted
    thread/realtime/started
    thread/realtime/itemAdded
    thread/realtime/transcript/delta
    thread/realtime/transcript/done
    thread/realtime/outputAudio/delta
    thread/realtime/sdp
    thread/realtime/error
    thread/realtime/closed
    windows/worldWritableWarning
    windowsSandbox/setupCompleted
    account/login/completed
    """

    private func decodeTokenUsageModel(
        extraRoot: String = "",
        extraTokenUsage: String = ""
    ) throws -> String? {
        let data = Data(
            """
            {
              "threadId": "thread-123",
              "turnId": "turn-456",
              "tokenUsage": {
                "last": {
                  "inputTokens": 1200,
                  "cachedInputTokens": 900,
                  "outputTokens": 300,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1500
                },
                "total": {
                  "inputTokens": 10000,
                  "cachedInputTokens": 7000,
                  "outputTokens": 2000,
                  "reasoningOutputTokens": 400,
                  "totalTokens": 12000
                },
                "modelContextWindow": 258400
                \(extraTokenUsage)
              }
              \(extraRoot)
            }
            """.utf8
        )

        return try JSONDecoder()
            .decode(ThreadTokenUsageUpdatedNotificationPayload.self, from: data)
            .toDomainNotification()
            .model
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func encodedAuditJSON(_ record: CodexAppServerNotificationAuditRecord) throws -> String {
        String(data: try JSONEncoder().encode(record), encoding: .utf8) ?? ""
    }

    private func XCTAssertAuditJSON(
        _ json: String,
        excludes privateValues: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for privateValue in privateValues {
            XCTAssertFalse(json.contains(privateValue), "Stored private value: \(privateValue)", file: file, line: line)
        }
    }

    private func auditField(_ keyPath: String, in audit: CodexTokenUsagePayloadAudit) throws -> CodexTokenPayloadAuditField {
        try XCTUnwrap(audit.fields.first { $0.keyPath == keyPath })
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
            throw CodexSourceHealthReaderError.versionCommandFailed
        }
        guard let output = outputs[executableURL.path] else {
            throw CodexSourceHealthReaderError.versionCommandFailed
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
            throw CodexSourceHealthReaderError.versionCommandFailed
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
    argumentFileURL: URL? = nil
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
            result = {}
        elif method == "getAuthStatus":
            result = {
                "authMethod": "chatgpt",
                "authToken": None,
                "requiresOpenaiAuth": True,
            }
        elif method == "account/rateLimits/read":
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
