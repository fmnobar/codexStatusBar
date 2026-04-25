import AppKit
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
            id: "data-management",
            title: "Data management settings",
            detail: "View the local history database, choose raw retention, export backups, import backups, and clear local history."
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
    static let defaultCheckCacheDuration: TimeInterval = 300

    let versionInfo: AppVersionInfo
    let releaseNotes: [AppReleaseNote]
    let projectURL: URL
    @Published private(set) var updateState: AppUpdateCheckState = .idle

    private let updateClient: AppUpdateCheckClientProtocol
    private let now: () -> Date
    private let checkCacheDuration: TimeInterval
    private let publishedDateFormatter: DateFormatter
    private var lastCheckedAt: Date?

    init(
        versionInfo: AppVersionInfo = .current(),
        releaseNotes: [AppReleaseNote] = AppReleaseNotes.current,
        projectURL: URL = InstallUpdateSettingsViewModel.defaultProjectURL,
        updateClient: AppUpdateCheckClientProtocol = GitHubLatestReleaseClient(),
        now: @escaping () -> Date = Date.init,
        checkCacheDuration: TimeInterval = InstallUpdateSettingsViewModel.defaultCheckCacheDuration,
        publishedDateFormatter: DateFormatter = InstallUpdateSettingsViewModel.makePublishedDateFormatter()
    ) {
        self.versionInfo = versionInfo
        self.releaseNotes = releaseNotes
        self.projectURL = projectURL
        self.updateClient = updateClient
        self.now = now
        self.checkCacheDuration = checkCacheDuration
        self.publishedDateFormatter = publishedDateFormatter
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
        guard let lastCheckedAt else {
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

    func checkForUpdatesIfNeeded() async {
        guard shouldCheckForUpdates else {
            return
        }

        await checkForUpdates(force: false)
    }

    func checkForUpdates(force: Bool) async {
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

    static func current(bundle: Bundle = .main) -> InstallUpdateSettingsViewModel {
        InstallUpdateSettingsViewModel(versionInfo: .current(bundle: bundle))
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

    private static func makePublishedDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

struct InstallUpdateSettingsView: View {
    @StateObject private var viewModel: InstallUpdateSettingsViewModel

    init(viewModel: InstallUpdateSettingsViewModel = .current()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            appSection
            updateSection
            releaseNotesSection
        }
        .formStyle(.grouped)
        .task {
            await viewModel.checkForUpdatesIfNeeded()
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

                    if viewModel.isCheckingForUpdates {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                LabeledContent("Latest Release", value: viewModel.latestReleaseText)
                LabeledContent("Published", value: viewModel.publishedDateText)
                LabeledContent("Last Checked", value: viewModel.lastCheckedText)
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
                    .disabled(viewModel.isCheckingForUpdates)

                    Button {
                        revealAppInFinder()
                    } label: {
                        Label("Reveal App in Finder", systemImage: "folder")
                    }
                    .disabled(!viewModel.canRevealApp)
                }

                HStack {
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
}
