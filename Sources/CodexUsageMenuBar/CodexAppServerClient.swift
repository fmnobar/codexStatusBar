import Foundation

enum CodexClientError: LocalizedError {
    case codexExecutableNotFound
    case appServerUnavailable
    case invalidResponse
    case websocketUnavailable
    case jsonRPCError(String)

    var errorDescription: String? {
        switch self {
        case .codexExecutableNotFound:
            return "The Codex CLI executable could not be found."
        case .appServerUnavailable:
            return "The Codex app server could not be reached."
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
    var onSnapshot: ((CodexRateLimitSnapshot) -> Void)?

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

    func start() async throws -> CodexRateLimitSnapshot {
        try await ensureConnected()
        return try await fetchLatestSnapshot()
    }

    func refresh() async throws -> CodexRateLimitSnapshot {
        do {
            try await ensureConnected()
            return try await fetchLatestSnapshot()
        } catch {
            resetSocketState()
            try await ensureConnected()
            return try await fetchLatestSnapshot()
        }
    }

    func stop() {
        resetSocketState()
        stopManagedProcess()
    }

    private func ensureConnected() async throws {
        if isInitialized, webSocketTask != nil {
            return
        }

        try await ensureServerAvailable()
        try openWebSocketIfNeeded()
        try await initializeSessionIfNeeded()
    }

    private func ensureServerAvailable() async throws {
        if let currentPort, await readyzResponds(on: currentPort) {
            return
        }

        currentPort = nil

        for port in portRange {
            if await readyzResponds(on: port) {
                currentPort = port
                ownsProcess = false
                return
            }

            do {
                try await startManagedServer(on: port)
                currentPort = port
                ownsProcess = true
                return
            } catch {
                stopManagedProcess()
            }
        }

        throw CodexClientError.appServerUnavailable
    }

    private func startManagedServer(on port: Int) async throws {
        let executableURL = try resolveCodexExecutableURL()
        let nullDevice = FileHandle(forWritingAtPath: "/dev/null")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]
        process.standardOutput = nullDevice
        process.standardError = nullDevice

        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if await readyzResponds(on: port) {
                return
            }

            if !process.isRunning {
                break
            }

            try await Task.sleep(nanoseconds: UInt64(readyPollInterval * 1_000_000_000))
        }

        throw CodexClientError.appServerUnavailable
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

    private func fetchLatestSnapshot() async throws -> CodexRateLimitSnapshot {
        let result = try await sendRequest(method: "account/rateLimits/read", params: nil)
        let data = try makeJSONData(from: result)
        let response = try decoder.decode(AccountRateLimitsResponse.self, from: data)
        return response.selectedSnapshot()
    }

    private func sendRequest(method: String, params: Any?) async throws -> Any {
        guard let webSocketTask else {
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

                do {
                    try await webSocketTask.send(.string(text))
                } catch {
                    await MainActor.run {
                        self.pendingRequests.removeValue(forKey: requestID)?.resume(throwing: error)
                    }
                }
            }
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

    private func handleIncomingMessage(data: Data) throws {
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

        if method == "account/rateLimits/updated", let params = object["params"] {
            let notificationData = try makeJSONData(from: params)
            let notification = try decoder.decode(AccountRateLimitsUpdatedNotificationPayload.self, from: notificationData)

            if let snapshot = notification.selectedSnapshot() {
                onSnapshot?(snapshot)
            }
        }
    }

    private func handleReceiveFailure(_ error: Error) {
        failPendingRequests(with: error)
        resetSocketState()
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
        isInitialized = false
        failPendingRequests(with: CodexClientError.websocketUnavailable)
    }

    private func stopManagedProcess() {
        guard ownsProcess, let process else {
            return
        }

        if process.isRunning {
            process.terminate()
        }

        self.process = nil
        ownsProcess = false
    }

    private func resolveCodexExecutableURL() throws -> URL {
        let fileManager = FileManager.default

        let bundledURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        if fileManager.isExecutableFile(atPath: bundledURL.path) {
            return bundledURL
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

    private func readyzResponds(on port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/readyz") else {
            return false
        }

        do {
            let (_, response) = try await urlSession.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(statusCode)
        } catch {
            return false
        }
    }

    private func makeJSONData(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}
