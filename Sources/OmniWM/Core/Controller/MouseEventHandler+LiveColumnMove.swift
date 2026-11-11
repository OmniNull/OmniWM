// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isLiveColumnDragActive: Bool {
        state.nativeTitleBarDrag?.liveDrag == true || state.liveTabPull != nil
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
        if button == .left, state.liveTabPull != nil {
            moveLiveTabPull(to: location)
            return true
        }
        guard button == .left, state.nativeTitleBarDrag != nil else { return false }
        state.liveDragLocation = location
        recordLivePointerSample(location)
        state.liveDragModifiers = nil
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
        if let location = state.liveDragLocation {
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
        state.liveDragReferenceOffset = state.liveDragLocation.map { observed.midX - $0.x }
        drag.liveDrag = true
        drag.adoptionStartFrame = start
        state.deferredClickScroll = nil
        if let location = state.liveDragLocation,
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
            guard let self, let location = state.liveDragLocation else { return }
            state.liveDragModifiers = flags
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

    static let liveDragPassLimit = 4

    static func runLiveDragPasses(immediate: Bool, _ pass: (Bool) -> Bool) -> Bool {
        var immediate = immediate
        for _ in 0 ..< liveDragPassLimit {
            guard pass(immediate) else { return true }
            immediate = false
        }
        return false
    }

    func updateLiveColumnDrag(at location: CGPoint, immediate: Bool = false) {
        let finished = Self.runLiveDragPasses(immediate: immediate) { immediate in
            runLiveColumnDragPass(at: location, immediate: immediate)
        }
        if !finished {
            MouseTrace.record("live-drag passes capped at=\(TraceFormat.point(location))")
        }
    }

    private func runLiveColumnDragPass(at location: CGPoint, immediate: Bool) -> Bool {
        guard isLiveColumnDragActive,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.windowToken == (state.liveTabPull?.token ?? state.nativeTitleBarDrag?.token)
        else {
            endLiveColumnDragTracking()
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
        if let edgeScroll = state.liveEdgeScroll {
            let hopsRun = edgeScroll.hopping || edgeScroll.hopsDone
            if !togglesStackMode,
               hopsRun || !move.stackMode && !move.inStack
            {
                return false
            }
            if togglesStackMode, hopsRun {
                state.liveEdgeScroll?.delayTimer?.invalidate()
                state.liveEdgeScroll?.hopping = false
                state.liveEdgeScroll?.hopsDone = false
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
        let step = controller.workspaceManager.withNiriViewportState(
            for: workspaceId,
            committingIf: { $0.changesLayout },
            {
                togglesStackMode
                    ? engine.liveColumnMoveStackModeChanged(
                        held: !move.stackMode,
                        cursor: reference,
                        context: context,
                        state: &$0
                    )
                    : engine.liveColumnMoveUpdate(
                        cursor: reference,
                        windowMidX: liveDragWindowMidX(location),
                        at: now,
                        immediate: immediate,
                        slowed: slowed,
                        context: context,
                        state: &$0
                    )
            }
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

    func wantsLiveStackMode(_ move: LiveColumnMove) -> Bool {
        guard let controller else { return false }
        return Self.mouseMoveModifiersMatch(
            state.liveDragModifiers ?? modifierFlagsProvider(),
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
                if let location = state.liveDragLocation {
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
        let releasedAt = state.liveDragLocation.map(liveDragReference)
        endLiveColumnDragTracking()
        guard let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.windowToken == token,
              let context = liveColumnContext(for: move.workspaceId)
        else { return false }

        let workspaceId = move.workspaceId
        let carriedFrom = move.carry?.originalWorkspaceId
        let carriedTokens = move.isWholeColumn
            ? engine.liveDraggedColumn(for: move)?.windowNodes.map(\.token) ?? [token]
            : [token]
        let releaseFrame = releasedFrame
            ?? controller.workspaceManager.entry(for: token).flatMap { $0.axRef.flatMap(nativeWindowFrameProvider) }
        traceLiveStrip("release-before", in: workspaceId, at: state.liveDragLocation)
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
        traceLiveStrip("release-ended", in: workspaceId, at: state.liveDragLocation)
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
        endLiveColumnDragTracking()
        state.nativeTitleBarDrag?.liveDragDeclined = true
        returnCarriedLiveColumnDragHome()
        guard let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              let context = liveColumnContext(for: move.workspaceId)
        else {
            controller?.niriEngine?.liveColumnMove = nil
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
        if let timer = state.liveHoverTimer, timer.isValid {
            if abs(timer.fireDate.timeIntervalSince(fireDate)) >= 0.005 {
                timer.fireDate = fireDate
            }
            return
        }
        state.liveHoverTimer = scheduleLiveDragTimer(after: delay) { [weak self] in
            guard let self, let location = state.liveDragLocation else { return }
            state.liveHoverTimer = nil
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
        state.liveHoverTimer?.invalidate()
        state.liveHoverTimer = nil
    }

    private func endLiveColumnDragTracking() {
        controller?.pointerEdgeBarrier.publishLiveDragHold(nil)
        controller?.syncLiveDragPointerHold(active: false)
        clearLiveEdgeZone()
        cancelLiveHoverCheck()
        state.nativeTitleBarDrag?.liveDrag = false
        state.liveTabPull = nil
        state.liveDragModifiers = nil
        clearLiveDragReference()
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
