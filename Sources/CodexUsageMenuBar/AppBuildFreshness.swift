import AppKit
import Combine
import Foundation

struct AppBuildFingerprint: Codable, Equatable {
    static let fileName = "BuildFingerprint.json"
    static let unknownText = "unknown"

    let schemaVersion: Int
    let sourceRoot: String?
    let gitCommit: String?
    let gitBranch: String?
    let isDirty: Bool?
    let buildTime: String?
    let installedBundlePath: String?
    let executableSHA256: String?

    init(
        schemaVersion: Int = 1,
        sourceRoot: String? = nil,
        gitCommit: String? = nil,
        gitBranch: String? = nil,
        isDirty: Bool? = nil,
        buildTime: String? = nil,
        installedBundlePath: String? = nil,
        executableSHA256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRoot = Self.normalized(sourceRoot)
        self.gitCommit = Self.normalized(gitCommit)
        self.gitBranch = Self.normalized(gitBranch)
        self.isDirty = isDirty
        self.buildTime = Self.normalized(buildTime)
        self.installedBundlePath = Self.normalized(installedBundlePath)
        self.executableSHA256 = Self.normalized(executableSHA256)
    }

    static func load(fromBundleURL bundleURL: URL, fileManager: FileManager = .default) -> AppBuildFingerprint? {
        let resourceURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)

