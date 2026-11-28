// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
extension AXEventHandler {
    private enum IdentityRebindPreparation {
        case acknowledged(AXManagedWindowRebindAcknowledgement?)
        case failed
    }

    func completeManagedWindowIdentityRebind(
        rebind: ManagedWindowIdentityRebind, execution: AdmissionRetryExecution
    ) async {
        guard let controller else { return }
        var requiresBindingRefresh = false
        defer {
            if requiresBindingRefresh {
                bindCurrentManagedWindows(afterRebinding: rebind.oldWindow, to: rebind.newWindow)
            }
        }
        guard controller.hasStartedServices else {
            retryManagedWindowIdentityRebind(rebind: rebind, execution: execution)
            return
        }
        guard case let .acknowledged(acknowledgement) = await prepareManagedWindowIdentityRebind(
            rebind, controller: controller
        ) else {
            retryManagedWindowIdentityRebind(rebind: rebind, execution: execution)
            return
        }
        guard let rebind = await commitAcknowledgedManagedWindowIdentity(
            rebind: rebind, execution: execution, acknowledgement: acknowledgement, controller: controller
        ) else { return }
        applyManagedWindowIdentityRebindRuntimeState(
            rebind: rebind, acknowledgement: acknowledgement, controller: controller
        )
        requiresBindingRefresh = true
        guard currentManagedWindowIdentityRebindEntry(
            rebind: rebind, execution: execution, acknowledgement: acknowledgement
        ) != nil else {
            rollbackAndRetireManagedIdentityRebind(
                rebind: rebind, execution: execution, acknowledgement: acknowledgement, controller: controller
            )
            return
        }
        if let sizeConstraints = rebind.sizeConstraints {
            controller.workspaceManager.setCachedConstraints(sizeConstraints, for: rebind.newWindow.token)
        }
        await finalizeManagedWindowIdentityRebind(
            rebind: rebind, execution: execution, acknowledgement: acknowledgement, controller: controller
        )
    }

    private func prepareManagedWindowIdentityRebind(
        _ rebind: ManagedWindowIdentityRebind, controller: WMController
    ) async -> IdentityRebindPreparation {
        if let provider = managedWindowIdentityRebindAcknowledgementProvider {
            return await provider(rebind.oldWindow, rebind.newWindow) ? .acknowledged(nil) : .failed
        }
        guard let acknowledgement = await controller.axManager.rebindWindowAsync(
            from: rebind.oldWindow, to: rebind.newWindow
        ) else { return .failed }
        return .acknowledged(acknowledgement)
    }

    private func commitAcknowledgedManagedWindowIdentity(
        rebind: ManagedWindowIdentityRebind, execution: AdmissionRetryExecution,
        acknowledgement: AXManagedWindowRebindAcknowledgement?, controller: WMController
    ) async -> ManagedWindowIdentityRebind? {
        var rebind = rebind
        if rebind.managedReplacementMetadata != nil,
           isCurrentManagedWindowIdentityRebind(rebind: rebind, execution: execution, acknowledgement: acknowledgement)
        {
            let window = rebind.newWindow.axRef
            var observation = if let provider = rebindMinimizationProvider {
                await provider(window)
            } else {
                await acknowledgement?.destinationContext.windowMinimizationAsync(window)
            }
            if let notification = admissionRetryStateByWindowId[execution.windowId]?.rebindMinimization,
               observation.map({ notification.sequence > $0.sequence }) ?? true
            {
                observation = notification
            }
            rebind.minimizedAttribute = observation?.isMinimized ?? rebind.minimizedAttribute
        }
        guard isCurrentManagedWindowIdentityRebind(
                  rebind: rebind, execution: execution, acknowledgement: acknowledgement
              ),
              commitManagedWindowIdentityRebind(
                  from: rebind.oldWindow.token, to: rebind.newWindow.token,
                  axRef: rebind.newWindow.axRef, managedReplacementMetadata: rebind.managedReplacementMetadata
              ) != nil
        else {
            rollbackAndRetireManagedIdentityRebind(
                rebind: rebind, execution: execution, acknowledgement: acknowledgement, controller: controller
            )
            return nil
        }
        return rebind
    }

    func applyManagedWindowIdentityRebindRuntimeState(
        rebind: ManagedWindowIdentityRebind,
        acknowledgement: AXManagedWindowRebindAcknowledgement?, controller: WMController
    ) {
        controller.mouseEventHandler.discardNativeTitleBarDrag(for: rebind.oldWindow.token)
        let retainedParkTarget = controller.axManager.commitFrameApplicationStateForRebind(
            from: rebind.oldWindow, to: rebind.newWindow, acknowledgement: acknowledgement
        )
        if let minimizedAttribute = rebind.minimizedAttribute {
            updateWindowMinimizedState(minimizedAttribute, token: rebind.newWindow.token)
        }
        if let retainedParkTarget {
            controller.axManager.applyParkFramesParallel([retainedParkTarget])
        }
    }

    private func rollbackAndRetireManagedIdentityRebind(
        rebind: ManagedWindowIdentityRebind, execution: AdmissionRetryExecution,
        acknowledgement: AXManagedWindowRebindAcknowledgement?, controller: WMController
    ) {
        if let acknowledgement {
            controller.axManager.rollbackWindowRebind(acknowledgement, newWindow: rebind.newWindow)
        }
        retireManagedIdentityRebindAndRescan(rebind: rebind, execution: execution)
    }

    private func retireManagedIdentityRebindAndRescan(
        rebind: ManagedWindowIdentityRebind, execution: AdmissionRetryExecution
    ) {
        retireStaleManagedWindowIdentityRebind(
            windowId: execution.windowId, retryGeneration: execution.generation,
            executionOwner: execution.executionOwner
        )
        requestTargetedFullRescan(for: [rebind.oldWindow.token.pid, rebind.newWindow.token.pid])
    }

    private func finalizeManagedWindowIdentityRebind(
        rebind: ManagedWindowIdentityRebind, execution: AdmissionRetryExecution,
        acknowledgement: AXManagedWindowRebindAcknowledgement?, controller: WMController
    ) async {
        let finalized = if let provider = managedWindowIdentityRebindFinalizationProvider {
            await provider(rebind.oldWindow, rebind.newWindow)
        } else {
            await controller.axManager.finalizeWindowRebindContextState(
                from: rebind.oldWindow, to: rebind.newWindow, acknowledgement: acknowledgement
            )
        }
        guard finalized else {
            retireManagedIdentityRebindAndRescan(rebind: rebind, execution: execution)
            return
        }
        guard let currentEntry = currentManagedWindowIdentityRebindEntry(
            rebind: rebind, execution: execution, acknowledgement: acknowledgement
        ) else {
            retireManagedIdentityRebindAndRescan(rebind: rebind, execution: execution)
            return
        }
        finishManagedWindowIdentityRebind(
            rebind: rebind, entry: currentEntry, windowId: execution.windowId,
            directPreparedSubscriptionRetainCount: nil
        )
    }
}
