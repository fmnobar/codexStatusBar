import Foundation
import SwiftUI

enum CodexResetCreditSyncStatus: String, Codable, Equatable {
    case neverSynced = "never_synced"
    case refreshing
    case succeeded
    case failed

    var displayText: String {
        switch self {
        case .neverSynced:
            return "Not synced"
        case .refreshing:
            return "Refreshing"
        case .succeeded:
            return "Synced"
        case .failed:
            return "Failed"
        }
    }
}

struct CodexResetCreditState: Codable, Equatable {
    var snapshot: CodexResetCreditSnapshot?
    var status: CodexResetCreditSyncStatus
    var lastSyncedAt: Date?
    var lastErrorText: String?

    init(
        snapshot: CodexResetCreditSnapshot? = nil,
        status: CodexResetCreditSyncStatus = .neverSynced,
        lastSyncedAt: Date? = nil,
        lastErrorText: String? = nil
    ) {
        self.snapshot = snapshot
        self.status = status
        self.lastSyncedAt = lastSyncedAt
        self.lastErrorText = lastErrorText
    }

    func isStale(now: Date, staleAfter: TimeInterval) -> Bool {
        guard let lastSyncedAt else {
            return true
        }

        return now.timeIntervalSince(lastSyncedAt) >= staleAfter
    }
}

@MainActor
final class CodexResetCreditStore: ObservableObject {
    static let defaultCacheDuration: TimeInterval = 10 * 60
    static let defaultCreditLimit = 20

    @Published private(set) var state: CodexResetCreditState

    private let fileURL: URL
    private let fileManager: FileManager
    private let creditLimit: Int

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        creditLimit: Int = CodexResetCreditStore.defaultCreditLimit
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.creditLimit = creditLimit
        state = (try? Self.loadState(from: fileURL)) ?? CodexResetCreditState()
    }

    static func applicationSupportStore() -> CodexResetCreditStore {
        let directoryURL = (try? CodexStatusBarData.directoryURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CodexStatusBar", isDirectory: true)
        return CodexResetCreditStore(
            fileURL: directoryURL.appendingPathComponent("reset-credits.json")
        )
    }

    func recordRefreshStarted() {
        state = CodexResetCreditState(
            snapshot: state.snapshot,
            status: .refreshing,
            lastSyncedAt: state.lastSyncedAt,
            lastErrorText: nil
        )
    }

    func recordSuccess(_ snapshot: CodexResetCreditSnapshot) {
        let boundedCredits = Array(snapshot.credits.prefix(creditLimit))
        let boundedSnapshot = CodexResetCreditSnapshot(
            fetchedAt: snapshot.fetchedAt,
            availableCount: snapshot.availableCount,
            credits: boundedCredits
        )
        state = CodexResetCreditState(
            snapshot: boundedSnapshot,
            status: .succeeded,
            lastSyncedAt: boundedSnapshot.fetchedAt,
            lastErrorText: nil
        )
        persist()
    }

    func recordFailure(_ errorText: String) {
        state = CodexResetCreditState(
            snapshot: state.snapshot,
            status: .failed,
            lastSyncedAt: state.lastSyncedAt,
            lastErrorText: errorText
        )
        persist()
    }

    func clear() {
        state = CodexResetCreditState()
        try? fileManager.removeItem(at: fileURL)
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            // A cache write failure must never affect current usage display.
        }
    }

    private static func loadState(from fileURL: URL) throws -> CodexResetCreditState {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexResetCreditState.self, from: data)
    }
}

enum CodexSourceVersionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case appBundled = "app_bundled"
    case homebrew
    case usrLocal = "usr_local"
    case discoveredApp = "discovered_app"
    case path

    var displayTitle: String {
        switch self {
        case .appBundled:
            return "App-bundled"
        case .homebrew:
            return "Homebrew"
        case .usrLocal:
            return "/usr/local"
        case .discoveredApp:
            return "Codex.app"
        case .path:
            return "PATH"
        }
    }
}

struct CodexExecutableCandidate: Equatable, Sendable {
    let url: URL
    let kind: CodexSourceVersionKind
}

enum CodexExecutableCandidateProvider {
    private static let appBundledExecutablePaths = [
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex",
    ]

    private static let fallbackFixedCandidates: [CodexExecutableCandidate] = [
        CodexExecutableCandidate(
            url: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            kind: .appBundled
        ),
        CodexExecutableCandidate(
            url: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            kind: .appBundled
        ),
        CodexExecutableCandidate(
            url: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            kind: .appBundled
        ),
        CodexExecutableCandidate(
            url: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            kind: .appBundled
        ),
        CodexExecutableCandidate(
            url: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            kind: .homebrew
        ),
        CodexExecutableCandidate(
            url: URL(fileURLWithPath: "/usr/local/bin/codex"),
            kind: .usrLocal
        ),
    ]

