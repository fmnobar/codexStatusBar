import Foundation

enum CodexClientError: LocalizedError {
    case codexExecutableNotFound
    case appServerUnavailable
    case authTokenUnavailable
    case invalidResponse
    case websocketUnavailable
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
        case .jsonRPCError(let message):
            return message
        }
    }
}

@MainActor
final class CodexAppServerClient: NSObject, CodexRateLimitClientProtocol {
    var onSnapshot: ((CodexUsageSnapshot) -> Void)?
    var onTokenUsage: ((CodexTokenUsageNotification) -> Void)?
    var onTokenUsagePayloadAudit: ((CodexTokenUsagePayloadAudit) -> Void)?
    var onAppServerAuditDiagnosticEvent: ((CodexAppServerAuditDiagnosticEvent) -> Void)?

    private let decoder = JSONDecoder()
    private let urlSession: URLSession
    private let portRange: ClosedRange<Int>
    private let readyTimeout: TimeInterval
    private let readyPollInterval: TimeInterval

    private var process: Process?
    private var ownsProcess = false
    private var currentPort: Int?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var standardInputFileHandle: FileHandle?
    private var standardOutputFileHandle: FileHandle?
    private var standardIOBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]
    private var isInitialized = false

    init(
        urlSession: URLSession = .shared,
        portRange: ClosedRange<Int> = 8877...8881,
        readyTimeout: TimeInterval = 5,
        readyPollInterval: TimeInterval = 0.25
    ) {
        self.urlSession = urlSession
        self.portRange = portRange
        self.readyTimeout = readyTimeout
        self.readyPollInterval = readyPollInterval
    }

    func start() async throws -> CodexUsageSnapshot {
        try await ensureConnected()
        return try await fetchLatestUsageSnapshot()
    }

    func refresh() async throws -> CodexUsageSnapshot {
        do {
            try await ensureConnected()
            return try await fetchLatestUsageSnapshot()
        } catch {
            resetSocketState()
            try await ensureConnected()
            return try await fetchLatestUsageSnapshot()
        }
    }

    func usageDiagnostics() async throws -> CodexUsageDiagnosticsSnapshot {
        do {
            try await ensureConnected()
            return try await fetchUsageDiagnostics()
        } catch {
            resetSocketState()
            try await ensureConnected()
            return try await fetchUsageDiagnostics()
        }
    }

    func stop() {
        resetSocketState()
        stopManagedProcess()
    }

    private func ensureConnected() async throws {
        if isInitialized, webSocketTask != nil || standardInputFileHandle != nil {
            return
        }

        if let currentPort {
            do {
                try await connectToServer(on: currentPort)
                return
            } catch {
                resetSocketState()
                self.currentPort = nil
            }
        }

        try await ensureServerAvailable()
    }

    private func ensureServerAvailable() async throws {
        let executableURL = try resolveCodexExecutableURL()
        if executableSupportsWebSocketListen(executableURL) {
            for port in portRange {
                do {
                    try await connectToServer(on: port)
                    ownsProcess = false
                    return
                } catch {
                    resetSocketState()
                    currentPort = nil
                }

                resetSocketState()
                currentPort = nil
            }

            for port in portRange {
                do {
                    try await startManagedWebSocketServer(on: port, executableURL: executableURL)
                    ownsProcess = true
                    return
                } catch {
                    stopManagedProcess()
                    resetSocketState()
                    currentPort = nil
                }
            }
        } else {
            do {
                try await startManagedStandardIOServer(executableURL: executableURL)
                ownsProcess = true
                currentPort = nil
                return
            } catch {
                stopManagedProcess()
                resetSocketState()
                currentPort = nil
            }
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

        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            do {
                try await connectToServer(on: port)
                return
            } catch {
                resetSocketState()
                currentPort = nil
            }

            if !process.isRunning {
                break
            }

            try await Task.sleep(nanoseconds: UInt64(readyPollInterval * 1_000_000_000))
        }

        throw CodexClientError.appServerUnavailable
    }

    private func startManagedStandardIOServer(executableURL: URL) async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let nullDevice = FileHandle(forWritingAtPath: "/dev/null")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleManagedProcessTermination(process)
            }
        }

        standardInputFileHandle = inputPipe.fileHandleForWriting
        standardOutputFileHandle = outputPipe.fileHandleForReading
        standardIOBuffer.removeAll(keepingCapacity: true)
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.handleStandardOutputData(data)
            }
        }

        try process.run()
        self.process = process
        try await initializeSessionIfNeeded()
        onAppServerAuditDiagnosticEvent?(.connected(mode: .standardIO))
    }

    private func connectToServer(on port: Int) async throws {
        currentPort = port
        try openWebSocketIfNeeded()
        try await initializeSessionIfNeeded()
        onAppServerAuditDiagnosticEvent?(.connected(mode: .webSocket))
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
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
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

            if let appServerSnapshot = try? await fetchAppServerUsageSnapshot(displaySnapshotOverride: whamSnapshot) {
                return appServerSnapshot
            }

            return CodexUsageSnapshot.aggregateOnly(displaySnapshot: whamSnapshot)
        } catch {
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
        guard webSocketTask != nil || standardInputFileHandle != nil else {
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

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation

            Task { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CodexClientError.websocketUnavailable)
                    return
                }

                await self.sendPayload(text, requestID: requestID)
            }
        }
    }

    private func sendPayload(_ text: String, requestID: Int) async {
        do {
            if let webSocketTask {
                try await webSocketTask.send(.string(text))
            } else if let standardInputFileHandle {
                let framedText = text + "\n"
                try standardInputFileHandle.write(contentsOf: Data(framedText.utf8))
            } else {
                throw CodexClientError.websocketUnavailable
            }
        } catch {
            pendingRequests.removeValue(forKey: requestID)?.resume(throwing: error)
        }
    }

    private func receiveLoop() async {
        guard let webSocketTask else {
            return
        }

        while !Task.isCancelled {
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
                handleReceiveFailure(error)
                return
            }
        }
    }

    func handleIncomingMessage(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexClientError.invalidResponse
        }

        if let requestID = object["id"] as? Int {
            if let errorObject = object["error"] as? [String: Any] {
                let message = errorObject["message"] as? String ?? "Codex returned an error."
                pendingRequests.removeValue(forKey: requestID)?.resume(throwing: CodexClientError.jsonRPCError(message))
                return
            }

            guard let result = object["result"] else {
                pendingRequests.removeValue(forKey: requestID)?.resume(throwing: CodexClientError.invalidResponse)
                return
            }

            pendingRequests.removeValue(forKey: requestID)?.resume(returning: result)
            return
        }

        guard let method = object["method"] as? String else {
            return
        }

        onAppServerAuditDiagnosticEvent?(.inboundMethod(method))

        if method == "account/rateLimits/updated", let params = object["params"] {
            onAppServerAuditDiagnosticEvent?(.rateLimitNotification)

            let notification: AccountRateLimitsUpdatedNotificationPayload
            do {
                let notificationData = try makeJSONData(from: params)
                notification = try decoder.decode(AccountRateLimitsUpdatedNotificationPayload.self, from: notificationData)
            } catch {
                onAppServerAuditDiagnosticEvent?(.receiveError(error.localizedDescription))
                throw error
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
                onAppServerAuditDiagnosticEvent?(.receiveError(error.localizedDescription))
                throw error
            }
        }
    }

    private func handleStandardOutputData(_ data: Data) {
        guard !data.isEmpty else {
            handleReceiveFailure(CodexClientError.appServerUnavailable)
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
                handleReceiveFailure(error)
                return
            }
        }
    }

    private func handleReceiveFailure(_ error: Error) {
        onAppServerAuditDiagnosticEvent?(.receiveError(error.localizedDescription))
        failPendingRequests(with: error)
        resetSocketState()
    }

    private func handleManagedProcessTermination(_ terminatedProcess: Process) {
        guard process === terminatedProcess else {
            return
        }

        process = nil
        ownsProcess = false
        handleReceiveFailure(CodexClientError.appServerUnavailable)
    }

    private func failPendingRequests(with error: Error) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()

        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func resetSocketState() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        standardOutputFileHandle?.readabilityHandler = nil
        try? standardInputFileHandle?.close()
        try? standardOutputFileHandle?.close()
        standardInputFileHandle = nil
        standardOutputFileHandle = nil
        standardIOBuffer.removeAll(keepingCapacity: true)
        isInitialized = false
        failPendingRequests(with: CodexClientError.websocketUnavailable)
        onAppServerAuditDiagnosticEvent?(.disconnected(errorText: nil))
    }

    private func stopManagedProcess() {
        guard ownsProcess, let process else {
            return
        }

        process.terminationHandler = nil

        if process.isRunning {
            process.terminate()
        }

        self.process = nil
        ownsProcess = false
    }

    private func resolveCodexExecutableURL() throws -> URL {
        let fileManager = FileManager.default

        for candidate in candidateCodexExecutableURLs(fileManager: fileManager) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for pathComponent in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(pathComponent)).appendingPathComponent("codex")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        throw CodexClientError.codexExecutableNotFound
    }

    private func executableSupportsWebSocketListen(_ executableURL: URL) -> Bool {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--help"]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let helpText = String(decoding: output, as: UTF8.self)
        return CodexAppServerListenSupport.supportsWebSocket(helpText: helpText)
    }

    private func candidateCodexExecutableURLs(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = [
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]

        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if let appBundleURLs = try? fileManager.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let discoveredCandidates = appBundleURLs
                .filter { $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.hasPrefix("Codex") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { $0.appending(path: "Contents/Resources/codex", directoryHint: .notDirectory) }

            candidates.append(contentsOf: discoveredCandidates)
        }

        var deduplicated: [URL] = []
        var seenPaths = Set<String>()

        for candidate in candidates where seenPaths.insert(candidate.path).inserted {
            deduplicated.append(candidate)
        }

        return deduplicated
    }

    private func makeJSONData(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

private enum WhamUsageFetchError: Error {
    case unauthorized
    case unexpectedStatusCode(Int)
}
