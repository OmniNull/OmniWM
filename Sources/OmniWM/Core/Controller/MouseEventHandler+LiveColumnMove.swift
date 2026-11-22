// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isLiveColumnDragActive: Bool {
        state.nativeTitleBarDrag?.liveDrag == true || liveDragSession?.carriedWindow?.layout == .niri
    }

    func holdsSelectionScroll(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if controller?.niriEngine?.isLiveColumnMoveActive(in: workspaceId) == true { return true }
        guard let token = state.deferredClickScroll,
              pressedMouseButtonsProvider() & MouseButton.left.pressedMask != 0
        else { return false }
        return controller?.workspaceManager.entry(for: token)?.workspaceId == workspaceId
    }

    func deferClickScrollIfPressed(on token: WindowToken) -> Bool {
        guard tracksNativeTitleBarDrag(windowId: token.windowId),
              pressedMouseButtonsProvider() & MouseButton.left.pressedMask != 0
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
        if state.nativeTitleBarDrag?.canStartLiveDwindleDrag == true {
            return trackLiveDwindleDrag(at: location, button: button)
        }
        if button == .left, liveDragSession?.carriedWindow != nil {
            moveCarriedWindow(to: location)
            return true
        }
        guard button == .left,
              let drag = state.nativeTitleBarDrag,
              drag.canStartLiveNiriDrag || drag.liveDrag || drag.liveDragHandedOver
        else { return false }
        livePointer.location = location
        recordLivePointerSample(location)
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
            if state.nativeTitleBarDrag != drag {
                state.nativeTitleBarDrag = drag
            }
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
        if MouseTrace.shared.isActive, !drag.liveDrag {
            traceLiveDragCheck(drag, entry: entry)
        }
        guard !drag.liveDrag, !drag.liveDragDeclined,
              drag.dwindleResizeWorkspaceId == nil,
              drag.canStartLiveNiriDrag,
              let controller,
              controller.isNiriStrip(entry.workspaceId),
              let start = drag.liveStartFrame ?? drag.adoptionStartFrame,
              let observed = entry.axRef.flatMap(nativeWindowFrameProvider),
              Self.isNativeMove(from: start, to: observed),
              let engine = controller.niriEngine,
              let context = liveColumnContext(for: entry.workspaceId),
              let window = engine.findNode(for: entry.token, in: entry.workspaceId)
        else { return false }

        finishPendingLiveStackDrop()
        let layoutStart = liveCrossDisplayMove == nil ? controller.niriLayoutHandler
            .layoutChangeStartCoveringEveryNiriWorkspace(in: entry.workspaceId) : nil
        let began = controller.workspaceManager.withNiriViewportState(for: entry.workspaceId) { viewportState in
            engine.liveColumnMoveBegin(
                windowId: window.id,
                windowToken: entry.token,
                canCarry: liveCrossDisplayMove != nil || hasOtherLiveDisplay(than: context),
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
        liveDragSession = .init(referenceOffset: livePointer.location.map {
            context.primaryStart(of: observed) + context.primarySpan(of: observed) / 2 - context
                .primaryCoordinate(of: $0)
        })
        drag.liveDrag = true
        drag.adoptionStartFrame = start
        state.deferredClickScroll = nil
        if let location = livePointer.location,
           let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        {
            holdLiveEdgeZone(startingAt: location, monitorFrame: monitor.frame, orientation: context.orientation)
        }
        controller.syncLiveDragPointerHold(active: true)
        return true
    }

    private func traceLiveDragCheck(_ drag: MouseInputState.NativeTitleBarDrag, entry: WindowState) {
        guard !drag.liveDragDeclined else {
            traceLiveDragDecline("check token=\(TraceFormat.token(entry.token)) declined=true")
            return
        }
        let start = drag.liveStartFrame ?? drag.adoptionStartFrame
        let observed = entry.axRef.flatMap(nativeWindowFrameProvider)
        traceLiveDragDecline(
            "check token=\(TraceFormat.token(entry.token)) declined=\(drag.liveDragDeclined) "
                + "resize=\(drag.dwindleResizeWorkspaceId != nil) "
                + "start=\(TraceFormat.rect(drag.adoptionStartFrame)) live-start=\(TraceFormat.rect(drag.liveStartFrame)) "
                + "observed=\(TraceFormat.rect(observed)) "
                + "moved=\(start.flatMap { old in observed.map { Self.isNativeMove(from: old, to: $0) } } ?? false)"
        )
    }

    nonisolated static func isNativeMove(from start: CGRect, to observed: CGRect) -> Bool {
        let tolerance = FrameTolerance.screenMatch
        let keptSize = abs(observed.width - start.width) <= tolerance
            && abs(observed.height - start.height) <= tolerance
        let moved = abs(observed.minX - start.minX) > tolerance || abs(observed.minY - start.minY) > tolerance
        return keptSize && moved
    }

    func handleNiriAnimationsSettled(in workspaceId: WorkspaceDescriptor.ID) {
        guard let engine = controller?.niriEngine else { return }
        controller?.niriLayoutHandler.followOverflowMessage(in: workspaceId)
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
            startLiveEdgeHopInterval()
            startLiveEdgeScrollIfDue()
        }
        if state.liveDropScroll?.workspaceId == workspaceId {
            runLiveDropScroll()
        }
        if state.awaitsNativeTitleBarDragTarget {
            recheckUnannotatedDragAfterSlide(in: workspaceId)
        }
    }

    func finishLiveColumnDrag(
        token: WindowToken,
        releaseFrame releasedFrame: CGRect? = nil,
        startSize: CGSize? = nil
    ) -> Bool {
        guard let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.windowToken == token
        else {
            endLiveDragSession()
            return false
        }
        guard let (context, releasedAt) = endLiveDragSession(in: move.workspaceId) else {
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
        let releaseFrame = (
            releasedFrame
                ?? controller.workspaceManager.entry(for: token).flatMap { $0.axRef.flatMap(nativeWindowFrameProvider) }
        ).map { frame in startSize.map { CGRect(origin: frame.origin, size: $0) } ?? frame }
        traceLiveStrip("release-before", in: workspaceId, at: livePointer.location)
        let ended = controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            engine.liveColumnMoveEnd(
                releasedFrame: releaseFrame,
                releasedAt: releasedAt,
                context: context,
                state: &viewportState
            )
        }
        guard ended else { return false }
        traceLiveStrip("release-ended", in: workspaceId, at: livePointer.location)
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
        settleLiveDrop(of: token, in: workspaceId, engine: engine)
        return true
    }

    private func endLiveDragSession(
        in workspaceId: WorkspaceDescriptor.ID
    ) -> (NiriInteractionContext, CGPoint?)? {
        defer { endLiveDragSession() }
        guard let context = liveColumnContext(for: workspaceId) else { return nil }
        let releasedAt = livePointer.location.map { liveDragReference($0, orientation: context.orientation) }
        return (context, releasedAt)
    }

    @inline(__always)
    private func settleLiveDrop(
        of token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine
    ) {
        if engine.isLiveStackDropPending(in: workspaceId) {
            refreshLiveColumnLayout(in: workspaceId, engine: engine)
            if !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
                finishLiveStackDrop(in: workspaceId)
            }
            return
        }
        recordLiveDragLayoutChange()
        state.liveDropScroll = .init(token: token, workspaceId: workspaceId)
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        if !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
            runLiveDropScroll()
        }
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
        if liveCrossDisplayMove?.released == true {
            recordLiveCrossDisplayMove()
        }
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
        controller?.niriLayoutHandler.scheduleOverflowCheck()
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

    func endLiveDragSession() {
        if isCarryingWindowByGesture {
            controller?.layoutRefreshController.carriedWindowDrawStamp = nil
            clearMoveInteractionState()
            livePointer.location = nil
            NSCursor.arrow.set()
        } else {
            controller?.pointerEdgeBarrier.publishLiveDragHold(nil)
            controller?.syncLiveDragPointerHold(active: false)
        }
        endLiveEdgeScroll()
        liveDragSession?.hoverTimer?.invalidate()
        liveDragSession?.followUp?.invalidate()
        liveDragSession = nil
        state.nativeTitleBarDrag?.liveDrag = false
        livePointer.samples = []
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
        let refresh = controller.layoutRefreshController
        refresh.carriedWindowDrawStamp = nil
        refresh.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
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
        return liveColumnContext(for: workspaceId, engine: engine, monitor: monitor, controller: controller)
    }

    func liveColumnContext(
        for workspaceId: WorkspaceDescriptor.ID, engine: NiriLayoutEngine, monitor: Monitor, controller: WMController
    ) -> NiriInteractionContext {
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