    static func candidates(
        fileManager: FileManager = .default,
        manifestURL: URL? = Bundle.main.url(
            forResource: "CodexExecutableCandidates",
            withExtension: "txt"
        ),
        applicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) -> [CodexExecutableCandidate] {
        var candidates = fixedCandidates(manifestURL: manifestURL)

        if let appBundleURLs = try? fileManager.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let discoveredCandidates = appBundleURLs
                .filter { $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.hasPrefix("Codex") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .flatMap { appBundleURL in
                    appBundledExecutablePaths.map { executablePath in
                        CodexExecutableCandidate(
                            url: appBundleURL.appending(path: executablePath, directoryHint: .notDirectory),
                            kind: .discoveredApp
                        )
                    }
                }

            candidates.append(contentsOf: discoveredCandidates)
        }

        return deduplicated(candidates)
    }

    static func fixedCandidates(manifestURL: URL?) -> [CodexExecutableCandidate] {
        guard let manifestURL,
              let contents = try? String(contentsOf: manifestURL, encoding: .utf8)
        else {
            return fallbackFixedCandidates
        }

        let paths = contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !paths.isEmpty,
              Set(paths).count == paths.count,
              paths.allSatisfy({ path in
                  path.hasPrefix("/")
                      && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              })
        else {
            return fallbackFixedCandidates
        }

        return paths.map { path in
            CodexExecutableCandidate(
                url: URL(fileURLWithPath: path),
                kind: fixedCandidateKind(for: path)
            )
        }
    }

    private static func fixedCandidateKind(for path: String) -> CodexSourceVersionKind {
        if path.hasPrefix("/Applications/"), path.contains(".app/Contents/Resources/") {
            return .appBundled
        }
        if path.hasPrefix("/opt/homebrew/") {
            return .homebrew
        }
        if path.hasPrefix("/usr/local/") {
            return .usrLocal
        }
        return .path
    }

    static func pathCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CodexExecutableCandidate] {
        guard let path = environment["PATH"] else {
            return []
        }

        return deduplicated(path
            .split(separator: ":")
            .map { pathComponent in
                CodexExecutableCandidate(
                    url: URL(fileURLWithPath: String(pathComponent)).appendingPathComponent("codex"),
                    kind: .path
                )
            })
    }

    static func orderedCandidates(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        manifestURL: URL? = Bundle.main.url(
            forResource: "CodexExecutableCandidates",
            withExtension: "txt"
        ),
        applicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) -> [CodexExecutableCandidate] {
        deduplicated(
            candidates(
                fileManager: fileManager,
                manifestURL: manifestURL,
                applicationsURL: applicationsURL
            )
                + pathCandidates(environment: environment)
        )
    }

    static func executableURLs(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        orderedCandidates(fileManager: fileManager, environment: environment).map(\.url)
    }

    static func deduplicated(_ candidates: [CodexExecutableCandidate]) -> [CodexExecutableCandidate] {
        var deduplicated: [CodexExecutableCandidate] = []
        var seenPaths = Set<String>()

        for candidate in candidates {
            let canonicalPath = candidate.url
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard seenPaths.insert(canonicalPath).inserted else {
                continue
            }
            deduplicated.append(candidate)
        }

        return deduplicated
    }
}

@MainActor
protocol CodexSourceVersionCommandRunning {
    func versionOutput(for executableURL: URL, timeout: TimeInterval) async throws -> String
}

enum CodexExecutableProbeError: LocalizedError, Equatable {
    case versionCommandTimedOut
    case versionCommandFailed
    case versionOutputMalformed

    var errorDescription: String? {
        switch self {
        case .versionCommandTimedOut:
            return "Version command timed out."
        case .versionCommandFailed:
            return "Version command failed."
        case .versionOutputMalformed:
            return "Version output was malformed."
        }
    }
}

private enum CodexBoundedCommandError: Error {
    case cancelled
    case timedOut
    case failed
    case outputTooLarge
}

private final class CodexBoundedCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class CodexBoundedOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()
    private var exceededLimit = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(maximumBytes, 1)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let remainingCapacity = max(maximumBytes - storage.count, 0)
        if remainingCapacity > 0 {
            storage.append(data.prefix(remainingCapacity))
        }
        if data.count > remainingCapacity {
            exceededLimit = true
        }
    }

    func snapshot() -> (data: Data, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, exceededLimit)
    }
}

