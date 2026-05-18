import Combine
import CryptoKit
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
        let expectedTag = normalizedTagName
        let expectedPrefix = "CodexStatusBar-\(expectedTag)-build"

        return assets.first { asset in
            guard asset.name.hasPrefix(expectedPrefix), asset.name.hasSuffix(".zip") else {
                return false
            }

            let buildStart = asset.name.index(asset.name.startIndex, offsetBy: expectedPrefix.count)
            let buildEnd = asset.name.index(asset.name.endIndex, offsetBy: -4)
            guard buildStart < buildEnd else {
                return false
            }

            return asset.name[buildStart..<buildEnd].allSatisfy(\.isNumber)
        }
    }

    var releaseVersionText: String {
        var version = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") {
            version.removeFirst()
        }
        return version
    }

    private var normalizedTagName: String {
        let trimmedTag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTag.hasPrefix("v") || trimmedTag.hasPrefix("V") {
            return "v\(trimmedTag.dropFirst())"
        }
        return "v\(trimmedTag)"
    }
}

struct AppUpdateReleaseAsset: Equatable, Identifiable {
    var id: String { name }

    let name: String
    let browserDownloadURL: URL
    let contentType: String?
    let size: Int64
    let digest: String?
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
}

enum AppUpdateDownloadError: Error, Equatable {
    case invalidResponse
    case requestFailed(statusCode: Int)
    case writeFailed
}

@MainActor
protocol AppUpdateDownloadClientProtocol: AnyObject {
    func download(
        asset: AppUpdateReleaseAsset,
        to destinationURL: URL,
        progress: @escaping (Double?) -> Void
    ) async throws -> URL
}

@MainActor
final class AppUpdateDownloadClient: AppUpdateDownloadClientProtocol {
    typealias ResponseLoader = (URLRequest) async throws -> (Data, URLResponse)

    private let fileManager: FileManager
    private let responseLoader: ResponseLoader

    init(
        fileManager: FileManager = .default,
        responseLoader: @escaping ResponseLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.fileManager = fileManager
        self.responseLoader = responseLoader
    }

    func download(
        asset: AppUpdateReleaseAsset,
        to destinationURL: URL,
        progress: @escaping (Double?) -> Void
    ) async throws -> URL {
        progress(0)

        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("CodexStatusBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await responseLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateDownloadError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateDownloadError.requestFailed(statusCode: httpResponse.statusCode)
        }

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
            progress(1)
            return destinationURL
        } catch {
            throw AppUpdateDownloadError.writeFailed
        }
    }
}

enum AppUpdatePackageVerificationError: Error, Equatable {
    case checksumMalformed
    case checksumMismatch
    case unzipFailed
    case missingAppBundle
    case missingInfoPlist
    case bundleIdentifierMismatch(expected: String, actual: String?)
    case versionMismatch(expected: String, actual: String?)
    case verificationCommandFailed(String)
}

@MainActor
protocol AppUpdatePackageVerifierProtocol: AnyObject {
    func verify(
        zipURL: URL,
        release: AppUpdateRelease,
        asset: AppUpdateReleaseAsset,
        installedBundleIdentifier: String
    ) async throws -> AppUpdatePackage
}

struct AppUpdateCommandResult: Equatable {
    let output: String
    let errorOutput: String
}

enum AppUpdateCommandError: Error, Equatable {
    case launchFailed(String)
    case nonZeroExit(status: Int32, output: String)
}

@MainActor
protocol AppUpdateCommandRunning {
    func run(executablePath: String, arguments: [String]) async throws -> AppUpdateCommandResult
}

@MainActor
final class AppUpdateProcessCommandRunner: AppUpdateCommandRunning {
    func run(executablePath: String, arguments: [String]) async throws -> AppUpdateCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = arguments
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    try process.run()
                    process.waitUntilExit()

                    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                    guard process.terminationStatus == 0 else {
                        let combinedOutput = [output, errorOutput]
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        throw AppUpdateCommandError.nonZeroExit(
                            status: process.terminationStatus,
                            output: combinedOutput
                        )
                    }

                    continuation.resume(returning: AppUpdateCommandResult(output: output, errorOutput: errorOutput))
                } catch let error as AppUpdateCommandError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: AppUpdateCommandError.launchFailed(error.localizedDescription))
                }
            }
        }
    }
}

@MainActor
final class AppUpdatePackageVerifier: AppUpdatePackageVerifierProtocol {
    private let fileManager: FileManager
    private let commandRunner: AppUpdateCommandRunning

    init(
        fileManager: FileManager = .default,
        commandRunner: AppUpdateCommandRunning = AppUpdateProcessCommandRunner()
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    func verify(
        zipURL: URL,
        release: AppUpdateRelease,
        asset: AppUpdateReleaseAsset,
        installedBundleIdentifier: String
    ) async throws -> AppUpdatePackage {
        try verifyChecksumIfAvailable(zipURL: zipURL, asset: asset)

        let extractionURL = zipURL
            .deletingLastPathComponent()
            .appendingPathComponent("Expanded", isDirectory: true)
        try? fileManager.removeItem(at: extractionURL)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)

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

        do {
            _ = try await commandRunner.run(
                executablePath: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
            )
            _ = try await commandRunner.run(
                executablePath: "/usr/sbin/spctl",
                arguments: ["-a", "-vv", "--type", "execute", appURL.path]
            )
        } catch {
            throw AppUpdatePackageVerificationError.verificationCommandFailed(String(describing: error))
        }

        return AppUpdatePackage(release: release, asset: asset, zipURL: zipURL, appURL: appURL)
    }

    private func verifyChecksumIfAvailable(zipURL: URL, asset: AppUpdateReleaseAsset) throws {
        guard let digest = asset.digest?.trimmingCharacters(in: .whitespacesAndNewlines), !digest.isEmpty else {
            return
        }

        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else {
            return
        }

        let expectedHash = String(digest.dropFirst(prefix.count)).lowercased()
        guard
            expectedHash.count == 64,
            expectedHash.allSatisfy({ $0.isHexDigit })
        else {
            throw AppUpdatePackageVerificationError.checksumMalformed
        }

        let data = try Data(contentsOf: zipURL)
        let actualHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        guard actualHash == expectedHash else {
            throw AppUpdatePackageVerificationError.checksumMismatch
        }
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

    static let installerScript = """
    #!/bin/bash
    set -euo pipefail

    CURRENT_PID="$1"
    STAGED_APP="$2"
    TARGET_APP="$3"
    LOG_PATH="$4"

    exec >"$LOG_PATH" 2>&1

    while kill -0 "$CURRENT_PID" 2>/dev/null; do
      sleep 0.2
    done

    TARGET_PARENT="$(dirname "$TARGET_APP")"
    TEMP_TARGET="$TARGET_PARENT/.CodexStatusBar.update.$$"

    rm -rf "$TEMP_TARGET"
    ditto "$STAGED_APP" "$TEMP_TARGET"
    rm -rf "$TARGET_APP"
    mv "$TEMP_TARGET" "$TARGET_APP"
    open "$TARGET_APP"
    """
}
