// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        if shouldIgnoreScrollingFrameChange(windowId, controller: controller) { return }
        guard case let .exact(windowServerToken, windowInfo) = resolveWindowServerIdentity(windowId) else { return }
        if retryAdmissionForFrameChange(windowId: windowId, windowServerToken: windowServerToken) { return }
        guard let entry = controller.workspaceManager.entry(for: windowServerToken) else { return }
        if entry.mode == .tiling,
           controller.mouseEventHandler.handleNativeTitleBarDragFrameChanged(for: entry)
        {
            return
        }
        if repairParkedWindowFrame(entry, windowInfo: windowInfo, controller: controller) { return }
        let focusedObservedFrame = observedFrameForFocusedFrameChange(
            windowId: windowId,
            windowServerToken: windowServerToken,
            resolvedToken: windowServerToken
        )

        guard isWindowDisplayable(token: windowServerToken) else { return }

        applyObservedFrameChange(entry, focusedObservedFrame: focusedObservedFrame, controller: controller)
    }

    private func retryAdmissionForFrameChange(windowId: UInt32, windowServerToken: WindowToken) -> Bool {
        if let retryState = admissionRetryStateByWindowId[windowId] {
            guard retryState.expectedToken.map({ $0 == windowServerToken }) ?? true else { return true }
            if retryAdmissionAfterFrameChangeRequiresEarlyReturn(windowId: windowId) { return true }
        }
        return false
    }

    private func repairParkedWindowFrame(
        _ entry: WindowState,
        windowInfo: WindowServerInfo,
        controller: WMController
    ) -> Bool {
        guard let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) else { return false }
        let observedFrame = ScreenCoordinateSpace.toAppKit(rect: windowInfo.frame)
        if hiddenState.workspaceInactive {
            controller.layoutRefreshController.repairWorkspaceInactivePark(for: entry, observedFrame: observedFrame)
        } else if let side = hiddenState.offscreenSide {
            controller.layoutRefreshController.repairLayoutTransientPark(
                for: entry,
                side: side,
                observedFrame: observedFrame
            )
        }
        return true
    }

    private func applyObservedFrameChange(
        _ entry: WindowState,
        focusedObservedFrame: CGRect?,
        controller: WMController
    ) {
        if entry.mode == .floating {
            if let frame = focusedObservedFrame ?? observedFrame(for: entry),
               !shouldSuppressFrameChangedRelayout(for: entry, observedFrame: frame)
            {
                updateFloatingWindowGeometryAndMonitorMembership(
                    entry: entry,
                    frame: frame
                )
            }
            return
        }

        if controller.isInteractiveGestureActive {
            return
        }

        if controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) {
            return
        }

        if shouldSuppressFrameChangedRelayout(
            for: entry,
            observedFrame: focusedObservedFrame
        ) {
            return
        }

        let suppressionObservedFrame = focusedObservedFrame
            ?? (controller.axManager.lastAppliedFrame(for: entry.windowId) == nil ? nil : observedFrame(for: entry))
        if suppressionObservedFrame != focusedObservedFrame,
           shouldSuppressFrameChangedRelayout(
               for: entry,
               observedFrame: suppressionObservedFrame
           )
        {
            return
        }

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func shouldSuppressFrameChangedRelayout(
        for entry: WindowState,
        observedFrame: CGRect?
    ) -> Bool {
        guard let controller else { return false }
        return controller.axManager.shouldSuppressFrameChangeRelayout(
            for: entry.windowId,
            observedFrame: observedFrame
        )
    }

    private func observedFrameForFocusedFrameChange(
        windowId: UInt32,
        windowServerToken: WindowToken?,
        resolvedToken: WindowToken?
    ) -> CGRect? {
        guard let controller else { return nil }
        guard let target = controller.workspaceManager.renderableFocusToken,
              let entry = controller.workspaceManager.entry(for: target)
        else { return nil }

        if let windowServerToken {
            guard windowServerToken == target else { return nil }
        } else {
            guard resolvedToken == target,
                  entry.mode == .floating
            else { return nil }
            if needsFocusedAXConfirmationForUnresolvedFrameChange(entry),
               focusedWindowToken(for: target.pid) != target
            {
                return nil
            }
        }

        guard controller.axManager.pendingFrameWrite(for: entry.windowId) == nil else { return nil }
        guard let frame = observedFrame(for: entry) else { return nil }
        return frame
    }

    private func needsFocusedAXConfirmationForUnresolvedFrameChange(_ entry: WindowState) -> Bool {
        guard let controller else { return true }
        return entry.layoutReason == .nativeFullscreen
            || controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
    }

    func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        AXWindowService.framePreferFast(axRef)
            ?? (try? AXWindowService.frame(axRef))
    }

    func observedFrame(for entry: WindowState) -> CGRect? {
        observedFrame(for: entry.axRef)
    }

    private func shouldIgnoreScrollingFrameChange(_ windowId: UInt32, controller: WMController) -> Bool {
        if let trackedEntry = controller.workspaceManager.entry(forWindowId: Int(windowId)),
           trackedEntry.mode == .tiling,
           trackedEntry.hiddenState == nil,
           controller.niriLayoutHandler.hasScrollAnimation(for: trackedEntry.workspaceId)
        {
            return true
        }
        return false
    }
}
