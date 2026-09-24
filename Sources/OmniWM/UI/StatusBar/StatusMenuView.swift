// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation
import SwiftUI

struct StatusMenuHelpSelection: Equatable {
    private(set) var hoveredControl: StatusMenuControl?
    private(set) var focusedControl: StatusMenuControl?
    private(set) var presentedControl: StatusMenuControl?

    mutating func hoverEntered(_ control: StatusMenuControl) {
        hoveredControl = control
    }

    @discardableResult
    mutating func hoverExited(_ control: StatusMenuControl) -> Bool {
        guard hoveredControl == control else { return false }
        hoveredControl = nil
        return true
    }

    @discardableResult
    mutating func presentHovered(_ control: StatusMenuControl) -> Bool {
        guard hoveredControl == control else { return false }
        presentedControl = control
        return true
    }

    mutating func focusChanged(_ control: StatusMenuControl, isFocused: Bool) {
        if isFocused {
            focusedControl = control
            if hoveredControl == nil {
                presentedControl = control
            }
        } else if focusedControl == control {
            focusedControl = nil
            if hoveredControl == nil {
                presentedControl = nil
            }
        }
    }

    mutating func settleAfterHoverExit() {
        guard hoveredControl == nil else { return }
        presentedControl = focusedControl
    }

    mutating func reset() {
        hoveredControl = nil
        focusedControl = nil
        presentedControl = nil
    }
}

@MainActor
@Observable
final class StatusMenuHelpPresentation {
    typealias Sleep = @MainActor (Duration) async throws -> Void

    private enum DelayedTransition {
        case present(StatusMenuControl)
        case settle
    }

    private(set) var selection = StatusMenuHelpSelection()

    @ObservationIgnored
    private let sleep: Sleep

    @ObservationIgnored
    private var transitionTask: Task<Void, Never>?

    init(sleep: @escaping Sleep = { try await Task<Never, Never>.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func hoverChanged(_ control: StatusMenuControl, isHovered: Bool) {
        if isHovered {
            selection.hoverEntered(control)
            schedule(.present(control), after: .milliseconds(300))
            return
        }

        guard selection.hoverExited(control) else { return }
        schedule(.settle, after: .milliseconds(150))
    }

    func focusChanged(_ control: StatusMenuControl, isFocused: Bool) {
        let hasHoveredControl = selection.hoveredControl != nil
        selection.focusChanged(control, isFocused: isFocused)
        if !hasHoveredControl {
            transitionTask?.cancel()
            transitionTask = nil
        }
    }

    func reset() {
        transitionTask?.cancel()
        transitionTask = nil
        selection.reset()
    }

    private func schedule(_ transition: DelayedTransition, after delay: Duration) {
        transitionTask?.cancel()
        let sleep = sleep
        transitionTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            switch transition {
            case let .present(control):
                selection.presentHovered(control)
            case .settle:
                selection.settleAfterHoverExit()
            }
            transitionTask = nil
        }
    }
}

struct StatusMenuPrimaryView: View {
    let model: StatusMenuModel

    @State private var helpPresentation = StatusMenuHelpPresentation()

    var body: some View {
        VStack(spacing: 0) {
            MenuHeader()
            MenuDivider()
            if !model.diagnosticsIssues.isEmpty {
                MenuActionRow(
                    icon: "exclamationmark.triangle.fill",
                    label: String(localized: "Issues Detected (\(model.diagnosticsIssues.count))")
                ) {
                    model.openSettings(section: .diagnostics)
                }
                MenuDivider()
            }
            if model.displaySpacesMode != .enabled {
                MenuInfoRow(
                    icon: "exclamationmark.triangle.fill",
                    label: model.displaySpacesMode == .disabled
                        ? String(localized: "Enable “Displays have separate Spaces”")
                        : String(localized: "Could not verify display Spaces setting")
                )
                MenuDivider()
            }
            MenuSectionLabel(text: String(localized: "CONTROLS"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(model.toggleTiles) { tile in
                    MenuToggleTile(
                        control: tile.control,
                        isOn: tile.isOn,
                        onHoverChanged: handleHoverChanged,
                        onFocusChanged: handleFocusChanged
                    )
                }
            }
            .padding(10)
            StatusMenuControlHelpCard(control: helpPresentation.selection.presentedControl)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            MenuDivider()
            if model.canShowHiddenIcons {
                MenuActionRow(icon: "eye", label: String(localized: "Show Hidden Icons")) {
                    model.showHiddenIcons()
                }
            }
            MenuActionRow(icon: "gearshape", label: String(localized: "Settings")) {
                model.openSettings()
            }
            MenuActionRow(icon: "ladybug", label: String(localized: "Report a Bug…")) {
                model.openReportIssue()
            }
            MenuActionRow(icon: "slider.horizontal.3", label: String(localized: "App Rules")) {
                model.openAppRules()
            }
            if model.checkForUpdatesAction != nil {
                MenuActionRow(icon: "arrow.down.circle", label: String(localized: "Check for Updates...")) {
                    model.checkForUpdates()
                }
            }
            MenuDivider()
        }
        .onChange(of: model.menuPresentationGeneration) { _, _ in
            helpPresentation.reset()
        }
        .onDisappear {
            helpPresentation.reset()
        }
    }

    private func handleHoverChanged(_ control: StatusMenuControl, _ isHovered: Bool) {
        helpPresentation.hoverChanged(control, isHovered: isHovered)
    }

    private func handleFocusChanged(_ control: StatusMenuControl, _ isFocused: Bool) {
        helpPresentation.focusChanged(control, isFocused: isFocused)
    }
}

struct StatusMenuFooterView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            MenuDivider()
            MenuActionRow(icon: "sparkles", label: String(localized: "Omni Sponsors")) {
                model.openSponsors()
            }
            MenuDivider()
            MenuActionRow(icon: "power", label: String(localized: "Quit OmniWM"), isDestructive: true) {
                model.quit()
            }
        }
    }
}

