import AppKit
import Combine
import Foundation
import SwiftUI

struct AppVersionInfo: Equatable {
    static let unknownText = "Unknown"

    let appName: String
    let version: String
    let build: String
    let bundleIdentifier: String
    let bundleURL: URL?

    init(
        infoDictionary: [String: Any],
        bundleIdentifier: String?,
        bundleURL: URL?
    ) {
        appName = Self.firstString(
            for: ["CFBundleDisplayName", "CFBundleName"],
            in: infoDictionary
        ) ?? Self.unknownText
        version = Self.string(for: "CFBundleShortVersionString", in: infoDictionary) ?? Self.unknownText
        build = Self.string(for: "CFBundleVersion", in: infoDictionary) ?? Self.unknownText
        self.bundleIdentifier = bundleIdentifier
            ?? Self.string(for: "CFBundleIdentifier", in: infoDictionary)
            ?? Self.unknownText
        self.bundleURL = bundleURL
    }

    static func current(bundle: Bundle = .main) -> AppVersionInfo {
        AppVersionInfo(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundleIdentifier: bundle.bundleIdentifier,
            bundleURL: bundle.bundleURL
        )
    }

    var versionBuildText: String {
        "Version \(version) (\(build))"
    }

    private static func firstString(for keys: [String], in infoDictionary: [String: Any]) -> String? {
        keys.lazy
            .compactMap { string(for: $0, in: infoDictionary) }
            .first
    }

