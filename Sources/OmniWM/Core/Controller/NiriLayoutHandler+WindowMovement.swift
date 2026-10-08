// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    @discardableResult
    func moveWindow(direction: Direction) -> WindowMoveOutcome {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return .blocked }
        let outcome = moveWindow(handle: handle, direction: direction)
        return commitWindowMoveOutcome(outcome, handle: handle, direction: direction)
    }

    private func commitWindowMoveOutcome(
        _ outcome: StructuralMutationOutcome,
        handle: WindowHandle,
        direction: Direction
    ) -> WindowMoveOutcome {
        commitNormalStructuralMutation(outcome)
        let moveOutcome: WindowMoveOutcome = switch outcome {
        case .changed:
            .movedWithinWorkspace
        case .atWorkspaceEdge:
            .atWorkspaceEdge
        case .unchanged:
            .blocked
        }
        NiriLayoutTrace.record(
            .move,
            workspaceId: controller?.workspaceManager.entry(for: handle.id)?.workspaceId,
            "\(direction) win=\(handle.id.windowId) outcome=\(moveOutcome)"
        )
        return moveOutcome
    }

    func moveWindow(handle: WindowHandle, direction: Direction) -> StructuralMutationOutcome {
        let allowEdgeWrap = !(controller?.settings.focus.moveCrossesMonitorAtEdge ?? false)
        let stacksIntoColumn = controller?.settings.niri.moveWindowStacksIntoColumn ?? true
        var edgeOutcome = WindowMoveOutcome.blocked
        let outcome = performStructuralMutation(handle: handle) { ctx, state in
            let movesAcrossContainers = direction.primaryStep(for: ctx.orientation) != nil
            let usesPredictedAnimation = ctx.orientation == .vertical || !movesAcrossContainers
            edgeOutcome = windowMoveOutcomeAtEdge(
                for: ctx.windowNode,
                direction: direction,
                engine: ctx.engine,
                in: ctx.wsId,
                orientation: ctx.orientation
            )
            if !stacksIntoColumn, movesAcrossContainers,
               let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId),
               ctx.engine.projectedWindows(in: column, workspaceId: ctx.wsId).count == 1
            {
                let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
                guard ctx.engine.moveColumn(
                    column,
                    direction: direction,
                    context: ctx.interactionContext(motion: ctx.motion),
                    state: &state
                ) else {
                    return nil
                }
                ctx.prepareCapturedAnimation(oldFrames: oldFrames)
                return NiriStructuralMutation(movedTokens: [ctx.windowNode.token], operation: .columnMoved)
            }
            let oldFrames = usesPredictedAnimation
                ? ctx.engine.captureWindowFrames(in: ctx.wsId)
                : [:]
            let motion = ctx.orientation == .vertical && movesAcrossContainers
                ? MotionSnapshot.disabled
                : ctx.motion
            guard ctx.engine.moveWindow(
                ctx.windowNode,
                direction: direction,
                context: ctx.interactionContext(motion: motion),
                state: &state,
                allowEdgeWrap: allowEdgeWrap
            ) else {
                return nil
            }

            if usesPredictedAnimation {
                ctx.preparePredictedAnimation(
                    state: state,
                    oldFrames: oldFrames,
                    yContainmentFrame: ctx.orientation == .vertical
                        ? ctx.monitor.frame
                        : nil
                )
            }
            return NiriStructuralMutation(
                movedTokens: [ctx.windowNode.token],
                operation: movesAcrossContainers
                    ? .windowConsumedOrExpelled(token: ctx.windowNode.token)
                    : .windowMovedInColumn(token: ctx.windowNode.token)
            )
        }

        if case .unchanged = outcome, edgeOutcome == .atWorkspaceEdge {
            return .atWorkspaceEdge
        }
        return outcome
    }

    @discardableResult
    func moveWindowWithinContainer(direction: Direction) -> WindowMoveOutcome {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return .blocked }
        return commitWindowMoveOutcome(
            moveWindowWithinContainer(handle: handle, direction: direction),
            handle: handle,
            direction: direction
        )
    }

    func moveWindowWithinContainer(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard let step = direction.secondaryStep(for: .horizontal) else { return .unchanged }
        var edgeOutcome = WindowMoveOutcome.blocked
        let outcome = performStructuralMutation(handle: handle) { ctx, state in
            edgeOutcome = windowMoveOutcomeAtEdge(
                for: ctx.windowNode,
                direction: direction,
                engine: ctx.engine,
                in: ctx.wsId,
                orientation: .horizontal
            )
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveWindowWithinContainer(
                ctx.windowNode,
                step: step,
                in: ctx.wsId
            ) else {
                return nil
            }
            ctx.preparePredictedAnimation(
                state: state,
                oldFrames: oldFrames
            )
            return NiriStructuralMutation(
                movedTokens: [ctx.windowNode.token],
                operation: .windowMovedInColumn(token: ctx.windowNode.token)
            )
        }

        if case .unchanged = outcome, edgeOutcome == .atWorkspaceEdge {
            return .atWorkspaceEdge
        }
        return outcome
    }

    func moveWindowOrToAdjacentWorkspace(direction: Direction) {
        guard direction == .down || direction == .up else { return }
        guard moveWindowWithinContainer(direction: direction) == .atWorkspaceEdge else { return }
        controller?.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: direction)
    }

    func moveWindowOrToAdjacentWorkspace(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .down || direction == .up else { return .unchanged }
        let outcome = moveWindowWithinContainer(handle: handle, direction: direction)
        guard case .atWorkspaceEdge = outcome else { return outcome }
        return controller?.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(
            handle: handle,
            direction: direction
        ) ?? .unchanged
    }

    func consumeTransferredWindow(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        enteringFrom direction: Direction,
        anchorToken: WindowToken?
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        let context = transferredWindowContext(
            workspaceId: workspaceId,
            monitor: monitor,
            engine: engine,
            controller: controller
        )
        var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)

        var consumed = false

        controller.workspaceManager.withEngineMutationScope(in: workspaceId, label: "drag_drop_move") {
            guard let movedNode = engine.findNode(for: token, in: workspaceId),
                  let column = engine.findColumn(containing: movedNode, in: workspaceId)
            else { return }

            movedNode.stopMoveAnimations()

            let anchorColumn = anchorToken
                .flatMap { engine.findNode(for: $0, in: workspaceId) }
                .flatMap { engine.findColumn(containing: $0, in: workspaceId) }

            if let anchorColumn, anchorColumn.id != column.id {
                consumed = engine.consumeWindow(
                    movedNode,
                    into: anchorColumn,
                    enteringFrom: direction,
                    context: context,
                    state: &targetState
                )
            }

            if !consumed {
                activateUnconsumedWindow(
                    movedNode, engine: engine,
                    context: context,
                    state: &targetState
                )
            }
        }

        targetState.cancelAnimation()

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: targetState,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
    }

    private func activateUnconsumedWindow(
        _ movedNode: NiriWindow,
        engine: NiriLayoutEngine,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        engine.activateWindow(movedNode.id, in: context.workspaceId)
        state.selectedNodeId = movedNode.id
        engine.ensureSelectionVisible(
            node: movedNode,
            context: context,
            state: &state
        )
    }

    private func transferredWindowContext(
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        engine: NiriLayoutEngine,
        controller: WMController
    ) -> NiriInteractionContext {
        let workingFrame = controller.niriWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = resolvedOrientation(
            for: workspaceId,
            monitor: monitor,
            engine: engine
        )
        return NiriInteractionContext(
            workspaceId: workspaceId, motion: .disabled, workingFrame: workingFrame,
            gaps: gaps, orientation: orientation
        )
    }
}