struct StatusMenuAdvancedView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            if model.ipcMenuEnabled {
                MenuSectionLabel(text: String(localized: "IPC / CLI"))
                MenuToggleRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    label: String(localized: "Enable IPC"),
                    isOn: ipcEnabled
                )
                cliStatusRow
                MenuDivider()
            }
            MenuSectionLabel(text: String(localized: "SETTINGS FILE"))
            MenuActionRow(icon: "folder", label: String(localized: "Reveal Settings File")) {
                model.performSettingsFileAction(.reveal)
            }
            MenuActionRow(icon: "pencil", label: String(localized: "Edit Settings File")) {
                model.performSettingsFileAction(.open)
            }
        }
    }

    private var ipcEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.ipcEnabled },
            set: { model.settings.ipcEnabled = $0 }
        )
    }

    @ViewBuilder
    private var cliStatusRow: some View {
        if model.cliManager != nil, let status = model.cliStatus {
            switch status {
            case .appManaged:
                MenuActionRow(icon: "trash", label: String(localized: "Remove CLI from PATH…")) {
                    model.removeCLI()
                }
            case .conflict:
                MenuInfoRow(
                    icon: "exclamationmark.triangle.fill",
                    label: String(localized: "CLI path is already occupied")
                )
            case .homebrewManaged:
                MenuInfoRow(icon: "checkmark.circle.fill", label: String(localized: "CLI available via Homebrew"))
            case .notInstalled:
                MenuActionRow(icon: "terminal", label: String(localized: "Install CLI to PATH…")) {
                    model.installCLI()
                }
            }
        }
    }
}

struct StatusMenuDiagnosticsView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            if model.traceCapturePhase == .idle {
                MenuActionRow(icon: "record.circle", label: String(localized: "Record a Problem")) {
                    model.toggleTraceRecording(profile: .problem)
                }
                MenuActionRow(
                    icon: "gauge.with.dots.needle.67percent",
                    label: String(localized: "Measure Performance")
                ) {
                    model.toggleTraceRecording(profile: .performance)
                }
            } else {
                MenuActionRow(
                    icon: traceIcon,
                    label: traceLabel
                ) {
                    model.toggleTraceRecording(profile: model.traceCaptureProfile ?? .problem)
                }
                .disabled(model.traceCapturePhase == .starting || model.traceCapturePhase == .finalizing)
            }
            MenuActionRow(icon: "stethoscope", label: String(localized: "Open Troubleshooting…")) {
                model.openSettings(section: .diagnostics)
            }
        }
    }

    private var traceIcon: String {
        switch model.traceCapturePhase {
        case .idle: "record.circle"
        case .starting: "hourglass"
        case .recording: "stop.circle"
        case .finalizing: "hourglass"
        }
    }

    private var traceLabel: String {
        switch model.traceCapturePhase {
        case .idle: String(localized: "Start Recording")
        case .starting:
            if model.traceCaptureProfile == .performance {
                String(localized: "Starting performance capture…")
            } else {
                String(localized: "Starting diagnostics…")
            }
        case .recording:
            if model.traceCaptureProfile == .performance {
                String(localized: "Stop & Save Performance Capture")
            } else {
                String(localized: "Stop & Save Recording")
            }
        case .finalizing:
            if model.traceCaptureProfile == .performance {
                String(localized: "Finalizing performance capture…")
            } else {
                String(localized: "Finalizing diagnostics…")
            }
        }
    }
}

struct StatusMenuHelpLinksView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(spacing: 0) {
            MenuActionRow(icon: "link", label: String(localized: "GitHub"), isExternal: true) {
                open("https://github.com/OmniNull/OmniWM")
            }
            MenuActionRow(icon: "heart", label: String(localized: "Sponsor on GitHub"), isExternal: true) {
                open("https://github.com/sponsors/BarutSRB")
            }
            MenuActionRow(icon: "heart", label: String(localized: "Sponsor on PayPal"), isExternal: true) {
                open("https://paypal.me/beacon2024")
            }
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
