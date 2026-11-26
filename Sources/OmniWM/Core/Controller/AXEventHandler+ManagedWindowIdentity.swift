// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
extension AXEventHandler {
    @discardableResult
    func rekeyManagedWindowIdentity(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil,
        admissionHints: ManagedWindowAdmissionHints? = nil,
        sizeConstraints: WindowSizeConstraints? = nil,
        minimizedAttribute: Bool? = nil,
        preparedSubscriptionRetainContribution: Int = 0,
        focusedAdmissionContinuation: FocusedAdmissionRetryContinuation? = nil
    ) -> ManagedWindowIdentityRebindResult {
        assert(preparedSubscriptionRetainContribution >= 0)
        guard let controller else { return .rejected }
        guard let oldEntry = managedIdentityRebindSource(from: oldToken, to: newToken, controller: controller),
              let oldAXRef = oldEntry.axRef
        else {
            return .rejected
        }
        let rebind = ManagedWindowIdentityRebind(
            oldWindow: .init(token: oldToken, axRef: oldAXRef),
            newWindow: .init(token: newToken, axRef: axRef),
            managedReplacementMetadata: managedReplacementMetadata,
            admissionHints: admissionHints, sizeConstraints: sizeConstraints,
            minimizedAttribute: minimizedAttribute
        )
        let changesRuntimeIdentity = oldToken != newToken
            || !CFEqual(oldAXRef.element, axRef.element)
        let requiresAcknowledgement = changesRuntimeIdentity
            && (controller.hasStartedServices || oldToken.pid != newToken.pid)
        if requiresAcknowledgement {
            let scheduled = scheduleManagedWindowIdentityRebind(
                rebind: rebind,
                preparedSubscriptionRetainContribution: preparedSubscriptionRetainContribution,
                focusedAdmissionContinuation: focusedAdmissionContinuation
            )
            return scheduled ? .pending : .rejected
        }
        guard let rekeyedEntry = commitManagedWindowIdentityRebind(
            from: oldToken,
            to: newToken,
            axRef: axRef,
            managedReplacementMetadata: managedReplacementMetadata
        ) else { return .rejected }
        if let sizeConstraints {
            controller.workspaceManager.setCachedConstraints(sizeConstraints, for: newToken)
        }

        if changesRuntimeIdentity {
            applyManagedWindowIdentityRebindRuntimeState(
                rebind: rebind,
                acknowledgement: nil, controller: controller
            )
            bindCurrentManagedWindows(afterRebinding: rebind.oldWindow, to: rebind.newWindow)
        }
        let entry = controller.workspaceManager.entry(for: newToken) ?? rekeyedEntry
        finishManagedWindowIdentityRebind(
            rebind: rebind,
            entry: entry,
            windowId: windowId,
            directPreparedSubscriptionRetainCount: preparedSubscriptionRetainContribution
        )
        return .committed(entry)
    }

    private func managedIdentityRebindSource(
        from oldToken: WindowToken, to newToken: WindowToken, controller: WMController
    ) -> WindowState? {
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken),
              oldToken == newToken || controller.workspaceManager.entry(for: newToken) == nil
        else {
            return nil
        }
        if let collision = controller.workspaceManager.entry(forWindowId: newToken.windowId),
           collision.token != oldToken
        {
            return nil
        }
        return oldEntry
    }

    func bindCurrentManagedWindows(
        afterRebinding oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity
    ) {
        guard let controller else { return }
        controller.axManager.bindManagedWindows(
            controller.workspaceManager.entries(forPid: oldWindow.token.pid)
        )
        if oldWindow.token.pid != newWindow.token.pid {
            controller.axManager.bindManagedWindows(
                controller.workspaceManager.entries(forPid: newWindow.token.pid)
            )
        }
    }

    func retryManagedWindowIdentityRebind(
        rebind: ManagedWindowIdentityRebind, execution: AdmissionRetryExecution
    ) {
        let oldWindow = rebind.oldWindow
        let newWindow = rebind.newWindow
        let windowId = execution.windowId
        let retryGeneration = execution.generation
        let executionOwner = execution.executionOwner
        guard let controller else { return }
        guard var state = admissionRetryStateByWindowId[windowId],
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner)
        else {
            return
        }
        if state.identityRebindTargetDestroyed {
            cancelCreatedWindowRetry(windowId: windowId)
            discardDeferredReplacementProtection(windowId: windowId)
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }
        if controller.hasStartedServices,
           !isManagedWindowIdentityRebindTargetAlive(pid: newWindow.token.pid)
        {
            retireStaleManagedWindowIdentityRebind(
                windowId: windowId,
                retryGeneration: retryGeneration,
                executionOwner: executionOwner
            )
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }
        state.task = nil
        state.executionPhase = .waiting
        admissionRetryStateByWindowId[windowId] = state
        _ = scheduleManagedWindowIdentityRebind(rebind: rebind, preparedSubscriptionRetainContribution: 0)
    }

    @discardableResult
    private func scheduleManagedWindowIdentityRebind(
        rebind: ManagedWindowIdentityRebind,
        preparedSubscriptionRetainContribution: Int,
        focusedAdmissionContinuation: FocusedAdmissionRetryContinuation? = nil
    ) -> Bool {
        let oldWindow = rebind.oldWindow
        let newWindow = rebind.newWindow
        let managedReplacementMetadata = rebind.managedReplacementMetadata
        let admissionHints = rebind.admissionHints
        let sizeConstraints = rebind.sizeConstraints
        guard let windowId = UInt32(exactly: newWindow.token.windowId) else { return false }
        let scheduled = scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: newWindow.token,
            axRef: newWindow.axRef,
            reason: .factsDeferred,
            trigger: .identityRebind(
                oldWindow: oldWindow,
                newWindow: newWindow,
                managedReplacementMetadata: managedReplacementMetadata,
                admissionHints: admissionHints,
                sizeConstraints: sizeConstraints,
                minimizedAttribute: rebind.minimizedAttribute
            ),
            preparedSubscriptionRetainContribution: preparedSubscriptionRetainContribution
        )
        if scheduled, let focusedAdmissionContinuation {
            _ = retainFocusedAdmissionContinuation(
                focusedAdmissionContinuation,
                windowId: windowId
            )
        }
        return scheduled
    }
}
