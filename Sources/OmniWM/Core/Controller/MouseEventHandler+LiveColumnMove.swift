// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isLiveColumnDragActive: Bool {
        state.nativeTitleBarDrag?.liveDrag == true
    }

    func holdsSelectionScroll(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if controller?.niriEngine?.isLiveColumnMoveActive(in: workspaceId) == true { return true }
        guard let token = state.deferredClickScroll,
              pressedMouseButtonsProvider() & MouseButton.left.pressedMask != 0
        else { return false }
        return controller?.workspaceManager.entry(for: token)?.workspaceId == workspaceId
    }

    func deferClickScrollIfPressed(on token: WindowToken) -> Bool {
        guard controller?.settings.niri.naturalWindowDrag == true,
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
        guard button == .left, state.nativeTitleBarDrag != nil else { return false }
        state.liveDragLocation = location
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

    func beginLiveColumnDragIfEligible(
        _ drag: inout MouseInputState.NativeTitleBarDrag,
        entry: WindowState
    ) -> Bool {
        guard !drag.liveDrag, !drag.liveDragDeclined,
              drag.dwindleResizeWorkspaceId == nil,
              let controller,
              controller.settings.niri.naturalWindowDrag,
              controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              let start = drag.adoptionStartFrame,
              let observed = entry.axRef.flatMap(nativeWindowFrameProvider),
              Self.isNativeMove(from: start, to: observed),
              let engine = controller.niriEngine,
              let context = liveColumnContext(for: entry.workspaceId),
              let window = engine.findNode(for: entry.token, in: entry.workspaceId)
        else { return false }

        let began = controller.workspaceManager.withNiriViewportState(for: entry.workspaceId) { viewportState in
            engine.liveColumnMoveBegin(
                windowId: window.id,
                windowToken: entry.token,
                context: context,
                state: &viewportState
            )
        }
        guard began else {
            drag.liveDragDeclined = true
            return false
        }
        drag.liveDrag = true
        state.deferredClickScroll = nil
        return true
    }

    nonisolated static func isNativeMove(from start: CGRect, to observed: CGRect) -> Bool {
        let tolerance = FrameTolerance.screenMatch
        let keptSize = abs(observed.width - start.width) <= tolerance
            && abs(observed.height - start.height) <= tolerance
        let moved = abs(observed.minX - start.minX) > tolerance || abs(observed.minY - start.minY) > tolerance
        return keptSize && moved
    }

    func updateLiveColumnDrag(at location: CGPoint) {
        guard isLiveColumnDragActive,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.windowToken == state.nativeTitleBarDrag?.token
        else {
            endLiveColumnDragTracking()
            return
        }
        let workspaceId = move.workspaceId
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId),
              !pointerHasLeft(monitor, at: location)
        else {
            cancelLiveColumnDrag()
            return
        }
        if move.phase == .settling, !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
            engine.liveColumnMoveSettled()
        }
        guard let context = liveColumnContext(for: workspaceId) else { return }

        let now = liveDragClock()
        let step = controller.workspaceManager.withNiriViewportState(
            for: workspaceId,
            committingIf: { $0 == .changed },
            { engine.liveColumnMoveUpdate(cursor: location, at: now, context: context, state: &$0) }
        )
        if case let .hovering(until) = step {
            scheduleLiveHoverCheck(after: until - now)
            return
        }
        cancelLiveHoverCheck()
        guard step == .changed else { return }
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        if !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
            engine.liveColumnMoveSettled()
            updateLiveColumnDrag(at: location)
        }
    }

    func handleNiriAnimationsSettled(in workspaceId: WorkspaceDescriptor.ID) {
        guard let engine = controller?.niriEngine else { return }
        if isLiveColumnDragActive,
           let move = engine.liveColumnMove,
           move.workspaceId == workspaceId,
           move.phase == .settling
        {
            engine.liveColumnMoveSettled()
            if let location = state.liveDragLocation {
                updateLiveColumnDrag(at: location)
            }
        }
        if state.liveDropScroll?.workspaceId == workspaceId {
            runLiveDropScroll()
        }
    }

    func finishLiveColumnDrag(token: WindowToken) -> Bool {
        endLiveColumnDragTracking()
        guard let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.windowToken == token,
              let context = liveColumnContext(for: move.workspaceId)
        else { return false }

        let workspaceId = move.workspaceId
        let releaseX = controller.workspaceManager.entry(for: token)
            .flatMap { $0.axRef.flatMap(nativeWindowFrameProvider) }?
            .minX
        let ended = controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            engine.liveColumnMoveEnd(releasedAtScreenX: releaseX, context: context, state: &viewportState)
        }
        guard ended else { return false }
        controller.workspaceManager.recordLayoutOperation(
            .interactiveMoveEnded(token: token),
            in: workspaceId,
            source: .mouse
        )
        state.liveDropScroll = .init(token: token, workspaceId: workspaceId)
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        if !hasPendingLiveColumnAnimation(in: workspaceId, engine: engine) {
            runLiveDropScroll()
        }
        return true
    }

    func cancelLiveColumnDrag() {
        guard isLiveColumnDragActive else { return }
        endLiveColumnDragTracking()
        state.nativeTitleBarDrag?.liveDragDeclined = true
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
        if let timer = state.liveHoverTimer, timer.isValid, abs(timer.fireDate.timeIntervalSince(fireDate)) < 0.005 {
            return
        }
        cancelLiveHoverCheck()
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

    private func pointerHasLeft(_ monitor: Monitor, at location: CGPoint) -> Bool {
        let monitors = controller?.workspaceManager.monitors ?? []
        if monitors.contains(where: { $0.id != monitor.id && $0.frame.contains(location) }) { return true }
        let frame = monitor.frame
        return location.x < frame.minX || location.x > frame.maxX
            || location.y < frame.minY || location.y > frame.maxY
    }

    private func endLiveColumnDragTracking() {
        cancelLiveHoverCheck()
        state.nativeTitleBarDrag?.liveDrag = false
    }

    private func runLiveDropScroll() {
        guard let pending = state.liveDropScroll else { return }
        state.liveDropScroll = nil
        guard let engine = controller?.niriEngine, engine.liveColumnMove == nil else { return }
        scrollSelectionIntoView(pending.token, in: pending.workspaceId, engine: engine)
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

    private func refreshLiveColumnLayout(in workspaceId: WorkspaceDescriptor.ID, engine: NiriLayoutEngine) {
        guard let controller else { return }
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
        controller.niriLayoutHandler.startScrollAnimationIfNeeded(
            for: workspaceId,
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            engine: engine
        )
    }

    private func hasPendingLiveColumnAnimation(
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
