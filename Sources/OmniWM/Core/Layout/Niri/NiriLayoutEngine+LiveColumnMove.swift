// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnMoveBegin(
        windowId: NodeId,
        windowToken: WindowToken,
        pullsTab: Bool = false,
        canCarry: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard liveColumnMove == nil, interactiveMove == nil, interactiveResize == nil,
              let window = findNode(by: windowId, in: context.workspaceId) as? NiriWindow,
              !window.isFullscreen,
              !isExcludedFromProjection(windowToken, in: context.workspaceId),
              let column = findColumn(containing: window, in: context.workspaceId),
              let index = column.windowNodes.firstIndex(where: { $0 === window }),
              !pullsTab || column.isTabbed
        else {
            MouseTrace.record(
                "live-drag begin refused live=\(liveColumnMove != nil) stackDrop=\(liveStackDrop != nil) "
                    + "move=\(interactiveMove != nil) resize=\(interactiveResize != nil) "
                    + "orientation=\(context.orientation) "
                    + "window=\(findNode(by: windowId, in: context.workspaceId) is NiriWindow) "
                    + "excluded=\(isExcludedFromProjection(windowToken, in: context.workspaceId))"
            )
            return false
        }
        let isWholeColumn = column.isTabbed && !pullsTab
        let inStack = projectedWindows(in: column, workspaceId: context.workspaceId).count > 1 && !isWholeColumn
        guard inStack || canCarry || projectedColumns(in: context.workspaceId).count > 1 else {
            MouseTrace.record("live-drag begin refused lone-column")
            return false
        }

        let columns = columns(in: context.workspaceId)
        let positions = primaryPositions(context: context, state: state)
        let activeColumn = columns.indices.contains(state.activeColumnIndex) ? columns[state.activeColumnIndex] : column
        let windowSizing = LiveColumnMove.WindowSizing(height: window.height, windowWidth: window.windowWidth)
        liveColumnMove = LiveColumnMove(
            windowId: windowId,
            windowToken: windowToken,
            workspaceId: context.workspaceId,
            homeColumnId: column.id,
            isWholeColumn: isWholeColumn,
            pullsTab: pullsTab,
            home: inStack ? .stackSlot : .origin,
            homeSlotIndex: index,
            originalSlot: .init(of: column, at: index, windowSizing: windowSizing),
            ownSizing: containerSizingState(for: column),
            ownWindowSizing: windowSizing,
            originalColumnOrder: columns.map(\.id),
            originalViewport: state,
            originalActiveColumnId: activeColumn.id,
            originalViewPosition: (positions[activeColumn.id] ?? 0) + state.viewOffset
        )
        retargetActiveColumn(to: column, context: context, state: &state)
        state.selectedNodeId = windowId
        return true
    }

    func liveColumnMoveUpdate(
        cursor: CGPoint,
        windowMidX: CGFloat? = nil,
        at time: TimeInterval,
        immediate: Bool = false,
        slowed: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        guard let decision = liveColumnMoveDecision(
            .init(cursor: cursor, time: immediate ? nil : time, slowed: slowed),
            windowMidX: windowMidX,
            context: context,
            strip: liveColumnStrip(context: context, state: state)
        ) else { return .unchanged }
        return applyLiveColumnMoveDecision(decision, context: context, state: &state)
    }

    func liveColumnMoveDecision(
        _ pointer: LiveColumnMove.Pointer,
        windowMidX: CGFloat?,
        context: NiriInteractionContext,
        strip: [LiveColumnMove.StripColumn]
    ) -> LiveColumnMove.Decision? {
        guard let move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              liveDraggedColumn(for: move) != nil
        else { return nil }
        var decision = LiveColumnMove.Decision(move: move, pointer: pointer, strip: strip)
        decision.closing = liveClosingSlotDecision(
            windowMidX: windowMidX ?? context.primaryCoordinate(of: pointer.cursor),
            strip: decision.strip,
            move: &decision.move,
            context: context
        )
        guard decision.closing == nil else { return decision }
        decision.action = liveStepDecision(
            decision.pointer,
            strip: decision.strip,
            move: &decision.move,
            context: context
        )
        return decision
    }

    func keepLiveColumnMoveDecision(_ decision: LiveColumnMove.Decision) -> LiveColumnMove.Step? {
        guard let step = decision.passiveStep else { return nil }
        liveColumnMove = decision.move
        return step
    }

    func applyLiveColumnMoveDecision(
        _ decision: LiveColumnMove.Decision,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        var current = decision.strip
        var closed = false
        let step: LiveColumnMove.Step
        if let closing = decision.closing {
            liveColumnMove = decision.move
            if let strip = placeLiveSlot(closing, in: current, context: context, state: &state) {
                current = strip
                closed = true
            }
            step = liveColumnMoveStep(decision.pointer, strip: current, context: context, state: &state)
        } else {
            step = applyLiveAction(
                decision.action,
                pointer: decision.pointer,
                move: decision.move,
                context: context,
                state: &state
            )
        }
        guard closed else { return step }
        if case let .hovering(until) = step {
            return .changedWhileHovering(until: until)
        }
        return .changed
    }

    private func liveColumnMoveStep(
        _ pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        guard var move = liveColumnMove, move.workspaceId == context.workspaceId else { return .unchanged }
        let action = liveStepDecision(pointer, strip: strip, move: &move, context: context)
        return applyLiveAction(action, pointer: pointer, move: move, context: context, state: &state)
    }

    private func liveStepDecision(
        _ pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Action {
        guard let dragged = liveDraggedColumn(for: move) else { return .nothing }
        let cursor = pointer.cursor

        let dropSpace = liveDropSpace(for: move)
        noteLiveHeading(&move, at: context.primaryCoordinate(of: cursor))
        if let action = liveSpecialModeDecision(pointer: pointer, strip: strip, move: &move, context: context) {
            return action
        }
        let previousDwell = move.dwell
        move.endSideDwell()
        let homeClosed = move.originClosedToward != nil
        let underPointer = liveColumnOrStripEnd(
            in: strip, at: cursor,
            ignoring: dropSpace,
            closedHome: homeClosed ? dragged : nil,
            context: context
        )
        let side = livePointerSide(of: underPointer, pointer: pointer, strip: strip, context: context)
        if let underPointer, move.lockedTarget != .init(columnId: underPointer.id, side: side) {
            move.lockedTarget = nil
        }
        guard let target = liveTarget(
                  underPointer,
                  side: side,
                  dragged: dragged,
                  homeClosed: homeClosed,
                  dropSpace: dropSpace
              ),
              move.lockedTarget != .init(columnId: target.id, side: side)
        else {
            return .nothing
        }
        if let until = liveHoverUntil(on: target.id, side: side, since: previousDwell, pointer: pointer, move: &move) {
            return .hovering(until: until)
        }
        let pinned = livePinnedColumn(
            underPointer,
            target: target,
            in: liveWindowColumns(in: strip, besides: dragged, dropSpace),
            heading: move.heading,
            at: context.primaryCoordinate(of: cursor)
        )
        let besideHome = liveNeighbour(of: target, on: side) === dragged
        let kind: LiveColumnMove.ReorderKind = if target === dragged, let dropSpace {
            .closeDropSpace(dropSpace, revealsHome: false)
        } else if let dropSpace, besideHome, !homeClosed {
            .closeDropSpace(dropSpace, revealsHome: true)
        } else {
            .openDropSpace(existing: dropSpace, beside: besideHome && homeClosed ? dragged : target)
        }
        return .reorder(.init(dragged: dragged, target: target, side: side, pinned: pinned, kind: kind))
    }

    private func livePointerSide(
        of underPointer: NiriContainer?,
        pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> LiveColumnMove.Side {
        guard let underPointer else { return .after }
        return liveTargetSide(
            underPointer,
            cursor: pointer.cursor,
            strip: strip,
            awayFromHome: pointer.time == nil,
            context: context
        )
    }

    private func liveHoverUntil(
        on targetId: NodeId,
        side: LiveColumnMove.Side,
        since previousDwell: LiveColumnMove.Dwell?,
        pointer: LiveColumnMove.Pointer,
        move: inout LiveColumnMove
    ) -> TimeInterval? {
        let delay = liveHoverDelay
        guard let time = pointer.time, delay > 0 else { return nil }
        let since = previousDwell?.start(on: targetId, in: .side(side)) ?? time
        let until = since + delay
        guard pointer.slowed || time >= until else {
            move.dwell = .init(columnId: targetId, region: .side(side), since: since)
            return until
        }
        return nil
    }

    private func liveSpecialModeDecision(
        pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Action? {
        let cursor = pointer.cursor
        if move.home == .stackSlot {
            return liveInStackDecision(cursor: cursor, strip: strip, move: &move, context: context)
        }
        return liveCentreDecision(pointer: pointer, strip: strip, move: &move, context: context)
    }

    private func noteLiveHeading(_ move: inout LiveColumnMove, at x: CGFloat) {
        guard let from = move.headingFromX else {
            move.headingFromX = x
            return
        }
        guard abs(x - from) >= 2 else { return }
        move.heading = x > from ? .after : .before
        move.headingFromX = x
    }

    private func liveTarget(
        _ underPointer: NiriContainer?,
        side: LiveColumnMove.Side,
        dragged: NiriContainer,
        homeClosed: Bool,
        dropSpace: NiriContainer?
    ) -> NiriContainer? {
        guard let target = underPointer else { return nil }
        if target === dragged { return dropSpace == nil ? nil : target }
        switch liveNeighbour(of: target, on: side) {
        case let neighbour? where neighbour === dropSpace: return nil
        case let neighbour? where neighbour === dragged && homeClosed:
            guard let dropSpace else { return target }
            return liveNeighbour(of: dragged, on: side) === dropSpace ? nil : target
        case let neighbour? where neighbour === dragged: return dropSpace == nil ? nil : target
        default: return target
        }
    }

    private func liveNeighbour(of column: NiriContainer, on side: LiveColumnMove.Side) -> NiriContainer? {
        (side == .before ? column.prevSibling() : column.nextSibling()) as? NiriContainer
    }

    private func livePinnedColumn(
        _ underPointer: NiriContainer?,
        target: NiriContainer,
        in windows: [LiveColumnMove.StripColumn],
        heading: LiveColumnMove.Side?,
        at primary: CGFloat
    ) -> NiriContainer {
        if let underPointer,
           windows.contains(where: { $0.column === underPointer && $0.contains(x: primary) })
        {
            return underPointer
        }
        let ahead = heading == .before
            ? windows.last { $0.maxX <= primary }
            : windows.first { $0.minX >= primary }
        return ahead?.column ?? target
    }

    private func liveWindowColumns(
        in strip: [LiveColumnMove.StripColumn],
        besides dragged: NiriContainer,
        _ dropSpace: NiriContainer?
    ) -> [LiveColumnMove.StripColumn] {
        strip.filter { !$0.column.isLiveDropSpace && $0.column !== dragged && $0.column !== dropSpace }
    }

    func liveDropSpacePin(
        leaving dragged: NiriContainer,
        beside target: NiriContainer,
        heading: LiveColumnMove.Side?,
        strip: [LiveColumnMove.StripColumn],
        at primary: CGFloat
    ) -> (under: NiriContainer?, pinned: NiriContainer) {
        let under = strip.first { $0.column !== dragged && $0.contains(x: primary) }?.column
        let windows = liveWindowColumns(in: strip, besides: dragged, nil)
        return (
            under,
            livePinnedColumn(under, target: target, in: windows, heading: heading, at: primary)
        )
    }

    private func applyLiveAction(
        _ action: LiveColumnMove.Action,
        pointer: LiveColumnMove.Pointer,
        move: LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        var move = move
        defer { liveColumnMove = move }
        return performLiveAction(action, pointer: pointer, move: &move, context: context, state: &state)
    }

    func performLiveAction(
        _ action: LiveColumnMove.Action,
        pointer: LiveColumnMove.Pointer,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        let cursor = pointer.cursor
        switch action {
        case .nothing:
            return .unchanged
        case let .hovering(until):
            return .hovering(until: until)
        case let .leaveStack(towardTrailingSide):
            guard leaveLiveStack(
                towardTrailingSide: towardTrailingSide,
                cursor: cursor,
                move: &move,
                context: context,
                state: &state
            ) else { return .unchanged }
            move.pointerHold = nil
            move.phase = .settling
            return .changed
        case let .moveInStack(window, home, index):
            moveLiveSlot(window, in: home, to: index, context: context)
            move.homeSlotIndex = index
            armLiveStackSuppression(&move, at: cursor, context: context)
            move.phase = .settling
            return .changed
        case .closeHint:
            closeLiveLandingHint(move: &move, context: context, state: &state)
            return .changed
        case let .showHint(landing):
            guard showLiveLandingHint(landing, move: &move, context: context, state: &state) else {
                return .unchanged
            }
            return .changed
        case let .switchHint(columnId, dwellSince):
            closeLiveLandingHint(move: &move, context: context, state: &state)
            move.dwell = dwellSince.map { .init(columnId: columnId, region: .centre, since: $0) }
            return .changed
        case let .reorder(reorder):
            return applyLiveReorder(reorder, cursor: cursor, move: &move, context: context, state: &state)
        }
    }

    func liveColumnMoveWouldChange(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> Bool {
        guard var move = liveColumnMove, move.workspaceId == context.workspaceId else { return false }
        let action = liveStepDecision(.init(cursor: cursor, time: nil), strip: strip, move: &move, context: context)
        return action.passiveStep == nil
    }

    func isLiveColumnMoveActive(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        liveColumnMove?.workspaceId == workspaceId || isLiveStackDropSettling(in: workspaceId)
    }

    func isLiveStackDropSettling(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard liveStackDrop?.workspaceId == workspaceId else { return false }
        return hasAnyColumnAnimationsRunning(in: workspaceId) || hasAnyWindowAnimationsRunning(in: workspaceId)
    }

    func isLiveDraggedWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let move = liveColumnMove else { return false }
        return move.windowToken == token && move.workspaceId == workspaceId
    }

    func isLiveDraggedColumn(_ column: NiriContainer) -> Bool {
        guard let move = liveColumnMove, !move.pullsTab else { return false }
        return liveDraggedColumn(for: move) === column
    }

    func liveColumnMoveSettled() {
        liveColumnMove?.phase = .dragging
    }

    func liveColumnMoveEdgeScrolls(toward side: LiveColumnMove.Side?) {
        liveColumnMove?.edgeScrollSide = side
    }

    func liveColumnMovePointerInEdgeZone(_ inZone: Bool) {
        liveColumnMove?.pointerInEdgeZone = inZone
    }
}
