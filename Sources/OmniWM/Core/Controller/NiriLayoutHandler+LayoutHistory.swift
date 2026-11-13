// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import QuartzCore

struct NiriLayoutChangeStart {
    let workspaceId: WorkspaceDescriptor.ID
    let snapshots: [WorkspaceDescriptor.ID: NiriLayoutSnapshot]
    let startedAt: TimeInterval
    let sizes: [WindowToken: CGSize]
}

extension NiriLayoutHandler {
    func layoutChangeStart(in workspaceId: WorkspaceDescriptor.ID?) -> NiriLayoutChangeStart? {
        guard let controller,
              controller.settings.niri.macOSFusion,
              let workspaceId,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
              let engine = controller.niriEngine,
              let main = engine.layoutSnapshot(in: workspaceId, focused: focusedToken(in: workspaceId))
        else { return nil }
        var snapshots = [workspaceId: main]
        var sizes = engine.windowSizes(in: workspaceId)
        for other in controller.workspaceManager.workspaces.map(\.id)
            where other != workspaceId && controller.workspaceManager.activeLayoutKind(for: other) == .niri
        {
            snapshots[other] = engine.layoutSnapshot(in: other, focused: focusedToken(in: other))
            sizes.merge(engine.windowSizes(in: other)) { here, _ in here }
        }
        return NiriLayoutChangeStart(
            workspaceId: workspaceId,
            snapshots: snapshots,
            startedAt: layoutStepClock(),
            sizes: sizes
        )
    }

    func activeLayoutChangeStart() -> NiriLayoutChangeStart? {
        layoutChangeStart(in: controller?.activeWorkspace()?.id)
    }

    func recordLayoutChange(since start: NiriLayoutChangeStart?) {
        guard let start, let engine = controller?.niriEngine else { return }
        engine.recordLayoutChanges(
            in: start.workspaceId,
            since: start.snapshots,
            timing: NiriLayoutStepTiming(
                startedAt: start.startedAt,
                recordedAt: layoutStepClock(),
                sizesAtStart: start.sizes
            )
        )
        scheduleOverflowCheck()
    }

