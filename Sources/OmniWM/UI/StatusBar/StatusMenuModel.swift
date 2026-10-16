// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class StatusMenuModel {
    let settings: SettingsStore
    private(set) weak var controller: WMController?
    var cliManager: AppCLIManager?
    var updateCoordinator: (any AppUpdateCoordinating)?
    var checkForUpdatesAction: (() -> Void)?
    var ipcMenuEnabled = false
    var infoAlertPresenter: (String, String) -> Void
    var confirmationAlertPresenter: (String, String, String, String) -> Bool
    var settingsFileActionPerformer: (SettingsFileAction, SettingsStore) throws -> SettingsFileStatus
    private(set) var cliStatus: AppCLIExposureStatus?
    private(set) var menuPresentationGeneration = 0

    init(settings: SettingsStore, controller: WMController) {
        self.settings = settings
        self.controller = controller
        infoAlertPresenter = { title, message in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = alert.runModal()
        }
        confirmationAlertPresenter = { title, message, confirmTitle, cancelTitle in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: cancelTitle)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
        settingsFileActionPerformer = { action, settings in
            try SettingsFileWorkflow.perform(
                action,
                settings: settings
            )
        }
    }

    var diagnosticsIssues: [DiagnosticsIssue] {
        controller?.diagnosticsIssues ?? []
    }

    var displaySpacesMode: DisplaySpacesMode {
        controller?.displaySpacesMode ?? .enabled
    }

    var isTraceCaptureActive: Bool {
        controller?.isTraceCaptureActive ?? false
    }

    var traceCapturePhase: TraceCapturePhase {
        controller?.traceCaptureStatus.phase ?? .idle
    }

    var traceCaptureProfile: TraceCaptureProfile? {
        controller?.traceCaptureStatus.profile
    }

    var canShowHiddenIcons: Bool {
        settings.effectiveHiddenBarEnabled && controller?.isHiddenBarHidingAvailable == true
    }

    func menuWillOpen() {
        menuPresentationGeneration += 1
        controller?.refreshDiagnosticsIssues()
        refreshCLIStatus()
    }

    func refreshCLIStatus() {
        cliStatus = cliManager?.exposureStatus()
    }

    func menuDidClose() {
        menuPresentationGeneration += 1
    }

    var toggleTiles: [ToggleTileSpec] {
        let settings = settings
        weak let controller = controller
        var tiles: [ToggleTileSpec] = [
            ToggleTileSpec(
                control: .bordersEnabled,
                isOn: Binding(
                    get: { settings.borders.enabled },
                    set: {
                        settings.borders.enabled = $0
                        controller?.borderSettingsChanged()
                    }
                )
            ),
            ToggleTileSpec(
                control: .workspaceBarEnabled,
                isOn: Binding(
                    get: { settings.workspaceBar.enabled },
                    set: {
                        settings.workspaceBar.enabled = $0
                        controller?.setWorkspaceBarEnabled($0)
                    }
                )
            ),
            ToggleTileSpec(
                control: .preventSleepEnabled,
                isOn: Binding(
                    get: { settings.preventSleepEnabled },
                    set: {
                        settings.preventSleepEnabled = $0
                        controller?.setPreventSleepEnabled($0)
                    }
                )
            ),
            ToggleTileSpec(
                control: .focusFollowsMouse,
                isOn: Binding(
                    get: { settings.focus.followsMouse },
                    set: {
                        settings.focus.followsMouse = $0
                        controller?.setFocusFollowsMouse($0)
                    }
                )
            ),
            ToggleTileSpec(
                control: .focusCrossesMonitorAtEdge,
                isOn: Binding(
                    get: { settings.focus.crossesMonitorAtEdge },
                    set: { settings.focus.crossesMonitorAtEdge = $0 }
                )
            ),
            ToggleTileSpec(
                control: .moveMouseToFocusedWindow,
                isOn: Binding(
                    get: { settings.focus.moveMouseToFocusedWindow },
                    set: {
                        settings.focus.moveMouseToFocusedWindow = $0
                        controller?.setMoveMouseToFocusedWindow($0)
                    }
                )
            ),
            ToggleTileSpec(
                control: .focusFollowsWindowToMonitor,
                isOn: Binding(
                    get: { settings.focus.followsWindowToMonitor },
                    set: { settings.focus.followsWindowToMonitor = $0 }
                )
            ),
            ToggleTileSpec(
                control: .moveCrossesMonitorAtEdge,
                isOn: Binding(
                    get: { settings.focus.moveCrossesMonitorAtEdge },
                    set: { settings.focus.moveCrossesMonitorAtEdge = $0 }
                )
            ),
            ToggleTileSpec(
                control: .mouseWarpEnabled,
                isOn: Binding(
                    get: { settings.pointer.enabled },
                    set: { settings.pointer.enabled = $0 }
                )
            )
        ]
        if controller?.isHiddenBarHidingAvailable == true {
            tiles.append(
                ToggleTileSpec(
                    control: .hiddenBarEnabled,
                    isOn: Binding(
                        get: { settings.hiddenBar.resolvedEnabled },
                        set: { [weak self] enabled in
                            guard let self, let controller else { return }
                            Task {
                                do {
                                    try await ShellSettingsEdits.set(
                                        enabled,
                                        key: "enabled",
                                        table: "hiddenBar",
                                        settings: settings,
                                        controller: controller
                                    )
                                } catch {
                                    infoAlertPresenter(
                                        String(localized: "Unable to Save Shell Settings"),
                                        error.localizedDescription
                                    )
                                }
                            }
                        }
                    )
                )
            )
        }
        return tiles
    }

    func openSettings(section: SettingsSection? = nil) {
        guard let controller else { return }
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: updateCoordinator,
            section: section
        )
    }

    func showHiddenIcons() {
        guard canShowHiddenIcons else { return }
        controller?.toggleHiddenBarPanel()
    }

    func openAppRules() {
        guard let controller else { return }
        AppRulesWindowController.shared.show(settings: settings, controller: controller)
    }

    func openShellFolder() {
        ShellProfiles
            .openFolder(ShellWidgetHost.shellDirectory(in: settings.settingsFileURL.deletingLastPathComponent()))
    }

    func openReportIssue() {
        openSettings(section: .reportIssue)
    }

    func checkForUpdates() {
        checkForUpdatesAction?()
    }

    func openSponsors() {
        controller?.openSponsorsWindow()
    }

    func quit(terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }) {
        scheduleOnMainRunLoop(terminate)
    }

    func toggleTraceRecording(profile: TraceCaptureProfile = .problem) {
        guard let controller else { return }
        let wasRecording = controller.isTraceCaptureActive
        Task {
            switch await controller.toggleTraceCapture(desiredState: .toggle, profile: profile) {
            case .noChange,
                 .started:
                break
            case let .stopped(artifact):
                NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
            case let .writeFailed(reason):
                infoAlertPresenter(
                    wasRecording
                        ? String(localized: "Recording could not be saved")
                        : String(localized: "Recording could not be started"),
                    reason
                )
            }
        }
    }

    func performSettingsFileAction(_ action: SettingsFileAction) {
        do {
            _ = try settingsFileActionPerformer(
                action,
                settings
            )
        } catch {
            Log.config.error("settings file action failed: \(error.localizedDescription)")
        }
    }
}

