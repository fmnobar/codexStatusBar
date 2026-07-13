import Darwin
import Foundation

private func rethrowCancellation(_ error: Error) throws {
    if error is CancellationError {
        throw CancellationError()
    }
    try Task.checkCancellation()
}

enum CodexClientError: LocalizedError, Equatable {
    case codexExecutableNotFound
    case appServerUnavailable
    case authTokenUnavailable
    case invalidResponse
    case websocketUnavailable
    case requestTimedOut
    case responseTooLarge
    case jsonRPCError(String)

    var errorDescription: String? {
        switch self {
        case .codexExecutableNotFound:
            return "The Codex CLI executable could not be found."
        case .appServerUnavailable:
            return "The Codex app server could not be reached."
        case .authTokenUnavailable:
            return "Codex auth is unavailable."
        case .invalidResponse:
            return "Codex returned an invalid response."
        case .websocketUnavailable:
            return "The Codex websocket is not connected."
        case .requestTimedOut:
            return "The Codex app server request timed out."
        case .responseTooLarge:
            return "The Codex app server response exceeded the size limit."
        case .jsonRPCError(let message):
            return message
        }
    }
}

@MainActor
final class CodexJSONRPCRequestTracker {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private var pendingRequests: [Int: PendingRequest] = [:]

    var pendingRequestCount: Int {
        pendingRequests.count
    }

    func response(
        for requestID: Int,
        timeout: TimeInterval,
        send: @escaping @MainActor () async throws -> Void
    ) async throws -> Data {
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestID] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: nil
                )

                let timeoutNanoseconds = UInt64(max(timeout, 0.001) * 1_000_000_000)
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.fail(requestID: requestID, with: CodexClientError.requestTimedOut)
                }
                pendingRequests[requestID]?.timeoutTask = timeoutTask

                Task { @MainActor [weak self] in
                    do {
                        try await send()
                    } catch {
                        self?.fail(requestID: requestID, with: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.fail(requestID: requestID, with: CancellationError())
            }
        }
    }

    @discardableResult
    func succeed(requestID: Int, resultData: Data) -> Bool {
        guard let pendingRequest = takePendingRequest(requestID: requestID) else {
            return false
        }
        pendingRequest.continuation.resume(returning: resultData)
        return true
    }

    @discardableResult
    func fail(requestID: Int, with error: Error) -> Bool {
        guard let pendingRequest = takePendingRequest(requestID: requestID) else {
            return false
        }
        pendingRequest.continuation.resume(throwing: error)
        return true
    }

    func failAll(with error: Error) {
        let requestIDs = Array(pendingRequests.keys)
        for requestID in requestIDs {
            fail(requestID: requestID, with: error)
        }
    }

    private func takePendingRequest(requestID: Int) -> PendingRequest? {
        guard let pendingRequest = pendingRequests.removeValue(forKey: requestID) else {
            return nil
        }
        pendingRequest.timeoutTask?.cancel()
        return pendingRequest
    }
}