        guard fileManager.fileExists(atPath: resourceURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: resourceURL)
            return try JSONDecoder().decode(AppBuildFingerprint.self, from: data)
        } catch {
            return nil
        }
    }

    var sourceRootURL: URL? {
        guard let sourceRoot = Self.knownValue(sourceRoot) else {
            return nil
        }

        return URL(fileURLWithPath: sourceRoot, isDirectory: true)
    }

    var installedBundleURL: URL? {
        guard let installedBundlePath = Self.knownValue(installedBundlePath) else {
            return nil
        }

        return URL(fileURLWithPath: installedBundlePath, isDirectory: true)
    }

    var shortCommitText: String {
        guard let gitCommit = Self.knownValue(gitCommit) else {
            return "Unknown"
        }

        return String(gitCommit.prefix(7))
    }

    var branchText: String {
        Self.knownValue(gitBranch) ?? "Unknown"
    }

    var buildTimeText: String {
        Self.knownValue(buildTime) ?? "Unknown"
    }

    var sourceRootText: String {
        Self.knownValue(sourceRoot) ?? "Unknown"
    }

    var installedBundlePathText: String {
        Self.knownValue(installedBundlePath) ?? "Unknown"
    }

    var executableHashText: String {
        guard let executableSHA256 = Self.knownValue(executableSHA256) else {
            return "Unknown"
        }

        return String(executableSHA256.prefix(12))
    }

    static func knownValue(_ value: String?) -> String? {
        guard let normalized = normalized(value), normalized != unknownText else {
            return nil
        }

        return normalized
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AppFreshnessState: Equatable {
    case current(running: AppBuildFingerprint?, installed: AppBuildFingerprint?, sourceCommit: String?)
    case sourceNewerThanInstalled(
        running: AppBuildFingerprint?,
        installed: AppBuildFingerprint,
        sourceCommit: String,
        sourceRoot: URL?
    )
    case installedBundleNewerThanRunning(
        running: AppBuildFingerprint,
        installed: AppBuildFingerprint,
        sourceCommit: String?
    )
    case unknown(String)

    var isStale: Bool {
        switch self {
        case .sourceNewerThanInstalled, .installedBundleNewerThanRunning:
            return true
        case .current, .unknown:
            return false
        }
    }

    var statusText: String {
        switch self {
        case .current:
            return "Local build is current."
        case .sourceNewerThanInstalled:
            return "Source checkout is newer than the installed app."
        case .installedBundleNewerThanRunning:
            return "Installed app was updated; relaunch to use it."
        case .unknown:
            return "Local build freshness is unknown."
        }
    }

    var compactWarningText: String? {
        switch self {
        case .sourceNewerThanInstalled:
            return "Newer local source is available. Run ./install.sh."
        case .installedBundleNewerThanRunning:
            return "A newer installed app is available. Relaunch to use it."
        case .current, .unknown:
            return nil
        }
    }

    var canRelaunchLatestInstalledApp: Bool {
        if case .installedBundleNewerThanRunning = self {
            return relaunchBundleURL != nil
        }

        return false
    }

    var relaunchBundleURL: URL? {
        switch self {
        case .installedBundleNewerThanRunning(_, let installed, _):
            return installed.installedBundleURL
        case .current, .sourceNewerThanInstalled, .unknown:
            return nil
        }
    }

    var runningFingerprint: AppBuildFingerprint? {
        switch self {
        case .current(let running, _, _):
            return running
        case .sourceNewerThanInstalled(let running, _, _, _):
            return running
        case .installedBundleNewerThanRunning(let running, _, _):
            return running
        case .unknown:
            return nil
        }
    }

    var installedFingerprint: AppBuildFingerprint? {
        switch self {
        case .current(_, let installed, _):
            return installed
        case .sourceNewerThanInstalled(_, let installed, _, _):
            return installed
        case .installedBundleNewerThanRunning(_, let installed, _):
            return installed
        case .unknown:
            return nil
        }
    }

    var sourceCommit: String? {
        switch self {
        case .current(_, _, let sourceCommit):
            return sourceCommit
        case .sourceNewerThanInstalled(_, _, let sourceCommit, _):
            return sourceCommit
        case .installedBundleNewerThanRunning(_, _, let sourceCommit):
            return sourceCommit
        case .unknown:
            return nil
        }
    }

    var sourceRootURL: URL? {
        switch self {
        case .sourceNewerThanInstalled(_, _, _, let sourceRoot):
            return sourceRoot
        case .current(_, let installed, _):
            return installed?.sourceRootURL
        case .installedBundleNewerThanRunning(_, let installed, _):
            return installed.sourceRootURL
        case .unknown:
            return nil
        }
    }

    var installCommandText: String? {
        guard let sourceRootURL else {
            return nil
        }

        return "cd \(sourceRootURL.path)\n./install.sh"
    }
}

struct AppFreshnessChecker {
    var runningFingerprint: AppBuildFingerprint?
    var bundleURL: URL?
    var fileManager: FileManager = .default
    var sourceHeadReader: (URL) -> String? = { AppFreshnessChecker.readGitHeadCommit(sourceRootURL: $0) }

    @MainActor
    static func current(bundle: Bundle = .main) -> AppFreshnessChecker {
        AppFreshnessRuntime.captureLaunchFingerprint(bundle: bundle)
        return AppFreshnessChecker(
            runningFingerprint: AppFreshnessRuntime.launchFingerprint,
            bundleURL: bundle.bundleURL
        )
    }

    func check() -> AppFreshnessState {
        guard let bundleURL else {
            return .unknown("Installed app location is unavailable.")
        }

        guard let installedFingerprint = AppBuildFingerprint.load(
            fromBundleURL: bundleURL,
            fileManager: fileManager
        ) else {
            return .unknown("Build fingerprint is unavailable.")
        }

        let sourceCommit = installedFingerprint.sourceRootURL.flatMap(sourceHeadReader)

        if
            let runningFingerprint,
            let runningCommit = AppBuildFingerprint.knownValue(runningFingerprint.gitCommit),
            let installedCommit = AppBuildFingerprint.knownValue(installedFingerprint.gitCommit),
            runningCommit != installedCommit
        {
            return .installedBundleNewerThanRunning(
                running: runningFingerprint,
                installed: installedFingerprint,
                sourceCommit: sourceCommit
            )
        }

        if installedFingerprint.sourceRootURL != nil, sourceCommit == nil {
            return .unknown("Source checkout is unavailable.")
        }

        if
            let sourceCommit,
            let installedCommit = AppBuildFingerprint.knownValue(installedFingerprint.gitCommit),
            sourceCommit != installedCommit
        {
            return .sourceNewerThanInstalled(
                running: runningFingerprint,
                installed: installedFingerprint,
                sourceCommit: sourceCommit,
                sourceRoot: installedFingerprint.sourceRootURL
            )
        }

        return .current(
            running: runningFingerprint,
            installed: installedFingerprint,
            sourceCommit: sourceCommit
        )
    }

    static func readGitHeadCommit(sourceRootURL: URL) -> String? {
        let fileManager = FileManager.default
        let gitURL = sourceRootURL.appendingPathComponent(".git", isDirectory: false)
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        let gitDirectoryURL: URL
        if isDirectory.boolValue {
            gitDirectoryURL = gitURL
        } else {
            guard
                let gitFile = try? String(contentsOf: gitURL, encoding: .utf8),
                let gitdirLine = gitFile
                    .split(separator: "\n")
                    .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gitdir:") })
            else {
                return nil
            }

            let gitdirPath = gitdirLine
                .dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if gitdirPath.hasPrefix("/") {
                gitDirectoryURL = URL(fileURLWithPath: gitdirPath, isDirectory: true)
            } else {
                gitDirectoryURL = sourceRootURL.appendingPathComponent(gitdirPath, isDirectory: true)
            }
        }

        let headURL = gitDirectoryURL.appendingPathComponent("HEAD", isDirectory: false)
        guard let headText = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }

        let headValue = headText.trimmingCharacters(in: .whitespacesAndNewlines)
        if headValue.hasPrefix("ref:") {
            let refPath = headValue
                .dropFirst("ref:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let refURL = gitDirectoryURL.appendingPathComponent(refPath, isDirectory: false)
            return (try? String(contentsOf: refURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return headValue.isEmpty ? nil : headValue
    }
}

@MainActor
enum AppFreshnessRuntime {
    private static var storedLaunchFingerprint: AppBuildFingerprint?
    private static var didCaptureLaunchFingerprint = false

    static func captureLaunchFingerprint(bundle: Bundle = .main) {
        guard !didCaptureLaunchFingerprint else {
            return
        }

        didCaptureLaunchFingerprint = true
        storedLaunchFingerprint = AppBuildFingerprint.load(fromBundleURL: bundle.bundleURL)
    }

    static var launchFingerprint: AppBuildFingerprint? {
        return storedLaunchFingerprint
    }
}

@MainActor
final class AppFreshnessStatusViewModel: ObservableObject {
    @Published private(set) var state: AppFreshnessState

    private let stateProvider: () -> AppFreshnessState
    private let relaunchAction: (URL) -> Void

    init(
        initialState: AppFreshnessState,
        stateProvider: @escaping () -> AppFreshnessState,
        relaunchAction: @escaping (URL) -> Void
    ) {
        state = initialState
        self.stateProvider = stateProvider
        self.relaunchAction = relaunchAction
    }

    static func current(bundle: Bundle = .main) -> AppFreshnessStatusViewModel {
        let checker = AppFreshnessChecker.current(bundle: bundle)
        return AppFreshnessStatusViewModel(
            initialState: checker.check(),
            stateProvider: { checker.check() },
            relaunchAction: { appURL in
                AppFreshnessRelauncher.relaunch(appURL: appURL)
            }
        )
    }

    var shouldShowWarning: Bool {
        state.isStale
    }

    var popoverWarningText: String {
        state.compactWarningText ?? state.statusText
    }

    var statusText: String {
        switch state {
        case .unknown(let reason):
            return "\(state.statusText) \(reason)"
        case .current, .sourceNewerThanInstalled, .installedBundleNewerThanRunning:
            return state.statusText
        }
    }

    var runningCommitText: String {
        state.runningFingerprint?.shortCommitText ?? "Unknown"
    }

    var installedCommitText: String {
        state.installedFingerprint?.shortCommitText ?? "Unknown"
    }

    var sourceCommitText: String {
        guard let sourceCommit = state.sourceCommit else {
            return "Unknown"
        }

        return String(sourceCommit.prefix(7))
    }

    var branchText: String {
        state.installedFingerprint?.branchText ?? "Unknown"
    }

    var buildTimeText: String {
        state.installedFingerprint?.buildTimeText ?? "Unknown"
    }

    var sourceRootText: String {
        state.installedFingerprint?.sourceRootText ?? "Unknown"
    }

    var installedPathText: String {
        state.installedFingerprint?.installedBundlePathText ?? "Unknown"
    }

    var executableHashText: String {
        state.installedFingerprint?.executableHashText ?? "Unknown"
    }

    var dirtyStateText: String {
        guard let isDirty = state.installedFingerprint?.isDirty else {
            return "Unknown"
        }

        return isDirty ? "Dirty" : "Clean"
    }

    var installCommandText: String? {
        state.installCommandText
    }

    var canRelaunchLatestInstalledApp: Bool {
        state.canRelaunchLatestInstalledApp
    }

    func refresh() {
        state = stateProvider()
    }

    func relaunchLatestInstalledApp() {
        guard let appURL = state.relaunchBundleURL else {
            return
        }

        relaunchAction(appURL)
    }
}

enum AppFreshnessRelauncher {
    @MainActor
    static func relaunch(
        appURL: URL,
        terminateApplication: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 0.5; /usr/bin/open -n \"$1\"",
            "codex-status-bar-relaunch",
            appURL.path,
        ]
        try? process.run()
        terminateApplication()
    }
}
