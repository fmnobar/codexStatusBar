import AppKit
import SwiftUI

@main
struct CodexUsageMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
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
