// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    @discardableResult
    func updateLiveColumnDrag(at location: CGPoint, immediate: Bool = false, drawing frame: CGRect? = nil) -> Bool {
        cancelLiveDragFollowUp()
        return runLiveColumnDragPass(at: location, immediate: immediate, drawing: frame)
    }

    private func scheduleLiveDragFollowUp() {
        guard liveDragSession != nil, liveDragSession?.followUp == nil else { return }
        liveDragSession?.followUp = scheduleLiveDragTimer(after: 0) { [weak self] in
            self?.runLiveDragFollowUp()
        }
    }

    private func runLiveDragFollowUp() {
        guard liveDragSession?.followUp != nil else { return }
        liveDragSession?.followUp = nil
        guard let location = livePointer.location else { return }
        updateLiveColumnDrag(at: location)
    }

    private func cancelLiveDragFollowUp() {
        liveDragSession?.followUp?.invalidate()
        liveDragSession?.followUp = nil
    }

    private func runLiveColumnDragPass(at location: CGPoint, immediate: Bool, drawing frame: CGRect?) -> Bool {
        guard isLiveColumnDragActive,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.windowToken == (liveDragSession?.carriedWindow?.token ?? state.nativeTitleBarDrag?.token)
        else {
            endLiveDragSession()
            return false
        }
        let (workspaceId, token) = (move.workspaceId, move.windowToken)
        let slowed = livePointerHasSlowed(at: liveDragClock())
        let updateLabel = slowed ? "update slowed=1" : "update slowed=0"
        guard let monitor = liveDragMonitor(in: workspaceId, at: location, label: updateLabel, controller: controller)
        else { return false }
        let context = liveColumnContext(for: workspaceId, engine: engine, monitor: monitor, controller: controller)
        var refreshed = false
        defer {
            if let frame, !refreshed {
                controller.layoutRefreshController.renderCarriedWindow(
                    token, frame: frame, engine: engine, monitor: monitor, context: context
                )
            }
        }
        trackLiveEdgeZone(at: location, monitorFrame: monitor.frame, orientation: context.orientation)
        let reference = liveDragReference(location, orientation: context.orientation)
        let manager = controller.workspaceManager
        let viewport = manager.niriViewportState(for: workspaceId)
        var strip = engine.liveColumnStrip(context: context, state: viewport)
        traceLiveStrip(updateLabel, in: workspaceId, at: location, strip: strip, viewport: viewport)
        publishLiveDragHold(on: monitor, strip: strip, context: context, state: viewport)
        let gate = liveEdgeScrollGate(home: move.home, at: reference, engine: engine, workspaceId: workspaceId)
        guard gate != .blocked else { return false }
        if gate == .stopped {
            strip = engine.liveColumnStrip(context: context, state: manager.niriViewportState(for: workspaceId))
        }
        if move.phase == .settling, !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
            engine.liveColumnMoveSettled()
        }

        let immediate = immediate || gate == .stopped
        let now = liveDragClock()
        let step = runLiveColumnMoveUpdate(
            .init(cursor: reference, time: immediate ? nil : now, slowed: slowed),
            windowMidX: liveDragWindowMidX(location, orientation: context.orientation),
            engine: engine,
            context: context,
            strip: strip
        )
        scheduleLiveHoverCheck(for: step, at: now)
        refreshed = settleLiveDragStep(step, immediate: immediate, at: location, in: workspaceId, engine: engine)
        return refreshed
    }

    private func scheduleLiveHoverCheck(for step: LiveColumnMove.Step, at now: TimeInterval) {
        if let until = step.hoverDeadline {
            let stopCheck = livePointerStopCheckDelay(at: now) ?? .infinity
            scheduleLiveHoverCheck(after: min(until - now, stopCheck))
        } else {
            cancelLiveHoverCheck()
        }
    }

    @inline(__always)
    private func liveDragMonitor(
        in workspaceId: WorkspaceDescriptor.ID,
        at location: CGPoint,
        label: String,
        controller: WMController
    ) -> Monitor? {
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else {
            traceLiveDrag(label, at: location)
            cancelLiveColumnDrag()
            return nil
        }
        if !state.gestureOwnsWindowInteraction, pointerHasLeft(monitor, at: location) {
            traceLiveDrag(label, at: location)
            if !carryLiveColumnDrag(from: workspaceId, at: location) {
                MouseTrace.record("live-drag carry refused at=\(TraceFormat.point(location)) from=\(workspaceId)")
                handOverLiveColumnDrag()
            }
            return nil
        }
        return monitor
    }

    private enum LiveEdgeScrollGate {
        case open
        case blocked
        case stopped
    }

    @inline(__always)
    private func liveEdgeScrollGate(
        home: LiveColumnMove.Home,
        at reference: CGPoint,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) -> LiveEdgeScrollGate {
        if let edgeScroll = liveDragSession?.edgeScroll,
           edgeScroll.hopping || edgeScroll.hopsDone || home != .stackSlot
        {
            return .blocked
        }
        guard isLiveEdgeScrolling else { return .open }
        guard liveEdgeScrollReachesColumn(
            at: reference,
            time: CACurrentMediaTime(),
            engine: engine,
            workspaceId: workspaceId
        ) else { return .blocked }
        stopLiveEdgeScroll()
        return .stopped
    }

    @inline(__always)
    private func settleLiveDragStep(
        _ step: LiveColumnMove.Step,
        immediate: Bool,
        at location: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine
    ) -> Bool {
        guard step.changesLayout else {
            if step == .unchanged {
                startLiveEdgeScrollIfDue()
            }
            return false
        }
        traceLiveDrag(immediate ? "changed-immediate" : "changed", at: location)
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        if !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
            engine.liveColumnMoveSettled()
            scheduleLiveDragFollowUp()
        }
        return true
    }

    @inline(__always)
    private func runLiveColumnMoveUpdate(
        _ pointer: LiveColumnMove.Pointer,
        windowMidX: CGFloat?,
        engine: NiriLayoutEngine,
        context: NiriInteractionContext,
        strip: [LiveColumnMove.StripColumn]
    ) -> LiveColumnMove.Step {
        guard let manager = controller?.workspaceManager,
              let decision = engine.liveColumnMoveDecision(
                  pointer,
                  windowMidX: windowMidX,
                  context: context,
                  strip: strip
              )
        else { return .unchanged }
        if let step = engine.keepLiveColumnMoveDecision(decision) {
            return step
        }
        return manager.withNiriViewportState(
            for: context.workspaceId,
            committingIf: { $0.changesLayout },
            { engine.applyLiveColumnMoveDecision(decision, context: context, state: &$0) }
        )
    }

    private func scheduleLiveHoverCheck(after delay: TimeInterval) {
        let fireDate = Date(timeIntervalSinceNow: max(0, delay))
        if let timer = liveDragSession?.hoverTimer, timer.isValid {
            if abs(timer.fireDate.timeIntervalSince(fireDate)) >= 0.005 {
                timer.fireDate = fireDate
            }
            return
        }
        liveDragSession?.hoverTimer = scheduleLiveDragTimer(after: delay) { [weak self] in
            guard let self, let location = livePointer.location else { return }
            liveDragSession?.hoverTimer = nil
            updateLiveColumnDrag(at: location)
        }
    }

    func scheduleLiveDragTimer(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func cancelLiveHoverCheck() {
        liveDragSession?.hoverTimer?.invalidate()
        liveDragSession?.hoverTimer = nil
    }
}