enum CodexBoundedCommandRunner {
    static func output(
        for executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> String {
        try Task.checkCancellation()
        let cancellation = CodexBoundedCommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(
                            returning: try outputSynchronously(
                                for: executableURL,
                                arguments: arguments,
                                timeout: timeout,
                                maximumOutputBytes: maximumOutputBytes,
                                cancellation: cancellation
                            )
                        )
                    } catch CodexBoundedCommandError.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    nonisolated private static func outputSynchronously(
        for executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        cancellation: CodexBoundedCommandCancellation
    ) throws -> String {
        guard !cancellation.isCancelled else {
            throw CodexBoundedCommandError.cancelled
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputAccumulator = CodexBoundedOutputAccumulator(maximumBytes: maximumOutputBytes)
        let outputReadGroup = DispatchGroup()
        outputReadGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { outputReadGroup.leave() }
            while true {
                do {
                    guard let chunk = try outputPipe.fileHandleForReading.read(upToCount: 16 * 1_024),
                          !chunk.isEmpty
                    else {
                        return
                    }
                    outputAccumulator.append(chunk)
                } catch {
                    return
                }
            }
        }

        do {
            try process.run()
            try? outputPipe.fileHandleForWriting.close()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            _ = outputReadGroup.wait(timeout: .now() + 0.25)
            throw CodexBoundedCommandError.failed
        }

        let deadline = Date().addingTimeInterval(max(timeout, 0.01))
        var commandError: CodexBoundedCommandError?
        while process.isRunning {
            if cancellation.isCancelled {
                commandError = .cancelled
                break
            } else if outputAccumulator.snapshot().exceededLimit {
                commandError = .outputTooLarge
                break
            }
            if Date() >= deadline {
                commandError = .timedOut
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }

        if cancellation.isCancelled, commandError == nil {
            commandError = .cancelled
        }

        if commandError != nil, process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.35)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        if outputReadGroup.wait(timeout: .now() + 0.25) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            _ = outputReadGroup.wait(timeout: .now() + 0.25)
        }
        let outputSnapshot = outputAccumulator.snapshot()

        if let commandError {
            throw commandError
        }
        guard !outputSnapshot.exceededLimit else {
            throw CodexBoundedCommandError.outputTooLarge
        }
        guard process.terminationStatus == 0 else {
            throw CodexBoundedCommandError.failed
        }

        return String(decoding: outputSnapshot.data, as: UTF8.self)
    }
}

struct ProcessCodexSourceVersionCommandRunner: CodexSourceVersionCommandRunning {
    func versionOutput(for executableURL: URL, timeout: TimeInterval) async throws -> String {
        do {
            return try await CodexBoundedCommandRunner.output(
                for: executableURL,
                arguments: ["--version"],
                timeout: timeout,
                maximumOutputBytes: 256 * 1_024
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch CodexBoundedCommandError.timedOut {
            throw CodexExecutableProbeError.versionCommandTimedOut
        } catch {
            throw CodexExecutableProbeError.versionCommandFailed
        }
    }
}

@MainActor
protocol CodexAppServerCapabilityProbing {
    func capabilities(
        for executableURL: URL,
        timeout: TimeInterval
    ) async throws -> CodexAppServerListenSupport.Capabilities
}

struct ProcessCodexAppServerCapabilityProber: CodexAppServerCapabilityProbing {
    func capabilities(
        for executableURL: URL,
        timeout: TimeInterval
    ) async throws -> CodexAppServerListenSupport.Capabilities {
        let helpText = try await CodexBoundedCommandRunner.output(
            for: executableURL,
            arguments: ["app-server", "--help"],
            timeout: timeout,
            maximumOutputBytes: 256 * 1_024
        )
        return CodexAppServerListenSupport.capabilities(helpText: helpText)
    }
}

struct ResolvedCodexExecutable: Equatable, Sendable {
    let url: URL
    let version: String
    let capabilities: CodexAppServerListenSupport.Capabilities
}

@MainActor
protocol CodexExecutableResolving {
    func resolve() async throws -> ResolvedCodexExecutable?
}

struct CodexExecutableResolver: CodexExecutableResolving {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let versionRunner: CodexSourceVersionCommandRunning
    private let capabilityProber: CodexAppServerCapabilityProbing
    private let commandTimeout: TimeInterval
    private let candidatesOverride: [CodexExecutableCandidate]?

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        versionRunner: CodexSourceVersionCommandRunning = ProcessCodexSourceVersionCommandRunner(),
        capabilityProber: CodexAppServerCapabilityProbing = ProcessCodexAppServerCapabilityProber(),
        commandTimeout: TimeInterval = 2,
        candidates: [CodexExecutableCandidate]? = nil
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.versionRunner = versionRunner
        self.capabilityProber = capabilityProber
        self.commandTimeout = commandTimeout
        self.candidatesOverride = candidates
    }

    func resolve() async throws -> ResolvedCodexExecutable? {
        let candidates = candidatesOverride ?? CodexExecutableCandidateProvider.orderedCandidates(
            fileManager: fileManager,
            environment: environment
        )

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.url.path) {
            try Task.checkCancellation()
            do {
                let versionOutput = try await versionRunner.versionOutput(
                    for: candidate.url,
                    timeout: commandTimeout
                )
                try Task.checkCancellation()
                guard let version = Self.parseVersion(from: versionOutput) else {
                    continue
                }

                let capabilities = try await capabilityProber.capabilities(
                    for: candidate.url,
                    timeout: commandTimeout
                )
                try Task.checkCancellation()
                guard capabilities.preferredTransport != nil else {
                    continue
                }

                return ResolvedCodexExecutable(
                    url: candidate.url,
                    version: version,
                    capabilities: capabilities
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // A wrapper can be executable while its packaged binary is missing.
                // Continue through the remaining canonical executable candidates.
                continue
            }
        }

        try Task.checkCancellation()
        return nil
    }

    private static func parseVersion(from output: String) -> String? {
        let pattern = #"\d+(?:\.[0-9A-Za-z-]+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let versionRange = Range(match.range, in: output)
        else {
            return nil
        }

        return String(output[versionRange])
    }

}
