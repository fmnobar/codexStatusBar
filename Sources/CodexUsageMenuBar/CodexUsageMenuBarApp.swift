import SwiftUI

@main
struct CodexUsageMenuBarApp: App {
    @StateObject private var viewModel: MenuBarStatusViewModel

    init() {
        let viewModel = MenuBarStatusViewModel(client: CodexAppServerClient())
        _viewModel = StateObject(wrappedValue: viewModel)

        Task {
            await viewModel.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(viewModel: viewModel)
                .frame(width: 300)
                .onAppear {
                    Task {
                        await viewModel.popoverDidAppear()
                    }
                }
        } label: {
            HStack(spacing: 6) {
                CodexMarkView()
                Text(viewModel.menuBarPercentText)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
