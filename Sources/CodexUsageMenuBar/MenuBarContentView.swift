import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isLoading && !viewModel.hasSnapshot {
                Text("Loading…")
                    .font(.system(size: 13))
            } else if let errorMessage = viewModel.errorMessage, !viewModel.hasSnapshot {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Retry") {
                    Task {
                        await viewModel.manualRefresh()
                    }
                }
            } else {
                selectableRow(viewModel.fiveHourRow)
                selectableRow(viewModel.sevenDayRow)
                Divider()
                footer
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func selectableRow(_ row: MenuBarLimitRowPresentation) -> some View {
        Button {
            viewModel.selectMenuBarDisplayWindow(row.displayWindow)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .frame(width: 14, alignment: .top)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .font(.system(size: 13))

                        Text(row.remainingPercentText)
                            .font(.system(size: 13, weight: .semibold))
                    }

                    Text(row.resetText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let footerStatusText = viewModel.footerStatusText {
                    Text(footerStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.isStaleSnapshot ? .orange : .secondary)
                }

                if let footerModeText = viewModel.footerModeText {
                    Text(footerModeText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    await viewModel.manualRefresh()
                }
            } label: {
                TimelineView(.animation) { context in
                    let rotation = refreshRotation(at: context.date)

                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .rotationEffect(rotation)
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)
            .help(viewModel.isRefreshing ? "Refreshing…" : "Refresh")
            .accessibilityLabel(viewModel.isRefreshing ? "Refreshing" : "Refresh")
        }
    }

    private func refreshRotation(at date: Date) -> Angle {
        guard viewModel.isRefreshing else {
            return .degrees(0)
        }

        let cycleDuration = 0.9
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration

        return .degrees(progress * 360)
    }
}
