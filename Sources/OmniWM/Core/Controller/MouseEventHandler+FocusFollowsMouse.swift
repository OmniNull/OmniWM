// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var hasLatestFocusFollowsMouseSample: Bool {
        state.latestFocusFollowsMouseSample != nil
    }

    private var externalFocusBlocksFocusFollowsMouse: Bool {
        guard let workspaceManager = controller?.workspaceManager else { return false }
        switch workspaceManager.nativeFocusOwner {
        case .ownedSurface:
            return true
        case .external:
            return workspaceManager.activeNativeFullscreenFocusOwnerToken == nil
        case .managed,
             .none:
            return false
        }
    }

    private enum FocusFollowsMouseTarget {
        case niri(workspaceId: WorkspaceDescriptor.ID, window: NiriWindow)
        case dwindle(workspaceId: WorkspaceDescriptor.ID, token: WindowToken)
        case floating(token: WindowToken)
    }

    func handleMouseMovedFromTap(
        at location: CGPoint,
        modifiersRawValue: UInt64,
        windowIdUnderPointer: Int?
    ) {
        guard let controller else { return }
        guard controller.isEnabled else {
            cancelActiveMouseInteraction()
            return
        }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return
        }

        controller.workspaceBarManager.handleAutoHideMouseMoved(at: location)

        guard controller.focusFollowsMouseEnabled || state.isResizing else {
            resetHoveredEdgesIfNeeded()
            return
        }

        if shouldBlockOwnWindowInput(at: location) {
            resetHoveredEdgesIfNeeded()
            return
        }

        if controller.focusFollowsMouseEnabled,
           !controller.settings.focus.lockModifier.isHeld(inRawFlags: modifiersRawValue),
           shouldHandleFocusFollowsMouse(at: location)
        {
            handleFocusFollowsMouse(at: location, windowIdUnderPointer: windowIdUnderPointer)
        }

        guard !state.isResizing else { return }
        resetHoveredEdgesIfNeeded()
    }

    private func shouldHandleFocusFollowsMouse(at location: CGPoint) -> Bool {
        guard !state.isMoving, !state.isResizing, !isTrackpadSwipeSessionActive else { return false }
        guard let controller else { return false }
        guard let workspaceId = workspaceIdForPointer(at: location) else {
            return true
        }
        return !controller.niriLayoutHandler.hasScrollAnimation(for: workspaceId)
    }

    func workspaceIdForPointer(at location: CGPoint) -> WorkspaceDescriptor.ID? {
        guard let controller else { return nil }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors) else {
            return controller.activeWorkspace()?.id
        }
        return controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
    }

    func resolvedNiriOrientation(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> Monitor.Orientation {
        controller?.settings.monitors.effectiveOrientation(for: monitor)
            ?? engine.monitorForWorkspace(workspaceId)?.orientation
            ?? monitor.autoOrientation
    }

    func shouldBlockOwnWindowInput(at location: CGPoint) -> Bool {
        guard let controller else { return false }
        return controller.isPointInOwnWindow(location)
    }

    private func handleFocusFollowsMouse(at location: CGPoint, windowIdUnderPointer: Int?) {
        guard let controller else { return }
        guard !externalFocusBlocksFocusFollowsMouse,
              !hasPendingNativeFullscreenTransition(at: location),
              !isPointerDisplayShowingFullscreenSpace(at: location)
        else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(state.lastFocusFollowsMouseTime) >= state.focusFollowsMouseDebounce else {
            return
        }

        guard let target = resolveFocusFollowsMouseTarget(
            at: location,
            windowIdUnderPointer: windowIdUnderPointer
        ) else { return }
        let token = focusFollowsMouseToken(for: target)

        guard token != controller.workspaceManager.selectedManagedToken else { return }
        controller.focusPolicyEngine.performIfFocusFollowsMouseAllowed {
            state.lastFocusFollowsMouseTime = now
            activateFocusFollowsMouseTarget(target)
        }
    }

    private func hasPendingNativeFullscreenTransition(at location: CGPoint) -> Bool {
        guard let workspaceManager = controller?.workspaceManager else { return false }
        guard let monitor = location.monitorApproximation(in: workspaceManager.monitors),
              let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return workspaceManager.hasPendingNativeFullscreenTransition
        }
        return workspaceManager.hasPendingNativeFullscreenTransition(in: workspace.id)
    }

    private func isPointerDisplayShowingFullscreenSpace(at location: CGPoint) -> Bool {
        guard let controller else { return false }
        let workspaceManager = controller.workspaceManager
        guard workspaceManager.hasNativeFullscreenLifecycleContext else { return false }
        let topology = workspaceManager.spaceTopology
        guard topology.isPopulated,
              let monitor = location.monitorApproximation(in: workspaceManager.monitors)
        else { return true }
        return topology.isDisplayShowingFullscreenSpace(on: monitor) ?? true
    }

    private func resolveFocusFollowsMouseTarget(
        at location: CGPoint,
        windowIdUnderPointer: Int?
    ) -> FocusFollowsMouseTarget? {
        guard let controller else { return nil }

        if let windowIdUnderPointer, windowIdUnderPointer != 0 {
            return routedFocusFollowsMouseTarget(windowIdUnderPointer, controller: controller)
        }

        guard let workspaceId = workspaceIdForPointer(at: location),
              let workspace = controller.workspaceManager.descriptor(for: workspaceId)
        else {
            return nil
        }

        switch controller.settings.workspaces.layoutType(for: workspace.name) {
        case .niri,
             .defaultLayout:
            guard let engine = controller.niriEngine,
                  let window = engine.hitTestFocusableWindow(point: location, in: workspaceId)
            else {
                return nil
            }
            return .niri(workspaceId: workspaceId, window: window)

        case .dwindle:
            guard let engine = controller.dwindleEngine else { return nil }
            let presentationTime = controller.animationClock.now()
            guard let token = engine.hitTestFocusableWindow(
                point: location,
                in: workspaceId,
                at: presentationTime
            ) else {
                return nil
            }
            return .dwindle(workspaceId: workspaceId, token: token)
        }
    }

    private func routedFocusFollowsMouseTarget(
        _ windowIdUnderPointer: Int, controller: WMController
    ) -> FocusFollowsMouseTarget? {
        guard windowIdUnderPointer > 0,
              let entry = controller.workspaceManager.entry(
                  forWindowId: windowIdUnderPointer,
                  inVisibleWorkspaces: true
              ),
              controller.isManagedWindowDisplayable(entry.token),
              let workspace = controller.workspaceManager.descriptor(for: entry.workspaceId)
        else {
            return nil
        }

        switch entry.mode {
        case .floating:
            return .floating(token: entry.token)

        case .tiling:
            switch controller.settings.workspaces.layoutType(for: workspace.name) {
            case .niri,
                 .defaultLayout:
                guard let window = controller.niriEngine?.findNode(
                    for: entry.token,
                    in: entry.workspaceId
                ), controller.niriEngine?.isProjectedFocusableWindow(
                    window,
                    in: entry.workspaceId
                ) == true else {
                    return nil
                }
                return .niri(workspaceId: entry.workspaceId, window: window)

            case .dwindle:
                guard controller.dwindleEngine?.findNode(
                    for: entry.token,
                    in: entry.workspaceId
                ) != nil else {
                    return nil
                }
                return .dwindle(workspaceId: entry.workspaceId, token: entry.token)
            }
        }
    }

    private func focusFollowsMouseToken(for target: FocusFollowsMouseTarget) -> WindowToken {
        switch target {
        case let .niri(_, window):
            window.token
        case let .dwindle(_, token):
            token
        case let .floating(token):
            token
        }
    }

    func latestFocusFollowsMouseToken() -> WindowToken? {
        guard let controller,
              let sample = state.latestFocusFollowsMouseSample,
              !isInputSuppressed,
              controller.isEnabled,
              controller.focusFollowsMouseEnabled,
              !controller.isOverviewOpen(),
              !shouldBlockOwnWindowInput(at: sample.location),
              !controller.settings.focus.lockModifier.isHeld(inRawFlags: sample.modifiersRawValue),
              !state.isMoving,
              !state.isResizing,
              !isTrackpadSwipeSessionActive,
              controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange,
              !externalFocusBlocksFocusFollowsMouse,
              !hasPendingNativeFullscreenTransition(at: sample.location),
              !isPointerDisplayShowingFullscreenSpace(at: sample.location),
              let target = resolveFocusFollowsMouseTarget(
                  at: sample.location,
                  windowIdUnderPointer: sample.windowIdUnderPointer
              )
        else {
            return nil
        }
        return focusFollowsMouseToken(for: target)
    }

    private func activateFocusFollowsMouseTarget(_ target: FocusFollowsMouseTarget) {
        guard let controller else { return }

        switch target {
        case let .niri(workspaceId, window):
            controller.niriLayoutHandler.activatePointerHoveredWindow(
                window,
                in: workspaceId
            )
        case let .dwindle(workspaceId, token):
            controller.dwindleLayoutHandler.activateWindow(
                token,
                in: workspaceId,
                origin: .focusFollowsMouse,
                layoutRefresh: false
            )
        case let .floating(token):
            controller.focusWindow(token, origin: .focusFollowsMouse)
        }
    }
}
