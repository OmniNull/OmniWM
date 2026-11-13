// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func configureInputRouting() {
        axManager.isWindowParked = { [workspaceManager] windowId in
            workspaceManager.withEntry(forWindowId: windowId) { $0.hiddenState != nil } == true
        }
        axManager.onParkFrameApplyFailed = { [weak self] result in
            self?.layoutRefreshController.repairLayoutTransientPark(after: result)
        }
        intentLedger.seqProvider = { [eventIntake] in eventIntake.lastSeq }
        intentLedger.deadlineWheel = deadlineWheel
        focusPolicyEngine.intentLedger = intentLedger
        focusPolicyEngine.deadlineWheel = deadlineWheel
        hotkeys.isMouseButtonCaptured = { [weak self] button in
            self?.mouseEventHandler.state.capturedOtherMouseButton == button
        }
        hotkeys.onCommand = { [weak self] invocation in
            guard let self else { return }
            if !eventIntake.enqueue(.hotkeyInvocation(invocation)) {
                _ = commandHandler.handleHotkeyInvocation(invocation)
            }
        }
        hotkeys.onKeyboardModeChange = { [weak self] kind in
            self?.keyboardModeDidChange(kind)
        }
        hotkeys.isKeyboardModeArmingBlocked = { [weak self] in
            guard let self else { return true }
            return secureInputMonitor.isSecureInputActive || isLockScreenActive
        }
        hotkeys.onWindowSwitcherAction = { [weak self] action, generation in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .begin = action {
                    guard settings.windowSwitcher.enabled else { return }
                    windowSwitcherController.handle(action, generation: generation)
                } else {
                    windowSwitcherControllerStorage?.handle(action, generation: generation)
                }
            }
        }
        settings.onDynamicHotkeysChanged = { [weak self] in
            guard let self else { return }
            updateHotkeyBindings(settings.hotkeyBindings)
        }
    }

    func configureMotionCallbacks() {
        settings.gestures.onWorkspaceSwipeEnabledChange = { [weak self] in
            self?.layoutRefreshController.workspaceSwipe.syncAvailability()
        }
        settings.onSlideWorkspaceSwitchesChanged = { [weak self] in
            self?.layoutRefreshController.workspaceSwipe.syncAvailability()
        }
        motionPolicy.onAnimationsEnabledChange = { [weak self] in
            self?.layoutRefreshController.workspaceSwipe.syncAvailability()
            self?.workspaceBarManager.refreshShellShaders()
        }
    }

    func configureSurfaceCallbacks() {
        configureAppTheming()
        traceCaptureCoordinator.onStateChange = { [weak self] in
            self?.statusBarController?.handleTraceCaptureStateChange()
        }
        secureInputIndicator.openHotkeysSettings = { [weak self] in
            self?.statusBarController?.openSettings(section: .hotkeys)
        }
        tabRailManager.ringOrderedAbove = { [weak self] in self?.surfaceReconciler.ringWindowId(orderedAbove: $0) }
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
        workspaceManager.onHostedFamilyWorkspaceChanged = { [weak self] token, workspace in
            self?.retargetHostedChildFocus(afterMoving: token, to: workspace)
        }
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
            self?.windowMarkRegistry.retire(entry.token)
            self?.windowActionHandlerStorage?.handleOverviewWindowRemoved(entry)
            self?.layoutRefreshController.workspaceSwipe.windowRemoved(entry.token)
            self?.niriEdgePictures.remove(entry.token)
            PreviewCaptureCoordinator.shared.windowRemoved(entry.token)
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
            self?.surfaceReconciler.reapplyParkingEdgeMasks()
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
        ownedWindowRegistry.onWindowWillClose = { [weak self] in
            self?.releaseStaleOwnedSurfaceFocus()
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
            alert.messageText = String(localized: "Enable “Displays have separate Spaces”")
            alert.informativeText = String(localized:
                "OmniWM requires the macOS setting “Displays have separate Spaces.” Turn it on in System Settings > Desktop & Dock > Mission Control, then log out and back in. Window management stays paused until it is enabled."
            )
            alert.addButton(withTitle: String(localized: "OK"))
            _ = alert.runModal()
        }
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding], force: Bool = false) {
        let enabledBindings = bindings.filter { settings.isCommandFeatureEnabled($0.command) }
        hotkeys.updateBindings(
            enabledBindings,
            systemHyperTrigger: settings.systemHyperTrigger,
            force: force
        )
        refreshHotkeyFailureSnapshots()
        refreshDiagnosticsIssues()
        refreshKeyboardModeIndicator()
    }
}
