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
                selectableLine(
                    text: viewModel.fiveHourLine,
                    displayWindow: .fiveHour
                )

                selectableLine(
                    text: viewModel.sevenDayLine,
                    displayWindow: .sevenDay
                )
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func selectableLine(text: String, displayWindow: MenuBarDisplayWindow) -> some View {
        Button {
            viewModel.selectMenuBarDisplayWindow(displayWindow)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: viewModel.selectedMenuBarDisplayWindow == displayWindow ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .frame(width: 14)

                Text(text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
