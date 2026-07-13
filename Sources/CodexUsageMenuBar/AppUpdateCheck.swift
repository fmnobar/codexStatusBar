import Combine
import CryptoKit
import Darwin
import Foundation

struct AppUpdateRelease: Equatable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [AppUpdateReleaseAsset]

    init(
        tagName: String,
        name: String?,
        htmlURL: URL,
        publishedAt: Date?,
        assets: [AppUpdateReleaseAsset] = []
    ) {
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    var displayVersionText: String {
        tagName
    }

    var displayNameText: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        return tagName
    }

    var matchingCodexStatusBarZipAsset: AppUpdateReleaseAsset? {
        let trimmedTag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isCanonicalReleaseTag(trimmedTag) else {
            return nil
        }
        let expectedPrefix = "CodexStatusBar-\(trimmedTag)-build"

        let matchingAssets = assets.filter { asset in
            guard asset.name.hasPrefix(expectedPrefix), asset.name.hasSuffix(".zip") else {
                return false
            }

            let buildStart = asset.name.index(asset.name.startIndex, offsetBy: expectedPrefix.count)
            let buildEnd = asset.name.index(asset.name.endIndex, offsetBy: -4)
            guard buildStart < buildEnd else {
                return false
            }

            let build = asset.name[buildStart..<buildEnd]
            return build.first?.isNumber == true
                && build.first != "0"
                && build.allSatisfy(\.isNumber)
        }

        return matchingAssets.count == 1 ? matchingAssets[0] : nil
    }

    var releaseVersionText: String {
        var version = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") {
            version.removeFirst()
        }
        return version
    }

    private static func isCanonicalReleaseTag(_ tag: String) -> Bool {
        guard tag.hasPrefix("v") else {
            return false
        }
        let components = tag.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3
            && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

struct AppUpdateReleaseAsset: Equatable, Identifiable {
    var id: String { name }

    let name: String
    let browserDownloadURL: URL
    let contentType: String?
    let size: Int64
    let digest: String?

    var buildNumber: String? {
        guard name.hasSuffix(".zip"), let buildRange = name.range(of: "-build", options: .backwards) else {
            return nil
        }

        let start = buildRange.upperBound
        let end = name.index(name.endIndex, offsetBy: -4)
        guard start < end else {
            return nil
        }

        let build = name[start..<end]
        return build.first?.isNumber == true
            && build.first != "0"
            && build.allSatisfy(\.isNumber)
            ? String(build)
            : nil
    }
}

enum AppUpdateCheckClientError: Error, Equatable {
    case noPublishedRelease
    case invalidResponse
    case requestFailed(statusCode: Int)
    case decodingFailed
}

@MainActor
protocol AppUpdateCheckClientProtocol: AnyObject {
    func latestRelease() async throws -> AppUpdateRelease
}

@MainActor
final class GitHubLatestReleaseClient: AppUpdateCheckClientProtocol {
    typealias ResponseLoader = (URLRequest) async throws -> (Data, URLResponse)

    static let defaultEndpoint = URL(string: "https://api.github.com/repos/fmnobar/codexStatusBar/releases/latest")!

    private let endpoint: URL
    private let responseLoader: ResponseLoader

    init(
        endpoint: URL = GitHubLatestReleaseClient.defaultEndpoint,
        responseLoader: @escaping ResponseLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.endpoint = endpoint
        self.responseLoader = responseLoader
    }

    func latestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CodexStatusBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await responseLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateCheckClientError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            throw AppUpdateCheckClientError.noPublishedRelease
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateCheckClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(GitHubLatestReleasePayload.self, from: data)
            return AppUpdateRelease(
                tagName: payload.tagName,
                name: payload.name,
                htmlURL: payload.htmlURL,
                publishedAt: payload.publishedAt,
                assets: payload.assets.map(\.asset)
            )
        } catch {
            throw AppUpdateCheckClientError.decodingFailed
        }
    }
}

private struct GitHubLatestReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [GitHubReleaseAssetPayload]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        assets = try container.decodeIfPresent([GitHubReleaseAssetPayload].self, forKey: .assets) ?? []
    }
}

private struct GitHubReleaseAssetPayload: Decodable {
    let name: String
    let browserDownloadURL: URL
    let contentType: String?
    let size: Int64
    let digest: String?

    var asset: AppUpdateReleaseAsset {
        AppUpdateReleaseAsset(
            name: name,
            browserDownloadURL: browserDownloadURL,
            contentType: contentType,
            size: size,
            digest: digest
        )
    }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case contentType = "content_type"
        case size
        case digest
    }
}

enum AppVersionComparison: Equatable {
    case updateAvailable
    case upToDate
    case inconclusive

    static func compare(installedVersion: String, latestTag: String) -> AppVersionComparison {
        guard
            let installed = SemanticAppVersion.parse(installedVersion),
            let latest = SemanticAppVersion.parse(latestTag)
        else {
            return .inconclusive
        }

        return latest > installed ? .updateAvailable : .upToDate
    }
}

private struct SemanticAppVersion: Comparable {
    let components: [Int]

    static func parse(_ rawValue: String) -> SemanticAppVersion? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }

        if let prereleaseIndex = value.firstIndex(of: "-") {
            value = String(value[..<prereleaseIndex])
        }
        if let buildIndex = value.firstIndex(of: "+") {
            value = String(value[..<buildIndex])
        }

        let rawComponents = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else {
            return nil
        }

        let components = rawComponents.compactMap { component -> Int? in
            guard !component.isEmpty, component.allSatisfy(\.isNumber) else {
                return nil
            }
            return Int(component)
        }

        guard components.count == rawComponents.count else {
            return nil
        }

        return SemanticAppVersion(components: components)
    }

    static func < (lhs: SemanticAppVersion, rhs: SemanticAppVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let leftComponent = lhs.components.indices.contains(index) ? lhs.components[index] : 0
            let rightComponent = rhs.components.indices.contains(index) ? rhs.components[index] : 0

            if leftComponent != rightComponent {
                return leftComponent < rightComponent
            }
        }

        return false
    }
}

enum AppUpdateCheckState: Equatable {
    case idle
    case checking
    case updateAvailable(AppUpdateRelease)
    case upToDate(AppUpdateRelease)
    case noPublishedRelease
    case inconclusive(AppUpdateRelease)
    case failed

    var release: AppUpdateRelease? {
        switch self {
        case .updateAvailable(let release), .upToDate(let release), .inconclusive(let release):
            return release
        case .idle, .checking, .noPublishedRelease, .failed:
            return nil
        }
    }
}

struct AppUpdatePromptPresentation: Equatable {
    let release: AppUpdateRelease

