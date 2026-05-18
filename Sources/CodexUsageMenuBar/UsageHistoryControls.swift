import SwiftUI

struct NeutralCheckboxMark: View {
    let isSelected: Bool
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: size, height: size, alignment: .center)
    }
}

struct NeutralCheckboxToggleStyle: ToggleStyle {
    var size: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                NeutralCheckboxMark(isSelected: configuration.isOn, size: size)
                configuration.label
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct UsageHistoryPeriodNavigationView: View {
    @ObservedObject var viewModel: UsageHistoryViewModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.goToPreviousPeriod()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToPreviousPeriod)
            .help(viewModel.previousPeriodHelpText)
            .accessibilityLabel(viewModel.previousPeriodAccessibilityLabel)

            Text(viewModel.periodTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 72, alignment: .center)

            Button {
                viewModel.jumpToCurrentPeriod()
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canJumpToCurrentPeriod)
            .help(viewModel.currentPeriodHelpText)
            .accessibilityLabel(viewModel.currentPeriodAccessibilityLabel)

            Button {
                viewModel.goToNextPeriod()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoToNextPeriod)
            .help(viewModel.nextPeriodHelpText)
            .accessibilityLabel(viewModel.nextPeriodAccessibilityLabel)
        }
    }
}
