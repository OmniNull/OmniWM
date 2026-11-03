// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
extension LayoutRefreshController {
    struct WindowPositionPlan {
        let entry: WindowState
        let frame: CGRect
    }

    func repairWorkspaceInactivePark(for entry: WindowState, observedFrame: CGRect) {
        guard let controller,
              entry.layoutReason == .standard,
              let verifiedFrame = controller.axManager.verifiedParkFrame(for: entry.windowId),
              !observedFrame.approximatelyEqual(to: verifiedFrame, tolerance: FrameTolerance.frameWrite),
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id != entry.workspaceId
        else { return }

        controller.axManager.markParkPending(for: entry.windowId, pid: entry.pid)

        guard !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token),
              !controller.axManager.macOSHiddenAppPIDs.contains(entry.pid),
              !controller.workspaceManager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
        else { return }

        hideWindow(
            entry,
            monitor: monitor,
            side: preferredHideSide(for: monitor),
            reason: .workspaceInactive,
            observedFrame: observedFrame
        )
    }

    func repairLayoutTransientPark(after result: AXFrameApplyResult) {
        switch result.writeResult.failureReason {
        case nil,
             .verificationMismatch,
             .positionWriteFailed:
            break
        default:
            return
        }
        guard let controller,
              let observedFrame = result.writeResult.observedFrame,
              !observedFrame.size.isWithinFrameTolerance(of: result.targetFrame.size),
              let entry = controller.workspaceManager.entry(for: WindowToken(
                  pid: result.pid,
                  windowId: result.windowId
              )),
              let axRef = entry.axRef,
              sameAXWindowIdentity(axRef, result.expectedWindow),
              let side = entry.hiddenState?.offscreenSide
        else { return }
        repairLayoutTransientPark(for: entry, side: side, observedFrame: observedFrame)
    }

    func repairLayoutTransientPark(
        for entry: WindowState,
        side: HideSide,
        observedFrame: CGRect
    ) {
        guard let controller,
              entry.layoutReason == .standard,
              let parkFrame = controller.axManager.parkTargetFrame(for: entry.windowId),
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == entry.workspaceId,
              let parkOrigin = liveFrameHideOrigin(
                  for: observedFrame,
                  monitor: monitor,
                  side: side,
                  reason: .layoutTransient
              ),
              !observedFrame.size.isWithinFrameTolerance(of: parkFrame.size) || !observedFrame.approximatelyEqual(
                  to: CGRect(origin: parkOrigin, size: observedFrame.size),
                  tolerance: FrameTolerance.frameWrite
              ),
              !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token),
              !controller.axManager.macOSHiddenAppPIDs.contains(entry.pid),
              !controller.workspaceManager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
        else { return }

        hideWindow(
            entry,
            monitor: monitor,
            side: side,
            reason: .layoutTransient,
            observedFrame: observedFrame
        )
    }

    private func externalPositionPlans(_ plans: [WindowPositionPlan], hidingNative: Bool) -> [WindowPositionPlan] {
        guard let controller else { return [] }
        return plans.filter { plan in
            guard plan.entry.axRef != nil else {
                if !hidingNative { controller.shellAppWindowManager.setFrame(plan.frame, for: plan.entry.token) }
                controller.shellAppWindowManager.setHidden(hidingNative, for: plan.entry.token)
                return false
            }
            return !controller.workspaceManager.isWindowSuppressedByMacOS(plan.entry.token)
        }
    }

    @discardableResult
    func applyPositionPlans(
        _ plans: [WindowPositionPlan],
        deferringVisibleAXFor deferredTokens: Set<WindowToken> = []
    ) -> Set<WindowToken> {
        guard let controller, !plans.isEmpty else { return [] }
        let plans = externalPositionPlans(plans, hidingNative: false)
        guard !plans.isEmpty else { return [] }

        var requiresVisibleAXTokens = controller.axManager.cancelParkFrameJobs(
            plans.map { (pid: $0.entry.pid, windowId: $0.entry.windowId) },
            reason: "revealed"
        )
        controller.axManager.applyPositionsViaSkyLight(
            plans.map { SkyLightPositionTarget(token: $0.entry.token, frame: $0.frame) },
            allowInactive: true
        )
        let visibleFrames = plans.compactMap { plan -> AXFrameApplicationTarget? in
            guard let axRef = plan.entry.axRef, requiresVisibleAXTokens.contains(plan.entry.token) else { return nil }
            if deferredTokens.contains(plan.entry.token) {
                return nil
            }
            controller.axManager.markWindowActive(plan.entry.windowId)
            controller.axManager.forceApplyNextFrame(for: plan.entry.windowId)
            return .init(pid: plan.entry.pid, window: axRef, frame: plan.frame)
        }
        if !visibleFrames.isEmpty {
            controller.axManager.unsuppressFrameWrites(
                visibleFrames.map { (pid: $0.pid, windowId: $0.windowId) }
            )
            controller.axManager.applyFramesParallel(visibleFrames)
        }
        requiresVisibleAXTokens.formIntersection(deferredTokens)
        return requiresVisibleAXTokens
    }

    private func externalFrameTarget(for plan: WindowPositionPlan) -> AXFrameApplicationTarget? {
        guard let axRef = plan.entry.axRef else { return nil }
        return AXFrameApplicationTarget(pid: plan.entry.pid, window: axRef, frame: plan.frame)
    }

    func applyParkPositionPlans(
        _ plans: [WindowPositionPlan],
        movablePlans: [WindowPositionPlan],
        animationTick: Bool,
        afterFrameWritesOf awaitedWindowIds: Set<Int> = []
    ) {
        guard let controller, !plans.isEmpty else { return }
        let plans = externalPositionPlans(plans, hidingNative: true)
        guard !plans.isEmpty else { return }
        let movablePlans = movablePlans.filter {
            !controller.workspaceManager.isWindowSuppressedByMacOS($0.entry.token) && $0.entry.axRef != nil
        }

        if animationTick {
            for plan in plans {
                guard let axRef = plan.entry.axRef else { continue }
                controller.axManager.markParkPending(.init(
                    pid: plan.entry.pid,
                    window: axRef,
                    frame: plan.frame
                ))
            }
        } else {
            for plan in movablePlans where controller.axManager.verifiedParkFrame(for: plan.entry.windowId) != nil {
                controller.axManager.markParkPending(for: plan.entry.windowId, pid: plan.entry.pid)
            }
        }

        let waitsForFrameWrites = awaitedWindowIds.contains(where: controller.axManager.isAwaitingFrameWrite)
        if !movablePlans.isEmpty, !waitsForFrameWrites {
            controller.axManager.applyPositionsViaSkyLight(
                movablePlans.map { SkyLightPositionTarget(token: $0.entry.token, frame: $0.frame) },
                allowInactive: true, tracingPark: true
            )
        }

        for plan in plans {
            if animationTick {
                controller.axManager.recordSkyLightMove(windowId: plan.entry.windowId, origin: plan.frame.origin)
            }
            FrameApplyTrace.recordEvent(
                pid: plan.entry.pid,
                windowId: plan.entry.windowId,
                outcome: animationTick ? "outcome=sls-park-intent/animation" : "outcome=sls-park-intent/settled",
                target: plan.frame
            )
        }

        if animationTick { return }

        controller.axManager.applyParkFramesParallel(
            plans.compactMap { externalFrameTarget(for: $0) },
            afterFrameWritesOf: awaitedWindowIds
        )
    }
}