    @discardableResult
    func stepLayoutHistory(
        _ direction: NiriLayoutHistoryDirection,
        in requestedWorkspaceId: WorkspaceDescriptor.ID? = nil,
        keepingFocus: Bool = false
    ) -> Bool {
        guard let controller,
              controller.settings.niri.macOSFusion,
              let workspaceId = requestedWorkspaceId ?? layoutHistoryWorkspaceId(),
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
              let engine = controller.niriEngine,
              !engine.isLiveColumnMoveActive(in: workspaceId),
              !engine.isLiveStackDropPending(in: workspaceId),
              !isMouseResizeUnderway(engine: engine)
        else { return false }
        if applyLayoutHistoryStep(
            in: workspaceId,
            keepingFocus: keepingFocus,
            frontsRestoredWindow: !keepingFocus,
            step: { engine, wsId, focused in
                engine.stepLayoutHistory(direction, in: wsId, focused: focused)
            }
        ) {
            return true
        }
        guard let entry = engine.peekLayoutHistory(direction, in: workspaceId) else { return false }
        let transfers = engine.layoutHistoryTransfers(entry, in: workspaceId)
        let focused = focusedToken(in: workspaceId)
        guard !transfers.isEmpty, var inverse = engine.layoutSnapshot(in: workspaceId, focused: focused) else {
            return false
        }
        inverse.away = engine.awayParts(for: transfers.bringIn)
        let drawn = engine.drawnLayout(in: workspaceId)
        for item in transfers.bringIn {
            transferWindow(item.token, to: workspaceId)
        }
        for away in transfers.sendAway
            where controller.workspaceManager.activeLayoutKind(for: away.workspaceId) == .niri
        {
            for token in away.tokens {
                transferWindow(token, to: away.workspaceId)
            }
        }
        let broughtBack = transfers.bringIn.last?.token
        let keyboardFocus = controller.focusedManagedTokenForCommand()
        let followed = broughtBack != nil ? nil : transfers.sendAway.last { isShownOnADisplay($0.workspaceId) }
            .flatMap { away in away.tokens.last.map { (token: $0, workspaceId: away.workspaceId) } }
            .flatMap { followed in !keepingFocus || followed.token == keyboardFocus ? followed : nil }
        let stepped = applyLayoutHistoryStep(
            in: workspaceId,
            drawn: drawn,
            focusedBefore: focused,
            keepingFocus: keepingFocus,
            frontsRestoredWindow: !keepingFocus && followed == nil
        ) { engine, wsId, _ in
            engine.commitTransferredLayoutHistoryStep(direction, in: wsId, inverse: inverse).map { step in
                broughtBack.map { NiriLayoutHistoryStep(focused: $0) } ?? step
            }
        }
        for other in Set(entry.away.map(\.workspaceId) + transfers.bringIn.map(\.from)) {
            requestLayoutCommandRelayout(in: other)
        }
        if stepped, let followed, let window = engine.findNode(for: followed.token, in: followed.workspaceId) {
            controller.workspaceManager
                .withNiriViewportState(for: followed.workspaceId) { $0.selectedNodeId = window.id }
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: window.id,
                focusedToken: window.token,
                in: followed.workspaceId,
                onMonitor: controller.workspaceManager.monitorId(for: followed.workspaceId)
            )
            controller.focusWindow(window.token)
        }
        return stepped
    }

    func isShownOnADisplay(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let manager = controller?.workspaceManager, let monitorId = manager.monitorId(for: workspaceId) else {
            return false
        }
        return manager.activeWorkspace(on: monitorId)?.id == workspaceId
    }

    func layoutHistoryWorkspaceId() -> WorkspaceDescriptor.ID? {
        guard let controller else { return nil }
        if let token = controller.focusedManagedTokenForCommand(),
           let workspaceId = controller.workspaceManager.entry(for: token)?.workspaceId,
           controller.workspaceManager.visibleWorkspaceIds().contains(workspaceId)
        {
            return workspaceId
        }
        return controller.activeWorkspace()?.id
    }

    private func focusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        guard let controller, let engine = controller.niriEngine else { return nil }
        let selected = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
        return selected.flatMap { engine.findNode(by: $0, in: workspaceId) as? NiriWindow }?.token
    }

    private func transferWindow(_ token: WindowToken, to workspaceId: WorkspaceDescriptor.ID) {
        guard let controller, let handle = controller.workspaceManager.handle(for: token) else { return }
        let navigation = controller.workspaceNavigationHandler
        guard let mutation = navigation.moveWindow(handle: handle, toWorkspaceId: workspaceId).mutation else { return }
        navigation.finishWorkspaceMove(mutation, focusPolicy: .retainCurrent)
    }

    private func applyLayoutHistoryStep(
        in workspaceId: WorkspaceDescriptor.ID,
        drawn earlierDrawn: NiriDrawnLayout? = nil,
        focusedBefore: WindowToken? = nil,
        keepingFocus: Bool = false,
        frontsRestoredWindow: Bool = true,
        step: (NiriLayoutEngine, WorkspaceDescriptor.ID, WindowToken?) -> NiriLayoutHistoryStep?
    ) -> Bool {
        guard let controller else { return false }
        var stepped = false
        var fronted: NiriWindow?
        withNiriWorkspaceContext(for: workspaceId) { engine, wsId, motion, state, monitor, workingFrame, gaps, orientation in
            let selected = state.selectedNodeId.flatMap { engine.findNode(by: $0, in: wsId) as? NiriWindow }?.token
            let focused = earlierDrawn == nil ? selected : focusedBefore
            let drawn = earlierDrawn ?? engine.drawnLayout(in: wsId)
            guard let step = step(engine, wsId, focused) else { return }
            let context = NiriInteractionContext(
                workspaceId: wsId,
                motion: motion,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            let kept = keepingFocus ? focused.flatMap { engine.findNode(for: $0, in: wsId) == nil ? nil : $0 } : nil
            if let token = kept ?? step.focused ?? focused, let window = engine.findNode(for: token, in: wsId) {
                state.selectedNodeId = window.id
                if token != focused { fronted = window }
                let span = engine.findColumn(containing: window, in: wsId)
                    .flatMap { engine.columnScreenSpan($0, context: context, state: state) }
                let shown = span.map {
                    $0.lowerBound >= workingFrame.minX - 0.5 && $0.upperBound <= workingFrame.maxX + 0.5
                } ?? false
                if !shown {
                    engine.ensureSelectionVisible(node: window, context: context, state: &state)
                }
            }
            let anchor = state.selectedNodeId.flatMap { engine.findNode(by: $0, in: wsId) as? NiriWindow }
                ?? engine.root(for: wsId)?.allWindows.first
            if let anchor {
                let operation = NiriOperationContext(
                    controller: controller,
                    engine: engine,
                    motion: motion,
                    wsId: wsId,
                    windowNode: anchor,
                    monitor: monitor,
                    orientation: orientation,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
                let now = engine.animationClock?.now() ?? CACurrentMediaTime()
                engine.stopWindowMoveAnimations(in: wsId)
                let settled = operation.settledFrames(state: state)
                engine.animateRestoredWidths(from: drawn, settled: settled, context: context)
                var drawnView = state
                drawnView.viewOffset = controller.workspaceManager.animationDriver.plannedRenderOffset(
                    in: wsId,
                    localState: state,
                    storeOffset: controller.workspaceManager.niriViewportState(for: wsId).viewOffset,
                    at: now
                )
                engine.animateRestoredWindows(
                    from: drawn,
                    start: operation.predictedFrames(state: drawnView, at: now),
                    context: context
                )
            }
            recordLayoutOperation(.columnMoved, in: wsId)
            requestLayoutCommandRelayout(in: wsId)
            startScrollAnimationIfNeeded(for: wsId, state: state, engine: engine)
            stepped = true
        }
        if frontsRestoredWindow, let fronted {
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: fronted.id,
                focusedToken: fronted.token,
                in: workspaceId,
                onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
            )
            controller.focusWindow(fronted.token)
        }
        return stepped
    }
}
