// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class ScratchpadStackingController {
    private weak var controller: WMController?
    private var scratchpadStackingPlan: ScratchpadStackingPlan?
    private var deferredScratchpadStacking: DeferredScratchpadStacking?
    private var scratchpadStackingGeneration: UInt64 = 0

    init(controller: WMController) {
        self.controller = controller
    }

    func stackScratchpadMembers(
        _ tokens: [WindowToken],
        in index: ScratchpadIndex,
        on workspaceId: WorkspaceDescriptor.ID,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) {
        let planId = reserveScratchpadStackingGeneration()
        startScratchpadStacking(
            tokens,
            in: index,
            on: workspaceId,
            planId: planId,
            focusOrigin: focusOrigin
        )
    }

    private func reserveScratchpadStackingGeneration() -> UInt64 {
        scratchpadStackingGeneration &+= 1
        scratchpadStackingPlan = nil
        deferredScratchpadStacking = nil
        return scratchpadStackingGeneration
    }

    private func startScratchpadStacking(
        _ tokens: [WindowToken],
        in index: ScratchpadIndex,
        on workspaceId: WorkspaceDescriptor.ID,
        planId: UInt64,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic,
        waitingFor barrierRequest: ManagedFocusRequest? = nil
    ) {
        guard let controller else { return }
        guard scratchpadStackingGeneration == planId else { return }
        let handles = tokens.compactMap { controller.workspaceManager.handle(for: $0) }
        guard !handles.isEmpty else {
            scratchpadStackingPlan = nil
            return
        }
        var plan = ScratchpadStackingPlan(
            id: planId,
            index: index,
            workspaceId: workspaceId,
            handles: handles,
            nextHandleIndex: 0,
            pendingHandle: nil,
            pendingRequestId: nil,
            pendingActivationSettled: false,
            continuationScheduled: false,
            focusOrigin: focusOrigin
        )
        if let barrierRequest {
            guard barrierRequest.workspaceId == workspaceId,
                  let barrierHandle = controller.workspaceManager.handle(for: barrierRequest.token),
                  controller.intentLedger.activeManagedRequest(requestId: barrierRequest.requestId) != nil,
                  controller.workspaceManager.pendingManagedFocusMatches(
                      token: barrierRequest.token,
                      workspaceId: barrierRequest.workspaceId,
                      requestId: barrierRequest.requestId
                  )
            else {
                scratchpadStackingPlan = nil
                return
            }
            plan.pendingHandle = barrierHandle
            plan.pendingRequestId = barrierRequest.requestId
            plan.pendingActivationSettled = controller.axEventHandler.frontmostApplicationPIDProvider()
                == barrierRequest.token.pid
            scratchpadStackingPlan = plan
            return
        }
        scratchpadStackingPlan = plan
        advanceScratchpadStacking(planId: planId)
    }

    func resumeRehomedScratchpadStackingAfterFocusHandoff() {
        guard let controller else { return }
        guard let deferred = deferredScratchpadStacking,
              deferred.id == scratchpadStackingGeneration
        else {
            return
        }
        deferredScratchpadStacking = nil
        startScratchpadStacking(
            deferred.tokens,
            in: deferred.index,
            on: deferred.workspaceId,
            planId: deferred.id,
            waitingFor: controller.intentLedger.activeManagedRequest
        )
    }

    private func advanceScratchpadStacking(planId: UInt64) {
        guard let controller else { return }
        guard var plan = scratchpadStackingPlan, plan.id == planId else { return }
        guard controller.workspaceManager.revealedScratchpadIndex() == plan.index,
              controller.workspaceManager.visibleWorkspaceIds().contains(plan.workspaceId)
        else {
            scratchpadStackingPlan = nil
            return
        }

        while plan.nextHandleIndex < plan.handles.count {
            let handle = plan.handles[plan.nextHandleIndex]
            plan.nextHandleIndex += 1
            guard let entry = scratchpadStackingEntry(for: handle, in: plan) else {
                continue
            }

            plan.pendingHandle = handle
            plan.pendingRequestId = nil
            plan.pendingActivationSettled = controller.axEventHandler.frontmostApplicationPIDProvider() == entry.pid
            plan.continuationScheduled = false
            scratchpadStackingPlan = plan
            let origin: ManagedFocusOrigin = plan.handles[plan.nextHandleIndex...].contains { candidate in
                scratchpadStackingEntry(for: candidate, in: plan) != nil
            } ? .pointerHover : plan.focusOrigin
            guard let request = controller.focusWindow(handle.id, origin: origin) else {
                plan.pendingHandle = nil
                scratchpadStackingPlan = plan
                continue
            }
            guard controller.intentLedger.activeManagedRequest(requestId: request.requestId) != nil,
                  controller.workspaceManager.pendingManagedFocusMatches(
                      token: request.token,
                      workspaceId: request.workspaceId,
                      requestId: request.requestId
                  )
            else {
                plan.pendingHandle = nil
                scratchpadStackingPlan = plan
                continue
            }
            plan.pendingRequestId = request.requestId
            scratchpadStackingPlan = plan
            return
        }

        scratchpadStackingPlan = nil
    }

    private func scratchpadStackingEntry(
        for handle: WindowHandle,
        in plan: ScratchpadStackingPlan
    ) -> WindowState? {
        guard let controller else { return nil }
        guard controller.workspaceManager.scratchpadIndex(for: handle.id) == plan.index,
              let entry = controller.workspaceManager.entry(for: handle),
              entry.workspaceId == plan.workspaceId,
              controller.workspaceManager.hiddenState(for: handle.id) == nil,
              !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token),
              !controller.isManagedWindowSuspendedForNativeFullscreen(handle.id)
        else {
            return nil
        }
        return entry
    }

    private func scheduleScratchpadStackingIfReady(planId: UInt64) {
        guard let controller else { return }
        guard var plan = scratchpadStackingPlan,
              plan.id == planId,
              !plan.continuationScheduled,
              plan.pendingActivationSettled,
              let pendingPID = plan.pendingHandle?.id.pid,
              let requestId = plan.pendingRequestId,
              controller.intentLedger.intent(id: requestId)?.phase == .confirmed,
              controller.intentLedger.newestFocusIntentId() == requestId
        else {
            return
        }
        plan.continuationScheduled = true
        scratchpadStackingPlan = plan
        controller.scheduleScratchpadStackingContinuation { [weak self] in
            guard let self,
                  let controller = self.controller,
                  var currentPlan = scratchpadStackingPlan,
                  currentPlan.id == planId,
                  currentPlan.pendingRequestId == requestId
            else {
                return
            }
            guard controller.intentLedger.intent(id: requestId)?.phase == .confirmed,
                  controller.intentLedger.newestFocusIntentId() == requestId,
                  controller.axEventHandler.frontmostApplicationPIDProvider() == pendingPID,
                  controller.workspaceManager.selectedManagedToken == currentPlan.pendingHandle?.id,
                  controller.workspaceManager.revealedScratchpadIndex() == currentPlan.index,
                  controller.workspaceManager.visibleWorkspaceIds().contains(currentPlan.workspaceId)
            else {
                scratchpadStackingPlan = nil
                return
            }
            currentPlan.pendingHandle = nil
            currentPlan.pendingRequestId = nil
            currentPlan.pendingActivationSettled = false
            currentPlan.continuationScheduled = false
            scratchpadStackingPlan = currentPlan
            advanceScratchpadStacking(planId: planId)
        }
    }
}

