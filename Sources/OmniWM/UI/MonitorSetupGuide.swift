// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct MonitorSetupGuide: View {
    private enum Step: Int, CaseIterable {
        case macOSArrangement
        case physicalArrangement
        case workspaceHomes
        case mouseWarp

        var title: String {
            switch self {
            case .macOSArrangement: String(localized: "Arrange Displays in macOS")
            case .physicalArrangement: String(localized: "Match Your Real Desk")
            case .workspaceHomes: String(localized: "Give Every Display a Workspace")
            case .mouseWarp: String(localized: "Make the Pointer Feel Natural")
            }
        }

        var icon: String {
            switch self {
            case .macOSArrangement: "macwindow.on.rectangle"
            case .physicalArrangement: "display.2"
            case .workspaceHomes: "rectangle.3.group"
            case .mouseWarp: "computermouse"
            }
        }
    }

    @Bindable private var settings: SettingsStore
    @Bindable private var controller: WMController
    private let onFinish: () -> Void
    private let onSkip: () -> Void

    @State private var step = Step.macOSArrangement
    @State private var draft: MonitorSetupDraft
    @State private var draftMonitors: [Monitor]
    @State private var liveMonitors: [Monitor]
    @State private var selectedMonitor: Monitor.ID?
    @State private var confirmedMacOSArrangement = false
    @State private var identificationOverlayController: MonitorIdentificationOverlayController
    @AccessibilityFocusState private var headingFocused: Bool

    init(
        settings: SettingsStore,
        controller: WMController,
        monitors: [Monitor],
        onFinish: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        let sortedMonitors = MonitorSettingsTabModel.sortedMonitors(monitors)
        self.settings = settings
        self.controller = controller
        self.onFinish = onFinish
        self.onSkip = onSkip
        _draft = State(initialValue: MonitorSetupDraft(
            monitors: sortedMonitors,
            routingMode: settings.monitors.routingMode,
            arrangements: settings.monitors.arrangements,
            mouseWarpEnabled: settings.pointer.enabled,
            workspaceConfigurations: settings.workspaces.configurations,
            monitorRanking: settings.monitors.ranking
        ))
        _draftMonitors = State(initialValue: sortedMonitors)
        _liveMonitors = State(initialValue: sortedMonitors)
        _selectedMonitor = State(initialValue: sortedMonitors.first?.id)
        _identificationOverlayController = State(initialValue: MonitorIdentificationOverlayController())
    }

    private var routingReadiness: MonitorSetupDraft.Readiness {
        draft.readiness(for: liveMonitors)
    }

    private var hasWorkspaceCoverage: Bool {
        draft.hasWorkspaceCoverage(in: liveMonitors)
    }

    private var canContinue: Bool {
        switch step {
        case .macOSArrangement:
            confirmedMacOSArrangement && liveMonitors.count > 1
        case .physicalArrangement:
            routingReadiness == .ready
        case .workspaceHomes:
            routingReadiness == .ready && hasWorkspaceCoverage
        case .mouseWarp:
            routingReadiness == .ready && hasWorkspaceCoverage
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .padding(28)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .background(.background)
        .onAppear {
            headingFocused = true
            refreshLiveMonitors()
        }
        .onChange(of: step) { _, _ in
            identificationOverlayController.hide()
            headingFocused = true
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            refreshLiveMonitors()
        }
        .onDisappear {
            identificationOverlayController.hide()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(step.title, systemImage: step.icon)
                    .font(.title2.bold())
                    .accessibilityHeading(.h1)
                    .accessibilityFocused($headingFocused)

                Spacer()

                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(
                value: Double(step.rawValue + 1),
                total: Double(Step.allCases.count)
            )
            .accessibilityLabel("Monitor setup progress")
            .accessibilityValue("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var stepContent: some View {
        if routingReadiness == .monitorConfigurationChanged {
            monitorConfigurationChangedContent
        } else {
            switch step {
            case .macOSArrangement:
                MonitorSetupMacOSArrangementStep(
                    liveMonitors: liveMonitors,
                    animationsEnabled: controller.motionPolicy.animationsEnabled,
                    confirmedMacOSArrangement: $confirmedMacOSArrangement
                )
            case .physicalArrangement:
                MonitorSetupPhysicalArrangementStep(
                    draft: $draft,
                    selectedMonitor: $selectedMonitor,
                    draftMonitors: draftMonitors,
                    liveMonitors: liveMonitors,
                    identificationOverlayController: identificationOverlayController
                )
            case .workspaceHomes:
                MonitorSetupWorkspaceHomesStep(
                    draft: $draft,
                    draftMonitors: draftMonitors,
                    liveMonitors: liveMonitors
                )
            case .mouseWarp:
                MonitorSetupMouseWarpStep(
                    mouseWarpEnabled: $draft.mouseWarpEnabled,
                    animationsEnabled: controller.motionPolicy.animationsEnabled
                )
            }
        }
    }

    private var monitorConfigurationChangedContent: some View {
        ContentUnavailableView {
            Label("Displays Changed", systemImage: "display.trianglebadge.exclamationmark")
        } description: {
            Text("A display was connected or disconnected while setup was open.")
        } actions: {
            Button("Restart with Current Displays", action: restartWithCurrentDisplays)
        }
        .frame(minHeight: 260)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip for Now") {
                identificationOverlayController.hide()
                onSkip()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if step != .macOSArrangement {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .macOSArrangement
                }
            }

            if step == .mouseWarp {
                Button("Finish", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            } else {
                Button("Continue") {
                    step = Step(rawValue: step.rawValue + 1) ?? .mouseWarp
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func refreshLiveMonitors() {
        let monitors = MonitorSettingsTabModel.sortedMonitors(Monitor.current())
        liveMonitors = monitors
        if draft.readiness(for: monitors) == .monitorConfigurationChanged {
            identificationOverlayController.hide()
        }
    }

    private func restartWithCurrentDisplays() {
        let monitors = liveMonitors
        draftMonitors = monitors
        draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: settings.monitors.routingMode,
            arrangements: settings.monitors.arrangements,
            mouseWarpEnabled: draft.mouseWarpEnabled,
            workspaceConfigurations: settings.workspaces.configurations,
            monitorRanking: settings.monitors.ranking
        )
        selectedMonitor = monitors.first?.id
        confirmedMacOSArrangement = false
        step = .macOSArrangement
        identificationOverlayController.hide()
    }

    private func finish() {
        guard routingReadiness == .ready,
              hasWorkspaceCoverage,
              let routingSettings = draft.routingSettings(monitors: liveMonitors)
        else { return }

        let workspaceConfigurationsChanged = settings.workspaces.configurations != draft.workspaceConfigurations
        settings.applyMonitorSetup(
            routingSettings: routingSettings,
            monitors: liveMonitors,
            mouseWarpEnabled: draft.mouseWarpEnabled,
            workspaceConfigurations: draft.workspaceConfigurations
        )
        if workspaceConfigurationsChanged {
            controller.updateWorkspaceConfig()
        }
        controller.resetMouseWarpTransientState()
        settings.monitorSetupStatus = .completed
        identificationOverlayController.hide()
        onFinish()
    }
}
