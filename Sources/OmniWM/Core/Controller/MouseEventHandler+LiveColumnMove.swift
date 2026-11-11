// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isLiveColumnDragActive: Bool {
        state.nativeTitleBarDrag?.liveDrag == true || liveDragSession?.tabPull != nil
    }

    func holdsSelectionScroll(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if controller?.niriEngine?.isLiveColumnMoveActive(in: workspaceId) == true { return true }
        guard let token = state.deferredClickScroll,
              pressedMouseButtonsProvider() & MouseButton.left.pressedMask != 0
        else { return false }
        return controller?.workspaceManager.entry(for: token)?.workspaceId == workspaceId
    }

    func deferClickScrollIfPressed(on token: WindowToken) -> Bool {
        guard controller?.settings.niri.macOSFusion == true,
              pressedMouseButtonsProvider() & MouseButton.left.pressedMask != 0,
              tracksNativeTitleBarDrag(windowId: token.windowId)
        else { return false }
        if !isLiveColumnDragActive {
            state.deferredClickScroll = token
        }
        return true
    }

    func runDeferredClickScroll() {
        guard let token = state.deferredClickScroll else { return }
        state.deferredClickScroll = nil
        guard let controller,
              let engine = controller.niriEngine,
              let entry = controller.workspaceManager.entry(for: token),
              controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              !engine.isLiveColumnMoveActive(in: entry.workspaceId)
        else { return }
        scrollSelectionIntoView(token, in: entry.workspaceId, engine: engine)
    }

    func trackLiveColumnDrag(at location: CGPoint, button: MouseButton) -> Bool {
        if button == .left, liveDragSession?.tabPull != nil {
            moveLiveTabPull(to: location)
            return true
        }
        guard button == .left,
              state.nativeTitleBarDrag != nil,
              controller?.settings.niri.macOSFusion == true
        else { return false }
        livePointer.location = location
        recordLivePointerSample(location)
        liveDragSession?.modifiers = nil
        resumeHandedOverLiveColumnDrag(at: location)
        guard isLiveColumnDragActive else { return false }
        updateLiveColumnDrag(at: location)
        return true
    }

    func handleLiveColumnDragFrameChange(
        _ drag: inout MouseInputState.NativeTitleBarDrag,
        entry: WindowState
    ) -> Bool {
        if drag.liveDrag {
            state.nativeTitleBarDrag = drag
            return true
        }
        guard beginLiveColumnDragIfEligible(&drag, entry: entry) else { return false }
        state.nativeTitleBarDrag = drag
        if let location = livePointer.location {
            updateLiveColumnDrag(at: location)
        }
        return true
    }

    func traceLiveDragDecline(_ reason: @autoclosure () -> String) {
        guard MouseTrace.shared.isActive else { return }
        let reason = reason()
        guard reason != state.liveDragTracedDecline else { return }
        state.liveDragTracedDecline = reason
        MouseTrace.record("live-drag declined \(reason)")
    }

    func beginLiveColumnDragIfEligible(
        _ drag: inout MouseInputState.NativeTitleBarDrag,
        entry: WindowState
    ) -> Bool {
        if MouseTrace.shared.isActive, !drag.liveDrag, drag.liveDragDeclined {
            traceLiveDragDecline("check token=\(TraceFormat.token(entry.token)) declined=true")
        } else if MouseTrace.shared.isActive, !drag.liveDrag {
            let start = drag.liveStartFrame ?? drag.adoptionStartFrame
            let observed = entry.axRef.flatMap(nativeWindowFrameProvider)
            traceLiveDragDecline(
                "check token=\(TraceFormat.token(entry.token)) declined=\(drag.liveDragDeclined) "
                    + "resize=\(drag.dwindleResizeWorkspaceId != nil) "
                    + "start=\(TraceFormat.rect(drag.adoptionStartFrame)) live-start=\(TraceFormat.rect(drag.liveStartFrame)) "
                    + "observed=\(TraceFormat.rect(observed)) "
                    + "moved=\(start.flatMap { s in observed.map { Self.isNativeMove(from: s, to: $0) } } ?? false)"
            )
        }
        guard !drag.liveDrag, !drag.liveDragDeclined,
              drag.dwindleResizeWorkspaceId == nil,
              let controller,
              controller.settings.niri.macOSFusion,
              controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              let start = drag.liveStartFrame ?? drag.adoptionStartFrame,
              let observed = entry.axRef.flatMap(nativeWindowFrameProvider),
              Self.isNativeMove(from: start, to: observed),
              let engine = controller.niriEngine,
              let context = liveColumnContext(for: entry.workspaceId),
              let window = engine.findNode(for: entry.token, in: entry.workspaceId)
        else { return false }

        finishPendingLiveStackDrop()
        let layoutStart = controller.niriLayoutHandler.layoutChangeStart(in: entry.workspaceId)
        let began = controller.workspaceManager.withNiriViewportState(for: entry.workspaceId) { viewportState in
            engine.liveColumnMoveBegin(
                windowId: window.id,
                windowToken: entry.token,
                canCarry: hasOtherLiveStrip(than: entry.workspaceId),
                context: context,
                state: &viewportState
            )
        }
        guard began else {
            traceLiveDragDecline("engine-refused token=\(TraceFormat.token(entry.token))")
            drag.liveDragDeclined = true
            return false
        }
        state.liveDragLayoutStart = layoutStart
        liveDragSession = .init(referenceOffset: livePointer.location.map { observed.midX - $0.x })
        drag.liveDrag = true
        drag.adoptionStartFrame = start
        state.deferredClickScroll = nil
        if let location = livePointer.location,
           let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        {
            holdLiveEdgeZone(startingAt: location, monitorFrame: monitor.frame)
        }
        startLiveDragKeyCapture()
        return true
    }

    func startLiveDragKeyCapture() {
        controller?.syncLiveDragPointerHold(active: true)
        liveDragModifierCapture.start { [weak self] flags in
            guard let self, let location = livePointer.location else { return }
            liveDragSession?.modifiers = flags
            updateLiveColumnDrag(at: location)
        }
    }

    nonisolated static func isNativeMove(from start: CGRect, to observed: CGRect) -> Bool {
        let tolerance = FrameTolerance.screenMatch
        let keptSize = abs(observed.width - start.width) <= tolerance
            && abs(observed.height - start.height) <= tolerance
        let moved = abs(observed.minX - start.minX) > tolerance || abs(observed.minY - start.minY) > tolerance
        return keptSize && moved
    }

    func updateLiveColumnDrag(at location: CGPoint, immediate: Bool = false) {
        cancelLiveDragFollowUp()
        guard runLiveColumnDragPass(at: location, immediate: immediate) else { return }
        scheduleLiveDragFollowUp()
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

    private func runLiveColumnDragPass(at location: CGPoint, immediate: Bool) -> Bool {
        guard isLiveColumnDragActive,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.windowToken == (liveDragSession?.tabPull?.token ?? state.nativeTitleBarDrag?.token)
        else {
            endLiveDragSession()
            return false
        }
        let workspaceId = move.workspaceId
        let reference = liveDragReference(location)
        let slowed = livePointerHasSlowed(at: liveDragClock())
        traceLiveDrag(slowed ? "update slowed=1" : "update slowed=0", at: location)
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else {
            cancelLiveColumnDrag()
            return false
        }
        if pointerHasLeft(monitor, at: location) {
            if !carryLiveColumnDrag(from: workspaceId, at: location) {
                MouseTrace.record("live-drag carry refused at=\(TraceFormat.point(location)) from=\(workspaceId)")
                handOverLiveColumnDrag()
            }
            return false
        }
        trackLiveEdgeZone(at: location, monitorFrame: monitor.frame)
        publishLiveDragHold(on: monitor, workspaceId: workspaceId)
        let togglesStackMode = wantsLiveStackMode(move) != move.stackMode
        if let edgeScroll = liveDragSession?.edgeScroll {
            let hopsRun = edgeScroll.hopping || edgeScroll.hopsDone
            if !togglesStackMode,
               hopsRun || !move.stackMode && move.home != .stackSlot
            {
                return false
            }
            if togglesStackMode, hopsRun {
                liveDragSession?.edgeScroll?.delayTimer?.invalidate()
                liveDragSession?.edgeScroll?.hopping = false
                liveDragSession?.edgeScroll?.hopsDone = false
            }
        }
        var immediate = immediate
        if isLiveEdgeScrolling {
            if togglesStackMode, let context = liveColumnContext(for: workspaceId) {
                controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
                    _ = engine.liveColumnMoveStackModeChanged(
                        held: !move.stackMode,
                        cursor: reference,
                        duringEdgeScroll: true,
                        context: context,
                        state: &viewportState
                    )
                }
                return false
            }
            guard !move.stackMode, liveEdgeScrollReachesColumn(
                at: reference,
                time: CACurrentMediaTime(),
                engine: engine,
                workspaceId: workspaceId
            ) else { return false }
            stopLiveEdgeScroll()
            immediate = true
        }
        if move.phase == .settling, !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
            engine.liveColumnMoveSettled()
        }
        guard let context = liveColumnContext(for: workspaceId) else { return false }

        let now = liveDragClock()
        let step = togglesStackMode
            ? controller.workspaceManager.withNiriViewportState(
                for: workspaceId,
                committingIf: { $0.changesLayout },
                {
                    engine.liveColumnMoveStackModeChanged(
                        held: !move.stackMode,
                        cursor: reference,
                        context: context,
                        state: &$0
                    )
                }
            )
            : runLiveColumnMoveUpdate(
                cursor: reference,
                windowMidX: liveDragWindowMidX(location),
                at: now,
                immediate: immediate,
                slowed: slowed,
                engine: engine,
                context: context
            )
        if let until = step.hoverDeadline {
            let stopCheck = livePointerStopCheckDelay(at: now) ?? .infinity
            scheduleLiveHoverCheck(after: min(until - now, stopCheck))
        } else {
            cancelLiveHoverCheck()
        }
        guard step.changesLayout else {
            if step == .unchanged {
                startLiveEdgeScrollIfDue()
            }
            return false
        }
        traceLiveDrag(immediate ? "changed-immediate" : "changed", at: location)
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        guard !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) else { return false }
        engine.liveColumnMoveSettled()
        return true
    }

    private func runLiveColumnMoveUpdate(
        cursor: CGPoint,
        windowMidX: CGFloat?,
        at time: TimeInterval,
        immediate: Bool,
        slowed: Bool,
        engine: NiriLayoutEngine,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Step {
        guard let manager = controller?.workspaceManager,
              let decision = engine.liveColumnMoveDecision(
                  cursor: cursor,
                  windowMidX: windowMidX,
                  at: time,
                  immediate: immediate,
                  slowed: slowed,
                  context: context,
                  state: manager.niriViewportState(for: context.workspaceId)
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

    func wantsLiveStackMode(_ move: LiveColumnMove) -> Bool {
        guard let controller else { return false }
        return Self.mouseMoveModifiersMatch(
            liveDragSession?.modifiers ?? modifierFlagsProvider(),
            required: controller.settings.niri.macOSFusionModifier.cgEventFlags
        )
    }

    func handleNiriAnimationsSettled(in workspaceId: WorkspaceDescriptor.ID) {
        guard let engine = controller?.niriEngine else { return }
        if engine.isLiveStackDropPending(in: workspaceId), engine.liveColumnMove?.workspaceId != workspaceId {
            finishLiveStackDrop(in: workspaceId)
            return
        }
        if isLiveColumnDragActive, let move = engine.liveColumnMove, move.workspaceId == workspaceId {
            if move.phase == .settling {
                engine.liveColumnMoveSettled()
                if let location = livePointer.location {
                    updateLiveColumnDrag(at: location)
                }
            }
            startLiveEdgeScrollIfDue()
        }
        if state.liveDropScroll?.workspaceId == workspaceId {
            runLiveDropScroll()
        }
    }

    func finishLiveColumnDrag(token: WindowToken, releaseFrame releasedFrame: CGRect? = nil) -> Bool {
        let stacking = controller?.niriEngine?.liveColumnMove.map { wantsLiveStackMode($0) } ?? false
        let releasedAt = livePointer.location.map(liveDragReference)
        endLiveDragSession()
        guard let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.windowToken == token
        else { return false }
        guard let context = liveColumnContext(for: move.workspaceId) else {
            MouseTrace.record("live-drag release without context ws=\(move.workspaceId), cancelling")
            state.liveDragLayoutStart = nil
            cancelLiveColumnMove()
            return false
        }

        let workspaceId = move.workspaceId
        let carriedFrom = move.carry?.originalWorkspaceId
        let carriedTokens = move.isWholeColumn
            ? engine.liveDraggedColumn(for: move)?.windowNodes.map(\.token) ?? [token]
            : [token]
        let releaseFrame = releasedFrame
            ?? controller.workspaceManager.entry(for: token).flatMap { $0.axRef.flatMap(nativeWindowFrameProvider) }
        traceLiveStrip("release-before", in: workspaceId, at: livePointer.location)
        let ended = controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            engine.liveColumnMoveEnd(
                releasedFrame: releaseFrame,
                releasedAt: releasedAt,
                stacking: stacking,
                context: context,
                state: &viewportState
            )
        }
        guard ended else { return false }
        traceLiveStrip("release-ended", in: workspaceId, at: livePointer.location)
        if let drop = engine.liveStackDrop, drop.workspaceId == workspaceId,
           let target = engine.liveColumn(withId: drop.targetColumnId, in: workspaceId)
        {
            controller.forgetObservedHeights(of: target.windowNodes.map(\.token))
        }
        controller.workspaceManager.recordLayoutOperation(
            .interactiveMoveEnded(token: token),
            in: workspaceId,
            source: .mouse
        )
        if let carriedFrom, carriedFrom != workspaceId {
            controller.finishLiveDragAcrossDisplays(
                token: token,
                carrying: carriedTokens,
                from: carriedFrom,
                to: workspaceId
            )
            traceLiveStrip("release-handed-to-workspace-move", in: workspaceId, at: nil)
        }
        if engine.isLiveStackDropPending(in: workspaceId) {
            refreshLiveColumnLayout(in: workspaceId, engine: engine)
            if !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
                finishLiveStackDrop(in: workspaceId)
            }
            return true
        }
        recordLiveDragLayoutChange()
        state.liveDropScroll = .init(token: token, workspaceId: workspaceId)
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        if !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
            runLiveDropScroll()
        }
        return true
    }

    func finishInterruptedLiveStackDrop(in workspaceId: WorkspaceDescriptor.ID, whileSettling: Bool = false) {
        guard let controller,
              let engine = controller.niriEngine,
              engine.isLiveStackDropPending(in: workspaceId),
              !whileSettling || engine.isLiveStackDropSettling(in: workspaceId)
        else { return }
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { _ in
            engine.liveStackDropAbandon(in: workspaceId)
        }
        recordLiveDragLayoutChange()
    }

    func finishPendingLiveStackDrop() {
        guard let drop = controller?.niriEngine?.liveStackDrop else { return }
        finishLiveStackDrop(in: drop.workspaceId)
    }

    func finishLiveStackDrop(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let engine = controller.niriEngine,
              let context = liveColumnContext(for: workspaceId)
        else { return }
        let finished = controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            engine.liveStackDropFinish(context: context, state: &viewportState)
        }
        if finished {
            recordLiveDragLayoutChange()
            refreshLiveColumnLayout(in: workspaceId, engine: engine)
        }
    }

    func recordLiveDragLayoutChange() {
        controller?.niriLayoutHandler.recordLayoutChange(since: state.liveDragLayoutStart)
        state.liveDragLayoutStart = nil
    }

    func handOverLiveColumnDrag() {
        cancelLiveColumnDrag()
        state.nativeTitleBarDrag?.liveDragHandedOver = true
    }

    func cancelLiveColumnDrag() {
        MouseTrace.record("live-drag cancel requested active=\(isLiveColumnDragActive)")
        guard isLiveColumnDragActive else { return }
        state.liveDragLayoutStart = nil
        endLiveDragSession()
        state.nativeTitleBarDrag?.liveDragDeclined = true
        cancelLiveColumnMove()
    }

    private func cancelLiveColumnMove() {
        returnCarriedLiveColumnDragHome()
        guard let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              let context = liveColumnContext(for: move.workspaceId)
        else {
            controller?.niriEngine?.endLiveColumnMove()
            return
        }
        let cancelled = controller.workspaceManager.withNiriViewportState(for: move.workspaceId) { viewportState in
            engine.liveColumnMoveCancel(context: context, state: &viewportState)
        }
        if cancelled {
            refreshLiveColumnLayout(in: move.workspaceId, engine: engine)
        }
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

    private func endLiveDragSession() {
        controller?.pointerEdgeBarrier.publishLiveDragHold(nil)
        controller?.syncLiveDragPointerHold(active: false)
        endLiveEdgeScroll()
        liveDragSession?.hoverTimer?.invalidate()
        liveDragSession?.followUp?.invalidate()
        liveDragSession = nil
        state.nativeTitleBarDrag?.liveDrag = false
        livePointer.samples = []
        liveDragModifierCapture.stop()
    }

    private func runLiveDropScroll() {
        guard let pending = state.liveDropScroll else { return }
        state.liveDropScroll = nil
        guard let engine = controller?.niriEngine, engine.liveColumnMove == nil else { return }
        traceLiveStrip("drop-scroll-before", in: pending.workspaceId, at: nil)
        scrollSelectionIntoView(pending.token, in: pending.workspaceId, engine: engine)
        traceLiveStrip("drop-scroll-after", in: pending.workspaceId, at: nil)
    }

    private func scrollSelectionIntoView(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine
    ) {
        guard let controller,
              let window = engine.findNode(for: token, in: workspaceId),
              controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId == window.id,
              let context = liveColumnContext(for: workspaceId)
        else { return }
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            engine.ensureSelectionVisible(node: window, context: context, state: &viewportState)
        }
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
    }

    func refreshLiveColumnLayout(in workspaceId: WorkspaceDescriptor.ID, engine: NiriLayoutEngine) {
        guard let controller else { return }
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
        controller.niriLayoutHandler.startScrollAnimationIfNeeded(
            for: workspaceId,
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            engine: engine
        )
    }

    func hasPendingLiveColumnAnimation(
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine
    ) -> Bool {
        guard let controller else { return false }
        return hasPendingNiriAnimationWork(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            driver: controller.workspaceManager.animationDriver,
            engine: engine,
            workspaceId: workspaceId
        )
    }

    func liveColumnContext(for workspaceId: WorkspaceDescriptor.ID) -> NiriInteractionContext? {
        guard let controller,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else { return nil }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        return NiriInteractionContext(
            workspaceId: workspaceId,
            motion: controller.motionPolicy.snapshot(),
            workingFrame: geometry.workingFrame,
            gaps: geometry.innerGap,
            orientation: resolvedNiriOrientation(engine: engine, workspaceId: workspaceId, monitor: monitor)
        )
    }
}
