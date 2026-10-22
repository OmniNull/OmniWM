// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func resolvedOrientation(
        for workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        engine: NiriLayoutEngine
    ) -> Monitor.Orientation {
        controller?.settings.monitors.effectiveOrientation(for: monitor)
            ?? engine.monitorForWorkspace(workspaceId)?.orientation
            ?? monitor.autoOrientation
    }

    func startScrollAnimationIfNeeded(
        for workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine
    ) {
        guard let controller else { return }
        guard hasPendingNiriAnimationWork(
            state: state,
            driver: controller.workspaceManager.animationDriver,
            engine: engine,
            workspaceId: workspaceId
        ) else {
            return
        }
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
    }

    func registerScrollAnimation(_ workspaceId: WorkspaceDescriptor.ID, on displayId: CGDirectDisplayID) -> Bool {
        if scrollAnimationByDisplay[displayId] == workspaceId {
            return false
        }
        if let displacedWorkspaceId = scrollAnimationByDisplay[displayId] {
            cancelAnimationMotion(for: displacedWorkspaceId, gestureDisposition: .settleLiveOffset)
        }
        scrollAnimationByDisplay[displayId] = workspaceId
        return true
    }

    func hasScrollAnimation(for workspaceId: WorkspaceDescriptor.ID) -> Bool {
        scrollAnimationByDisplay.values.contains(workspaceId)
    }

    func tickScrollAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let wsId = scrollAnimationByDisplay[displayId] else { return }
        guard let controller else {
            scrollAnimationByDisplay.removeValue(forKey: displayId)
            return
        }
        guard let target = scrollAnimationTarget(workspaceId: wsId, displayId: displayId, controller: controller)
        else { return }
        let engine = target.engine
        let monitor = target.monitor

        let scrollTrace = ScrollTickTrace.shared.isActive
        let animsStart = scrollTrace ? CACurrentMediaTime() : 0
        let windowAnimationsRunning = engine.tickAllWindowAnimations(in: wsId, at: targetTime)
        let columnAnimationsRunning = engine.tickAllColumnAnimations(in: wsId, at: targetTime)
        let viewportTick = controller.workspaceManager.animationDriver.tickResult(in: wsId, at: targetTime)
        applyExpiredViewportGesture(viewportTick, workspaceId: wsId, controller: controller)
        let viewportMotionRunning = viewportTick.isRunning
        let animsMs = scrollTrace ? (CACurrentMediaTime() - animsStart) * 1000 : 0
        let state = controller.workspaceManager.niriViewportState(for: wsId)
        let animationsOngoing = viewportMotionRunning
            || windowAnimationsRunning
            || columnAnimationsRunning
        if !animationsOngoing {
            controller.resizeOverlay.settleOnLayout(in: wsId)
        }

        let didApplyFrames = applyFramesOnDemand(
            wsId: wsId,
            state: state,
            engine: engine,
            monitor: monitor,
            animationTime: targetTime,
            settlesAnimation: !animationsOngoing,
            animsMs: animsMs
        )
        guard didApplyFrames else {
            controller.layoutRefreshController.requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: [wsId]
            )
            return
        }

        if !animationsOngoing {
            finalizeAnimation()
            controller.layoutRefreshController.hideInactiveWorkspaces(
                activeWorkspaceIds: activeWorkspaceIds(controller: controller)
            )
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            controller.mouseEventHandler.handleNiriAnimationsSettled(in: wsId)
        }
    }

    private func activeWorkspaceIds(controller: WMController) -> Set<WorkspaceDescriptor.ID> {
        var activeIds = Set<WorkspaceDescriptor.ID>()
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeIds.insert(workspace.id)
            }
        }
        return activeIds
    }

    @discardableResult
    func applyFramesOnDemand(
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        engine: NiriLayoutEngine,
        monitor: Monitor,
        animationTime: TimeInterval? = nil,
        settlesAnimation: Bool = false,
        animsMs: Double = 0
    ) -> Bool {
        guard let controller,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            return false
        }

        let trace = ScrollTickTrace.shared.isActive && animationTime != nil
        let snapshotStart = trace ? CACurrentMediaTime() : 0
        guard let snapshot = makeWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitor,
            options: SnapshotOptions(
                viewportState: state,
                useScrollAnimationPath: true,
                removalSeed: nil,
                isActiveWorkspace: activeWorkspaceId == wsId
            )
        ) else {
            return false
        }
        let snapshotMs = trace ? (CACurrentMediaTime() - snapshotStart) * 1000 : 0

        let buildStart = CACurrentMediaTime()
        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine,
            monitor: monitor,
            animationTime: animationTime,
            settlesAnimation: settlesAnimation
        )
        let buildSeconds = CACurrentMediaTime() - buildStart
        controller.layoutRefreshController.recordScrollBuild(
            seconds: buildSeconds,
            workspaceCount: 1,
            windowCount: controller.workspaceManager.windowCount(in: wsId)
        )

        let commitStart = trace ? CACurrentMediaTime() : 0
        let applied = controller.layoutRefreshController.executeLayoutPlan(plan)
        if trace {
            recordScrollTickBreakdown(
                plan: plan,
                monitor: monitor,
                windowCount: snapshot.windows.count,
                spans: ScrollTickSpans(
                    anims: animsMs,
                    snapshot: snapshotMs,
                    build: buildSeconds * 1000,
                    commit: (CACurrentMediaTime() - commitStart) * 1000
                )
            )
        }
        return applied
    }

    private struct ScrollTickSpans {
        let anims: Double
        let snapshot: Double
        let build: Double
        let commit: Double
    }

    private func recordScrollTickBreakdown(
        plan: WorkspaceLayoutPlan,
        monitor: Monitor,
        windowCount: Int,
        spans: ScrollTickSpans
    ) {
        var show = 0
        var hide = 0
        for change in plan.diff.visibilityChanges {
            switch change {
            case .show: show += 1
            case .hide: hide += 1
            }
        }
        ScrollTickTrace.shared.record(
            ScrollTickTrace.Record(
                mediaTime: CACurrentMediaTime(),
                effectId: FrameEffectTraceContext.currentOrigin.effectId,
                displayId: monitor.displayId,
                animsMs: spans.anims,
                snapshotMs: spans.snapshot,
                buildMs: spans.build,
                commitMs: spans.commit,
                totalMs: spans.anims + spans.snapshot + spans.build + spans.commit,
                show: show,
                hide: hide,
                frames: plan.diff.frameChanges.count,
                windowCount: windowCount,
                isAnimationTick: plan.isAnimationTick
            )
        )
    }

    private func finalizeAnimation() {
        guard let controller else { return }

        controller.surfaceReconciler.noteRestackOccurred()

        if controller.moveMouseToFocusedWindowEnabled,
           controller.workspaceManager.pendingFocusedToken == nil,
           let token = controller.workspaceManager.nativeManagedFocusToken,
           !controller.axEventHandler.suppressesMouseWarp(for: token),
           controller.intentLedger.allowsMouseToFocusedWarp(for: token)
        {
            controller.moveMouseToWindow(token, preferredFrame: controller.preferredKeyboardFocusFrame(for: token))
        }
    }

    func cancelActiveAnimations(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }

        let hadScrollAnimation = scrollAnimationByDisplay.values.contains(workspaceId)
        let hadMotion = cancelAnimationMotion(for: workspaceId, gestureDisposition: .settleLiveOffset)
        for (displayId, wsId) in scrollAnimationByDisplay where wsId == workspaceId {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
        }

        guard hadScrollAnimation || hadMotion,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else {
            return
        }
        applyFramesOnDemand(
            wsId: workspaceId,
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            engine: engine,
            monitor: monitor
        )
    }

    @discardableResult
    func cancelAnimationMotion(
        for workspaceId: WorkspaceDescriptor.ID,
        gestureDisposition: MouseEventHandler.ViewportGestureTerminationDisposition = .settleLiveOffset
    ) -> Bool {
        guard let controller else { return false }
        let driver = controller.workspaceManager.animationDriver
        let engine = controller.niriEngine
        let hadViewportMotion = driver.hasMotion(in: workspaceId)
        terminateViewportGesture(for: workspaceId, disposition: gestureDisposition)
        driver.removeMotions(for: [workspaceId])
        let hadEngineAnimations = engine?.cancelAnimations(in: workspaceId) == true
        return hadViewportMotion || hadEngineAnimations
    }

    @discardableResult
    func terminateViewportGesture(
        for workspaceId: WorkspaceDescriptor.ID,
        disposition: MouseEventHandler.ViewportGestureTerminationDisposition
    ) -> Bool {
        guard let controller else { return false }
        let driver = controller.workspaceManager.animationDriver
        guard let sessionID = driver.gestureSessionID(in: workspaceId) else { return false }
        let terminated = controller.mouseEventHandler.terminateViewportGesture(
            in: workspaceId,
            sessionID: sessionID,
            disposition: disposition
        )
        if driver.gestureSessionID(in: workspaceId) == sessionID {
            driver.removeMotions(for: [workspaceId])
        }
        return terminated
    }

    private func scrollAnimationTarget(
        workspaceId wsId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        controller: WMController
    ) -> (engine: NiriLayoutEngine, monitor: Monitor)? {
        guard let engine = controller.niriEngine else {
            cancelAnimationMotion(for: wsId)
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            return nil
        }

        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == displayId }) else {
            cancelAnimationMotion(for: wsId, gestureDisposition: .settleLiveOffset)
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            return nil
        }

        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId else {
            cancelAnimationMotion(for: wsId, gestureDisposition: .settleLiveOffset)
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            controller.layoutRefreshController.hideInactiveWorkspaces(
                activeWorkspaceIds: activeWorkspaceIds(controller: controller)
            )
            return nil
        }

        return (engine, monitor)
    }

    private func applyExpiredViewportGesture(
        _ viewportTick: AnimationDriver.TickResult,
        workspaceId wsId: WorkspaceDescriptor.ID,
        controller: WMController
    ) {
        if case let .expiredGesture(relativeOffset, sessionID) = viewportTick {
            controller.workspaceManager.withNiriViewportState(for: wsId) { state in
                state.jumpOffset(to: state.viewOffset + CGFloat(relativeOffset))
                state.viewOffsetToRestore = nil
                state.activatePrevColumnOnRemoval = nil
            }
            controller.mouseEventHandler.handleExpiredViewportGesture(
                in: wsId,
                sessionID: sessionID
            )
        }
    }
}
