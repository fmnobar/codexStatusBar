import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isLoading && !viewModel.hasSnapshot {
                Text("Loading…")
                    .font(.system(size: 13))
            } else if let errorMessage = viewModel.errorMessage, !viewModel.hasSnapshot {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Retry") {
                    Task {
                        await viewModel.retry()
                    }
                }
            } else {
                Text(viewModel.fiveHourLine)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                Text(viewModel.sevenDayLine)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }
}
