// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    func repairLayoutTransientPark(for entry: WindowState, side: HideSide, observedFrame: CGRect) {
        guard let controller,
              entry.layoutReason == .standard,
              let parkFrame = controller.axManager.parkTargetFrame(for: entry.windowId),
              !observedFrame.size.isWithinFrameTolerance(of: parkFrame.size),
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
              let parkOrigin = liveFrameHideOrigin(
                  for: observedFrame,
                  monitor: monitor,
                  side: side,
                  reason: .layoutTransient
              ),
              !observedFrame.approximatelyEqual(
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

    @discardableResult
    func applyPositionPlans(
        _ plans: [WindowPositionPlan],
        deferringVisibleAXFor deferredTokens: Set<WindowToken> = []
    ) -> Set<WindowToken> {
        guard let controller, !plans.isEmpty else { return [] }
        let plans = plans.filter { !controller.workspaceManager.isWindowSuppressedByMacOS($0.entry.token) }
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
            guard requiresVisibleAXTokens.contains(plan.entry.token) else { return nil }
            if deferredTokens.contains(plan.entry.token) {
                return nil
            }
            controller.axManager.markWindowActive(plan.entry.windowId)
            controller.axManager.forceApplyNextFrame(for: plan.entry.windowId)
            return .init(pid: plan.entry.pid, window: plan.entry.axRef, frame: plan.frame)
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

    func applyParkPositionPlans(
        _ plans: [WindowPositionPlan],
        movablePlans: [WindowPositionPlan],
        animationTick: Bool
    ) {
        guard let controller, !plans.isEmpty else { return }
        let plans = plans.filter { !controller.workspaceManager.isWindowSuppressedByMacOS($0.entry.token) }
        guard !plans.isEmpty else { return }
        let movablePlans = movablePlans.filter {
            !controller.workspaceManager.isWindowSuppressedByMacOS($0.entry.token)
        }

        if animationTick {
            for plan in plans {
                controller.axManager.markParkPending(.init(
                    pid: plan.entry.pid,
                    window: plan.entry.axRef,
                    frame: plan.frame
                ))
            }
        } else {
            for plan in movablePlans where controller.axManager.verifiedParkFrame(for: plan.entry.windowId) != nil {
                controller.axManager.markParkPending(for: plan.entry.windowId, pid: plan.entry.pid)
            }
        }

        if !movablePlans.isEmpty {
            controller.axManager.applyPositionsViaSkyLight(
                movablePlans.map { SkyLightPositionTarget(token: $0.entry.token, frame: $0.frame) },
                allowInactive: true
            )
        }

        for plan in plans {
            if animationTick {
                controller.axManager.recordSkyLightMove(windowId: plan.entry.windowId, origin: plan.frame.origin)
            }
            FrameApplyTrace.recordEvent(
                pid: plan.entry.pid,
                windowId: plan.entry.windowId,
                outcome: animationTick ? "outcome=sls-parked/animation" : "outcome=sls-parked/settled",
                target: plan.frame
            )
        }

        if animationTick { return }

        controller.axManager.applyParkFramesParallel(
            plans.map {
                AXFrameApplicationTarget(pid: $0.entry.pid, window: $0.entry.axRef, frame: $0.frame)
            }
        )
    }
}
