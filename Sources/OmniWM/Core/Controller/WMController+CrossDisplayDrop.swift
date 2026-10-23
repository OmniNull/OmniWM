// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WMController {
    func performCrossDisplayDrop(_ drop: CrossDisplayDrop) {
        guard let plan = crossDisplayDropPlan(for: drop) else { return }
        performCrossDisplayDrop(plan)
    }

    func performCrossDisplayDrop(_ plan: CrossDisplayDropPlan) {
        let drop = plan.drop
        let heldSelection = workspaceManager.selectedManagedToken.map(plan.unit.tokens.contains) == true
        workspaceManager.withBatchedCrossWorkspaceDrop(
            into: drop.workspaceId,
            niriWorkspaceIds: plan.niriWorkspaceIds
        ) { states in
            let arrivals = plan.unit.tokens
                .map { CrossWorkspaceDropAssignment(token: $0, workspaceId: drop.workspaceId) }
            switch plan.operation {
            case let .move(placement):
                applyCrossDisplayMove(plan, placement: placement, states: &states)
                return arrivals
            case let .swap(partner):
                applyCrossDisplaySwap(plan, partner: partner, states: &states)
                return arrivals + partner.tokens.map {
                    CrossWorkspaceDropAssignment(token: $0, workspaceId: drop.sourceWorkspaceId)
                }
            }
        }
        finishCrossDisplayDrop(plan, heldSelection: heldSelection)
    }

    private enum DetachedCrossDisplayUnit {
        case niri(NiriTransferredColumn)
        case dwindle(DwindleTransferredTile)
    }

    private func applyCrossDisplayMove(
        _ plan: CrossDisplayDropPlan,
        placement: CrossDisplayDrop.Placement,
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) {
        let drop = plan.drop
        switch detachCrossDisplayUnit(plan, states: &states) {
        case let .niri(column):
            var state = states[drop.workspaceId, default: niriViewportState(for: drop.workspaceId)]
            attachCrossDisplayColumn(column, placement: placement, plan: plan, state: &state)
            states[drop.workspaceId] = state
        case let .dwindle(tile):
            dwindleEngine?.attachTransferredTile(
                tile,
                placement: Self.dwindleTransferPlacement(placement),
                in: drop.workspaceId
            )
        case nil:
            return
        }
        if plan.sourceLayout == .dwindle, plan.targetLayout == .niri {
            releaseDwindleConstraints(for: plan.unit)
        }
    }

    private func detachCrossDisplayUnit(
        _ plan: CrossDisplayDropPlan,
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) -> DetachedCrossDisplayUnit? {
        let token = plan.unit.activeToken
        let source = plan.drop.sourceWorkspaceId
        switch plan.sourceLayout {
        case .niri:
            guard let engine = niriEngine, let node = engine.findNode(for: token, in: source) else { return nil }
            if plan.targetLayout == .dwindle {
                workspaceManager.captureDetachedNiriPlacement(for: token, in: source)
            }
            let sizing = engine.detachWindowForTransfer(
                node,
                from: source,
                sourceState: &states[source, default: niriViewportState(for: source)]
            )
            return plan.targetLayout == .niri
                ? .niri(NiriTransferredColumn(windows: [node], activeIndex: 0, sizing: sizing))
                : .dwindle(DwindleTransferredTile(token: token))
        case .dwindle:
            guard let tile = dwindleEngine?.detachForTransfer(
                token: token,
                wholeTile: plan.unit.isGroup,
                from: source
            ) else {
                return nil
            }
            guard plan.targetLayout == .niri else { return .dwindle(tile) }
            return .niri(niriColumn(for: plan.unit, sizing: admittedNiriContainerSizing(for: token)))
        }
    }

    private func attachCrossDisplayColumn(
        _ column: NiriTransferredColumn,
        placement: CrossDisplayDrop.Placement,
        plan: CrossDisplayDropPlan,
        state: inout ViewportState
    ) {
        guard let engine = niriEngine else { return }
        let workspaceId = plan.drop.workspaceId
        for window in column.windows {
            window.constraints = plan.constraints[window.token] ?? .unconstrained
        }
        let window = column.activeWindow
        if case let .niriStack(target, after) = placement,
           column.windows.count == 1,
           let targetNode = engine.findNode(for: target, in: workspaceId)
        {
            engine.attachTransferredWindow(
                window,
                stackedWith: targetNode,
                after: after,
                in: workspaceId,
                state: &state
            )
        } else {
            let index: Int? = if case let .niriNewColumn(durableIndex) = placement { durableIndex } else { nil }
            engine.attachTransferredColumn(column, atDurableColumnIndex: index, in: workspaceId, state: &state)
        }
        prepareCrossDisplayNiriViewport(for: window, in: workspaceId, state: &state)
    }

    private func applyCrossDisplaySwap(
        _ plan: CrossDisplayDropPlan,
        partner: CrossDisplayDragUnit,
        states: inout [WorkspaceDescriptor.ID: ViewportState]
    ) {
        let source = plan.drop.sourceWorkspaceId
        let target = plan.drop.workspaceId
        var sourceState = states[source, default: niriViewportState(for: source)]
        var targetState = states[target, default: niriViewportState(for: target)]
        defer {
            if plan.sourceLayout == .niri { states[source] = sourceState }
            if plan.targetLayout == .niri { states[target] = targetState }
        }

        switch (plan.sourceLayout, plan.targetLayout) {
        case (.niri, .niri):
            guard let engine = niriEngine,
                  let node = engine.findNode(for: plan.unit.activeToken, in: source),
                  let partnerNode = engine.findNode(for: partner.activeToken, in: target)
            else { return }
            engine.swapWindowsAcrossWorkspaces(
                (node, source),
                (partnerNode, target),
                firstState: &sourceState,
                secondState: &targetState
            )
            node.constraints = plan.constraints[node.token] ?? .unconstrained
            partnerNode.constraints = plan.constraints[partnerNode.token] ?? .unconstrained
            prepareCrossDisplayNiriViewport(for: partnerNode, in: source, state: &sourceState)
            prepareCrossDisplayNiriViewport(for: node, in: target, state: &targetState)
        case (.niri, .dwindle):
            swapAcrossLayouts(
                niri: (plan.unit.activeToken, source),
                dwindle: (partner, target),
                plan: plan,
                niriState: &sourceState
            )
        case (.dwindle, .niri):
            swapAcrossLayouts(
                niri: (partner.activeToken, target),
                dwindle: (plan.unit, source),
                plan: plan,
                niriState: &targetState
            )
        case (.dwindle, .dwindle):
            swapDwindleUnits(plan.unit, in: source, with: partner, in: target)
        }
    }

    private func swapDwindleUnits(
        _ unit: CrossDisplayDragUnit,
        in source: WorkspaceDescriptor.ID,
        with partner: CrossDisplayDragUnit,
        in target: WorkspaceDescriptor.ID
    ) {
        guard let dwindle = dwindleEngine,
              let incoming = dwindle.transferTile(containing: unit.activeToken, wholeTile: unit.isGroup, in: source),
              let outgoing = dwindle.replaceSlot(
                  of: partner.activeToken,
                  wholeTile: partner.isGroup,
                  with: incoming,
                  in: target
              )
        else { return }
        _ = dwindle.replaceSlot(of: unit.activeToken, wholeTile: unit.isGroup, with: outgoing, in: source)
    }

    private func swapAcrossLayouts(
        niri niriSide: (token: WindowToken, workspaceId: WorkspaceDescriptor.ID),
        dwindle dwindleSide: (unit: CrossDisplayDragUnit, workspaceId: WorkspaceDescriptor.ID),
        plan: CrossDisplayDropPlan,
        niriState: inout ViewportState
    ) {
        guard let engine = niriEngine, let dwindle = dwindleEngine,
              let node = engine.findNode(for: niriSide.token, in: niriSide.workspaceId)
        else { return }
        workspaceManager.captureDetachedNiriPlacement(for: niriSide.token, in: niriSide.workspaceId)
        _ = dwindle.replaceSlot(
            of: dwindleSide.unit.activeToken,
            wholeTile: dwindleSide.unit.isGroup,
            with: DwindleTransferredTile(token: niriSide.token),
            in: dwindleSide.workspaceId
        )
        let arrived = niriColumn(for: dwindleSide.unit, sizing: nil)
        for window in arrived.windows {
            window.constraints = plan.constraints[window.token] ?? .unconstrained
        }
        engine.replaceWindowInSlot(
            node,
            with: arrived.windows,
            activeIndex: arrived.activeIndex,
            in: niriSide.workspaceId,
            state: &niriState
        )
        releaseDwindleConstraints(for: dwindleSide.unit)
        prepareCrossDisplayNiriViewport(for: arrived.activeWindow, in: niriSide.workspaceId, state: &niriState)
    }

    private func niriColumn(
        for unit: CrossDisplayDragUnit,
        sizing: NiriContainerSizingState?
    ) -> NiriTransferredColumn {
        NiriTransferredColumn(
            windows: unit.tokens.reversed().map { NiriWindow(token: $0) },
            activeIndex: unit.tokens.count - 1 - unit.activeIndex,
            sizing: sizing
        )
    }

    private func releaseDwindleConstraints(for unit: CrossDisplayDragUnit) {
        for token in unit.tokens {
            dwindleEngine?.releaseConstraintsIfUntracked(token)
        }
    }

    private func prepareCrossDisplayNiriViewport(
        for node: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard let engine = niriEngine, let monitor = workspaceManager.monitor(for: workspaceId) else { return }
        state.selectedNodeId = node.id
        engine.activateWindow(node.id, in: workspaceId)
        if engine.singleWindowLayoutContext(in: workspaceId) != nil {
            niriLayoutHandler.resetViewportForSingleWindowFit(state: &state)
            return
        }
        let geometry = niriSizingGeometry(for: monitor)
        engine.ensureSelectionVisible(
            node: node,
            context: NiriInteractionContext(
                workspaceId: workspaceId,
                motion: motionPolicy.snapshot(),
                workingFrame: geometry.workingFrame,
                gaps: geometry.gaps,
                orientation: geometry.orientation
            ),
            state: &state
        )
    }

    private func finishCrossDisplayDrop(_ plan: CrossDisplayDropPlan, heldSelection: Bool) {
        let drop = plan.drop
        let source = drop.sourceWorkspaceId
        let target = drop.workspaceId
        let token = plan.unit.activeToken
        switch plan.operation {
        case .move:
            workspaceManager.recordLayoutOperation(
                .windowMovedToWorkspace(token: token, to: target), in: source, source: .mouse
            )
            workspaceManager.recordLayoutOperation(.windowInserted(token: token), in: target, source: .mouse)
            recoverSourceFocusAfterMove(
                in: source,
                preferredNodeId: plan.sourceLayout == .niri ? niriViewportState(for: source).selectedNodeId : nil
            )
        case let .swap(partner):
            workspaceManager.recordLayoutOperation(.windowsSwapped, in: source, source: .mouse)
            workspaceManager.recordLayoutOperation(.windowsSwapped, in: target, source: .mouse)
            recoverSourceFocusAfterMove(in: source, preferredToken: partner.activeToken)
        }
        workspaceNavigationHandler.applySessionPatch(workspaceId: target, rememberedFocusToken: token)
        guard let handle = workspaceManager.handle(for: token) else { return }
        let mutation = StructuralMutation(
            sourceWorkspaceId: source,
            destinationWorkspaceId: target,
            selectedHandle: handle,
            scrollWorkspaceId: plan.targetLayout == .niri ? target : nil
        )
        let follows = heldSelection || settings.focus.followsWindowToMonitor
        workspaceNavigationHandler.finishWorkspaceMove(
            mutation,
            focusPolicy: follows ? .configured : .retainCurrent,
            focusOrigin: .pointerSelection
        )
        if mutation.scrollWorkspaceId != nil, let engine = niriEngine {
            niriLayoutHandler.startScrollAnimationIfNeeded(
                for: target,
                state: niriViewportState(for: target),
                engine: engine
            )
        }
    }

    private func admittedNiriContainerSizing(for token: WindowToken) -> NiriContainerSizingState? {
        if let detached = workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState {
            return detached
        }
        return workspaceManager.admissionHints(for: token)?.initialNiriContainerPrimarySpan.flatMap { span in
            niriEngine?.initialContainerSizingState(for: CGFloat(span))
        }
    }

    private func niriViewportState(for workspaceId: WorkspaceDescriptor.ID) -> ViewportState {
        workspaceManager.niriViewportState(for: workspaceId)
    }

    private static func dwindleTransferPlacement(_ placement: CrossDisplayDrop.Placement) -> DwindleTransferPlacement {
        switch placement {
        case let .dwindleBeside(target, direction):
            .beside(target, direction)
        case let .dwindleEdge(direction):
            .workspaceEdge(direction)
        case let .dwindleSplitBoundary(splitId):
            .splitBoundary(splitId)
        case .niriNewColumn,
             .niriStack,
             .swap,
             .workspace:
            .defaultPlacement
        }
    }
}