    private static func string(for key: String, in infoDictionary: [String: Any]) -> String? {
        guard let value = infoDictionary[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

struct AppReleaseNote: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
}

enum AppReleaseNotes {
    static let current: [AppReleaseNote] = [
        AppReleaseNote(
            id: "in-app-updates",
            title: "Guided in-app updates",
            detail: "Download, verify, and install signed GitHub Release updates from the Updates settings tab."
        ),
        AppReleaseNote(
            id: "data-management",
            title: "Data management settings",
            detail: "Use Lightweight storage by default, opt into Detailed Analytics, manage fixed retention, safe backups, and read-only historical archives."
        ),
        AppReleaseNote(
            id: "history-polish",
            title: "History chart polish",
            detail: "Inspect nearby samples, search model series, and see clearer empty states in the History window."
        ),
        AppReleaseNote(
            id: "usage-history",
            title: "Usage history by model",
            detail: "Chart rolling day, week, month, and year usage history with aggregate and model-specific series when available."
        ),
    ]
}

@MainActor
final class InstallUpdateSettingsViewModel: ObservableObject {
    static let defaultProjectURL = URL(string: "https://github.com/fmnobar/codexStatusBar")!
    static let updateCommandText = "git pull\n./install.sh"
    static let defaultCheckCacheDuration: TimeInterval = AppUpdateMonitor.defaultCheckCacheDuration

    let versionInfo: AppVersionInfo
    let releaseNotes: [AppReleaseNote]
    let projectURL: URL
    @Published private(set) var installState: AppUpdateInstallState = .idle

    private let updateMonitor: AppUpdateMonitor
    private let downloadClient: AppUpdateDownloadClientProtocol
    private let packageVerifier: AppUpdatePackageVerifierProtocol
    private let installer: AppUpdateInstallerProtocol
    private let stagingDirectoryProvider: @MainActor (AppUpdateRelease) throws -> URL
    private let processIdentifier: () -> Int32
    private let terminateApplication: () -> Void
    private let publishedDateFormatter: DateFormatter
    private var updateMonitorCancellable: AnyCancellable?

    init(
        versionInfo: AppVersionInfo = .current(),
        releaseNotes: [AppReleaseNote] = AppReleaseNotes.current,
        projectURL: URL = InstallUpdateSettingsViewModel.defaultProjectURL,
        updateMonitor: AppUpdateMonitor? = nil,
        updateClient: AppUpdateCheckClientProtocol = GitHubLatestReleaseClient(),
        downloadClient: AppUpdateDownloadClientProtocol = AppUpdateDownloadClient(),
        packageVerifier: AppUpdatePackageVerifierProtocol = AppUpdatePackageVerifier(),
        installer: AppUpdateInstallerProtocol = AppUpdateInstaller(),
        stagingDirectoryProvider: @escaping @MainActor (AppUpdateRelease) throws -> URL = { release in
            try InstallUpdateSettingsViewModel.defaultStagingDirectory(for: release)
        },
        processIdentifier: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        terminateApplication: @escaping () -> Void = { NSApp.terminate(nil) },
        now: @escaping () -> Date = Date.init,
        checkCacheDuration: TimeInterval = InstallUpdateSettingsViewModel.defaultCheckCacheDuration,
        publishedDateFormatter: DateFormatter = InstallUpdateSettingsViewModel.makePublishedDateFormatter()
    ) {
        self.versionInfo = versionInfo
        self.releaseNotes = releaseNotes
        self.projectURL = projectURL
        self.updateMonitor = updateMonitor ?? AppUpdateMonitor(
            versionInfo: versionInfo,
            updateClient: updateClient,
            now: now,
            checkCacheDuration: checkCacheDuration
        )
        self.downloadClient = downloadClient
        self.packageVerifier = packageVerifier
        self.installer = installer
        self.stagingDirectoryProvider = stagingDirectoryProvider
        self.processIdentifier = processIdentifier
        self.terminateApplication = terminateApplication
        self.publishedDateFormatter = publishedDateFormatter
        updateMonitorCancellable = self.updateMonitor.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    var updateState: AppUpdateCheckState {
        updateMonitor.updateState
    }

    var appNameText: String {
        versionInfo.appName
    }

    var versionText: String {
        versionInfo.versionBuildText
    }

    var bundleIdentifierText: String {
        versionInfo.bundleIdentifier
    }

    var installedPathText: String {
        versionInfo.bundleURL?.path ?? "Unavailable"
    }

    var appBundleURL: URL? {
        versionInfo.bundleURL
    }

    var canRevealApp: Bool {
        appBundleURL != nil
    }

    var updateCommandText: String {
        Self.updateCommandText
    }

    var updateStatusText: String {
        switch updateState {
        case .idle:
            return "Update status has not been checked yet."
        case .checking:
            return "Checking for updates..."
        case .updateAvailable(let release):
            return "Update available: \(release.displayVersionText)."
        case .upToDate:
            return "\(appNameText) is up to date."
        case .noPublishedRelease:
            return "No published release found."
        case .inconclusive:
            return "Latest release found, but the version could not be compared."
        case .failed:
            return "Could not check for updates."
        }
    }

    var latestReleaseText: String {
        updateState.release?.displayVersionText ?? "--"
    }

    var publishedDateText: String {
        guard let publishedAt = updateState.release?.publishedAt else {
            return "--"
        }

        return publishedDateFormatter.string(from: publishedAt)
    }

    var lastCheckedText: String {
        guard let lastCheckedAt = updateMonitor.lastCheckedAt else {
            return "--"
        }

        return publishedDateFormatter.string(from: lastCheckedAt)
    }

    var releasePageURL: URL? {
        updateState.release?.htmlURL
    }

    var canOpenReleasePage: Bool {
        releasePageURL != nil
    }

    var isCheckingForUpdates: Bool {
        updateState == .checking
    }

    var installStatusText: String? {
        switch installState {
        case .idle:
            if isUpdateAvailable, downloadableUpdateAsset == nil {
                return "This release does not include a downloadable Codex Status Bar zip."
            }
            return nil
        case .downloading(let progress):
            if let progress {
                return "Downloading update \(Int((progress * 100).rounded()))%..."
            }
            return "Downloading update..."
        case .verifying:
            return "Verifying downloaded update..."
        case .ready:
            return "Update downloaded and verified."
        case .installing:
            return "Installing update..."
        case .unavailable(let message, _), .failed(let message):
            return message
        }
    }

    var downloadProgressValue: Double? {
        guard case .downloading(let progress) = installState else {
            return nil
        }

        return progress
    }

    var isWorkingOnUpdateInstall: Bool {
        installState.isBusy
    }

    var canCheckForUpdates: Bool {
        !isCheckingForUpdates && !isWorkingOnUpdateInstall
    }

    var canDownloadUpdate: Bool {
        isUpdateAvailable && downloadableUpdateAsset != nil && !isWorkingOnUpdateInstall
    }

    var shouldShowDownloadUpdateButton: Bool {
        canDownloadUpdate && !installState.hasPreparedPackage
    }

    var canInstallPreparedUpdate: Bool {
        guard case .ready = installState else {
            return false
        }

        return !isWorkingOnUpdateInstall
    }

    var canRevealDownloadedUpdate: Bool {
        installState.preparedPackage != nil
    }

    var downloadedUpdateURL: URL? {
        installState.preparedPackage?.appURL
    }

    var isShowingInstallProgress: Bool {
        switch installState {
        case .downloading, .verifying, .installing:
            return true
        case .idle, .ready, .unavailable, .failed:
            return false
        }
    }

    func checkForUpdatesIfNeeded() async {
        await updateMonitor.checkIfNeeded()
    }

    func checkForUpdates(force: Bool) async {
        guard !isWorkingOnUpdateInstall else {
            return
        }
        if let package = installState.preparedPackage {
            removeOwnedStagingDirectory(package.cleanupRootURL)
        }
        installState = .idle
        await updateMonitor.check(force: force)
    }

    func downloadUpdate() async {
        guard
            case .updateAvailable(let release) = updateState,
            !isWorkingOnUpdateInstall
        else {
            return
        }

        guard let asset = release.matchingCodexStatusBarZipAsset else {
            installState = .unavailable("This release does not include a downloadable Codex Status Bar zip.", nil)
            return
        }

        guard let installedAppURL = appBundleURL else {
            installState = .unavailable("Installed app location is unavailable, so signer continuity cannot be verified.", nil)
            return
        }

        var ownedStagingDirectory: URL?
        do {
            let stagingRoot = try stagingDirectoryProvider(release)
            let stagingDirectory = stagingRoot
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try Data().write(
                to: stagingDirectory.appendingPathComponent(".codex-status-bar-update-staging"),
                options: .atomic
            )
            ownedStagingDirectory = stagingDirectory
            let zipURL = stagingDirectory.appendingPathComponent(asset.name)

            installState = .downloading(progress: nil)
            let downloadedZipURL = try await downloadClient.download(asset: asset, to: zipURL) { [weak self] progress in
                self?.installState = .downloading(progress: progress)
            }

            installState = .verifying
            let package = try await packageVerifier.verify(
                zipURL: downloadedZipURL,
                release: release,
                asset: asset,
                installedBundleIdentifier: versionInfo.bundleIdentifier,
                installedAppURL: installedAppURL
            )

            if installer.canInstall(to: installedAppURL) {
                installState = .ready(package)
            } else {
                installState = .unavailable("The installed app location is not writable. Reveal the verified download and replace it manually.", package)
            }
        } catch is AppUpdatePackageVerificationError {
            removeOwnedStagingDirectory(ownedStagingDirectory)
            installState = .failed("Downloaded update could not be verified.")
        } catch {
            removeOwnedStagingDirectory(ownedStagingDirectory)
            installState = .failed("Update could not be downloaded.")
        }
    }

    func installPreparedUpdate() async {
        guard
            case .ready(let package) = installState,
            let appBundleURL
        else {
            return
        }

        installState = .installing(package)

        do {
            _ = try await installer.install(
                package: package,
                targetAppURL: appBundleURL,
                currentProcessIdentifier: processIdentifier()
            )
            terminateApplication()
        } catch AppUpdateInstallerError.targetNotWritable {
            installState = .unavailable("The installed app location is not writable. Reveal the verified download and replace it manually.", package)
        } catch {
            removeOwnedStagingDirectory(package.cleanupRootURL)
            installState = .failed("Update could not be installed.")
        }
    }

    static func current(bundle: Bundle = .main) -> InstallUpdateSettingsViewModel {
        InstallUpdateSettingsViewModel(versionInfo: .current(bundle: bundle))
    }

    private var isUpdateAvailable: Bool {
        if case .updateAvailable = updateState {
            return true
        }

        return false
    }

    private var downloadableUpdateAsset: AppUpdateReleaseAsset? {
        updateState.release?.matchingCodexStatusBarZipAsset
    }

    private func removeOwnedStagingDirectory(_ directoryURL: URL?) {
        guard let directoryURL else {
            return
        }
        let markerURL = directoryURL.appendingPathComponent(".codex-status-bar-update-staging")
        let values = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard
            values?.isDirectory == true,
            values?.isSymbolicLink != true,
            FileManager.default.fileExists(atPath: markerURL.path)
        else {
            return
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func defaultStagingDirectory(for release: AppUpdateRelease) throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let safeTag = release.tagName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        return applicationSupportURL
            .appendingPathComponent("CodexStatusBar", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent(safeTag, isDirectory: true)
    }

    private static func makePublishedDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

enum AppUpdateInstallState: Equatable {
    case idle
    case downloading(progress: Double?)
    case verifying
    case ready(AppUpdatePackage)
    case installing(AppUpdatePackage)
    case unavailable(String, AppUpdatePackage?)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing:
            return true
        case .idle, .ready, .unavailable, .failed:
            return false
        }
    }

    var hasPreparedPackage: Bool {
        preparedPackage != nil
    }

    var preparedPackage: AppUpdatePackage? {
        switch self {
        case .ready(let package), .installing(let package):
            return package
        case .unavailable(_, let package):
            return package
        case .idle, .downloading, .verifying, .failed:
            return nil
        }
    }
}

struct InstallUpdateSettingsView: View {
    @StateObject private var viewModel: InstallUpdateSettingsViewModel
    @StateObject private var freshnessViewModel: AppFreshnessStatusViewModel
    @State private var isConfirmingInstall = false

    init(
        viewModel: InstallUpdateSettingsViewModel = .current(),
        freshnessViewModel: AppFreshnessStatusViewModel = .current()
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _freshnessViewModel = StateObject(wrappedValue: freshnessViewModel)
    }

    var body: some View {
        Form {
            appSection
            localBuildSection
            updateSection
            releaseNotesSection
        }
        .formStyle(.grouped)
        .onAppear {
            freshnessViewModel.refresh()
        }
        .task {
            await viewModel.checkForUpdatesIfNeeded()
        }
        .alert("Install Update?", isPresented: $isConfirmingInstall) {
            Button("Install and Relaunch", role: .destructive) {
                Task {
                    await viewModel.installPreparedUpdate()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Codex Status Bar will quit, replace the current app with the verified update, and reopen.")
        }
    }

    private var localBuildSection: some View {
        Section("Local Build") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: freshnessViewModel.shouldShowWarning ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(freshnessViewModel.shouldShowWarning ? .orange : .secondary)

                    Text(freshnessViewModel.statusText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("Running commit", value: freshnessViewModel.runningCommitText)
                LabeledContent("Installed commit", value: freshnessViewModel.installedCommitText)
                LabeledContent("Source HEAD", value: freshnessViewModel.sourceCommitText)
                LabeledContent("Branch", value: freshnessViewModel.branchText)
                LabeledContent("Build time", value: freshnessViewModel.buildTimeText)
                LabeledContent("Build state", value: freshnessViewModel.dirtyStateText)
                LabeledContent("Executable SHA-256", value: freshnessViewModel.executableHashText)

                LabeledContent("Source root") {
                    Text(freshnessViewModel.sourceRootText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                LabeledContent("Installed bundle") {
                    Text(freshnessViewModel.installedPathText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if let installCommandText = freshnessViewModel.installCommandText,
                   case .sourceNewerThanInstalled = freshnessViewModel.state {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From Terminal:")
                            .foregroundStyle(.secondary)

                        Text(installCommandText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                Button {
                    freshnessViewModel.refresh()
                } label: {
                    Label("Refresh Installed Status", systemImage: "arrow.clockwise")
                }

                if freshnessViewModel.canCheckSourceCheckout {
                    Button {
                        freshnessViewModel.checkSourceCheckout()
                    } label: {
                        Label("Check Source Checkout", systemImage: "folder.badge.gearshape")
                    }
                }

                if freshnessViewModel.canRelaunchLatestInstalledApp {
                    Button {
                        freshnessViewModel.relaunchLatestInstalledApp()
                    } label: {
                        Label("Relaunch Latest App", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
    }

    private var appSection: some View {
        Section("App") {
            LabeledContent("Name", value: viewModel.appNameText)
            LabeledContent("Version", value: viewModel.versionText)
            LabeledContent("Bundle ID", value: viewModel.bundleIdentifierText)

            LabeledContent("Installed at") {
                Text(viewModel.installedPathText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var updateSection: some View {
        Section("Update") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(viewModel.updateStatusText)
                        .foregroundStyle(.secondary)

                    if viewModel.isCheckingForUpdates || viewModel.isShowingInstallProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                LabeledContent("Latest Release", value: viewModel.latestReleaseText)
                LabeledContent("Published", value: viewModel.publishedDateText)
                LabeledContent("Last Checked", value: viewModel.lastCheckedText)

                if let installStatusText = viewModel.installStatusText {
                    Text(installStatusText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let downloadProgressValue = viewModel.downloadProgressValue {
                        ProgressView(value: downloadProgressValue)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("From the project checkout:")
                    .foregroundStyle(.secondary)

                Text(viewModel.updateCommandText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        Task {
                            await viewModel.checkForUpdates(force: true)
                        }
                    } label: {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(!viewModel.canCheckForUpdates)

                    Button {
                        revealAppInFinder()
                    } label: {
                        Label("Reveal App in Finder", systemImage: "folder")
                    }
                    .disabled(!viewModel.canRevealApp)
                }

                HStack {
                    if viewModel.shouldShowDownloadUpdateButton {
                        Button {
                            Task {
                                await viewModel.downloadUpdate()
                            }
                        } label: {
                            Label("Download Update", systemImage: "arrow.down.circle")
                        }
                        .disabled(!viewModel.canDownloadUpdate)
                    }

                    if viewModel.canInstallPreparedUpdate {
                        Button {
                            isConfirmingInstall = true
                        } label: {
                            Label("Install and Relaunch...", systemImage: "square.and.arrow.down")
                        }
                    }

                    if viewModel.canRevealDownloadedUpdate {
                        Button {
                            revealDownloadedUpdateInFinder()
                        } label: {
                            Label("Reveal Download", systemImage: "folder")
                        }
                    }

                    Button {
                        if let releasePageURL = viewModel.releasePageURL {
                            NSWorkspace.shared.open(releasePageURL)
                        }
                    } label: {
                        Label("Open Release Page", systemImage: "tag")
                    }
                    .disabled(!viewModel.canOpenReleasePage)

                    Button {
                        NSWorkspace.shared.open(viewModel.projectURL)
                    } label: {
                        Label("Open Project Page", systemImage: "safari")
                    }
                }
            }
        }
    }

    private var releaseNotesSection: some View {
        Section("What's New") {
            ForEach(viewModel.releaseNotes) { releaseNote in
                VStack(alignment: .leading, spacing: 3) {
                    Text(releaseNote.title)
                        .font(.headline)
                    Text(releaseNote.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func revealAppInFinder() {
        guard let appBundleURL = viewModel.appBundleURL else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([appBundleURL])
    }

    private func revealDownloadedUpdateInFinder() {
        guard let downloadedUpdateURL = viewModel.downloadedUpdateURL else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([downloadedUpdateURL])
    }
}