private struct ScratchpadStackingPlan {
    let id: UInt64
    let index: ScratchpadIndex
    let workspaceId: WorkspaceDescriptor.ID
    let handles: [WindowHandle]
    var nextHandleIndex: Int
    var pendingHandle: WindowHandle?
    var pendingRequestId: IntentID?
    var pendingActivationSettled: Bool
    var continuationScheduled: Bool
    let focusOrigin: ManagedFocusOrigin
}

private struct DeferredScratchpadStacking {
    let id: UInt64
    let index: ScratchpadIndex
    let workspaceId: WorkspaceDescriptor.ID
    let tokens: [WindowToken]
}

extension ScratchpadStackingController {
    func continueScratchpadStacking(after request: ManagedFocusRequest) {
        guard let plan = scratchpadStackingPlan,
              plan.pendingRequestId == request.requestId,
              plan.pendingHandle?.id == request.token
        else {
            return
        }
        scheduleScratchpadStackingIfReady(planId: plan.id)
    }

    func advanceScratchpadStackingAfterFocusRetryExhaustion(_ request: ManagedFocusRequest) {
        guard var plan = scratchpadStackingPlan,
              plan.pendingRequestId == request.requestId,
              plan.pendingHandle?.id == request.token
        else {
            return
        }
        plan.pendingHandle = nil
        plan.pendingRequestId = nil
        plan.pendingActivationSettled = false
        plan.continuationScheduled = false
        scratchpadStackingPlan = plan
        advanceScratchpadStacking(planId: plan.id)
    }

    func abortScratchpadStacking(matching requestId: IntentID) {
        guard scratchpadStackingPlan?.pendingRequestId == requestId else { return }
        _ = reserveScratchpadStackingGeneration()
    }

    func noteScratchpadStackingAppActivation(pid: pid_t, source: ActivationEventSource) {
        guard let controller else { return }
        guard source == .workspaceDidActivateApplication,
              var plan = scratchpadStackingPlan,
              let pendingHandle = plan.pendingHandle,
              pendingHandle.id.pid == pid,
              controller.axEventHandler.frontmostApplicationPIDProvider() == pid
        else {
            return
        }
        plan.pendingActivationSettled = true
        scratchpadStackingPlan = plan
        scheduleScratchpadStackingIfReady(planId: plan.id)
    }

    func rehomeRevealedScratchpad(activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return }
        guard let index = controller.workspaceManager.revealedScratchpadIndex() else { return }
        let members = controller.workspaceManager.scratchpadMembers(in: index)
        let focusedMember = controller.workspaceManager.selectedManagedToken.flatMap { members.contains($0) ? $0 : nil }
        var targetWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for token in members {
            guard let entry = controller.workspaceManager.entry(for: token),
                  !activeWorkspaceIds.contains(entry.workspaceId),
                  let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
                  let target = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
                  target != entry.workspaceId
            else {
                continue
            }
            controller.reassignManagedWindow(token, to: target)
            targetWorkspaceIds.insert(target)
        }
        guard !targetWorkspaceIds.isEmpty else { return }
        let planId = reserveScratchpadStackingGeneration()
        guard targetWorkspaceIds.count == 1,
              let targetWorkspaceId = targetWorkspaceIds.first
        else {
            return
        }
        let survivors = members.filter { token in
            controller.workspaceManager.entry(for: token)?.workspaceId == targetWorkspaceId
                && controller.workspaceManager.hiddenState(for: token) == nil
        }
        let preferred = focusedMember.flatMap { survivors.contains($0) ? $0 : nil } ?? survivors.last
        let ordered = survivors.filter { $0 != preferred } + survivors.filter { $0 == preferred }
        guard !ordered.isEmpty else { return }
        deferredScratchpadStacking = DeferredScratchpadStacking(
            id: planId,
            index: index,
            workspaceId: targetWorkspaceId,
            tokens: ordered
        )
    }
}
