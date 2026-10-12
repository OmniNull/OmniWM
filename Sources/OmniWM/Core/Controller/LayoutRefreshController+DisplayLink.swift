// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    enum DisplayLinkStopReason {
        case idle
        case noWork
        case monitorDisconnect
        case reset
    }

    func setup() {
        detectRefreshRates()
        layoutState.screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    func getOrCreateDisplayLink(for displayId: CGDirectDisplayID) -> CADisplayLink? {
        if let existing = layoutState.displayLinksByDisplay[displayId] {
            return existing
        }
        if displayLinkCreationAllowedForTests?(displayId) == false {
            return nil
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayId == displayId }) else {
            return nil
        }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        layoutState.displayLinksByDisplay[displayId] = link
        if var counters = performanceCounters {
            counters.displayLinksCreated &+= 1
            counters.activeDisplayLinks = layoutState.displayLinksByDisplay.count
            counters.activeDisplayLinkHighWater = max(
                counters.activeDisplayLinkHighWater,
                counters.activeDisplayLinks
            )
            performanceCounters = counters
        }
        return link
    }

    private func handleScreenParametersChanged() {
        workspaceSwipe.cancel(reason: "display-change")
        detectRefreshRates()
        controller?.syncMonitorsToNiriEngine()
        controller?.surfaceReconciler.noteWorldChanged()
    }

    func cleanupForMonitorDisconnect(displayId: CGDirectDisplayID, migrateAnimations: Bool) {
        if workspaceSwipe.flight?.preparation.monitor.displayId == displayId {
            workspaceSwipe.cancel(reason: "display-disconnected")
        }
        if let workspaceId = niriHandler.scrollAnimationByDisplay[displayId] {
            niriHandler.terminateViewportGesture(
                for: workspaceId,
                disposition: .settleLiveOffset
            )
        }
        invalidateDisplayLink(for: displayId, reason: .monitorDisconnect)

        if let animations = layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId) {
            for animation in animations.values {
                forgetClosingAnimation(animation)
            }
        }

        if migrateAnimations {
            if let workspaceId = niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId) {
                startScrollAnimation(for: workspaceId)
            }
        } else if let workspaceId = niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId) {
            niriHandler.cancelAnimationMotion(for: workspaceId)
        }
        stopDwindleAnimation(for: displayId)
    }

    private func detectRefreshRates() {
        layoutState.refreshRateByDisplay.removeAll()
        var backingScales: [CGDirectDisplayID: CGFloat] = [:]
        for screen in NSScreen.screens {
            guard let displayId = screen.displayId else { continue }
            layoutState.refreshRateByDisplay[displayId] = Monitor.refreshRate(for: displayId)
            backingScales[displayId] = screen.backingScaleFactor
        }
        layoutState.backingScaleByDisplay = backingScales
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        let entryTime = CACurrentMediaTime()
        guard let displayId = activeDisplayId(for: displayLink) else { return }

        let traceActive = AnimationTickTrace.shared.isActive
        let traceOrigin = traceActive
            ? FrameEffectTraceContext.makeDisplayTickOrigin(displayId: displayId)
            : .none
        let previousTraceOrigin = traceActive
            ? FrameEffectTraceContext.install(traceOrigin)
            : .none
        defer {
            if traceActive {
                FrameEffectTraceContext.restore(previousTraceOrigin)
            }
        }
        let previousTickTimestamp = layoutState.lastTickTimestampByDisplay
            .updateValue(displayLink.timestamp, forKey: displayId)
        let intervalMs = previousTickTimestamp.map { (displayLink.timestamp - $0) * 1000 } ?? 0
        let phaseTiming = applyDisplayAnimationTick(displayLink, displayId: displayId, traceActive: traceActive)
        let animationApplyEndTime = traceActive ? CACurrentMediaTime() : 0
        stopDisplayLinkIfIdle(for: displayId)
        let idleStopEndTime = traceActive ? CACurrentMediaTime() : 0
        auditParkVisibility(displayId: displayId)

        let completionTime = CACurrentMediaTime()
        let timing = DisplayTickTiming(
            intervalMs: intervalMs,
            expectedMs: displayLink.duration * 1000,
            workMs: (completionTime - entryTime) * 1000,
            entrySlackMs: (displayLink.targetTimestamp - entryTime) * 1000,
            completionSlackMs: (displayLink.targetTimestamp - completionTime) * 1000
        )
        let classification = displayTickMetrics.record(timing, hasPreviousTick: previousTickTimestamp != nil)

        guard traceActive else { return }
        AnimationTickTrace.shared.record(
            AnimationTickTrace.Record(
                mediaTime: completionTime,
                effectId: traceOrigin.effectId,
                displayId: displayId,
                timing: timing,
                scrollMs: (phaseTiming.scrollEndTime - entryTime) * 1000,
                dwindleMs: (phaseTiming.dwindleEndTime - phaseTiming.scrollEndTime) * 1000,
                closingMs: (phaseTiming.closingEndTime - phaseTiming.dwindleEndTime) * 1000,
                reconcileMs: (completionTime - phaseTiming.closingEndTime) * 1000,
                surfaceMs: (phaseTiming.surfaceEndTime - phaseTiming.closingEndTime) * 1000,
                transactionScopeMs: (animationApplyEndTime - phaseTiming.surfaceEndTime) * 1000,
                idleStopMs: (idleStopEndTime - animationApplyEndTime) * 1000,
                parkAuditMs: (completionTime - idleStopEndTime) * 1000,
                classification: classification
            )
        )
    }

    func startScrollAnimation(for workspaceId: WorkspaceDescriptor.ID, forGesture: Bool = false) {
        guard forGesture || controller?.motionPolicy.animationsEnabled != false else { return }
        guard let controller else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId),
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else {
            niriHandler.cancelActiveAnimations(for: workspaceId)
            return
        }
        let targetDisplayId = monitor.displayId

        let registrationChanged = niriHandler.registerScrollAnimation(workspaceId, on: targetDisplayId)
        if displayLinkActivationForTests?(targetDisplayId) == true {
            return
        }
        if !registrationChanged, layoutState.displayLinksByDisplay[targetDisplayId] != nil {
            return
        }
        guard let displayLink = getOrCreateDisplayLink(for: targetDisplayId) else {
            niriHandler.cancelAnimationMotion(for: workspaceId, gestureDisposition: .settleLiveOffset)
            niriHandler.scrollAnimationByDisplay.removeValue(forKey: targetDisplayId)
            return
        }
        displayLink.add(to: .main, forMode: .common)
    }

    func stopScrollAnimation(for displayId: CGDirectDisplayID) {
        if let workspaceId = niriHandler.scrollAnimationByDisplay[displayId] {
            niriHandler.terminateViewportGesture(
                for: workspaceId,
                disposition: .settleLiveOffset
            )
        }
        niriHandler.scrollAnimationByDisplay.removeValue(forKey: displayId)
        stopDisplayLinkIfIdle(for: displayId)
    }

    func acceptDwindleAnimationTarget(
        _ disposition: DwindleAnimationTargetDisposition,
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        plannedSeq: UInt64
    ) {
        let detachedDisplayIds = dwindleHandler.acceptAnimationTarget(
            disposition,
            workspaceId: workspaceId,
            displayId: displayId,
            plannedSeq: plannedSeq
        )
        for detachedDisplayId in detachedDisplayIds {
            stopDisplayLinkIfIdle(for: detachedDisplayId)
        }
    }

    func suspendStaleDwindleAnimation(
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID
    ) {
        let shouldRequestRelayout = dwindleHandler.suspendStaleAnimation(
            workspaceId: workspaceId,
            displayId: displayId
        )
        stopDisplayLinkIfIdle(for: displayId)
        guard shouldRequestRelayout else { return }
        requestRelayout(
            reason: .staleLayoutPlan,
            affectedWorkspaceIds: [workspaceId]
        )
    }

    func startDwindleAnimation(for workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller else { return }
        let targetDisplayId = monitor.displayId
        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId else {
            for displayId in dwindleHandler.animationDisplayIds(for: workspaceId) {
                stopDwindleAnimation(for: displayId)
            }
            controller.dwindleEngine?.cancelAnimations(in: workspaceId)
            return
        }
        guard controller.motionPolicy.animationsEnabled else {
            stopDwindleAnimation(for: targetDisplayId)
            return
        }
        guard dwindleHandler.animationSessionByDisplay[targetDisplayId]?.workspaceId == workspaceId else {
            stopDwindleAnimation(for: targetDisplayId)
            controller.dwindleEngine?.cancelAnimations(in: workspaceId)
            return
        }

        let registrationChanged = dwindleHandler.registerDwindleAnimation(
            workspaceId,
            monitor: monitor,
            on: targetDisplayId
        )
        if displayLinkActivationForTests?(targetDisplayId) == true {
            return
        }
        if !registrationChanged, layoutState.displayLinksByDisplay[targetDisplayId] != nil {
            return
        }

        if let displayLink = getOrCreateDisplayLink(for: targetDisplayId) {
            displayLink.add(to: .main, forMode: .common)
        } else {
            stopDwindleAnimation(for: targetDisplayId)
        }
    }

    func cancelFrameAnimations(forPID pid: pid_t) {
        let displayIds = Array(layoutState.closingAnimationsByDisplay.keys)
        for displayId in displayIds {
            guard var animations = layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
            else { continue }
            let removedWindowIds = animations.compactMap { windowId, animation in
                animation.pid == pid ? windowId : nil
            }
            for windowId in removedWindowIds {
                if let animation = animations.removeValue(forKey: windowId) {
                    forgetClosingAnimation(animation)
                }
            }
            if animations.isEmpty {
                layoutState.closingAnimationsByDisplay.removeValue(forKey: displayId)
                stopDisplayLinkIfIdle(for: displayId)
            } else {
                layoutState.closingAnimationsByDisplay[displayId] = animations
            }
        }
    }

    func stopDwindleAnimation(for displayId: CGDirectDisplayID) {
        for workspaceId in dwindleHandler.removeAnimationState(for: displayId) {
            controller?.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        stopDisplayLinkIfIdle(for: displayId)
    }

    func stopAllDwindleAnimations() {
        let removed = dwindleHandler.removeAllAnimationState()
        for workspaceId in removed.workspaceIds {
            controller?.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        for displayId in removed.displayIds {
            stopDisplayLinkIfIdle(for: displayId)
        }
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleHandler.hasDwindleAnimationRunning(in: workspaceId)
    }

    func resetDisplayLinkAndAnimationState() {
        let niriWorkspaceIds = Set(niriHandler.scrollAnimationByDisplay.values)
        let removedDwindleState = dwindleHandler.removeAllAnimationState()
        for workspaceId in niriWorkspaceIds {
            niriHandler.cancelAnimationMotion(
                for: workspaceId,
                gestureDisposition: .settleLiveOffsetWithoutRelayout
            )
        }
        for displayId in Array(layoutState.displayLinksByDisplay.keys) {
            invalidateDisplayLink(for: displayId, reason: .reset)
        }
        niriHandler.scrollAnimationByDisplay.removeAll()
        for workspaceId in removedDwindleState.workspaceIds {
            controller?.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        layoutState.closingAnimationsByDisplay.removeAll()
        closingAnimationIdsByObjectId.removeAll(keepingCapacity: true)
        lastSubmittedClosingFramesByAnimationId.removeAll(keepingCapacity: true)
    }

    func stopDisplayLinkIfIdle(
        for displayId: CGDirectDisplayID,
        reason: DisplayLinkStopReason = .idle
    ) {
        if niriHandler.scrollAnimationByDisplay[displayId] == nil,
           !workspaceSwipe.hasDisplayWork(displayId),
           dwindleHandler.dwindleAnimationByDisplay[displayId] == nil,
           layoutState.closingAnimationsByDisplay[displayId].map({ $0.isEmpty }) ?? true
        {
            invalidateDisplayLink(for: displayId, reason: reason)
            scheduleTrailingParkAudits(displayId: displayId)
        }
    }

    private func invalidateDisplayLink(
        for displayId: CGDirectDisplayID,
        reason: DisplayLinkStopReason
    ) {
        guard let link = layoutState.displayLinksByDisplay.removeValue(forKey: displayId) else { return }
        link.invalidate()
        layoutState.lastTickTimestampByDisplay.removeValue(forKey: displayId)
        performanceCounters?.displayLinksInvalidated &+= 1
        performanceCounters?.activeDisplayLinks = layoutState.displayLinksByDisplay.count
        switch reason {
        case .idle:
            performanceCounters?.displayLinkIdleStops &+= 1
        case .noWork:
            performanceCounters?.displayLinkNoWorkStops &+= 1
        case .monitorDisconnect:
            performanceCounters?.displayLinkMonitorDisconnectStops &+= 1
        case .reset:
            performanceCounters?.displayLinkResetStops &+= 1
        }
    }

    private func hasDisplayLinkWork(for displayId: CGDirectDisplayID) -> Bool {
        workspaceSwipe.hasDisplayWork(displayId)
            || niriHandler.scrollAnimationByDisplay[displayId] != nil
            || dwindleHandler.dwindleAnimationByDisplay[displayId] != nil
            || !(layoutState.closingAnimationsByDisplay[displayId]?.isEmpty ?? true)
    }

    private func scheduleTrailingParkAudits(displayId: CGDirectDisplayID) {
        guard ParkVisibilityAudit.shared.isActive else { return }
        layoutState.trailingAuditTask?.cancel()
        layoutState.trailingAuditTask = Task { @MainActor [weak self] in
            for _ in 0 ..< 30 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.auditParkVisibility(displayId: displayId)
            }
        }
    }

    private struct DisplayAnimationPhaseTiming {
        let scrollEndTime: CFTimeInterval
        let dwindleEndTime: CFTimeInterval
        let closingEndTime: CFTimeInterval
        let surfaceEndTime: CFTimeInterval
    }

    private func applyDisplayAnimationTick(
        _ displayLink: CADisplayLink,
        displayId: CGDirectDisplayID,
        traceActive: Bool
    ) -> DisplayAnimationPhaseTiming {
        var scrollEndTime: CFTimeInterval = 0
        var dwindleEndTime: CFTimeInterval = 0
        var closingEndTime: CFTimeInterval = 0
        var surfaceEndTime: CFTimeInterval = 0

        SkyLight.shared.withTransactionScope {
            workspaceSwipe.tick(displayId: displayId, timestamp: displayLink.targetTimestamp)
            niriHandler.tickScrollAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
            scrollEndTime = traceActive ? CACurrentMediaTime() : 0
            dwindleHandler.tickDwindleAnimation(targetTime: displayLink.targetTimestamp, displayId: displayId)
            dwindleEndTime = traceActive ? CACurrentMediaTime() : 0
            tickClosingAnimations(targetTime: displayLink.targetTimestamp, displayId: displayId)
            closingEndTime = traceActive ? CACurrentMediaTime() : 0
            controller?.surfaceReconciler.reconcileAnimationTick()
            surfaceEndTime = traceActive ? CACurrentMediaTime() : 0
        }
        return DisplayAnimationPhaseTiming(
            scrollEndTime: scrollEndTime,
            dwindleEndTime: dwindleEndTime,
            closingEndTime: closingEndTime,
            surfaceEndTime: surfaceEndTime
        )
    }

    private func activeDisplayId(for displayLink: CADisplayLink) -> CGDirectDisplayID? {
        guard let displayId = layoutState.displayLinksByDisplay.first(where: { $0.value === displayLink })?.key
        else { return nil }
        performanceCounters?.displayLinkCallbacks &+= 1
        guard hasDisplayLinkWork(for: displayId) else {
            performanceCounters?.noWorkDisplayLinkCallbacks &+= 1
            stopDisplayLinkIfIdle(for: displayId, reason: .noWork)
            return nil
        }
        performanceCounters?.meaningfulDisplayLinkCallbacks &+= 1

        return displayId
    }
}
