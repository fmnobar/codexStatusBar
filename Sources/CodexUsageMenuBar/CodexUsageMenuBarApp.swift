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
    private let preferencesWindowController = PreferencesWindowController()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            viewModel: viewModel,
            openPreferences: { [preferencesWindowController] in
                preferencesWindowController.show()
            }
        )

        Task {
            await viewModel.start()
        }
    }
}

@MainActor
private final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?

    func show() {
        let windowController = windowController ?? makeWindowController()
        self.windowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindowController() -> NSWindowController {
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        let contentSize = NSSize(width: 420, height: 300)
        window.setContentSize(contentSize)
        window.minSize = contentSize
        window.tabbingMode = .disallowed
        window.delegate = self

        let windowController = NSWindowController(window: window)
        windowController.shouldCascadeWindows = false
        return windowController
    }
}

private struct SettingsView: View {
    @AppStorage(MenuBarDisplayWindowStore.defaultsKey) private var selectedDisplayWindowRawValue = MenuBarDisplayWindow.sevenDay.rawValue
    @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("General")
                    .font(.headline)

                Toggle("Launch at login", isOn: launchAtLoginBinding)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Display")
                    .font(.headline)

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

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 380, height: 250, alignment: .topLeading)
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
