// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
extension AXEventHandler {
    func isCurrentManagedWindowIdentityRebind(
        rebind: ManagedWindowIdentityRebind,
        execution: AdmissionRetryExecution,
        acknowledgement: AXManagedWindowRebindAcknowledgement?
    ) -> Bool {
        let oldWindow = rebind.oldWindow
        let newWindow = rebind.newWindow
        let windowId = execution.windowId
        let retryGeneration = execution.generation
        let executionOwner = execution.executionOwner
        guard let controller,
              controller.hasStartedServices,
              !Task.isCancelled,
              newWindow.token.windowId == Int(windowId),
              let state = admissionRetryStateByWindowId[windowId],
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner),
              !state.identityRebindTargetDestroyed,
              case let .identityRebind(retryOld, retryNew, _, _, _) = state.trigger,
              retryOld.token == oldWindow.token,
              retryNew.token == newWindow.token,
              CFEqual(retryOld.axRef.element, oldWindow.axRef.element),
              CFEqual(retryNew.axRef.element, newWindow.axRef.element),
              let oldEntry = controller.workspaceManager.entry(for: oldWindow.token),
              let oldAXRef = oldEntry.axRef,
              CFEqual(oldAXRef.element, oldWindow.axRef.element),
              oldWindow.token == newWindow.token
              || controller.workspaceManager.entry(for: newWindow.token) == nil,
              isManagedWindowIdentityRebindTargetAlive(pid: newWindow.token.pid)
        else {
            return false
        }
        if let collision = controller.workspaceManager.entry(forWindowId: newWindow.token.windowId),
           collision.token != oldWindow.token
        {
            return false
        }
        if let acknowledgement,
           !controller.axManager.isCurrentWindowRebindAcknowledgement(
               acknowledgement,
               from: oldWindow,
               to: newWindow
           )
        {
            return false
        }
        return true
    }

    func currentManagedWindowIdentityRebindEntry(
        rebind: ManagedWindowIdentityRebind,
        execution: AdmissionRetryExecution,
        acknowledgement: AXManagedWindowRebindAcknowledgement?
    ) -> WindowState? {
        let oldWindow = rebind.oldWindow
        let newWindow = rebind.newWindow
        let windowId = execution.windowId
        let retryGeneration = execution.generation
        let executionOwner = execution.executionOwner
        guard let controller,
              controller.hasStartedServices,
              !Task.isCancelled,
              newWindow.token.windowId == Int(windowId),
              let state = admissionRetryStateByWindowId[windowId],
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner),
              !state.identityRebindTargetDestroyed,
              case let .identityRebind(retryOld, retryNew, _, _, _) = state.trigger,
              retryOld.token == oldWindow.token,
              retryNew.token == newWindow.token,
              CFEqual(retryOld.axRef.element, oldWindow.axRef.element),
              CFEqual(retryNew.axRef.element, newWindow.axRef.element),
              let entry = controller.workspaceManager.entry(for: newWindow.token),
              let entryAXRef = entry.axRef,
              CFEqual(entryAXRef.element, newWindow.axRef.element),
              controller.workspaceManager.entry(forWindowId: newWindow.token.windowId)?.token == newWindow.token,
              isManagedWindowIdentityRebindTargetAlive(pid: newWindow.token.pid)
        else {
            return nil
        }
        if let acknowledgement,
           !controller.axManager.isCurrentWindowRebindAcknowledgement(
               acknowledgement,
               from: oldWindow,
               to: newWindow
           )
        {
            return nil
        }
        return entry
    }

    func isManagedWindowIdentityRebindTargetAlive(pid: pid_t) -> Bool {
        if let provider = managedWindowIdentityRebindTargetIsAliveProvider {
            return provider(pid)
        }
        return NSRunningApplication(processIdentifier: pid)?.isTerminated == false
    }

    func retireStaleManagedWindowIdentityRebind(
        windowId: UInt32,
        retryGeneration: UInt64,
        executionOwner: UInt64
    ) {
        guard let state = admissionRetryStateByWindowId[windowId],
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner)
        else {
            return
        }
        cancelCreatedWindowRetry(windowId: windowId)
        discardDeferredReplacementProtection(windowId: windowId)
    }
}