/// Serializes potentially blocking pipe writes away from MainActor. Closing the
/// handle during connection teardown also gives a blocked write a chance to fail
/// without holding up request deadlines or the UI.
final class CodexStandardIOWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "com.farzad.codexstatusbar.app-server-stdin")
    private let onWriteStarted: () -> Void

    init(fileHandle: FileHandle, onWriteStarted: @escaping () -> Void = {}) throws {
        guard fcntl(fileHandle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.fileHandle = fileHandle
        self.onWriteStarted = onWriteStarted
    }

    var suppressesSIGPIPEForTesting: Bool {
        fcntl(fileHandle.fileDescriptor, F_GETNOSIGPIPE) == 1
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [fileHandle] in
                do {
                    self.onWriteStarted()
                    try fileHandle.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        queue.async { [fileHandle] in
            try? fileHandle.close()
        }
    }
}

private final class CodexManagedProcessTerminator: @unchecked Sendable {
    private let process: Process
    private let graceInterval: TimeInterval

    init(process: Process, graceInterval: TimeInterval = 0.35) {
        self.process = process
        self.graceInterval = graceInterval
    }

    func requestTermination() {
        if process.isRunning {
            process.terminate()
        }
    }

    func waitAndEscalate() {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        let deadline = Date().addingTimeInterval(graceInterval)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private final class CodexWebSocketPingWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completedResult: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            continuation.resume(with: completedResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(with result: Result<Void, Error>) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor
protocol CodexWebSocketConnectionOwnershipProbing {
    func processOwnsEstablishedConnection(processIdentifier: pid_t, port: Int) async throws -> Bool
}

struct CodexLsofWebSocketConnectionOwnershipProber: CodexWebSocketConnectionOwnershipProbing {
    func processOwnsEstablishedConnection(processIdentifier: pid_t, port: Int) async throws -> Bool {
        do {
            let output = try await CodexBoundedCommandRunner.output(
                for: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: [
                    "-nP",
                    "-a",
                    "-p", "\(processIdentifier)",
                    "-iTCP:\(port)",
                    "-sTCP:ESTABLISHED",
                    "-F", "pn",
                ],
                timeout: 0.5,
                maximumOutputBytes: 64 * 1_024
            )
            let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            return lines.contains("p\(processIdentifier)")
                && lines.contains { $0.hasPrefix("n127.0.0.1:\(port)->") }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return false
        }
    }
}

@MainActor
protocol CodexProfileTokenUsageFetching: AnyObject {
    func profileTokenUsageSnapshot() async throws -> CodexProfileTokenUsageSnapshot
}

@MainActor
protocol CodexResetCreditFetching: AnyObject {
    func resetCreditSnapshot() async throws -> CodexResetCreditSnapshot
}

@MainActor
final class CodexAppServerClient: NSObject, CodexRateLimitClientProtocol, CodexProfileTokenUsageFetching, CodexResetCreditFetching {
    private struct ConnectionAttempt {
        let id: UInt64
        let task: Task<Void, Error>
        var waiters: [UInt64: CheckedContinuation<Void, Error>]
    }

    var onSnapshot: ((CodexUsageSnapshot) -> Void)?
    var onTokenUsage: ((CodexTokenUsageNotification) -> Void)?
    var onTokenUsagePayloadAudit: ((CodexTokenUsagePayloadAudit) -> Void)?
    var onAppServerAuditDiagnosticEvent: ((CodexAppServerAuditDiagnosticEvent) -> Void)?

    private let decoder = JSONDecoder()
    private let urlSession: URLSession
    private let portRange: ClosedRange<Int>
    private let readyTimeout: TimeInterval
    private let readyPollInterval: TimeInterval
    private let requestTimeout: TimeInterval
    private let maximumIncomingMessageBytes: Int
    private let executableResolver: CodexExecutableResolving
    private let webSocketConnectionOwnershipProber: CodexWebSocketConnectionOwnershipProbing
    private let webSocketHandshakeOverride: (@MainActor (URLSessionWebSocketTask) async throws -> Void)?
    private let ensureConnectedOverride: (@MainActor () async throws -> Void)?
    private let sendRequestOverride: (@MainActor (String, Any?) async throws -> Any)?
    private let profileTokenUsageHTTPClient: CodexProfileTokenUsageHTTPClient?
    private let resetCreditHTTPClient: CodexResetCreditHTTPClient?

    private var process: Process?
    private var ownsProcess = false
    private var currentPort: Int?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var standardIOWriter: CodexStandardIOWriter?
    private var standardOutputFileHandle: FileHandle?
    private var standardIOBuffer = Data()
    private var transportGeneration: UInt64 = 0
    private var connectionAttempt: ConnectionAttempt?
    private var nextConnectionAttemptID: UInt64 = 1
    private var nextConnectionWaiterID: UInt64 = 1
    private var nextRequestID = 1
    private let requestTracker = CodexJSONRPCRequestTracker()
    private var isInitialized = false

    var hasManagedProcessForTesting: Bool {
        ownsProcess && process != nil
    }

    var managedProcessIdentifierForTesting: pid_t? {
        guard ownsProcess else {
            return nil
        }
        return process?.processIdentifier
    }

    var transportGenerationForTesting: UInt64 {
        transportGeneration
    }

    func retireConnectionForTesting(transportGeneration: UInt64) {
        retireManagedConnection(ifGeneration: transportGeneration)
    }

    init(
        urlSession: URLSession = .shared,
        portRange: ClosedRange<Int> = 8877...8881,
        readyTimeout: TimeInterval = 5,
        readyPollInterval: TimeInterval = 0.25,
        requestTimeout: TimeInterval = 10,
        maximumIncomingMessageBytes: Int = 4 * 1_024 * 1_024,
        executableResolver: CodexExecutableResolving? = nil,
        webSocketConnectionOwnershipProber: CodexWebSocketConnectionOwnershipProbing? = nil,
        webSocketHandshakeOverride: (@MainActor (URLSessionWebSocketTask) async throws -> Void)? = nil,
        ensureConnectedOverride: (@MainActor () async throws -> Void)? = nil,
        sendRequestOverride: (@MainActor (String, Any?) async throws -> Any)? = nil,
        profileTokenUsageHTTPClient: CodexProfileTokenUsageHTTPClient? = nil,
        resetCreditHTTPClient: CodexResetCreditHTTPClient? = nil
    ) {
        self.urlSession = urlSession
        self.portRange = portRange
        self.readyTimeout = readyTimeout
        self.readyPollInterval = readyPollInterval
        self.requestTimeout = requestTimeout
        self.maximumIncomingMessageBytes = max(maximumIncomingMessageBytes, 1)
        self.executableResolver = executableResolver ?? CodexExecutableResolver()
        self.webSocketConnectionOwnershipProber = webSocketConnectionOwnershipProber
            ?? CodexLsofWebSocketConnectionOwnershipProber()
        self.webSocketHandshakeOverride = webSocketHandshakeOverride
        self.ensureConnectedOverride = ensureConnectedOverride
        self.sendRequestOverride = sendRequestOverride
        self.profileTokenUsageHTTPClient = profileTokenUsageHTTPClient
        self.resetCreditHTTPClient = resetCreditHTTPClient
    }

    func start() async throws -> CodexUsageSnapshot {
        try await ensureConnected()
        return try await fetchLatestUsageSnapshot()
    }

    func refresh() async throws -> CodexUsageSnapshot {
        try await withSingleReconnect {
            try await self.fetchLatestUsageSnapshot()
        }
    }

    func usageDiagnostics() async throws -> CodexUsageDiagnosticsSnapshot {
        try await withSingleReconnect {
            try await self.fetchUsageDiagnostics()
        }
    }

    func profileTokenUsageSnapshot() async throws -> CodexProfileTokenUsageSnapshot {
        try await withSingleReconnect {
            try await self.fetchProfileTokenUsageSnapshot()
        }
    }

    func resetCreditSnapshot() async throws -> CodexResetCreditSnapshot {
        try await withSingleReconnect {
            try await self.fetchResetCreditHTTPSnapshot()
        }
    }

    func stop() {
        connectionAttempt?.task.cancel()
        retireManagedConnection()
    }

    private func ensureConnected() async throws {
        if let ensureConnectedOverride {
            try await ensureConnectedOverride()
            return
        }

        if isInitialized, webSocketTask != nil || standardIOWriter != nil {
            return
        }

        let waiterID = nextConnectionWaiterID
        nextConnectionWaiterID &+= 1

        if connectionAttempt == nil {
            let attemptID = nextConnectionAttemptID
            nextConnectionAttemptID &+= 1
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    throw CodexClientError.appServerUnavailable
                }
                try Task.checkCancellation()
                try await self.ensureServerAvailable()
                try Task.checkCancellation()
            }
            connectionAttempt = ConnectionAttempt(id: attemptID, task: task, waiters: [:])

            Task { @MainActor [weak self] in
                do {
                    try await task.value
                    self?.completeConnectionAttempt(id: attemptID, result: .success(()))
                } catch {
                    self?.completeConnectionAttempt(id: attemptID, result: .failure(error))
                }
            }
        }

        guard let attemptID = connectionAttempt?.id else {
            throw CodexClientError.appServerUnavailable
        }

        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard var attempt = connectionAttempt, attempt.id == attemptID else {
                    continuation.resume(throwing: CodexClientError.appServerUnavailable)
                    return
                }
                attempt.waiters[waiterID] = continuation
                connectionAttempt = attempt

                if Task.isCancelled {
                    cancelConnectionWaiter(attemptID: attemptID, waiterID: waiterID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelConnectionWaiter(attemptID: attemptID, waiterID: waiterID)
            }
        }
    }

    private func completeConnectionAttempt(id: UInt64, result: Result<Void, Error>) {
        guard let attempt = connectionAttempt, attempt.id == id else {
            return
        }
        connectionAttempt = nil
        for continuation in attempt.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelConnectionWaiter(attemptID: UInt64, waiterID: UInt64) {
        guard var attempt = connectionAttempt,
              attempt.id == attemptID,
              let continuation = attempt.waiters.removeValue(forKey: waiterID)
        else {
            return
        }

        let shouldCancelAttempt = attempt.waiters.isEmpty
        connectionAttempt = attempt
        continuation.resume(throwing: CancellationError())
        if shouldCancelAttempt {
            attempt.task.cancel()
        }
    }

    private func withSingleReconnect<T>(
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        var operationGeneration: UInt64?
        do {
            try await ensureConnected()
            operationGeneration = transportGeneration
            return try await operation()
        } catch {
            try rethrowCancellation(error)
            if let operationGeneration {
                retireManagedConnection(ifGeneration: operationGeneration)
            }
            try await ensureConnected()
            return try await operation()
        }
    }

    private func ensureServerAvailable() async throws {
        guard let resolvedExecutable = try await executableResolver.resolve() else {
            throw CodexClientError.codexExecutableNotFound
        }

        switch resolvedExecutable.capabilities.preferredTransport {
        case .standardIO:
            do {
                try await startManagedStandardIOServer(
                    executableURL: resolvedExecutable.url,
                    capabilities: resolvedExecutable.capabilities
                )
                ownsProcess = true
                currentPort = nil
                return
            } catch {
                stopManagedProcess()
                resetSocketState()
                currentPort = nil
                try rethrowCancellation(error)
            }

        case .legacyWebSocket:
            for port in portRange {
                do {
                    try await startManagedWebSocketServer(on: port, executableURL: resolvedExecutable.url)
                    ownsProcess = true
                    return
                } catch {
                    stopManagedProcess()
                    resetSocketState()
                    currentPort = nil
                    try rethrowCancellation(error)
                }
            }

        case .none:
            break
        }

        throw CodexClientError.appServerUnavailable
    }

    private func startManagedWebSocketServer(on port: Int, executableURL: URL) async throws {
        let nullDevice = FileHandle(forWritingAtPath: "/dev/null")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]
        process.standardOutput = nullDevice
        process.standardError = nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleManagedProcessTermination(process)
            }
        }

        try process.run()
        self.process = process
        ownsProcess = true

        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            guard self.process === process, process.isRunning else {
                break
            }
            do {
                currentPort = port
                try openWebSocketIfNeeded()
                guard let webSocketTask else {
                    throw CodexClientError.websocketUnavailable
                }
                // A WebSocket handshake and ping carry no app-server payload.
                // Do not start the receive loop or send initialize until lsof
                // proves the established server-side socket belongs to the
                // exact app-owned child PID.
                try await verifyWebSocketHandshake(webSocketTask)
                guard self.process === process, process.isRunning else {
                    resetSocketState()
                    currentPort = nil
                    break
                }

                let ownsConnection = try await webSocketConnectionOwnershipProber
                    .processOwnsEstablishedConnection(
                        processIdentifier: process.processIdentifier,
                        port: port
                    )
                guard ownsConnection else {
                    resetSocketState()
                    currentPort = nil
                    break
                }

                startWebSocketReceiveLoopIfNeeded()
                try await initializeSessionIfNeeded()
                guard self.process === process, process.isRunning else {
                    resetSocketState()
                    currentPort = nil
                    break
                }
                onAppServerAuditDiagnosticEvent?(.connected(mode: .webSocket))
                return
            } catch {
                resetSocketState()
                currentPort = nil
                try rethrowCancellation(error)
            }

            if !process.isRunning {
                break
            }

            try await Task.sleep(nanoseconds: UInt64(readyPollInterval * 1_000_000_000))
        }

        throw CodexClientError.appServerUnavailable
    }

    private func startManagedStandardIOServer(
        executableURL: URL,
        capabilities: CodexAppServerListenSupport.Capabilities
    ) async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let nullDevice = FileHandle(forWritingAtPath: "/dev/null")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = capabilities.explicitlyPrefersStandardIO
            ? ["app-server", "--stdio"]
            : ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleManagedProcessTermination(process)
            }
        }

        standardIOWriter = try CodexStandardIOWriter(fileHandle: inputPipe.fileHandleForWriting)
        standardOutputFileHandle = outputPipe.fileHandleForReading
        standardIOBuffer.removeAll(keepingCapacity: true)
        let generation = transportGeneration
        armStandardOutputRead(
            from: outputPipe.fileHandleForReading,
            generation: generation
        )

        try process.run()
        self.process = process
        ownsProcess = true
        try await initializeSessionIfNeeded()
        onAppServerAuditDiagnosticEvent?(.connected(mode: .standardIO))
    }

    /// FileHandle readability callbacks may run again before work dispatched to
    /// MainActor has been consumed. Disarm while a chunk is in flight so noisy
    /// app-server notifications cannot build an unbounded queue of retained Data.
    private func armStandardOutputRead(from fileHandle: FileHandle, generation: UInt64) {
        fileHandle.readabilityHandler = { [weak self] handle in
            handle.readabilityHandler = nil
            let data = handle.availableData

            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.transportGeneration,
                      self.standardOutputFileHandle === handle
                else {
                    return
                }

                self.handleStandardOutputData(data, generation: generation)

                guard !data.isEmpty,
                      generation == self.transportGeneration,
                      self.standardOutputFileHandle === handle
                else {
                    return
                }
                self.armStandardOutputRead(from: handle, generation: generation)
            }
        }
    }

    private func openWebSocketIfNeeded() throws {
        guard webSocketTask == nil else {
            return
        }

        guard let currentPort, let websocketURL = URL(string: "ws://127.0.0.1:\(currentPort)") else {
            throw CodexClientError.websocketUnavailable
        }

        let webSocketTask = urlSession.webSocketTask(with: websocketURL)
        webSocketTask.resume()

        self.webSocketTask = webSocketTask
    }

    private func verifyWebSocketHandshake(_ webSocketTask: URLSessionWebSocketTask) async throws {
        if let webSocketHandshakeOverride {
            try await webSocketHandshakeOverride(webSocketTask)
            return
        }

        try Task.checkCancellation()
        let waiter = CodexWebSocketPingWaiter()
        let timeout = min(max(requestTimeout, 0.1), 1)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiter.install(continuation)
                webSocketTask.sendPing { error in
                    if let error {
                        waiter.finish(with: .failure(error))
                    } else {
                        waiter.finish(with: .success(()))
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    waiter.finish(with: .failure(CodexClientError.appServerUnavailable))
                }
            }
        } onCancel: {
            waiter.finish(with: .failure(CancellationError()))
        }
    }

    private func startWebSocketReceiveLoopIfNeeded() {
        guard receiveLoopTask == nil else {
            return
        }
        receiveLoopTask?.cancel()
        let generation = transportGeneration
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation)
        }
    }

    private func initializeSessionIfNeeded() async throws {
        guard !isInitialized else {
            return
        }

        _ = try await sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-usage-menu-bar",
                    "title": "Codex Usage Menu Bar",
                    "version": "1.0.0",
                ],
                "capabilities": [
                    "experimentalApi": true,
                ],
            ]
        )

        isInitialized = true
    }

    private func fetchLatestUsageSnapshot() async throws -> CodexUsageSnapshot {
        do {
            let whamSnapshot = try await fetchWhamUsageSnapshot()

            do {
                let appServerSnapshot = try await fetchAppServerUsageSnapshot(displaySnapshotOverride: whamSnapshot)
                return appServerSnapshot
            } catch {
                try rethrowCancellation(error)
            }

            return CodexUsageSnapshot.aggregateOnly(displaySnapshot: whamSnapshot)
        } catch {
            try rethrowCancellation(error)
            return try await fetchAppServerUsageSnapshot(displaySnapshotOverride: nil)
        }
    }

    private func fetchAppServerUsageSnapshot(displaySnapshotOverride: CodexRateLimitSnapshot?) async throws -> CodexUsageSnapshot {
        let result = try await sendRequest(method: "account/rateLimits/read", params: nil)
        let data = try makeJSONData(from: result)
        let response = try decoder.decode(AccountRateLimitsResponse.self, from: data)
        return response.usageSnapshot(displaySnapshotOverride: displaySnapshotOverride)
    }

    private func fetchUsageDiagnostics() async throws -> CodexUsageDiagnosticsSnapshot {
        let result = try await sendRequest(method: "account/rateLimits/read", params: nil)
        let data = try makeJSONData(from: result)
        let response = try decoder.decode(AccountRateLimitsResponse.self, from: data)
        return response.diagnosticsSnapshot(generatedAt: Date())
    }

    private func fetchWhamUsageSnapshot() async throws -> CodexRateLimitSnapshot {
        do {
            return try await fetchWhamUsageSnapshot(refreshToken: false)
        } catch WhamUsageFetchError.unauthorized {
            return try await fetchWhamUsageSnapshot(refreshToken: true)
        }
    }

    private func fetchWhamUsageSnapshot(refreshToken: Bool) async throws -> CodexRateLimitSnapshot {
        let authStatus = try await fetchAuthStatus(includeToken: true, refreshToken: refreshToken)

        guard let authToken = authStatus.authToken, !authToken.isEmpty else {
            throw CodexClientError.authTokenUnavailable
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexStatusBar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexClientError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let response = try decoder.decode(WhamUsageResponse.self, from: data)
            guard let snapshot = response.selectedSnapshot() else {
                throw CodexClientError.invalidResponse
            }
            return snapshot
        case 401:
            throw WhamUsageFetchError.unauthorized
        default:
            throw WhamUsageFetchError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }

    private func fetchProfileTokenUsageSnapshot() async throws -> CodexProfileTokenUsageSnapshot {
        do {
            return try await fetchAccountTokenUsageSnapshot()
        } catch {
            try rethrowCancellation(error)
            return try await fetchProfileTokenUsageHTTPSnapshot()
        }
    }

    private func fetchAccountTokenUsageSnapshot() async throws -> CodexProfileTokenUsageSnapshot {
        let result = try await sendRequest(method: "account/usage/read", params: nil)
        let data = try makeJSONData(from: result)
        return try decoder
            .decode(CodexAccountTokenUsageResponse.self, from: data)
            .domainSnapshot(fetchedAt: Date())
    }

    private func fetchProfileTokenUsageHTTPSnapshot() async throws -> CodexProfileTokenUsageSnapshot {
        let profileClient = profileTokenUsageHTTPClient ?? CodexProfileTokenUsageHTTPClient(responseLoader: { [urlSession] request in
            try await urlSession.data(for: request)
        })

        return try await profileClient.fetch { [weak self] refreshToken in
            guard let self else {
                throw CodexClientError.appServerUnavailable
            }

            let authStatus = try await self.fetchAuthStatus(includeToken: true, refreshToken: refreshToken)
            return authStatus.authToken
        }
    }

    private func fetchResetCreditHTTPSnapshot() async throws -> CodexResetCreditSnapshot {
        let resetCreditClient = resetCreditHTTPClient ?? CodexResetCreditHTTPClient(responseLoader: { [urlSession] request in
            try await urlSession.data(for: request)
        })

        return try await resetCreditClient.fetch { [weak self] refreshToken in
            guard let self else {
                throw CodexClientError.appServerUnavailable
            }

            let authStatus = try await self.fetchAuthStatus(includeToken: true, refreshToken: refreshToken)
            return authStatus.authToken
        }
    }

    private func fetchAuthStatus(includeToken: Bool, refreshToken: Bool) async throws -> GetAuthStatusResponse {
        let result = try await sendRequest(
            method: "getAuthStatus",
            params: [
                "includeToken": includeToken,
                "refreshToken": refreshToken,
            ]
        )
        let data = try makeJSONData(from: result)
        return try decoder.decode(GetAuthStatusResponse.self, from: data)
    }

    private func sendRequest(method: String, params: Any?) async throws -> Any {
        if let sendRequestOverride {
            return try await sendRequestOverride(method, params)
        }

        guard webSocketTask != nil || standardIOWriter != nil else {
            throw CodexClientError.websocketUnavailable
        }

        let requestID = nextRequestID
        nextRequestID += 1

        var payload: [String: Any] = [
            "id": requestID,
            "method": method,
        ]

        if let params {
            payload["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let text = String(decoding: data, as: UTF8.self)

        let resultData = try await requestTracker.response(
            for: requestID,
            timeout: requestTimeout
        ) { [weak self] in
            guard let self else {
                throw CodexClientError.websocketUnavailable
            }
            try await self.sendPayload(text)
        }
        return try JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed])
    }

    private func sendPayload(_ text: String) async throws {
        if let webSocketTask {
            try await webSocketTask.send(.string(text))
        } else if let standardIOWriter {
            let framedText = text + "\n"
            try await standardIOWriter.write(Data(framedText.utf8))
        } else {
            throw CodexClientError.websocketUnavailable
        }
    }

    private func receiveLoop(generation: UInt64) async {
        guard let webSocketTask else {
            return
        }

        while !Task.isCancelled, generation == transportGeneration {
            do {
                let message = try await webSocketTask.receive()

                switch message {
                case .data(let data):
                    try handleIncomingMessage(data: data)
                case .string(let text):
                    try handleIncomingMessage(data: Data(text.utf8))
                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled || error is CancellationError || generation != transportGeneration {
                    return
                }
                handleReceiveFailure(error, generation: generation)
                return
            }
        }
    }

    func handleIncomingMessage(data: Data) throws {
        guard data.count <= maximumIncomingMessageBytes else {
            throw CodexClientError.responseTooLarge
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexClientError.invalidResponse
        }

        if let requestID = object["id"] as? Int {
            if let errorObject = object["error"] as? [String: Any] {
                let message = errorObject["message"] as? String ?? "Codex returned an error."
                requestTracker.fail(requestID: requestID, with: CodexClientError.jsonRPCError(message))
                return
            }

            guard let result = object["result"] else {
                requestTracker.fail(requestID: requestID, with: CodexClientError.invalidResponse)
                return
            }

            // A timeout, cancellation, or disconnect may already have completed the
            // continuation. Late responses are valid protocol noise and are ignored.
            let resultData = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
            requestTracker.succeed(requestID: requestID, resultData: resultData)
            return
        }

        guard let method = object["method"] as? String else {
            return
        }

        onAppServerAuditDiagnosticEvent?(.inboundMethod(method))
        if let notificationAudit = CodexAppServerNotificationAuditSanitizer.audit(
            method: method,
            params: object["params"]
        ) {
            onAppServerAuditDiagnosticEvent?(.notificationAudit(notificationAudit))
        }

        if method == "account/rateLimits/updated", let params = object["params"] {
            onAppServerAuditDiagnosticEvent?(.rateLimitNotification)

            let notification: AccountRateLimitsUpdatedNotificationPayload
            do {
                let notificationData = try makeJSONData(from: params)
                notification = try decoder.decode(AccountRateLimitsUpdatedNotificationPayload.self, from: notificationData)
            } catch {
                onAppServerAuditDiagnosticEvent?(.receiveError(
                    "Ignored malformed account/rateLimits/updated notification."
                ))
                // Notifications are optional side-channel updates. A malformed
                // payload must not tear down a healthy request transport.
                return
            }

            if notification.isCodexRelated {
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }

                    do {
                        let latestSnapshot = try await self.fetchLatestUsageSnapshot()
                        self.onSnapshot?(latestSnapshot)
                    } catch {
                        if let snapshot = notification.selectedSnapshot() {
                            self.onSnapshot?(CodexUsageSnapshot.aggregateOnly(displaySnapshot: snapshot))
                        }
                    }
                }
            }
        } else if method == "thread/tokenUsage/updated", let params = object["params"] {
            onAppServerAuditDiagnosticEvent?(.tokenUsageNotification)

            let audit = CodexTokenPayloadAuditor.audit(params: params)
            onAppServerAuditDiagnosticEvent?(.auditSanitizeAttempt(success: audit != nil))
            if let audit {
                onTokenUsagePayloadAudit?(audit)
            }

            do {
                let notificationData = try makeJSONData(from: params)
                let notification = try decoder.decode(ThreadTokenUsageUpdatedNotificationPayload.self, from: notificationData)
                onTokenUsage?(notification.toDomainNotification())
            } catch {
                onAppServerAuditDiagnosticEvent?(.receiveError(
                    "Ignored malformed thread/tokenUsage/updated notification."
                ))
                return
            }
        } else if method == "remoteControl/status/changed" {
            let remoteControlStatus = CodexRemoteControlStatusSanitizer.sanitize(params: object["params"])
            onAppServerAuditDiagnosticEvent?(
                .remoteControlNotification(
                    status: remoteControlStatus.status,
                    warningText: remoteControlStatus.warningText
                )
            )
        }
    }

    func handleStandardOutputData(_ data: Data) {
        handleStandardOutputData(data, generation: transportGeneration)
    }

    private func handleStandardOutputData(_ data: Data, generation: UInt64) {
        guard generation == transportGeneration else {
            return
        }
        guard !data.isEmpty else {
            handleReceiveFailure(CodexClientError.appServerUnavailable, generation: generation)
            return
        }

        standardIOBuffer.append(data)
        let lineSeparator = Data([0x0A])

        while let newlineRange = standardIOBuffer.firstRange(of: lineSeparator) {
            let lineData = standardIOBuffer.subdata(in: standardIOBuffer.startIndex..<newlineRange.lowerBound)
            standardIOBuffer.removeSubrange(standardIOBuffer.startIndex..<newlineRange.upperBound)

            guard !lineData.isEmpty else {
                continue
            }

            do {
                try handleIncomingMessage(data: lineData)
            } catch {
                handleReceiveFailure(error, generation: generation)
                return
            }
        }

        guard standardIOBuffer.count <= maximumIncomingMessageBytes else {
            handleReceiveFailure(CodexClientError.responseTooLarge, generation: generation)
            return
        }
    }

    private func handleReceiveFailure(_ error: Error, generation: UInt64) {
        guard generation == transportGeneration else {
            return
        }
        onAppServerAuditDiagnosticEvent?(.receiveError(error.localizedDescription))
        failPendingRequests(with: error)
        retireManagedConnection(ifGeneration: generation)
    }

    private func handleManagedProcessTermination(_ terminatedProcess: Process) {
        guard process === terminatedProcess else {
            return
        }

        process = nil
        ownsProcess = false
        currentPort = nil
        handleReceiveFailure(
            CodexClientError.appServerUnavailable,
            generation: transportGeneration
        )
    }

    private func failPendingRequests(with error: Error) {
        requestTracker.failAll(with: error)
    }

    private func resetSocketState() {
        transportGeneration &+= 1
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        standardOutputFileHandle?.readabilityHandler = nil
        standardIOWriter?.close()
        try? standardOutputFileHandle?.close()
        standardIOWriter = nil
        standardOutputFileHandle = nil
        standardIOBuffer.removeAll(keepingCapacity: true)
        isInitialized = false
        failPendingRequests(with: CodexClientError.websocketUnavailable)
        onAppServerAuditDiagnosticEvent?(.disconnected(errorText: nil))
    }

    private func retireManagedConnection() {
        let retiredOwnedProcess = ownsProcess && process != nil
        stopManagedProcess()
        resetSocketState()
        if retiredOwnedProcess {
            currentPort = nil
        }
    }

    private func retireManagedConnection(ifGeneration generation: UInt64) {
        guard generation == transportGeneration else {
            return
        }
        retireManagedConnection()
    }

    private func stopManagedProcess() {
        guard ownsProcess, let process else {
            ownsProcess = false
            return
        }

        process.terminationHandler = nil
        self.process = nil
        ownsProcess = false

        let terminator = CodexManagedProcessTerminator(process: process)
        terminator.requestTermination()
        Task.detached(priority: .utility) {
            terminator.waitAndEscalate()
        }
    }

    private func makeJSONData(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

private enum WhamUsageFetchError: Error {
    case unauthorized
    case unexpectedStatusCode(Int)
}