    var titleText: String {
        "Update \(release.displayVersionText) available"
    }
}

struct AppUpdateNotificationPreferences {
    static let snoozedReleaseTagKey = "AppUpdateNotification.snoozedReleaseTag"
    static let snoozedUntilKey = "AppUpdateNotification.snoozedUntil"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snooze(releaseTag: String, until date: Date) {
        defaults.set(releaseTag, forKey: Self.snoozedReleaseTagKey)
        defaults.set(date, forKey: Self.snoozedUntilKey)
    }

    func isSnoozed(releaseTag: String, at date: Date) -> Bool {
        guard
            defaults.string(forKey: Self.snoozedReleaseTagKey) == releaseTag,
            let snoozedUntil = defaults.object(forKey: Self.snoozedUntilKey) as? Date
        else {
            return false
        }

        return snoozedUntil > date
    }

    func clearExpiredSnooze(at date: Date) {
        guard
            let snoozedUntil = defaults.object(forKey: Self.snoozedUntilKey) as? Date,
            snoozedUntil <= date
        else {
            return
        }

        defaults.removeObject(forKey: Self.snoozedReleaseTagKey)
        defaults.removeObject(forKey: Self.snoozedUntilKey)
    }
}

@MainActor
final class AppUpdateMonitor: ObservableObject {
    static let defaultCheckCacheDuration: TimeInterval = 12 * 60 * 60
    static let defaultSnoozeDuration: TimeInterval = 24 * 60 * 60

    @Published private(set) var updateState: AppUpdateCheckState = .idle
    @Published private(set) var lastCheckedAt: Date?

    private let versionInfo: AppVersionInfo
    private let updateClient: AppUpdateCheckClientProtocol
    private let preferences: AppUpdateNotificationPreferences
    private let now: () -> Date
    private let checkCacheDuration: TimeInterval
    private let snoozeDuration: TimeInterval

    init(
        versionInfo: AppVersionInfo = .current(),
        updateClient: AppUpdateCheckClientProtocol = GitHubLatestReleaseClient(),
        preferences: AppUpdateNotificationPreferences = AppUpdateNotificationPreferences(),
        now: @escaping () -> Date = Date.init,
        checkCacheDuration: TimeInterval = AppUpdateMonitor.defaultCheckCacheDuration,
        snoozeDuration: TimeInterval = AppUpdateMonitor.defaultSnoozeDuration
    ) {
        self.versionInfo = versionInfo
        self.updateClient = updateClient
        self.preferences = preferences
        self.now = now
        self.checkCacheDuration = checkCacheDuration
        self.snoozeDuration = snoozeDuration
    }

    var promptPresentation: AppUpdatePromptPresentation? {
        preferences.clearExpiredSnooze(at: now())

        guard case .updateAvailable(let release) = updateState else {
            return nil
        }

        guard !preferences.isSnoozed(releaseTag: release.tagName, at: now()) else {
            return nil
        }

        return AppUpdatePromptPresentation(release: release)
    }

    func checkIfNeeded() async {
        guard shouldCheckForUpdates else {
            return
        }

        await check(force: false)
    }

    func check(force: Bool) async {
        guard updateState != .checking else {
            return
        }
        if !force, !shouldCheckForUpdates {
            return
        }

        updateState = .checking

        do {
            let release = try await updateClient.latestRelease()
            lastCheckedAt = now()
            updateState = state(for: release)
        } catch AppUpdateCheckClientError.noPublishedRelease {
            lastCheckedAt = now()
            updateState = .noPublishedRelease
        } catch {
            lastCheckedAt = now()
            updateState = .failed
        }
    }

    func snoozeCurrentPrompt() {
        guard case .updateAvailable(let release) = updateState else {
            return
        }

        preferences.snooze(
            releaseTag: release.tagName,
            until: now().addingTimeInterval(snoozeDuration)
        )
        objectWillChange.send()
    }

    private var shouldCheckForUpdates: Bool {
        guard let lastCheckedAt else {
            return true
        }

        return now().timeIntervalSince(lastCheckedAt) >= checkCacheDuration
    }

    private func state(for release: AppUpdateRelease) -> AppUpdateCheckState {
        switch AppVersionComparison.compare(installedVersion: versionInfo.version, latestTag: release.tagName) {
        case .updateAvailable:
            return .updateAvailable(release)
        case .upToDate:
            return .upToDate(release)
        case .inconclusive:
            return .inconclusive(release)
        }
    }
}

struct AppUpdatePackage: Equatable {
    let release: AppUpdateRelease
    let asset: AppUpdateReleaseAsset
    let zipURL: URL
    let appURL: URL
    let cleanupRootURL: URL?
    let bundleIdentifier: String
    let immutableContentSHA256: String?
    let signingRequirement: AppUpdateSigningRequirement?

    init(
        release: AppUpdateRelease,
        asset: AppUpdateReleaseAsset,
        zipURL: URL,
        appURL: URL,
        cleanupRootURL: URL? = nil,
        bundleIdentifier: String = "com.farzad.codexstatusbar",
        immutableContentSHA256: String? = nil,
        signingRequirement: AppUpdateSigningRequirement? = nil
    ) {
        self.release = release
        self.asset = asset
        self.zipURL = zipURL
        self.appURL = appURL
        self.cleanupRootURL = cleanupRootURL
        self.bundleIdentifier = bundleIdentifier
        self.immutableContentSHA256 = immutableContentSHA256
        self.signingRequirement = signingRequirement
    }
}

struct AppUpdateSigningRequirement: Equatable {
    let teamIdentifier: String
    let designatedRequirement: String
}

enum AppUpdateDownloadError: Error, Equatable {
    case invalidResponse
    case requestFailed(statusCode: Int)
    case responseTooLarge(maximumBytes: Int64)
    case cancelled
    case writeFailed
}

@MainActor
protocol AppUpdateDownloadClientProtocol: AnyObject {
    func download(
        asset: AppUpdateReleaseAsset,
        to destinationURL: URL,
        progress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL
}

@MainActor
final class AppUpdateDownloadClient: AppUpdateDownloadClientProtocol {
    typealias ProgressHandler = @MainActor @Sendable (Double?) -> Void
    typealias ResponseLoader = (
        URLRequest,
        URL,
        Int64,
        @escaping ProgressHandler
    ) async throws -> URLResponse

    static let defaultMaximumArchiveBytes: Int64 = 256 * 1024 * 1024
    static let defaultRequestTimeout: TimeInterval = 60
    static let defaultResourceTimeout: TimeInterval = 10 * 60

    private let fileManager: FileManager
    private let maximumArchiveBytes: Int64
    private let requestTimeout: TimeInterval
    private let responseLoader: ResponseLoader

