import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel
    let onOpenHistory: () -> Void

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
                selectableRow(viewModel.tightestRow)
                Divider()
                historySection
                Divider()
                launchAtLoginSection
                Divider()
                footer
            }
        }
        .padding(12)
        .background(PopoverMaterialBackground())
    }

    @ViewBuilder
    private func selectableRow(_ row: MenuBarLimitRowPresentation) -> some View {
        Button {
            viewModel.selectMenuBarDisplayWindow(row.displayWindow)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                checkboxImage(isSelected: row.isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .font(.system(size: 13))

                        if !row.remainingPercentText.isEmpty {
                            Text(row.remainingPercentText)
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }

                    if !row.detailText.isEmpty {
                        Text(row.detailText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var historySection: some View {
        Button {
            onOpenHistory()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 14))
                    .frame(width: 14)

                Text("History")
                    .font(.system(size: 13))

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var launchAtLoginSection: some View {
        Button {
            viewModel.setLaunchAtLoginEnabled(!viewModel.launchAtLoginEnabled)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                checkboxImage(isSelected: viewModel.launchAtLoginEnabled)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                        .font(.system(size: 13))

                    if let launchAtLoginError = viewModel.launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
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

    private func checkboxImage(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.system(size: 14))
            .frame(width: 14, alignment: .top)
    }
}

private struct PopoverMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
    }
}
