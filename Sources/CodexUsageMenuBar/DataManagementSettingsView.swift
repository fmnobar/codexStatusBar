import SwiftUI

enum SettingsTabSelection: String {
    case general
    case updates
}

enum SettingsTabSelectionStore {
    static let key = "Settings.selectedTab"

    static func select(_ tab: SettingsTabSelection, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: key)
    }

    static func selectedTab(from rawValue: String) -> SettingsTabSelection {
        SettingsTabSelection(rawValue: rawValue) ?? .general
    }
}

struct AppSettingsView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel
    let updateMonitor: AppUpdateMonitor
    @AppStorage(SettingsTabSelectionStore.key) private var selectedTabRaw = SettingsTabSelection.general.rawValue

    var body: some View {
        TabView(selection: Binding(
            get: { SettingsTabSelectionStore.selectedTab(from: selectedTabRaw) },
            set: { selectedTabRaw = $0.rawValue }
        )) {
            Form {
                Section("Menu bar") {
                    Toggle("Show reset date", isOn: Binding(
                        get: { viewModel.menuBarDisplayOptions.showsResetDate },
                        set: { viewModel.setMenuBarShowsResetDate($0) }
                    ))
                    Toggle("Show reset time", isOn: Binding(
                        get: { viewModel.menuBarDisplayOptions.showsResetTime },
                        set: { viewModel.setMenuBarShowsResetTime($0) }
                    ))
                    Text(viewModel.menuBarPercentText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Section("Startup") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { viewModel.launchAtLoginEnabled },
                        set: { viewModel.setLaunchAtLoginEnabled($0) }
                    ))
                    if let error = viewModel.launchAtLoginError {
                        Text(error).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTabSelection.general)

            InstallUpdateSettingsView(viewModel: InstallUpdateSettingsViewModel(updateMonitor: updateMonitor))
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTabSelection.updates)
        }
        .frame(width: 760, height: 700)
        .scenePadding()
    }
}
