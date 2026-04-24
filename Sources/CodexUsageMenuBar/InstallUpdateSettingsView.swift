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

struct InstallUpdateSettingsViewModel: Equatable {
    static let defaultProjectURL = URL(string: "https://github.com/fmnobar/codexStatusBar")!
    static let updateCommandText = "git pull\n./install.sh"

    let versionInfo: AppVersionInfo
    let releaseNotes: [AppReleaseNote]
    let projectURL: URL

    init(
        versionInfo: AppVersionInfo = .current(),
        releaseNotes: [AppReleaseNote] = AppReleaseNotes.current,
        projectURL: URL = Self.defaultProjectURL
    ) {
        self.versionInfo = versionInfo
        self.releaseNotes = releaseNotes
        self.projectURL = projectURL
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

    static func current(bundle: Bundle = .main) -> InstallUpdateSettingsViewModel {
        InstallUpdateSettingsViewModel(versionInfo: .current(bundle: bundle))
    }
}

struct InstallUpdateSettingsView: View {
    let viewModel: InstallUpdateSettingsViewModel

    init(viewModel: InstallUpdateSettingsViewModel = .current()) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            appSection
            updateSection
            releaseNotesSection
        }
        .formStyle(.grouped)
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
                Text("From the project checkout:")
                    .foregroundStyle(.secondary)

                Text(viewModel.updateCommandText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack {
                Button("Reveal App in Finder") {
                    revealAppInFinder()
                }
                .disabled(!viewModel.canRevealApp)

                Button("Open Project Page") {
                    NSWorkspace.shared.open(viewModel.projectURL)
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