    init(
        fileManager: FileManager = .default,
        maximumArchiveBytes: Int64 = AppUpdateDownloadClient.defaultMaximumArchiveBytes,
        requestTimeout: TimeInterval = AppUpdateDownloadClient.defaultRequestTimeout,
        resourceTimeout: TimeInterval = AppUpdateDownloadClient.defaultResourceTimeout,
        responseLoader: ResponseLoader? = nil
    ) {
        self.fileManager = fileManager
        self.maximumArchiveBytes = maximumArchiveBytes
        self.requestTimeout = requestTimeout
        self.responseLoader = responseLoader ?? { request, destinationURL, maximumBytes, progress in
            let downloader = AppUpdateStreamingDownloader(
                destinationURL: destinationURL,
                maximumBytes: maximumBytes,
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout,
                progress: progress
            )
            return try await downloader.download(request: request)
        }
    }

    func download(
        asset: AppUpdateReleaseAsset,
        to destinationURL: URL,
        progress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL {
        progress(0)

        guard asset.size <= 0 || asset.size <= maximumArchiveBytes else {
            throw AppUpdateDownloadError.responseTooLarge(maximumBytes: maximumArchiveBytes)
        }

        var request = URLRequest(url: asset.browserDownloadURL)
        request.timeoutInterval = requestTimeout
        request.setValue("CodexStatusBar", forHTTPHeaderField: "User-Agent")

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: destinationURL)
            let response = try await responseLoader(
                request,
                destinationURL,
                maximumArchiveBytes,
                progress
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppUpdateDownloadError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw AppUpdateDownloadError.requestFailed(statusCode: httpResponse.statusCode)
            }
            let fileSize = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard fileSize >= 0, Int64(fileSize) <= maximumArchiveBytes else {
                throw AppUpdateDownloadError.responseTooLarge(maximumBytes: maximumArchiveBytes)
            }
            progress(1)
            return destinationURL
        } catch let error as AppUpdateDownloadError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch is CancellationError {
            try? fileManager.removeItem(at: destinationURL)
            throw AppUpdateDownloadError.cancelled
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw AppUpdateDownloadError.writeFailed
        }
    }
}

private final class AppUpdateStreamingDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let maximumBytes: Int64
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let progress: AppUpdateDownloadClient.ProgressHandler
    private let lock = NSLock()

    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var forcedError: AppUpdateDownloadError?
    private var didMoveDownload = false

    init(
        destinationURL: URL,
        maximumBytes: Int64,
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        progress: @escaping AppUpdateDownloadClient.ProgressHandler
    ) {
        self.destinationURL = destinationURL
        self.maximumBytes = maximumBytes
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.progress = progress
    }

    func download(request: URLRequest) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(request: request, continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(
        request: URLRequest,
        continuation: CheckedContinuation<URLResponse, Error>
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)

        lock.lock()
        if let forcedError {
            lock.unlock()
            session.invalidateAndCancel()
            continuation.resume(throwing: forcedError)
            return
        }
        self.continuation = continuation
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        if forcedError == nil {
            forcedError = .cancelled
        }
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes
            || (totalBytesExpectedToWrite > maximumBytes && totalBytesExpectedToWrite > 0) {
            lock.lock()
            forcedError = .responseTooLarge(maximumBytes: maximumBytes)
            lock.unlock()
            downloadTask.cancel()
            return
        }

        let fraction: Double? = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            : nil
        Task { @MainActor [progress] in
            progress(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let fileSize = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard fileSize >= 0, Int64(fileSize) <= maximumBytes else {
                throw AppUpdateDownloadError.responseTooLarge(maximumBytes: maximumBytes)
            }
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            lock.lock()
            didMoveDownload = true
            lock.unlock()
        } catch let error as AppUpdateDownloadError {
            lock.lock()
            forcedError = error
            lock.unlock()
        } catch {
            lock.lock()
            forcedError = .writeFailed
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let forcedError = forcedError
        let didMoveDownload = didMoveDownload
        lock.unlock()

        session.finishTasksAndInvalidate()
        guard let continuation else {
            return
        }
        if let forcedError {
            continuation.resume(throwing: forcedError)
        } else if let error {
            continuation.resume(throwing: error)
        } else if didMoveDownload, let response = task.response {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: AppUpdateDownloadError.writeFailed)
        }
    }
}

enum AppUpdatePackageVerificationError: Error, Equatable {
    case assetNameMismatch
    case checksumMissing
    case checksumMalformed
    case checksumMismatch
    case archiveTooLarge
    case checksumReadFailed
    case unzipFailed
    case missingAppBundle
    case missingInfoPlist
    case bundleIdentifierMismatch(expected: String, actual: String?)
    case versionMismatch(expected: String, actual: String?)
    case buildMismatch(expected: String, actual: String?)
    case expectedSignerUnavailable
    case signingTeamMismatch(expected: String, actual: String?)
    case designatedRequirementMismatch
    case immutableContentDigestUnavailable
    case verificationCommandFailed(String)
}

@MainActor
protocol AppUpdatePackageVerifierProtocol: AnyObject {
    func verify(
        zipURL: URL,
        release: AppUpdateRelease,
        asset: AppUpdateReleaseAsset,
        installedBundleIdentifier: String,
        installedAppURL: URL
    ) async throws -> AppUpdatePackage
}

struct AppUpdateCommandResult: Equatable {
    let output: String
    let errorOutput: String
}

enum AppUpdateCommandError: Error, Equatable {
    case launchFailed(String)
    case nonZeroExit(status: Int32, output: String)
    case timedOut
    case outputLimitExceeded
    case cancelled
}

@MainActor
protocol AppUpdateCommandRunning {
    func run(executablePath: String, arguments: [String]) async throws -> AppUpdateCommandResult
}

@MainActor
final class AppUpdateProcessCommandRunner: AppUpdateCommandRunning {
    static let defaultTimeout: TimeInterval = 60
    static let defaultMaximumOutputBytes = 1024 * 1024

    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    init(
        timeout: TimeInterval = AppUpdateProcessCommandRunner.defaultTimeout,
        maximumOutputBytes: Int = AppUpdateProcessCommandRunner.defaultMaximumOutputBytes
    ) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run(executablePath: String, arguments: [String]) async throws -> AppUpdateCommandResult {
        let execution = AppUpdateProcessExecution(
            executablePath: executablePath,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        return try await execution.run()
    }
}

private final class AppUpdateProcessExecution: @unchecked Sendable {
    private let executablePath: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let drainGroup = DispatchGroup()
    private let lock = NSLock()