extension StatusMenuModel {
    func installCLI() {
        guard let cliManager else { return }
        let status = cliManager.exposureStatus()
        guard case let .notInstalled(linkURL, directoryOnPath) = status else {
            cliStatus = status
            return
        }

        let directoryURL = linkURL.deletingLastPathComponent()
        var message =
            String(
                localized: "OmniWM will create a symlink at \(linkURL.path) pointing to its bundled omniwmctl binary."
            )
        if !directoryOnPath {
            message +=
                String(
                    localized: "\n\n\(directoryURL.path) is not currently in your PATH, so Terminal may not find `omniwmctl` until you add that directory."
                )
        }

        guard confirmationAlertPresenter(
            String(localized: "Install CLI to PATH?"),
            message,
            String(localized: "Install"),
            String(localized: "Cancel")
        ) else {
            return
        }

        do {
            let result = try cliManager.installCLIToPATH()
            cliStatus = cliManager.exposureStatus()
            infoAlertPresenter(String(localized: "CLI Installed"), installResultMessage(result))
        } catch {
            infoAlertPresenter(String(localized: "CLI Install Failed"), error.localizedDescription)
        }
    }

    func removeCLI() {
        guard let cliManager else { return }
        guard confirmationAlertPresenter(
            String(localized: "Remove CLI from PATH?"),
            String(localized: "OmniWM will remove the symlink it created for `omniwmctl`."),
            String(localized: "Remove"),
            String(localized: "Cancel")
        ) else {
            return
        }

        do {
            let result = try cliManager.removeInstalledCLI()
            cliStatus = cliManager.exposureStatus()
            infoAlertPresenter(String(localized: "CLI Link Updated"), installResultMessage(result))
        } catch {
            infoAlertPresenter(String(localized: "CLI Removal Failed"), error.localizedDescription)
        }
    }

    func installResultMessage(_ result: AppCLIInstallResult) -> String {
        switch result {
        case let .installed(linkURL, directoryOnPath),
             let .alreadyInstalled(linkURL, directoryOnPath):
            let state = directoryOnPath
                ? String(localized: "You can now run `omniwmctl` from Terminal.")
                :
                String(
                    localized: "Add \(linkURL.deletingLastPathComponent().path) to PATH before using `omniwmctl` in Terminal."
                )
            return "\(linkURL.path)\n\n\(state)"
        case let .homebrewManaged(linkURL):
            return String(localized: "Homebrew already manages `omniwmctl` at \(linkURL.path).")
        case let .notInstalled(linkURL):
            return String(localized: "No OmniWM-managed CLI symlink was found at \(linkURL.path).")
        case let .removed(linkURL):
            return String(localized: "Removed OmniWM's CLI symlink at \(linkURL.path).")
        }
    }
}
