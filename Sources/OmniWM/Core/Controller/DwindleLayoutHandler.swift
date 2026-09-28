// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor final class DwindleLayoutHandler {
    struct AnimationSession {
        let workspaceId: WorkspaceDescriptor.ID
        let engineIdentifier: ObjectIdentifier
        let geometry: DwindleAnimationGeometryContext
        let targetFrames: [WindowToken: CGRect]
        let plannedSeq: UInt64
    }

    private(set) lazy var groupReveals = DwindleGroupRevealTransactions(handler: self)

    weak var controller: WMController?

    var dwindleAnimationByDisplay: [CGDirectDisplayID: (WorkspaceDescriptor.ID, Monitor)] = [:]
    var stackableIncomingWorkspaceByToken: [WindowToken: WorkspaceDescriptor.ID] = [:]
    private(set) var animationSessionByDisplay: [CGDirectDisplayID: AnimationSession] = [:]
    private var staleRelayoutWorkspaceByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func canAcceptAnimationTarget(
        _ disposition: DwindleAnimationTargetDisposition,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: LayoutMonitorSnapshot
    ) -> Bool {
        switch disposition {
        case let .clear(engineIdentifier, geometry):
            guard let controller,
                  let engine = controller.dwindleEngine,
                  let currentMonitor = controller.workspaceManager.monitor(byId: monitor.monitorId),
                  let currentGeometry = geometryContext(
                      monitor: currentMonitor,
                      settings: controller.resolvedDwindleSettings(for: currentMonitor)
                  )
            else {
                return false
            }
            return ObjectIdentifier(engine) == engineIdentifier
                && geometry == currentGeometry
                && geometry == geometryContext(monitor: monitor, settings: geometry.settings)
        case let .replace(candidate):
            guard let controller,
                  let engine = controller.dwindleEngine,
                  let currentMonitor = controller.workspaceManager.monitor(byId: monitor.monitorId),
                  let currentGeometry = geometryContext(
                      monitor: currentMonitor,
                      settings: controller.resolvedDwindleSettings(for: currentMonitor)
                  ),
                  candidate.workspaceId == workspaceId,
                  candidate.engineIdentifier == ObjectIdentifier(engine),
                  candidate.geometry == currentGeometry,
                  candidate.geometry == geometryContext(monitor: monitor, settings: candidate.geometry.settings)
            else {
                return false
            }
            return true
        }
    }

    func acceptAnimationTarget(
        _ disposition: DwindleAnimationTargetDisposition,
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        plannedSeq: UInt64
    ) -> Set<CGDirectDisplayID> {
        clearStaleRelayoutState(for: workspaceId)
        switch disposition {
        case .clear:
            return removeAnimationState(for: workspaceId)
        case let .replace(candidate):
            guard controller?.workspaceManager.activeWorkspaceOrFirst(
                on: candidate.geometry.monitorId
            )?.id == workspaceId else {
                controller?.dwindleEngine?.cancelAnimations(in: workspaceId)
                return removeAnimationState(for: workspaceId)
            }
            var detachedDisplayIds: Set<CGDirectDisplayID> = []
            let previousDisplayIds = animationSessionByDisplay.compactMap { registeredDisplayId, session in
                session.workspaceId == workspaceId && registeredDisplayId != displayId
                    ? registeredDisplayId
                    : nil
            }
            for registeredDisplayId in previousDisplayIds {
                animationSessionByDisplay.removeValue(forKey: registeredDisplayId)
                if dwindleAnimationByDisplay[registeredDisplayId]?.0 == workspaceId {
                    dwindleAnimationByDisplay.removeValue(forKey: registeredDisplayId)
                }
                detachedDisplayIds.insert(registeredDisplayId)
            }
            animationSessionByDisplay[displayId] = AnimationSession(
                workspaceId: workspaceId,
                engineIdentifier: candidate.engineIdentifier,
                geometry: candidate.geometry,
                targetFrames: candidate.targetFrames,
                plannedSeq: plannedSeq
            )
            return detachedDisplayIds
        }
    }

    func suspendStaleAnimation(
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID
    ) -> Bool {
        animationSessionByDisplay.removeValue(forKey: displayId)
        if dwindleAnimationByDisplay[displayId]?.0 == workspaceId {
            dwindleAnimationByDisplay.removeValue(forKey: displayId)
        }
        let wasAlreadyStale = staleRelayoutWorkspaceByDisplay.values.contains(workspaceId)
        staleRelayoutWorkspaceByDisplay[displayId] = workspaceId
        return !wasAlreadyStale
    }

    func removeAnimationState(for displayId: CGDirectDisplayID) -> Set<WorkspaceDescriptor.ID> {
        var workspaceIds: Set<WorkspaceDescriptor.ID> = []
        if let workspaceId = animationSessionByDisplay.removeValue(forKey: displayId)?.workspaceId {
            workspaceIds.insert(workspaceId)
        }
        if let workspaceId = dwindleAnimationByDisplay.removeValue(forKey: displayId)?.0 {
            workspaceIds.insert(workspaceId)
        }
        if let workspaceId = staleRelayoutWorkspaceByDisplay.removeValue(forKey: displayId) {
            workspaceIds.insert(workspaceId)
        }
        return workspaceIds
    }

    func removeAllAnimationState() -> (workspaceIds: Set<WorkspaceDescriptor.ID>, displayIds: Set<CGDirectDisplayID>) {
        let workspaceIds = Set(animationSessionByDisplay.values.map(\.workspaceId))
            .union(dwindleAnimationByDisplay.values.map(\.0))
            .union(staleRelayoutWorkspaceByDisplay.values)
        let displayIds = Set(animationSessionByDisplay.keys)
            .union(dwindleAnimationByDisplay.keys)
            .union(staleRelayoutWorkspaceByDisplay.keys)
        animationSessionByDisplay.removeAll(keepingCapacity: true)
        dwindleAnimationByDisplay.removeAll(keepingCapacity: true)
        staleRelayoutWorkspaceByDisplay.removeAll(keepingCapacity: true)
        return (workspaceIds, displayIds)
    }

    func removeAnimationState(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Set<CGDirectDisplayID> {
        var displayIds: Set<CGDirectDisplayID> = []
        let sessionDisplayIds = animationSessionByDisplay.compactMap { displayId, session in
            session.workspaceId == workspaceId ? displayId : nil
        }
        for displayId in sessionDisplayIds {
            animationSessionByDisplay.removeValue(forKey: displayId)
            displayIds.insert(displayId)
        }
        let registrationDisplayIds = dwindleAnimationByDisplay.compactMap { displayId, registration in
            registration.0 == workspaceId ? displayId : nil
        }
        for displayId in registrationDisplayIds {
            dwindleAnimationByDisplay.removeValue(forKey: displayId)
            displayIds.insert(displayId)
        }
        clearStaleRelayoutState(for: workspaceId)
        return displayIds
    }

    private func clearStaleRelayoutState(for workspaceId: WorkspaceDescriptor.ID) {
        let displayIds = staleRelayoutWorkspaceByDisplay.compactMap { displayId, staleWorkspaceId in
            staleWorkspaceId == workspaceId ? displayId : nil
        }
        for displayId in displayIds {
            staleRelayoutWorkspaceByDisplay.removeValue(forKey: displayId)
        }
    }

    func registerDwindleAnimation(
        _ workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        on displayId: CGDirectDisplayID
    ) -> Bool {
        guard animationSessionByDisplay[displayId]?.workspaceId == workspaceId else {
            return false
        }
        if dwindleAnimationByDisplay[displayId]?.0 == workspaceId {
            return false
        }
        if let displacedWorkspaceId = dwindleAnimationByDisplay[displayId]?.0 {
            controller?.dwindleEngine?.cancelAnimations(in: displacedWorkspaceId)
        }
        dwindleAnimationByDisplay[displayId] = (workspaceId, monitor)
        return true
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleAnimationByDisplay.values.contains { $0.0 == workspaceId }
    }

    func animationDisplayIds(for workspaceId: WorkspaceDescriptor.ID) -> Set<CGDirectDisplayID> {
        let sessionDisplayIds = animationSessionByDisplay.compactMap { displayId, session in
            session.workspaceId == workspaceId ? displayId : nil
        }
        let registrationDisplayIds = dwindleAnimationByDisplay.compactMap { displayId, registration in
            registration.0 == workspaceId ? displayId : nil
        }
        return Set(sessionDisplayIds).union(registrationDisplayIds)
    }
}

extension DwindleLayoutHandler: LayoutSizable {}