    private var continuation: CheckedContinuation<AppUpdateCommandResult, Error>?
    private var outputData = Data()
    private var errorData = Data()
    private var forcedError: AppUpdateCommandError?
    private var didComplete = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run() async throws -> AppUpdateCommandResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            requestStop(error: .cancelled)
        }
    }

    private func start(continuation: CheckedContinuation<AppUpdateCommandResult, Error>) {
        lock.lock()
        self.continuation = continuation
        let cancelledBeforeStart = forcedError != nil
        lock.unlock()
        if cancelledBeforeStart {
            complete(terminationStatus: nil)
            return
        }

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        drainGroup.enter()
        drainGroup.enter()
        drain(
            handle: outputPipe.fileHandleForReading,
            isErrorOutput: false
        )
        drain(
            handle: errorPipe.fileHandleForReading,
            isErrorOutput: true
        )
        process.terminationHandler = { [weak self] process in
            self?.drainGroup.notify(queue: .global(qos: .utility)) {
                self?.complete(terminationStatus: process.terminationStatus)
            }
        }

        do {
            try process.run()
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
        } catch {
            lock.lock()
            forcedError = .launchFailed(error.localizedDescription)
            lock.unlock()
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            drainGroup.notify(queue: .global(qos: .utility)) { [weak self] in
                self?.complete(terminationStatus: nil)
            }
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.requestStop(error: .timedOut)
        }
        lock.lock()
        self.timeoutWorkItem = timeoutWorkItem
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )
    }

    private func drain(handle: FileHandle, isErrorOutput: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.drainGroup.leave() }
            do {
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    self?.append(data, isErrorOutput: isErrorOutput)
                }
            } catch {
                self?.requestStop(error: .launchFailed("Could not read command output."))
            }
        }
    }

    private func append(_ data: Data, isErrorOutput: Bool) {
        var shouldStop = false
        lock.lock()
        let totalBytes = outputData.count + errorData.count
        let remainingBytes = max(0, maximumOutputBytes - totalBytes)
        if remainingBytes > 0 {
            if isErrorOutput {
                errorData.append(data.prefix(remainingBytes))
            } else {
                outputData.append(data.prefix(remainingBytes))
            }
        }
        if data.count > remainingBytes, forcedError == nil {
            forcedError = .outputLimitExceeded
            shouldStop = true
        }
        lock.unlock()
        if shouldStop {
            stopProcess()
        }
    }

    private func requestStop(error: AppUpdateCommandError) {
        lock.lock()
        if forcedError == nil {
            forcedError = error
        }
        let shouldCompleteWithoutProcess = process.processIdentifier == 0
        lock.unlock()
        if shouldCompleteWithoutProcess {
            complete(terminationStatus: nil)
        } else {
            stopProcess()
        }
    }

    private func stopProcess() {
        guard process.isRunning else {
            return
        }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak process] in
            guard let process, process.isRunning else {
                return
            }
            kill(pid, SIGKILL)
        }
    }

    private func complete(terminationStatus: Int32?) {
        lock.lock()
        guard !didComplete, let continuation else {
            lock.unlock()
            return
        }
        didComplete = true
        self.continuation = nil
        timeoutWorkItem?.cancel()
        let forcedError = forcedError
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        lock.unlock()

        if let forcedError {
            continuation.resume(throwing: forcedError)
            return
        }
        guard let terminationStatus else {
            continuation.resume(throwing: AppUpdateCommandError.launchFailed("Command did not start."))
            return
        }
        guard terminationStatus == 0 else {
            let combinedOutput = [output, errorOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            continuation.resume(throwing: AppUpdateCommandError.nonZeroExit(
                status: terminationStatus,
                output: combinedOutput
            ))
            return
        }
        continuation.resume(returning: AppUpdateCommandResult(output: output, errorOutput: errorOutput))
    }
}

