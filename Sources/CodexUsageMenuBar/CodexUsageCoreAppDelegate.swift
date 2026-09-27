import AppKit
// Keep the AppIntents link explicit for Xcode's metadata pass.
import AppIntents
import SwiftUI

@MainActor
protocol CodexUsageApplicationRuntime: AnyObject {
    var settingsView: AnyView { get }
    func start()
    func stop()
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: any CodexUsageApplicationRuntime

    public override convenience init() {
        self.init(runtime: CodexUsageProductionRuntime())
    }

    init(runtime: any CodexUsageApplicationRuntime) {
        self.runtime = runtime
        super.init()
    }

    public var settingsView: some View { runtime.settingsView }

    public func applicationDidFinishLaunching(_ notification: Notification) { runtime.start() }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationWillTerminate(_ notification: Notification) { runtime.stop() }
}

enum CodexStatusBarData {
    static func directoryURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("CodexStatusBar", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
final class CodexUsageProductionRuntime: CodexUsageApplicationRuntime {
    private let updateMonitor: AppUpdateMonitor
    private let codexClient: CodexAppServerClient
    private let viewModel: MenuBarStatusViewModel
    private var statusItemController: StatusItemController?
    private var hasStarted = false

    var settingsView: AnyView {
        AnyView(AppSettingsView(viewModel: viewModel, updateMonitor: updateMonitor))
    }

    init() {
        AppFreshnessRuntime.captureLaunchFingerprint()
        updateMonitor = AppUpdateMonitor()
        codexClient = CodexAppServerClient()
        viewModel = MenuBarStatusViewModel(client: codexClient)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        statusItemController = StatusItemController(viewModel: viewModel, updateMonitor: updateMonitor, resetCreditClient: codexClient)
        Task { await viewModel.start() }
        Task { await updateMonitor.checkIfNeeded() }
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        viewModel.stop()
    }
}
