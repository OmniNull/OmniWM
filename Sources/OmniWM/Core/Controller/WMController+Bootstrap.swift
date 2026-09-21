// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func configureInputRouting() {
        axManager.isWindowParked = { [workspaceManager] windowId in
            workspaceManager.entry(forWindowId: windowId)?.hiddenState != nil
        }
        intentLedger.seqProvider = { [eventIntake] in eventIntake.lastSeq }
        intentLedger.deadlineWheel = deadlineWheel
        focusPolicyEngine.intentLedger = intentLedger
        focusPolicyEngine.deadlineWheel = deadlineWheel
        hotkeys.isOverviewMouseButtonCaptured = { [weak self] button in
            self?.mouseEventHandler.state.capturedOverviewButton == button
        }
        hotkeys.onCommand = { [weak self] invocation in
            guard let self else { return }
            if !eventIntake.enqueue(.hotkeyInvocation(invocation)) {
                _ = commandHandler.handleHotkeyInvocation(invocation)
            }
        }
    }

    func configureSurfaceCallbacks() {
        traceCaptureCoordinator.onStateChange = { [weak self] in
            self?.statusBarController?.handleTraceCaptureStateChange()
        }
        tabRailManager.onSelect = { [weak self] info, visualIndex, token in
            guard let self else { return }
            switch info.owner {
            case .niriColumn:
                layoutRefreshController.selectTabInNiri(
                    info: info,
                    visualIndex: visualIndex,
                    expectedToken: token
                )
            case .dwindleTile:
                dwindleLayoutHandler.selectGroupMember(
                    info: info,
                    visualIndex: visualIndex,
                    expectedToken: token
                )
            }
        }
    }

    func configureWorldCallbacks() {
        workspaceManager.onSessionStateChanged = { [weak self] surfaceScope in
            self?.handleSessionStateChanged(surfaceScope: surfaceScope)
        }
        workspaceManager.onRuntimeInvalidation = { [weak self] workspaceId, domains, surfaceScope in
            self?.handleRuntimeInvalidation(
                workspaceId: workspaceId,
                domains: domains,
                surfaceScope: surfaceScope
            )
        }
        workspaceManager.onWindowPresenceObserved = { [weak self] handle in
            self?.layoutRefreshController.recordWindowPresence(handle)
            self?.axEventHandler.probeUnresolvedNativeFocus(after: handle.token)
        }
        workspaceManager.onWindowRemoved = { [weak self] entry in
            self?.windowActionHandlerStorage?.handleOverviewWindowRemoved(entry)
        }
        workspaceManager.onDeferredWorkspaceMonitorMove = { [weak self] outcome in
            self?.layoutRefreshController.commitWorkspaceMonitorTransition(outcome)
        }
        workspaceManager.onAnimationMotionsWillBeRemoved = { [weak self] workspaceIds in
            guard let self else { return }
            for workspaceId in workspaceIds {
                self.niriLayoutHandler.terminateViewportGesture(
                    for: workspaceId,
                    disposition: .settleLiveOffset
                )
                let displayIds = self.niriLayoutHandler.scrollAnimationByDisplay.compactMap { displayId, registered in
                    registered == workspaceId ? displayId : nil
                }
                for displayId in displayIds {
                    self.layoutRefreshController.stopScrollAnimation(for: displayId)
                }
                for displayId in self.dwindleLayoutHandler.animationDisplayIds(for: workspaceId) {
                    self.layoutRefreshController.stopDwindleAnimation(for: displayId)
                }
            }
        }
    }

    func configureFocusAndMenuCallbacks() {
        focusPolicyEngine.onLeaseChanged = { [weak self] lease in
            self?.workspaceManager.recordReconcileEvent(
                .focusLeaseChanged(
                    lease: lease,
                    source: .focusPolicy
                )
            )
        }
        MenuAnywhereController.shared.onMenuTrackingChanged = { [weak self] isTracking in
            guard let self else { return }
            if isTracking {
                self.focusPolicyEngine.beginLease(
                    owner: .nativeMenu,
                    reason: "menu_anywhere",
                    suppressesFocusFollowsMouse: true,
                    duration: nil
                )
            } else {
                self.focusPolicyEngine.endLease(owner: .nativeMenu)
            }
        }
        self.hiddenBarController.onCursorWarp = { [weak self] point in
            self?.mouseWarpHandler.noteProgrammaticCursorMove(to: point)
        }
        self.hiddenBarController.statusItems.fallbackPlacementsProvider = { [weak self] in
            self?.hiddenBarFallbackIconPlacements() ?? []
        }
        self.workspaceBarManager.onPrimaryBarFramesChanged = { [weak self] in
            self?.hiddenBarController.statusItems.syncFallbackIcon()
        }
    }

    func setHotkeyRecordingActive(_ active: Bool) {
        hotkeys.setCommandHotkeysSuspended(active)
        refreshHotkeyFailureSnapshots()
    }

    func presentSeparateSpacesAlert() {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Enable “Displays have separate Spaces”"
            alert.informativeText = "OmniWM requires the macOS setting “Displays have separate Spaces.” "
                + "Turn it on in System Settings > Desktop & Dock > Mission Control, then log out and back in. "
                + "Window management stays paused until it is enabled."
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        }
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding], force: Bool = false) {
        hotkeys.updateBindings(
            bindings,
            systemHyperTrigger: settings.systemHyperTrigger,
            force: force
        )
        refreshHotkeyFailureSnapshots()
        refreshDiagnosticsIssues()
    }
}