enum AppUpdateImmutableContentDigest {
    // Release bundles use controlled filenames. Hashing each relative directory/file
    // path and file content (plus every symlink destination) makes copies and renames
    // stable while detecting any post-verification bundle substitution.
    static let shellProgram = #"""
    set -euo pipefail
    APP_PATH="$1"
    [[ -d "$APP_PATH" && ! -L "$APP_PATH" ]]
    {
      while IFS= read -r item_path; do
        relative_path="${item_path#"$APP_PATH"/}"
        if [[ -L "$item_path" ]]; then
          link_target="$(/usr/bin/readlink "$item_path")"
          printf 'L\037%s\037%s\n' "$relative_path" "$link_target"
        elif [[ -d "$item_path" ]]; then
          printf 'D\037%s\n' "$relative_path"
        else
          file_digest="$(/usr/bin/shasum -a 256 "$item_path" | /usr/bin/awk '{print $1}')"
          printf 'F\037%s\037%s\n' "$relative_path" "$file_digest"
        fi
      done < <(/usr/bin/find "$APP_PATH" -mindepth 1 \( -type d -o -type f -o -type l \) -print | LC_ALL=C /usr/bin/sort)
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
    """#

    @MainActor
    static func digest(
        for appURL: URL,
        commandRunner: AppUpdateCommandRunning
    ) async throws -> String {
        let result = try await commandRunner.run(
            executablePath: "/bin/bash",
            arguments: ["-c", shellProgram, "--", appURL.path]
        )
        let digest = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }), digest == digest.lowercased() else {
            throw AppUpdatePackageVerificationError.immutableContentDigestUnavailable
        }
        return digest
    }
}

private enum AppUpdateArchiveDigest {
    static func sha256(for fileURL: URL, maximumBytes: Int64) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            var totalBytes: Int64 = 0

            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                totalBytes += Int64(data.count)
                guard totalBytes <= maximumBytes else {
                    throw AppUpdatePackageVerificationError.archiveTooLarge
                }
                hasher.update(data: data)
            }

            return hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        }.value
    }
}

@MainActor
final class AppUpdatePackageVerifier: AppUpdatePackageVerifierProtocol {
    private let fileManager: FileManager
    private let commandRunner: AppUpdateCommandRunning
    private let maximumArchiveBytes: Int64

    init(
        fileManager: FileManager = .default,
        maximumArchiveBytes: Int64 = AppUpdateDownloadClient.defaultMaximumArchiveBytes,
        commandRunner: AppUpdateCommandRunning = AppUpdateProcessCommandRunner()
    ) {
        self.fileManager = fileManager
        self.maximumArchiveBytes = maximumArchiveBytes
        self.commandRunner = commandRunner
    }

    func verify(
        zipURL: URL,
        release: AppUpdateRelease,
        asset: AppUpdateReleaseAsset,
        installedBundleIdentifier: String,
        installedAppURL: URL
    ) async throws -> AppUpdatePackage {
        let releaseForAssetValidation = release.assets.isEmpty
            ? AppUpdateRelease(
                tagName: release.tagName,
                name: release.name,
                htmlURL: release.htmlURL,
                publishedAt: release.publishedAt,
                assets: [asset]
            )
            : release
        guard releaseForAssetValidation.matchingCodexStatusBarZipAsset == asset else {
            throw AppUpdatePackageVerificationError.assetNameMismatch
        }
        try await verifyChecksum(zipURL: zipURL, asset: asset)

        let extractionURL = zipURL
            .deletingLastPathComponent()
            .appendingPathComponent("Expanded-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        var shouldRetainExtraction = false
        defer {
            if !shouldRetainExtraction {
                try? fileManager.removeItem(at: extractionURL)
            }
        }

        do {
            _ = try await commandRunner.run(
                executablePath: "/usr/bin/ditto",
                arguments: ["-x", "-k", zipURL.path, extractionURL.path]
            )
        } catch {
            throw AppUpdatePackageVerificationError.unzipFailed
        }

        let appURL = extractionURL.appendingPathComponent("CodexStatusBar.app", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppUpdatePackageVerificationError.missingAppBundle
        }

        let info = try readInfoPlist(for: appURL)
        let actualBundleIdentifier = info["CFBundleIdentifier"] as? String
        guard actualBundleIdentifier == installedBundleIdentifier else {
            throw AppUpdatePackageVerificationError.bundleIdentifierMismatch(
                expected: installedBundleIdentifier,
                actual: actualBundleIdentifier
            )
        }

        let actualVersion = info["CFBundleShortVersionString"] as? String
        guard actualVersion == release.releaseVersionText else {
            throw AppUpdatePackageVerificationError.versionMismatch(
                expected: release.releaseVersionText,
                actual: actualVersion
            )
        }

        let expectedBuild = asset.buildNumber ?? ""
        let actualBuild = info["CFBundleVersion"] as? String
        guard !expectedBuild.isEmpty, actualBuild == expectedBuild else {
            throw AppUpdatePackageVerificationError.buildMismatch(
                expected: expectedBuild,
                actual: actualBuild
            )
        }

        let signingRequirement = try await expectedSigningRequirement(for: installedAppURL)

        do {
            _ = try await commandRunner.run(
                executablePath: "/usr/bin/codesign",
                arguments: [
                    "--verify",
                    "--deep",
                    "--strict",
                    "--verbose=2",
                    "-R=\(signingRequirement.designatedRequirement)",
                    appURL.path,
                ]
            )
            let stagedSignature = try await commandRunner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", appURL.path]
            )
            let stagedTeam = Self.teamIdentifier(from: stagedSignature)
            guard stagedTeam == signingRequirement.teamIdentifier else {
                throw AppUpdatePackageVerificationError.signingTeamMismatch(
                    expected: signingRequirement.teamIdentifier,
                    actual: stagedTeam
                )
            }
            let stagedRequirementResult = try await commandRunner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--display", "--requirements", "-", appURL.path]
            )
            guard Self.designatedRequirement(from: stagedRequirementResult) == signingRequirement.designatedRequirement else {
                throw AppUpdatePackageVerificationError.designatedRequirementMismatch
            }
            _ = try await commandRunner.run(
                executablePath: "/usr/sbin/spctl",
                arguments: ["-a", "-vv", "--type", "execute", appURL.path]
            )
        } catch let error as AppUpdatePackageVerificationError {
            throw error
        } catch {
            throw AppUpdatePackageVerificationError.verificationCommandFailed(String(describing: error))
        }

        let immutableContentSHA256: String
        do {
            immutableContentSHA256 = try await AppUpdateImmutableContentDigest.digest(
                for: appURL,
                commandRunner: commandRunner
            )
        } catch let error as AppUpdatePackageVerificationError {
            throw error
        } catch {
            throw AppUpdatePackageVerificationError.verificationCommandFailed(String(describing: error))
        }

        let package = AppUpdatePackage(
            release: release,
            asset: asset,
            zipURL: zipURL,
            appURL: appURL,
            cleanupRootURL: zipURL.deletingLastPathComponent(),
            bundleIdentifier: installedBundleIdentifier,
            immutableContentSHA256: immutableContentSHA256,
            signingRequirement: signingRequirement
        )
        shouldRetainExtraction = true
        return package
    }

    private func verifyChecksum(zipURL: URL, asset: AppUpdateReleaseAsset) async throws {
        guard let rawDigest = asset.digest, !rawDigest.isEmpty else {
            throw AppUpdatePackageVerificationError.checksumMissing
        }
        let digest = rawDigest.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = "sha256:"
        guard digest == rawDigest, digest.hasPrefix(prefix) else {
            throw AppUpdatePackageVerificationError.checksumMalformed
        }

        let expectedHash = String(digest.dropFirst(prefix.count)).lowercased()
        guard
            expectedHash.count == 64,
            expectedHash.allSatisfy({ $0.isHexDigit })
        else {
            throw AppUpdatePackageVerificationError.checksumMalformed
        }

        let fileSize = try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize, fileSize >= 0 else {
            throw AppUpdatePackageVerificationError.checksumReadFailed
        }
        guard Int64(fileSize) <= maximumArchiveBytes else {
            throw AppUpdatePackageVerificationError.archiveTooLarge
        }

        let actualHash: String
        do {
            actualHash = try await AppUpdateArchiveDigest.sha256(
                for: zipURL,
                maximumBytes: maximumArchiveBytes
            )
        } catch let error as AppUpdatePackageVerificationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppUpdatePackageVerificationError.checksumReadFailed
        }

        guard actualHash == expectedHash else {
            throw AppUpdatePackageVerificationError.checksumMismatch
        }
    }

    private func expectedSigningRequirement(for installedAppURL: URL) async throws -> AppUpdateSigningRequirement {
        do {
            let signatureResult = try await commandRunner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", installedAppURL.path]
            )
            guard
                let teamIdentifier = Self.teamIdentifier(from: signatureResult),
                Self.combinedOutput(signatureResult).contains("Authority=Developer ID Application:")
            else {
                throw AppUpdatePackageVerificationError.expectedSignerUnavailable
            }

            let requirementResult = try await commandRunner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--display", "--requirements", "-", installedAppURL.path]
            )
            guard let designatedRequirement = Self.designatedRequirement(from: requirementResult) else {
                throw AppUpdatePackageVerificationError.expectedSignerUnavailable
            }
            guard
                designatedRequirement.contains("anchor apple generic"),
                designatedRequirement.contains("certificate leaf[subject.OU] = \"\(teamIdentifier)\"")
            else {
                throw AppUpdatePackageVerificationError.expectedSignerUnavailable
            }

            return AppUpdateSigningRequirement(
                teamIdentifier: teamIdentifier,
                designatedRequirement: designatedRequirement
            )
        } catch let error as AppUpdatePackageVerificationError {
            throw error
        } catch {
            throw AppUpdatePackageVerificationError.expectedSignerUnavailable
        }
    }

    private static func teamIdentifier(from result: AppUpdateCommandResult) -> String? {
        combinedOutput(result)
            .split(separator: "\n")
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { identifier in
                identifier.isEmpty || identifier == "not set" ? nil : identifier
            }
    }

    private static func designatedRequirement(from result: AppUpdateCommandResult) -> String? {
        let output = combinedOutput(result)
        guard let markerRange = output.range(of: "designated =>") else {
            return nil
        }
        let requirement = output[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return requirement.isEmpty ? nil : requirement
    }

    private static func combinedOutput(_ result: AppUpdateCommandResult) -> String {
        [result.output, result.errorOutput]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func readInfoPlist(for appURL: URL) throws -> [String: Any] {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else {
            throw AppUpdatePackageVerificationError.missingInfoPlist
        }

        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppUpdatePackageVerificationError.missingInfoPlist
        }

        return plist
    }
}

struct AppUpdateInstallLaunch: Equatable {
    let scriptURL: URL
    let arguments: [String]
}

enum AppUpdateInstallerError: Error, Equatable {
    case targetParentUnavailable
    case targetNotWritable(URL)
    case scriptWriteFailed
    case missingSigningRequirement
    case missingImmutableContentDigest
    case missingSafeCleanupRoot
    case launchFailed(String)
}

@MainActor
protocol AppUpdateInstallerProtocol: AnyObject {
    func canInstall(to targetAppURL: URL) -> Bool
    func install(
        package: AppUpdatePackage,
        targetAppURL: URL,
        currentProcessIdentifier: Int32
    ) async throws -> AppUpdateInstallLaunch
}

@MainActor
protocol AppUpdateProcessLaunching {
    func launch(executableURL: URL, arguments: [String]) throws
}

@MainActor
final class AppUpdateProcessLauncher: AppUpdateProcessLaunching {
    func launch(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
    }
}

@MainActor
final class AppUpdateInstaller: AppUpdateInstallerProtocol {
    private let fileManager: FileManager
    private let processLauncher: AppUpdateProcessLaunching
    private let scriptDirectory: URL
    private let writableDirectoryCheck: (URL) -> Bool

    init(
        fileManager: FileManager = .default,
        processLauncher: AppUpdateProcessLaunching = AppUpdateProcessLauncher(),
        scriptDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexStatusBarUpdateInstaller", isDirectory: true),
        writableDirectoryCheck: ((URL) -> Bool)? = nil
    ) {
        self.fileManager = fileManager
        self.processLauncher = processLauncher
        self.scriptDirectory = scriptDirectory
        self.writableDirectoryCheck = writableDirectoryCheck ?? { url in
            fileManager.isWritableFile(atPath: url.path)
        }
    }

    func canInstall(to targetAppURL: URL) -> Bool {
        writableDirectoryCheck(targetAppURL.deletingLastPathComponent())
    }

    func install(
        package: AppUpdatePackage,
        targetAppURL: URL,
        currentProcessIdentifier: Int32
    ) async throws -> AppUpdateInstallLaunch {
        let targetParentURL = targetAppURL.deletingLastPathComponent()
        guard !targetParentURL.path.isEmpty else {
            throw AppUpdateInstallerError.targetParentUnavailable
        }
        guard writableDirectoryCheck(targetParentURL) else {
            throw AppUpdateInstallerError.targetNotWritable(targetParentURL)
        }
        guard let signingRequirement = package.signingRequirement else {
            throw AppUpdateInstallerError.missingSigningRequirement
        }
        guard
            let immutableContentSHA256 = package.immutableContentSHA256,
            immutableContentSHA256.count == 64,
            immutableContentSHA256.allSatisfy({ $0.isHexDigit }),
            immutableContentSHA256 == immutableContentSHA256.lowercased()
        else {
            throw AppUpdateInstallerError.missingImmutableContentDigest
        }
        guard let expectedBuild = package.asset.buildNumber else {
            throw AppUpdateInstallerError.missingImmutableContentDigest
        }
        guard let cleanupRootURL = package.cleanupRootURL else {
            throw AppUpdateInstallerError.missingSafeCleanupRoot
        }
        let cleanupRootPath = cleanupRootURL.standardizedFileURL.path
        let ownershipMarkerURL = cleanupRootURL
            .appendingPathComponent(".codex-status-bar-update-staging")
        var markerIsDirectory: ObjCBool = false
        let appIsDescendant = Self.isStrictDescendant(package.appURL, of: cleanupRootURL)
        let zipIsDescendant = Self.isStrictDescendant(package.zipURL, of: cleanupRootURL)
        let markerExists = fileManager.fileExists(
            atPath: ownershipMarkerURL.path,
            isDirectory: &markerIsDirectory
        )
        let markerIsSymbolicLink =
            (try? ownershipMarkerURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        guard
            cleanupRootPath != "/",
            appIsDescendant,
            zipIsDescendant,
            markerExists,
            !markerIsDirectory.boolValue,
            !markerIsSymbolicLink
        else {
            throw AppUpdateInstallerError.missingSafeCleanupRoot
        }

        do {
            try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
            let scriptURL = scriptDirectory
                .appendingPathComponent("install-codex-status-bar-\(UUID().uuidString).sh")
            let logURL = scriptDirectory
                .appendingPathComponent("install-codex-status-bar-\(UUID().uuidString).log")
            try Self.installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let arguments = [
                scriptURL.path,
                "\(currentProcessIdentifier)",
                package.appURL.path,
                targetAppURL.path,
                logURL.path,
                package.bundleIdentifier,
                package.release.releaseVersionText,
                expectedBuild,
                immutableContentSHA256,
                signingRequirement.teamIdentifier,
                signingRequirement.designatedRequirement,
                cleanupRootURL.path,
            ]
            try processLauncher.launch(executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: arguments)
            return AppUpdateInstallLaunch(scriptURL: scriptURL, arguments: arguments)
        } catch let error as AppUpdateInstallerError {
            throw error
        } catch {
            if error is CocoaError {
                throw AppUpdateInstallerError.scriptWriteFailed
            }
            throw AppUpdateInstallerError.launchFailed(error.localizedDescription)
        }
    }

    private static func isStrictDescendant(_ candidateURL: URL, of rootURL: URL) -> Bool {
        let rootComponents = rootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidateParentComponents = candidateURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .pathComponents
        guard
            !candidateURL.lastPathComponent.isEmpty,
            candidateParentComponents.count >= rootComponents.count
        else {
            return false
        }
        return candidateParentComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    static let installerScript = """
    #!/bin/bash
    set -euo pipefail

    CURRENT_PID="$1"
    STAGED_APP="$2"
    TARGET_APP="$3"
    LOG_PATH="$4"
    EXPECTED_BUNDLE_IDENTIFIER="$5"
    EXPECTED_VERSION="$6"
    EXPECTED_BUILD="$7"
    EXPECTED_CONTENT_SHA256="$8"
    EXPECTED_TEAM="$9"
    EXPECTED_REQUIREMENT="${10}"
    CLEANUP_ROOT="${11}"

    DITTO_BIN="${CODEX_UPDATE_DITTO_BIN:-/usr/bin/ditto}"
    MV_BIN="${CODEX_UPDATE_MV_BIN:-/bin/mv}"
    CODESIGN_BIN="${CODEX_UPDATE_CODESIGN_BIN:-/usr/bin/codesign}"
    SPCTL_BIN="${CODEX_UPDATE_SPCTL_BIN:-/usr/sbin/spctl}"
    OPEN_BIN="${CODEX_UPDATE_OPEN_BIN:-/usr/bin/open}"
    PGREP_BIN="${CODEX_UPDATE_PGREP_BIN:-/usr/bin/pgrep}"
    PS_BIN="${CODEX_UPDATE_PS_BIN:-/bin/ps}"
    KILL_BIN="${CODEX_UPDATE_KILL_BIN:-/bin/kill}"
    PLIST_BUDDY_BIN="${CODEX_UPDATE_PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
    MAX_EXIT_WAIT_ATTEMPTS="${CODEX_UPDATE_MAX_EXIT_WAIT_ATTEMPTS:-150}"
    MAX_LAUNCH_WAIT_ATTEMPTS="${CODEX_UPDATE_MAX_LAUNCH_WAIT_ATTEMPTS:-50}"
    WAIT_INTERVAL="${CODEX_UPDATE_WAIT_INTERVAL:-0.2}"

    exec >"$LOG_PATH" 2>&1

    fail() {
      echo "update installer: $*" >&2
      return 1
    }

    canonical_directory_path() {
      (cd -P -- "$1" && pwd -P)
    }

    TARGET_PARENT="$(canonical_directory_path "$(dirname "$TARGET_APP")")"
    TARGET_APP="$TARGET_PARENT/$(basename "$TARGET_APP")"
    CLEANUP_ROOT="$(canonical_directory_path "$CLEANUP_ROOT")"
    CLEANUP_ROOT="${CLEANUP_ROOT%/}"
    [[ "$(basename "$TARGET_APP")" == "CodexStatusBar.app" ]] || fail "Unexpected target app name."
    [[ -d "$TARGET_PARENT" && ! -L "$TARGET_PARENT" ]] || fail "Target parent is unavailable or symlinked."
    [[ -d "$STAGED_APP" && ! -L "$STAGED_APP" ]] || fail "Staged app is unavailable or symlinked."
    [[ -f "$CLEANUP_ROOT/.codex-status-bar-update-staging" ]] || fail "Update staging ownership marker is unavailable."
    [[ "$STAGED_APP" == "$CLEANUP_ROOT/"* ]] || fail "Staged app is outside the owned cleanup root."
    [[ "$TARGET_APP" != "$CLEANUP_ROOT" && "$TARGET_APP" != "$CLEANUP_ROOT/"* ]] \
      || fail "Cleanup root overlaps the installed target."
    [[ -n "$EXPECTED_BUNDLE_IDENTIFIER" && -n "$EXPECTED_VERSION" && -n "$EXPECTED_BUILD" ]] \
      || fail "Release identity is unavailable."
    [[ "$EXPECTED_CONTENT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "Immutable content digest is unavailable."
    [[ -n "$EXPECTED_TEAM" && -n "$EXPECTED_REQUIREMENT" ]] || fail "Signing requirement is unavailable."

    TEMP_TARGET="$TARGET_PARENT/.CodexStatusBar.update.$$"
    BACKUP_TARGET="$TARGET_PARENT/.CodexStatusBar.backup.$$"
    FAILED_TARGET="$TARGET_PARENT/.CodexStatusBar.failed.$$"
    HAD_BACKUP=0
    REPLACEMENT_INSTALLED=0
    INSTALL_CONFIRMED=0

    safe_remove_sibling() {
      local path="$1"
      local parent
      local name
      parent="$(canonical_directory_path "$(dirname "$path")")"
      name="$(basename "$path")"
      [[ "$parent" == "$TARGET_PARENT" ]] || fail "Refusing to remove path outside the target parent."
      case "$name" in
        .CodexStatusBar.update.*|.CodexStatusBar.backup.*|.CodexStatusBar.failed.*)
          ;;
        *)
          fail "Refusing to remove unexpected sibling '$name'."
          ;;
      esac
      [[ ! -L "$path" ]] || fail "Refusing to recursively remove a symlink."
      if [[ -e "$path" ]]; then
        /bin/rm -rf -- "$path"
      fi
    }

    safe_cleanup_staging() {
      [[ -d "$CLEANUP_ROOT" && ! -L "$CLEANUP_ROOT" ]] || return 0
      [[ -f "$CLEANUP_ROOT/.codex-status-bar-update-staging" ]] \
        || fail "Refusing to remove unowned update staging."
      [[ "$STAGED_APP" == "$CLEANUP_ROOT/"* ]] \
        || fail "Refusing to remove staging outside the verified cleanup relationship."
      /bin/rm -rf -- "$CLEANUP_ROOT"
    }

    target_process_identifiers() {
      local candidate_pid
      local command_path
      local expected_executable="$TARGET_APP/Contents/MacOS/CodexStatusBar"
      while IFS= read -r candidate_pid; do
        [[ -n "$candidate_pid" ]] || continue
        command_path="$("$PS_BIN" -p "$candidate_pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')"
        if [[ "$command_path" == "$expected_executable" ]]; then
          printf '%s\n' "$candidate_pid"
        fi
      done < <("$PGREP_BIN" -x CodexStatusBar 2>/dev/null || true)
    }

    terminate_target_executable() {
      local attempt
      local candidate_pid
      local -a target_pids=()
      while IFS= read -r candidate_pid; do
        [[ -n "$candidate_pid" ]] && target_pids+=("$candidate_pid")
      done < <(target_process_identifiers)
      (( ${#target_pids[@]} > 0 )) || return 0

      "$KILL_BIN" -TERM "${target_pids[@]}" >/dev/null 2>&1 || true
      for ((attempt = 0; attempt < MAX_LAUNCH_WAIT_ATTEMPTS; attempt += 1)); do
        if ! target_process_identifiers | grep -q .; then
          return 0
        fi
        sleep "$WAIT_INTERVAL"
      done

      while IFS= read -r candidate_pid; do
        [[ -n "$candidate_pid" ]] && "$KILL_BIN" -KILL "$candidate_pid" >/dev/null 2>&1 || true
      done < <(target_process_identifiers)
    }

    verify_signed_app() {
      local app_path="$1"
      local requirement_output
      local actual_requirement
      local signature_details
      local actual_team

      "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "-R=$EXPECTED_REQUIREMENT" "$app_path"
      signature_details="$("$CODESIGN_BIN" --display --verbose=4 "$app_path" 2>&1)"
      actual_team="$(printf '%s\n' "$signature_details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
      [[ "$actual_team" == "$EXPECTED_TEAM" ]] || fail "Staged app signer team '$actual_team' does not match '$EXPECTED_TEAM'."
      requirement_output="$("$CODESIGN_BIN" --display --requirements - "$app_path" 2>&1)"
      actual_requirement="$(printf '%s\n' "$requirement_output" | sed -n 's/^designated => //p' | head -1)"
      [[ "$actual_requirement" == "$EXPECTED_REQUIREMENT" ]] || fail "Staged app designated requirement does not match the installed app."
      "$SPCTL_BIN" -a -vv --type execute "$app_path"
    }

    immutable_content_digest() {
      /bin/bash -s -- "$1" <<'CODEX_UPDATE_DIGEST'
    \(AppUpdateImmutableContentDigest.shellProgram)
    CODEX_UPDATE_DIGEST
    }

    verify_release_app() {
      local app_path="$1"
      local actual_bundle_identifier
      local actual_version
      local actual_build
      local actual_content_sha256

      [[ -d "$app_path" && ! -L "$app_path" ]] || fail "Release app is unavailable or symlinked: $app_path"
      actual_bundle_identifier="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
      actual_version="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
      actual_build="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
      [[ "$actual_bundle_identifier" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
        || fail "Release app bundle identifier changed after verification."
      [[ "$actual_version" == "$EXPECTED_VERSION" ]] \
        || fail "Release app version changed after verification."
      [[ "$actual_build" == "$EXPECTED_BUILD" ]] \
        || fail "Release app build changed after verification."
      actual_content_sha256="$(immutable_content_digest "$app_path")"
      [[ "$actual_content_sha256" == "$EXPECTED_CONTENT_SHA256" ]] \
        || fail "Release app content changed after verification."
      verify_signed_app "$app_path"
    }

    restore_backup() {
      if [[ "$REPLACEMENT_INSTALLED" == "1" ]]; then
        terminate_target_executable || true
      fi
      if [[ "$REPLACEMENT_INSTALLED" == "1" && -e "$TARGET_APP" ]]; then
        if ! "$MV_BIN" "$TARGET_APP" "$FAILED_TARGET"; then
          echo "Could not move the failed replacement aside; backup remains at $BACKUP_TARGET" >&2
          return 1
        fi
      fi
      if [[ "$HAD_BACKUP" == "1" && -e "$BACKUP_TARGET" ]]; then
        if [[ -e "$TARGET_APP" ]] || ! "$MV_BIN" "$BACKUP_TARGET" "$TARGET_APP"; then
          echo "Could not restore the previous app; backup remains at $BACKUP_TARGET" >&2
          return 1
        fi
        "$OPEN_BIN" "$TARGET_APP" >/dev/null 2>&1 || true
      fi
      safe_remove_sibling "$TEMP_TARGET" || true
      safe_remove_sibling "$FAILED_TARGET" || true
    }

    finish() {
      local exit_status=$?
      if [[ "$exit_status" != "0" && "$INSTALL_CONFIRMED" != "1" ]]; then
        restore_backup || true
      fi
      safe_cleanup_staging || true
      return "$exit_status"
    }
    trap finish EXIT

    attempt=0
    while kill -0 "$CURRENT_PID" 2>/dev/null; do
      if (( attempt >= MAX_EXIT_WAIT_ATTEMPTS )); then
        fail "Timed out waiting for process $CURRENT_PID to exit."
      fi
      attempt=$((attempt + 1))
      sleep "$WAIT_INTERVAL"
    done

    safe_remove_sibling "$TEMP_TARGET"
    safe_remove_sibling "$BACKUP_TARGET"
    safe_remove_sibling "$FAILED_TARGET"
    # The detached process crosses a time-of-check/time-of-use boundary. Recheck
    # the complete identity immediately before the first copy, after that copy,
    # and again after the target-path swap.
    verify_release_app "$STAGED_APP"
    "$DITTO_BIN" "$STAGED_APP" "$TEMP_TARGET"
    verify_release_app "$TEMP_TARGET"

    if [[ -e "$TARGET_APP" ]]; then
      [[ -d "$TARGET_APP" && ! -L "$TARGET_APP" ]] || fail "Existing target app is not a regular app directory."
      "$MV_BIN" "$TARGET_APP" "$BACKUP_TARGET"
      HAD_BACKUP=1
    fi

    verify_release_app "$TEMP_TARGET"
    "$MV_BIN" "$TEMP_TARGET" "$TARGET_APP"
    REPLACEMENT_INSTALLED=1
    verify_release_app "$TARGET_APP"
    "$OPEN_BIN" "$TARGET_APP"

    expected_executable="$TARGET_APP/Contents/MacOS/CodexStatusBar"
    attempt=0
    launched=0
    while (( attempt < MAX_LAUNCH_WAIT_ATTEMPTS )); do
      while IFS= read -r candidate_pid; do
        [[ -n "$candidate_pid" ]] || continue
        command_path="$("$PS_BIN" -p "$candidate_pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')"
        if [[ "$command_path" == "$expected_executable" ]]; then
          launched=1
          break
        fi
      done < <("$PGREP_BIN" -x CodexStatusBar 2>/dev/null || true)
      [[ "$launched" == "1" ]] && break
      attempt=$((attempt + 1))
      sleep "$WAIT_INTERVAL"
    done
    [[ "$launched" == "1" ]] || fail "Replacement did not relaunch from the expected path."

    INSTALL_CONFIRMED=1
    if ! safe_remove_sibling "$BACKUP_TARGET"; then
      echo "Replacement succeeded, but the backup could not be removed: $BACKUP_TARGET" >&2
    fi
    """
}
