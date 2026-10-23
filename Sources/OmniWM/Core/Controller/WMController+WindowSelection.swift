// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func isManagedWindowDisplayable(_ token: WindowToken) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        return isManagedWindowDisplayable(entry)
    }

    func isManagedWindowDisplayable(_ entry: WindowState) -> Bool {
        !workspaceManager.isWindowSuppressedByMacOS(entry)
            && entry.layoutReason == .standard
            && entry.hiddenState == nil
    }

    func isManagedWindowSuppressedByMacOS(_ token: WindowToken) -> Bool {
        workspaceManager.isWindowSuppressedByMacOS(token)
    }

    func isManagedWindowSuspendedForNativeFullscreen(_ token: WindowToken) -> Bool {
        workspaceManager.isNativeFullscreenSuspended(token)
    }

    func monitorForInteraction() -> Monitor? {
        placementResolver.monitorForInteraction()
    }

    func interactionWorkspaceProjection() -> (monitor: Monitor?, workspace: WorkspaceDescriptor?) {
        let monitor = monitorForInteraction()
        return (monitor, monitor.flatMap { workspaceManager.activeWorkspace(on: $0.id) })
    }

    func activeWorkspace() -> WorkspaceDescriptor? {
        guard let monitor = monitorForInteraction() else { return nil }
        return workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
    }

    func focusedOrFrontmostWindowTokenForAutomation(
        preferFrontmostWhenExternalOrOwnedFocusActive: Bool = false
    ) -> WindowToken? {
        let selectedManagedToken = workspaceManager.selectedManagedToken
        let frontmostPid = commandHandler.frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostToken = commandHandler.frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { axEventHandler.focusedWindowToken(for: $0) }
        if preferFrontmostWhenExternalOrOwnedFocusActive {
            switch workspaceManager.nativeFocusOwner {
            case .external,
                 .ownedSurface:
                return frontmostToken ?? selectedManagedToken
            case .managed,
                 .none:
                break
            }
        }
        return selectedManagedToken ?? frontmostToken
    }

    func captureQuakeTerminalRestoreTarget() -> QuakeTerminalRestoreTarget? {
        guard let token = workspaceManager.renderableFocusToken
            ?? focusedOrFrontmostWindowTokenForAutomation(preferFrontmostWhenExternalOrOwnedFocusActive: true)
        else {
            return nil
        }

        if workspaceManager.entry(for: token) != nil {
            return .managed(token)
        }

        guard let axRef = AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
        else {
            return nil
        }

        return .external(
            KeyboardFocusTarget(
                token: token,
                axRef: axRef,
                workspaceId: nil,
                isManaged: false
            )
        )
    }

    func focusedManagedWindowScreenForQuakeTerminal() -> NSScreen? {
        guard let token = focusedOrFrontmostWindowTokenForAutomation(
                  preferFrontmostWhenExternalOrOwnedFocusActive: true
              ),
              let entry = workspaceManager.entry(for: token)
        else {
            return nil
        }

        if let monitorId = entry.observedState.monitorId
            ?? entry.desiredState.monitorId
            ?? workspaceManager.monitorId(for: entry.workspaceId),
           let screen = screen(for: monitorId)
        {
            return screen
        }

        if let frame = entry.observedState.frame
            ?? entry.desiredState.floatingFrame
            ?? entry.floatingState?.lastFrame,
           let monitor = frame.center.monitorApproximation(in: workspaceManager.monitors)
        {
            return screen(for: monitor.id)
        }

        return nil
    }

    func focusedManagedTokenForCommand() -> WindowToken? {
        let token = focusedOrFrontmostWindowTokenForAutomation()
        guard let token,
              workspaceManager.entry(for: token) != nil,
              !workspaceManager.isWindowSuppressedByMacOS(token)
        else {
            return nil
        }
        return token
    }

    func runningAppsWithWindows() -> [RunningAppInfo] {
        windowActionHandler.runningAppsWithWindows()
    }

    func runningAppsForRulePicker() -> [RunningAppInfo] {
        RunningAppInventory.rulePickerCandidates(trackedApplications: runningAppsWithWindows())
    }
}
