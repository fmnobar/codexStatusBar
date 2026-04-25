import AppKit
import SwiftUI

private enum MenuBarPopoverExpandedSection: Equatable {
    case history
    case settings
}

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel
    let historyStore: UsageHistoryStore
    var onContentSizeChange: (NSSize) -> Void = { _ in }
    var appVersionInfo: AppVersionInfo = .current()
    @State private var expandedSection: MenuBarPopoverExpandedSection?

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
                settingsSection
                Divider()
                footer
            }
        }
        .padding(12)
        .frame(width: popoverWidth, alignment: .topLeading)
        .background(PopoverMaterialBackground())
        .background(contentSizeReader)
        .animation(.snappy(duration: 0.18), value: expandedSection)
    }

    private var popoverWidth: CGFloat {
        switch expandedSection {
        case .history:
            return 820
        case .settings:
            return 640
        case nil:
            return 340
        }
    }

    private var contentSizeReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PopoverContentSizePreferenceKey.self, value: proxy.size)
        }
        .onPreferenceChange(PopoverContentSizePreferenceKey.self) { size in
            guard size.width > 0, size.height > 0 else {
                return
            }

            onContentSizeChange(NSSize(width: ceil(size.width), height: ceil(size.height)))
        }
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
        VStack(alignment: .leading, spacing: 10) {
            expandableHeader(title: "History", systemImage: "chart.xyaxis.line", section: .history)

            if expandedSection == .history {
                UsageHistoryView(store: historyStore)
                    .frame(height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            expandableHeader(title: "Settings", systemImage: "gearshape", section: .settings)

            if expandedSection == .settings {
                inlineSettings
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func expandableHeader(
        title: String,
        systemImage: String,
        section: MenuBarPopoverExpandedSection
    ) -> some View {
        Button {
            expandedSection = expandedSection == section ? nil : section
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 13))

                Spacer(minLength: 0)

                Image(systemName: expandedSection == section ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var inlineSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Menu Bar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Toggle(
                    "Show limit label",
                    isOn: Binding(
                        get: { viewModel.menuBarDisplayOptions.showsLimitLabel },
                        set: { viewModel.setMenuBarShowsLimitLabel($0) }
                    )
                )
                .toggleStyle(.checkbox)

                Toggle(
                    "Show reset date",
                    isOn: Binding(
                        get: { viewModel.menuBarDisplayOptions.showsResetDate },
                        set: { viewModel.setMenuBarShowsResetDate($0) }
                    )
                )
                .toggleStyle(.checkbox)

                Toggle(
                    "Show reset time",
                    isOn: Binding(
                        get: { viewModel.menuBarDisplayOptions.showsResetTime },
                        set: { viewModel.setMenuBarShowsResetTime($0) }
                    )
                )
                .toggleStyle(.checkbox)

                HStack(spacing: 8) {
                    Text("Preview")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(viewModel.menuBarPercentText)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                }
            }

            Divider()

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

            Divider()

            DataManagementSettingsView(store: historyStore)
                .frame(height: 560)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let footerStatusText = viewModel.footerStatusText {
                    Text(footerStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.isStaleSnapshot ? .orange : .secondary)
                }

                Text(appVersionInfo.versionBuildText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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

private struct PopoverContentSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let nextValue = nextValue()
        guard nextValue != .zero else {
            return
        }

        value = nextValue
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
