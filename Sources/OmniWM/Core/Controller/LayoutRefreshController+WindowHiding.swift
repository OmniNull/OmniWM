// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    struct HideTarget {
        let entry: WindowState
        let monitor: Monitor
        let side: HideSide
    }

    private enum HideOperationResolution {
        case movable(WindowPositionPlan, hiddenState: HiddenState)
        case alreadyHidden(WindowPositionPlan, hiddenState: HiddenState)
        case unavailable
    }

    private func resolveHideOperation(
        for entry: WindowState,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil,
        animationTick: Bool = false,
        preserveWorkspaceInactive: Bool = true,
        observedFrame: CGRect? = nil
    ) -> HideOperationResolution {
        guard let controller else { return .unavailable }
        var resolvedFrame = observedFrame
            ?? fastFrame(for: entry.token, axRef: entry.axRef)
            ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
        if resolvedFrame == nil, !animationTick {
            resolvedFrame = try? AXWindowService.frame(entry.axRef)
        }
        guard var frame = resolvedFrame else {
            return .unavailable
        }
        if animationTick, let liveOrigin = controller.axManager.skyLightLivePosition(for: entry.windowId) {
            frame.origin = liveOrigin
        }
        let hiddenState = updatedHiddenState(
            for: entry,
            frame: frame,
            monitor: monitor,
            policy: .init(side: side, reason: reason, preserveWorkspaceInactive: preserveWorkspaceInactive)
        )

        guard let origin = liveFrameHideOrigin(
            for: frame,
            monitor: monitor,
            side: side,
            reason: reason,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) else {
            return .unavailable
        }

        let moveEpsilon: CGFloat = 0.01
        if abs(frame.origin.x - origin.x) < moveEpsilon,
           abs(frame.origin.y - origin.y) < moveEpsilon
        {
            return .alreadyHidden(
                WindowPositionPlan(
                    entry: entry,
                    frame: CGRect(origin: origin, size: frame.size)
                ),
                hiddenState: hiddenState
            )
        }

        return .movable(
            WindowPositionPlan(
                entry: entry,
                frame: CGRect(origin: origin, size: frame.size)
            ),
            hiddenState: hiddenState
        )
    }

    private func updatedHiddenState(
        for entry: WindowState,
        frame: CGRect,
        monitor: Monitor,
        policy: HiddenStatePolicy
    ) -> HiddenState {
        guard let controller else {
            return HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: hiddenWindowReason(
                    for: policy,
                    existingState: nil
                )
            )
        }

        let existingState = controller.workspaceManager.hiddenState(for: entry.token)
        let proportionalPosition: CGPoint
        let referenceMonitorId: Monitor.ID?

        if let existingState {
            proportionalPosition = existingState.proportionalPosition
            referenceMonitorId = existingState.referenceMonitorId
        } else {
            let center = frame.center
            let referenceMonitor = center.monitorApproximation(in: controller.workspaceManager.monitors) ?? monitor
            proportionalPosition = self.proportionalPosition(topLeft: frame.topLeftCorner, in: referenceMonitor.frame)
            referenceMonitorId = referenceMonitor.id
        }

        return HiddenState(
            proportionalPosition: proportionalPosition,
            referenceMonitorId: referenceMonitorId,
            reason: hiddenWindowReason(
                for: policy,
                existingState: existingState
            )
        )
    }

    private func hiddenWindowReason(
        for policy: HiddenStatePolicy,
        existingState: HiddenState?
    ) -> HiddenReason {
        if existingState?.isScratchpad == true, policy.reason != .scratchpad {
            return .scratchpad
        }

        if policy.preserveWorkspaceInactive,
           existingState?.workspaceInactive == true,
           policy.reason == .layoutTransient
        {
            return .workspaceInactive
        }

        switch policy.reason {
        case .workspaceInactive:
            return .workspaceInactive
        case .layoutTransient:
            return .layoutTransient(policy.side)
        case .scratchpad:
            return .scratchpad
        }
    }

    @discardableResult
    func hideWindow(
        _ entry: WindowState,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil,
        observedFrame: CGRect? = nil
    ) -> Bool {
        guard let controller else { return false }
        let frameEntry = (pid: entry.pid, windowId: entry.windowId)
        switch resolveHideOperation(
            for: entry,
            monitor: monitor,
            side: side,
            reason: reason,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            observedFrame: observedFrame
        ) {
        case let .movable(plan, hiddenState):
            controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
            controller.axManager.cancelPendingFrameJobs([frameEntry], reason: "hide")
            controller.axManager.suppressFrameWrites([frameEntry])
            applyParkPositionPlans([plan], movablePlans: [plan], animationTick: false)
            return true
        case let .alreadyHidden(plan, hiddenState):
            controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
            controller.axManager.cancelPendingFrameJobs([frameEntry], reason: "hide")
            controller.axManager.suppressFrameWrites([frameEntry])
            applyParkPositionPlans([plan], movablePlans: [], animationTick: false)
            return true
        case .unavailable:
            controller.axManager.cancelPendingFrameJobs([frameEntry], reason: "hide-unavailable")
            controller.axManager.suppressFrameWrites([frameEntry])
            return false
        }
    }

    func applyLayoutTransientHides(
        _ hiddenEntries: [(entry: WindowState, side: HideSide)],
        monitor: Monitor,
        isAnimationTick: Bool,
        preserveWorkspaceInactive: Bool
    ) {
        guard !hiddenEntries.isEmpty, let controller else { return }
        applyHides(
            hiddenEntries.map { HideTarget(entry: $0.entry, monitor: monitor, side: $0.side) },
            reason: .layoutTransient,
            hiddenPlacementMonitors: controller.workspaceManager.monitors.map(HiddenPlacementMonitorContext.init),
            isAnimationTick: isAnimationTick,
            preserveWorkspaceInactive: preserveWorkspaceInactive
        )
    }

    func applyHides(
        _ targets: [HideTarget],
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext],
        isAnimationTick: Bool = false,
        preserveWorkspaceInactive: Bool = true
    ) {
        guard !targets.isEmpty, let controller else { return }
        var hiddenJobs: [(pid: pid_t, windowId: Int)] = []
        hiddenJobs.reserveCapacity(targets.count)
        var parkPlans: [WindowPositionPlan] = []
        parkPlans.reserveCapacity(targets.count)
        var movableParkPlans: [WindowPositionPlan] = []
        movableParkPlans.reserveCapacity(targets.count)

        for target in targets {
            let entry = target.entry
            switch resolveHideOperation(
                for: entry,
                monitor: target.monitor,
                side: target.side,
                reason: reason,
                hiddenPlacementMonitors: hiddenPlacementMonitors,
                animationTick: isAnimationTick,
                preserveWorkspaceInactive: preserveWorkspaceInactive
            ) {
            case let .movable(movePlan, hiddenState):
                controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
                hiddenJobs.append((entry.pid, entry.windowId))
                parkPlans.append(movePlan)
                movableParkPlans.append(movePlan)
            case let .alreadyHidden(plan, hiddenState):
                controller.workspaceManager.setHiddenState(hiddenState, for: entry.token)
                hiddenJobs.append((entry.pid, entry.windowId))
                parkPlans.append(plan)
            case .unavailable:
                hiddenJobs.append((entry.pid, entry.windowId))
            }
        }

        if !hiddenJobs.isEmpty {
            controller.axManager.cancelPendingFrameJobs(hiddenJobs, reason: "hide-batch")
            controller.axManager.suppressFrameWrites(hiddenJobs)
        }
        if !parkPlans.isEmpty {
            applyParkPositionPlans(
                parkPlans,
                movablePlans: movableParkPlans,
                animationTick: isAnimationTick
            )
        }
    }

    func liveFrameHideOrigin(
        for frame: CGRect,
        monitor: Monitor,
        side: HideSide,
        reason: HideReason,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]? = nil
    ) -> CGPoint? {
        guard let controller else { return nil }
        let baseReveal = Self.hiddenWindowEdgeRevealEpsilon
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let resolvedHiddenPlacementMonitors = hiddenPlacementMonitors
            ?? controller.workspaceManager.monitors.map(HiddenPlacementMonitorContext.init)

        switch reason {
        case .workspaceInactive,
             .scratchpad:
            return HiddenWindowPlacementResolver(
                monitor: hiddenPlacementMonitor,
                monitors: resolvedHiddenPlacementMonitors
            ).placement(
                for: frame.size,
                requestedEdge: AxisHideEdge(encodedHideSide: side),
                orthogonalOrigin: frame.origin.y,
                baseReveal: baseReveal,
                orientation: .horizontal
            ).origin
        case .layoutTransient:
            let orientation = controller.settings.monitors.effectiveOrientation(for: monitor)
            let orthogonalOrigin: CGFloat = switch orientation {
            case .horizontal: frame.origin.y
            case .vertical: frame.origin.x
            }
            let requestedEdge = AxisHideEdge(encodedHideSide: side)
            let placement = HiddenWindowPlacementResolver(
                monitor: hiddenPlacementMonitor,
                monitors: resolvedHiddenPlacementMonitors
            ).placement(
                for: frame.size,
                requestedEdge: requestedEdge,
                orthogonalOrigin: orthogonalOrigin,
                baseReveal: baseReveal,
                orientation: orientation
            )
            return placement.origin
        }
    }
}

extension LayoutRefreshController {
    private struct HiddenStatePolicy {
        let side: HideSide
        let reason: HideReason
        let preserveWorkspaceInactive: Bool
    }
}
