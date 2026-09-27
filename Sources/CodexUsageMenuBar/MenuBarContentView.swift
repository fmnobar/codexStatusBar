import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel
    @ObservedObject var updateMonitor: AppUpdateMonitor
    @ObservedObject var resetCreditStore: CodexResetCreditStore
    let resetCreditClient: CodexResetCreditFetching?
    var onOpenUpdatesSettings: () -> Void
    var onOpenSettings: () -> Void
    var onContentSizeChange: (NSSize) -> Void
    var appVersionInfo: AppVersionInfo
    @StateObject private var freshnessViewModel: AppFreshnessStatusViewModel
    @State private var resetCreditRefreshTask: Task<Void, Never>?

    init(
        viewModel: MenuBarStatusViewModel,
        updateMonitor: AppUpdateMonitor = AppUpdateMonitor(),
        resetCreditStore: CodexResetCreditStore = .applicationSupportStore(),
        resetCreditClient: CodexResetCreditFetching? = nil,
        onOpenUpdatesSettings: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onContentSizeChange: @escaping (NSSize) -> Void = { _ in },
        appVersionInfo: AppVersionInfo = .current(),
        freshnessViewModel: AppFreshnessStatusViewModel = .current()
    ) {
        self.viewModel = viewModel
        self.updateMonitor = updateMonitor
        self.resetCreditStore = resetCreditStore
        self.resetCreditClient = resetCreditClient
        self.onOpenUpdatesSettings = onOpenUpdatesSettings
        self.onOpenSettings = onOpenSettings
        self.onContentSizeChange = onContentSizeChange
        self.appVersionInfo = appVersionInfo
        _freshnessViewModel = StateObject(wrappedValue: freshnessViewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.isLoading && !viewModel.hasSnapshot {
                Text("Loading…")
                    .font(.system(size: 13))
            } else if let errorMessage = viewModel.errorMessage, !viewModel.hasSnapshot {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Settings", action: onOpenSettings)

                Button("Retry") {
                    Task {
                        await viewModel.manualRefresh()
                    }
                }
            } else {
                sevenDayUsageRow
                if shouldShowResetCreditsSection {
                    Divider()
                    resetCreditsSection
                }
                Divider()
                inlineSettings
                Divider()
                if freshnessViewModel.shouldShowWarning {
                    staleBuildWarningRow
                    Divider()
                }
                if updateMonitor.promptPresentation != nil {
                    updatePromptRow
                    Divider()
                }
                footer
            }
        }
        .padding(10)
        .frame(width: popoverWidth, alignment: .topLeading)
        .background(PopoverMaterialBackground())
        .background(contentSizeReader)
        .onAppear {
            freshnessViewModel.refresh()
            Task {
                await updateMonitor.checkIfNeeded()
            }
            refreshResetCreditsIfNeeded()
        }
        .onDisappear {
            resetCreditRefreshTask?.cancel()
            resetCreditRefreshTask = nil
        }
    }

    private var popoverWidth: CGFloat {
        360
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

    private var sevenDayUsageRow: some View {
        let row = viewModel.sevenDayRow

        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("7-day usage")
                    .font(.system(size: 12))

                Spacer(minLength: 0)

                Text(row.remainingPercentText)
                    .font(.system(size: 12, weight: .semibold))
            }

            Text(row.detailText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("7-day usage")
        .accessibilityValue("\(row.remainingPercentText), \(row.detailText)")
    }

    private var shouldShowResetCreditsSection: Bool {
        resetCreditClient != nil
            || resetCreditStore.state.snapshot != nil
            || resetCreditStore.state.status == .refreshing
    }

    private var resetCreditsSection: some View {
        let isRefreshing = resetCreditStore.state.status == .refreshing

        return HStack(alignment: .top, spacing: 8) {
            resetCreditsBody
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                refreshResetCredits(force: true)
            } label: {
                refreshIcon(isRefreshing: isRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing || resetCreditClient == nil)
            .help(isRefreshing ? "Refreshing available usage resets…" : "Refresh available usage resets")
            .accessibilityLabel(isRefreshing ? "Refreshing usage resets" : "Refresh usage resets")
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var resetCreditsBody: some View {
        if let snapshot = resetCreditStore.state.snapshot {
            if snapshot.credits.isEmpty {
                Text("No available resets.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.credits) { credit in
                        resetCreditRow(credit)
                    }
                }
            }
        } else if resetCreditStore.state.status == .failed {
            Text("Usage resets unavailable.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text("Checking available resets...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func resetCreditRow(_ credit: CodexResetCredit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(credit.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            HStack(spacing: 8) {
                Text("Granted \(Self.resetCreditDateFormatter.string(from: credit.grantedAt))")
                Text("Expires \(Self.resetCreditDateFormatter.string(from: credit.expiresAt))")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inlineSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                menuBarDisplayOptionsRow
                menuBarPreviewRow
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Launch at login")
            .accessibilityValue(viewModel.launchAtLoginEnabled ? "On" : "Off")
        }
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var menuBarDisplayOptionsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            inlineCheckboxOption(
                title: "Remaining %",
                isSelected: viewModel.menuBarDisplayOptions.showsRemainingPercentage,
                action: {
                    viewModel.setMenuBarShowsRemainingPercentage(!viewModel.menuBarDisplayOptions.showsRemainingPercentage)
                }
            )

            inlineCheckboxOption(
                title: "Reset date",
                isSelected: viewModel.menuBarDisplayOptions.showsResetDate,
                action: {
                    viewModel.setMenuBarShowsResetDate(!viewModel.menuBarDisplayOptions.showsResetDate)
                }
            )

            inlineCheckboxOption(
                title: "Reset time",
                isSelected: viewModel.menuBarDisplayOptions.showsResetTime,
                action: {
                    viewModel.setMenuBarShowsResetTime(!viewModel.menuBarDisplayOptions.showsResetTime)
                }
            )

        }
        .font(.system(size: 12))
    }

    private var menuBarPreviewRow: some View {
        HStack(spacing: 5) {
            if let remainingPercent = viewModel.weeklyRemainingPercent {
                Image(nsImage: StatusItemRingImage.make(remainingPercent: remainingPercent))
                    .renderingMode(.template)
                    .frame(width: 15, height: 15)
            }

            if !viewModel.menuBarPercentText.isEmpty {
                Text(viewModel.menuBarPercentText)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineCheckboxOption(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                checkboxImage(isSelected: isSelected)

                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "On" : "Off")
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            if let footerStatusText = viewModel.footerStatusText {
                Text(footerStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(viewModel.isStaleSnapshot ? .orange : .secondary)
                    .lineLimit(1)

                Text("•")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Text(appVersionInfo.versionBuildText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                Task {
                    await viewModel.manualRefresh()
                }
            } label: {
                refreshIcon(isRefreshing: viewModel.isRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)
            .help(viewModel.isRefreshing ? "Refreshing…" : "Refresh")
            .accessibilityLabel(viewModel.isRefreshing ? "Refreshing" : "Refresh")
        }
    }

    @ViewBuilder
    private func refreshIcon(isRefreshing: Bool) -> some View {
        if isRefreshing {
            TimelineView(.animation) { context in
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(refreshRotation(at: context.date))
                    .frame(width: 18, height: 18)
            }
        } else {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
        }
    }

    private var staleBuildWarningRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)

            Text(freshnessViewModel.popoverWarningText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if freshnessViewModel.canRelaunchLatestInstalledApp {
                Button("Relaunch") {
                    freshnessViewModel.relaunchLatestInstalledApp()
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.borderless)
                .help("Relaunch the installed app bundle")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var updatePromptRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.blue)

            Text(updateMonitor.promptPresentation?.titleText ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("Updates") {
                onOpenUpdatesSettings()
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.borderless)
            .help("Open Updates settings")

            Button("Later") {
                updateMonitor.snoozeCurrentPrompt()
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .help("Hide this update prompt for 24 hours")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func refreshRotation(at date: Date) -> Angle {
        let cycleDuration = 0.9
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration

        return .degrees(progress * 360)
    }

    private func checkboxImage(isSelected: Bool) -> some View {
        checkboxImage(isSelected: isSelected, size: 12)
    }

    private func checkboxImage(isSelected: Bool, size: CGFloat) -> some View {
        NeutralCheckboxMark(isSelected: isSelected, size: size)
    }

    private func refreshResetCreditsIfNeeded() {
        guard resetCreditStore.state.isStale(
            now: Date(),
            staleAfter: CodexResetCreditStore.defaultCacheDuration
        ) else {
            return
        }

        refreshResetCredits(force: false)
    }

    private func refreshResetCredits(force: Bool) {
        guard let resetCreditClient else {
            return
        }

        if !force,
           !resetCreditStore.state.isStale(
               now: Date(),
               staleAfter: CodexResetCreditStore.defaultCacheDuration
           )
        {
            return
        }

        resetCreditRefreshTask?.cancel()
        resetCreditRefreshTask = Task { @MainActor in
            resetCreditStore.recordRefreshStarted()
            do {
                let snapshot = try await resetCreditClient.resetCreditSnapshot()
                guard !Task.isCancelled else {
                    return
                }
                resetCreditStore.recordSuccess(snapshot)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                resetCreditStore.recordFailure("Usage resets unavailable.")
            }
        }
    }

    private static let resetCreditDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

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
