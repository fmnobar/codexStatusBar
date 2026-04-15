import AppKit
import ServiceManagement
import SwiftUI

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = MenuBarStatusViewModel(client: CodexAppServerClient())
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(viewModel: viewModel)

        Task {
            await viewModel.start()
        }
    }
}

private struct SettingsView: View {
    @AppStorage(MenuBarDisplayWindowStore.defaultsKey) private var selectedDisplayWindowRawValue = MenuBarDisplayWindow.sevenDay.rawValue
    @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }

            Section("Display") {
                Picker("Default menu bar display", selection: displayWindowBinding) {
                    ForEach(MenuBarDisplayWindow.allCases, id: \.rawValue) { displayWindow in
                        Text(displayWindow.displayTitle)
                            .tag(displayWindow)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 320)
        .task {
            refreshLaunchAtLoginState()
        }
    }

    private var displayWindowBinding: Binding<MenuBarDisplayWindow> {
        Binding(
            get: {
                MenuBarDisplayWindow(rawValue: selectedDisplayWindowRawValue) ?? .sevenDay
            },
            set: { newValue in
                selectedDisplayWindowRawValue = newValue.rawValue
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { isEnabled in
                do {
                    try LaunchAtLoginController.setEnabled(isEnabled)
                    launchAtLoginEnabled = LaunchAtLoginController.isEnabled
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginEnabled = LaunchAtLoginController.isEnabled
                    launchAtLoginError = "Launch at login could not be updated."
                }
            }
        )
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = LaunchAtLoginController.isEnabled
        launchAtLoginError = nil
    }
}

private enum LaunchAtLoginController {
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
