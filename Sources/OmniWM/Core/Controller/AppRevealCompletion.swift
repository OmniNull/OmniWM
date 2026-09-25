// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
struct AppRevealCompletion {
    let controller: WMController
    let actions: AppRevealActions
    let intentId: IntentID
    let payload: AppRevealFocusPayload
    let focusOrigin: ManagedFocusOrigin

    func perform() -> Bool {
        guard validateFocus(), drainPendingApps(), validateCoordinatedApps(), let handle = validatedHandle() else {
            return false
        }
        guard controller.intentLedger.confirmAppRevealFocus(intentId: intentId) != nil else {
            record(.rejected, reason: .intentNotPending)
            return false
        }

        return completeDestination(handle: handle)
    }

    private func validateFocus() -> Bool {
        guard controller.intentLedger.newestFocusIntentId() == payload.focusIntentWatermark else {
            return reject(.newerFocusIntent)
        }
        guard AppRevealActions.appRevealFocusFingerprint(controller: controller) == payload.focusFingerprint else {
            return reject(.focusStateChanged)
        }
        return true
    }

    private func drainPendingApps() -> Bool {
        for pid in payload.pendingAppPIDs {
            guard let expectedGeneration = payload.coordinatedAppGenerations[pid] else {
                return reject(.intentNotPending)
            }
            guard !controller.workspaceManager.isAppHidden(pid: pid) else {
                return reject(.stillHidden)
            }
            let generation = controller.workspaceManager.appVisibilityGeneration(for: pid)
            guard generation == expectedGeneration &+ 1 else {
                return reject(.visibilityGenerationChanged)
            }
            guard controller.intentLedger.drainAppRevealFocus(
                intentId: intentId,
                pid: pid,
                appVisibilityGeneration: generation
            ) != nil else {
                return reject(.intentNotPending)
            }
        }
        return true
    }

    private func validateCoordinatedApps() -> Bool {
        for (pid, expectedGeneration) in payload.coordinatedAppGenerations {
            guard !controller.workspaceManager.isAppHidden(pid: pid) else {
                return reject(.stillHidden)
            }
            guard controller.workspaceManager.appVisibilityGeneration(for: pid) == expectedGeneration &+ 1 else {
                return reject(.visibilityGenerationChanged)
            }
        }
        return true
    }

    private func validatedHandle() -> WindowHandle? {
        guard !controller.workspaceManager.isAppHidden(pid: payload.token.pid) else {
            _ = reject(.stillHidden)
            return nil
        }
        guard let handle = controller.workspaceManager.handle(for: payload.token) else {
            _ = reject(.handleMissing)
            return nil
        }
        guard ObjectIdentifier(handle) == payload.handleIdentity else {
            _ = reject(.handleIdentityChanged)
            return nil
        }
        guard let entry = controller.workspaceManager.entry(for: handle) else {
            _ = reject(.entryMissing)
            return nil
        }
        guard entry.pid == payload.token.pid else {
            _ = reject(.pidChanged)
            return nil
        }
        guard entry.workspaceId == payload.workspaceId else {
            _ = reject(.workspaceChanged)
            return nil
        }
        guard entry.layoutReason == .standard
            || controller.isManagedWindowSuspendedForNativeFullscreen(entry.token)
        else {
            _ = reject(.ineligibleLayout)
            return nil
        }
        return handle
    }

    private func completeDestination(handle: WindowHandle) -> Bool {
        switch payload.destination {
        case .window:
            if let originalToken = AppRevealActions.suspendedNativeFullscreenOriginalToken(
                for: handle.id,
                controller: controller
            ) {
                controller.activateNativeFullscreenPlaceholder(originalToken)
                return finish(true)
            }
            return finish(controller.windowActionHandler.navigateToWindowInternal(
                token: handle.id,
                workspaceId: payload.workspaceId,
                focusOrigin: focusOrigin
            ))
        case let .scratchpad(index, monitorId):
            return finish(controller.activateScratchpadFromBar(index: index, on: monitorId) == .executed)
        case let .scratchpadWindow(index, monitorId):
            return finish(
                actions.performSelectedScratchpadReveal(
                    token: handle.id,
                    workspaceId: payload.workspaceId,
                    index: index,
                    monitorId: monitorId,
                    focusOrigin: focusOrigin
                )
            )
        }
    }

    private func record(
        _ outcome: AppVisibilityTrace.Outcome,
        reason: AppVisibilityTrace.Reason? = nil
    ) {
        AppVisibilityTrace.record(
            .reveal,
            pid: payload.token.pid,
            outcome: outcome,
            intentId: intentId,
            windowId: payload.token.windowId,
            workspaceId: payload.workspaceId,
            generation: controller.workspaceManager.appVisibilityGeneration(for: payload.token.pid),
            destination: payload.destination.traceDestination,
            reason: reason
        )
    }

    private func reject(_ reason: AppVisibilityTrace.Reason) -> Bool {
        controller.intentLedger.cancelAppRevealFocus(intentId: intentId)
        record(.rejected, reason: reason)
        return false
    }

    private func finish(_ didComplete: Bool) -> Bool {
        record(
            didComplete ? .completed : .failed,
            reason: didComplete ? nil : .navigationFailed
        )
        return didComplete
    }
}
