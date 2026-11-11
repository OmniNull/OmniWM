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
              context.orientation == .horizontal,
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
        let windowSizing = LiveColumnMove.WindowSizing(size: window.size, height: window.height)
        liveColumnMove = LiveColumnMove(
            windowId: windowId,
            windowToken: windowToken,
            workspaceId: context.workspaceId,
            homeColumnId: column.id,
            isWholeColumn: isWholeColumn,
            pullsTab: pullsTab,
            home: inStack ? .stackSlot : .origin,
            homeSlotIndex: index,
            originalSlot: .init(
                columnId: column.id,
                index: index,
                displayMode: column.displayMode,
                activeTileIdx: column.activeTileIdx,
                windowSizing: windowSizing
            ),
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
            cursor: cursor,
            windowMidX: windowMidX,
            at: time,
            immediate: immediate,
            slowed: slowed,
            context: context,
            state: state
        ) else { return .unchanged }
        return applyLiveColumnMoveDecision(decision, context: context, state: &state)
    }

    func liveColumnMoveDecision(
        cursor: CGPoint,
        windowMidX: CGFloat? = nil,
        at time: TimeInterval,
        immediate: Bool = false,
        slowed: Bool = false,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> LiveColumnMove.Decision? {
        guard let move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              liveDraggedColumn(for: move) != nil
        else { return nil }
        var decision = LiveColumnMove.Decision(
            move: move,
            pointer: .init(cursor: cursor, time: immediate ? nil : time, slowed: slowed),
            strip: liveColumnStrip(context: context, state: state)
        )
        decision.closing = liveClosingSlotDecision(
            windowMidX: windowMidX ?? cursor.x,
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
        guard decision.action.passiveStep != nil else { return decision }
        decision.narrowing = liveNarrowingDecision(strip: decision.strip, move: decision.move, context: context)
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
                strip: current,
                move: decision.move,
                context: context,
                state: &state
            )
        }
        let narrowStrip = step == .changed ? liveColumnStrip(context: context, state: state) : current
        let narrowing = decision.closing == nil && decision.action.passiveStep != nil
            ? decision.narrowing
            : liveColumnMove.flatMap { liveNarrowingDecision(strip: narrowStrip, move: $0, context: context) }
        let narrowed = narrowing.map { placeLiveSlot($0, in: narrowStrip, context: context, state: &state) != nil }
            ?? false
        guard closed || narrowed else { return step }
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
        return applyLiveAction(action, pointer: pointer, strip: strip, move: move, context: context, state: &state)
    }

    private func liveStepDecision(
        _ pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Action {
        guard let dragged = liveDraggedColumn(for: move) else { return .nothing }
        let cursor = pointer.cursor
        let time = pointer.time
        let immediate = time == nil

        let dropSpace = liveDropSpace(for: move)
        noteLiveHeading(&move, at: cursor.x)
        if let action = liveSpecialModeDecision(pointer: pointer, strip: strip, move: &move, context: context) {
            return action
        }
        let previousDwell = move.dwell
        move.endSideDwell()
        let homeClosed = move.originClosedToward != nil
        let underPointer = liveColumnOrStripEnd(
            in: homeClosed ? strip.filter { $0.column !== dragged } : strip,
            at: cursor,
            ignoring: dropSpace,
            context: context
        )
        let overDropSpace = strip.contains { $0.column === dropSpace && $0.contains(x: cursor.x) }
        move.passed = move.passed.map { $0.extended(to: cursor.x) }.flatMap { passed in
            !passed.hasComeBack(at: cursor.x) && (overDropSpace || underPointer?.id == passed.columnId)
                ? passed
                : nil
        }
        let side = underPointer.map {
            liveTargetSide(
                $0,
                cursor: cursor,
                strip: strip,
                awayFromHome: immediate && move.carry == nil,
                context: context
            )
        } ?? .after
        if let underPointer, move.lockedTarget != .init(columnId: underPointer.id, side: side) {
            move.lockedTarget = nil
        }
        guard let target = liveTarget(
                  underPointer,
                  side: side,
                  dragged: dragged,
                  homeClosed: homeClosed,
                  dropSpace: dropSpace,
                  justPassed: move.passed?.columnId
              ),
              move.lockedTarget != .init(columnId: target.id, side: side)
        else {
            return .nothing
        }
        let delay = liveHoverDelay
        if let time, delay > 0 {
            let since = previousDwell?.start(on: target.id, in: .side(side)) ?? time
            let until = since + delay
            guard pointer.slowed || time >= until else {
                move.dwell = .init(columnId: target.id, region: .side(side), since: since)
                return .hovering(until: until)
            }
        }
        let pinned = livePinnedColumn(
            under: underPointer,
            target: target,
            excluding: [dragged, dropSpace].compactMap(\.self),
            heading: move.heading,
            strip: strip,
            cursor: cursor
        )
        let besideHome = liveNeighbour(of: target, on: side) === dragged
        let kind: LiveColumnMove.Reorder.Kind
        if target === dragged, let dropSpace {
            kind = .closeDropSpace(dropSpace, revealsHome: false)
        } else if let dropSpace, besideHome, !homeClosed {
            kind = .closeDropSpace(dropSpace, revealsHome: true)
        } else if move.carry != nil {
            kind = .carried
        } else {
            kind = .openDropSpace(
                existing: dropSpace,
                beside: besideHome && homeClosed ? dragged : target,
                triesHomeSpot: !immediate && move.home != .origin
            )
        }
        return .reorder(.init(dragged: dragged, target: target, side: side, pinned: pinned, kind: kind))
    }

    private func applyLiveAction(
        _ action: LiveColumnMove.Action,
        pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        var move = move
        defer { liveColumnMove = move }
        return performLiveAction(action, pointer: pointer, strip: strip, move: &move, context: context, state: &state)
    }

    func performLiveAction(
        _ action: LiveColumnMove.Action,
        pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
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
        case let .placeStackLanding(landing):
            guard placeLiveLanding(landing.map { .gap($0) }, move: &move, context: context, state: &state) else {
                return .unchanged
            }
            if landing != nil {
                armLiveStackSuppression(&move, at: cursor, context: context)
            }
            move.phase = .settling
            return .changed
        case let .leaveStack(towardTrailingSide, revealsToEdgeOnly):
            guard leaveLiveStack(
                towardTrailingSide: towardTrailingSide,
                revealsToEdgeOnly: revealsToEdgeOnly,
                cursor: cursor,
                move: &move,
                context: context,
                state: &state
            ) else { return .unchanged }
            move.endPointerHold(.stackLock)
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
        case let .showHint(landing, tracesRefusal):
            guard showLiveLandingHint(landing, move: &move, context: context, state: &state) else {
                if tracesRefusal {
                    traceLiveStackRefusalDetail("hint-not-placed x=\(Int(cursor.x.rounded()))")
                }
                return .unchanged
            }
            return .changed
        case let .switchHint(columnId, dwellSince):
            closeLiveLandingHint(move: &move, context: context, state: &state)
            move.dwell = dwellSince.map { .init(columnId: columnId, region: .centre, since: $0) }
            return .changed
        case let .reorder(reorder):
            return applyLiveReorder(reorder, cursor: cursor, strip: strip, move: &move, context: context, state: &state)
        }
    }

    private func applyLiveReorder(
        _ reorder: LiveColumnMove.Reorder,
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        let dragged = reorder.dragged
        let target = reorder.target
        let side = reorder.side
        switch reorder.kind {
        case let .closeDropSpace(dropSpace, revealsHome):
            closeLiveDropSpace(dropSpace, anchor: reorder.pinned, context: context, state: &state)
            move.dropSpaceId = nil
            if revealsHome {
                scrollLiveLandingUnderPointer(dragged, target: target, cursor: cursor, context: context, state: &state)
            }
            return markLiveChange(&move, target: target, side: side)
        case .carried:
            guard moveLiveSpot(dragged, beside: target, side: side, as: .carried, context: context, state: &state)
            else { return .unchanged }
            scrollLiveLandingUnderPointer(dragged, target: target, cursor: cursor, context: context, state: &state)
            return markLiveChange(&move, target: target, side: side)
        case let .openDropSpace(dropSpace, beside, triesHomeSpot):
            if triesHomeSpot,
               moveLiveSpot(
                   dragged,
                   beside: target,
                   side: side,
                   as: .homeSpot(removing: dropSpace, pinning: reorder.pinned),
                   context: context,
                   state: &state
               )
            {
                move.dropSpaceId = nil
                return markLiveChange(
                    &move,
                    target: target,
                    side: side,
                    passed: livePassed(target, side: side, strip: strip, cursor: cursor)
                )
            }
            guard let opened = openLiveDropSpace(
                existing: dropSpace,
                beside: beside,
                side: side,
                anchor: reorder.pinned,
                context: context,
                state: &state
            ) else { return .unchanged }
            move.dropSpaceId = opened.id
            move.pulledStripEnd = scrollLiveLandingUnderPointer(
                opened,
                target: target,
                cursor: cursor,
                pulledEnd: move.pulledStripEnd,
                context: context,
                state: &state
            )
            return markLiveChange(&move, target: target, side: side)
        }
    }

    @discardableResult
    func scrollLiveLandingUnderPointer(
        _ landing: NiriContainer,
        target: NiriContainer,
        cursor: CGPoint,
        pulledEnd: LiveColumnMove.Side? = nil,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Side? {
        let reveal = liveLandingReveal(
            showing: landing,
            besideTargetUnder: (target, cursor),
            strip: liveColumnStrip(context: context, state: state),
            pulledEnd: pulledEnd,
            context: context
        )
        state.animateToOffset(
            state.viewOffset + reveal.shift,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
        return reveal.pulledEnd
    }

    func closeOpenLiveDropSpace(
        move: inout LiveColumnMove,
        anchor: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard let dropSpace = liveDropSpace(for: move) else { return }
        closeLiveDropSpace(dropSpace, anchor: anchor, context: context, state: &state)
        move.dropSpaceId = nil
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

    private func livePinnedColumn(
        under underPointer: NiriContainer?,
        target: NiriContainer,
        excluding excluded: [NiriContainer],
        heading: LiveColumnMove.Side?,
        strip: [LiveColumnMove.StripColumn],
        cursor: CGPoint
    ) -> NiriContainer {
        let windows = strip.filter { placed in
            !placed.column.isLiveDropSpace && !excluded.contains { $0 === placed.column }
        }
        if let underPointer, windows.contains(where: { $0.column === underPointer && $0.contains(x: cursor.x) }) {
            return underPointer
        }
        let ahead = heading == .before
            ? windows.last { $0.maxX <= cursor.x }
            : windows.first { $0.minX >= cursor.x }
        return ahead?.column ?? target
    }

    func liveLandingReveal(
        showing column: NiriContainer,
        besideTargetUnder pointer: (target: NiriContainer, cursor: CGPoint),
        strip: [LiveColumnMove.StripColumn],
        pulledEnd: LiveColumnMove.Side?,
        context: NiriInteractionContext
    ) -> (shift: CGFloat, pulledEnd: LiveColumnMove.Side?) {
        guard let landing = strip.first(where: { $0.column === column }),
              let target = strip.first(where: { $0.column === pointer.target })
        else { return (0, pulledEnd) }
        let leadingEdge = context.workingFrame.minX + context.gaps
        let trailingEdge = context.workingFrame.maxX - context.gaps
        let pull = landing.width + context.gaps
        let opensStripStart = strip.first?.column === column
        let opensStripEnd = strip.last?.column === column
        let pullsStart = column.isLiveDropSpace && opensStripStart && pulledEnd != .before
        let pullsEnd = column.isLiveDropSpace && opensStripEnd && pulledEnd != .after
        let edgeScrollReveals = liveColumnMove.map { $0.pointerInEdgeZone || $0.edgeScrollSide != nil } ?? false
        let wanted: CGFloat
        if pullsStart {
            wanted = min(-pull, landing.minX - leadingEdge)
        } else if pullsEnd {
            wanted = max(pull, landing.maxX - trailingEdge)
        } else if landing.maxX <= context.workingFrame.minX || opensStripStart && landing.minX < leadingEdge - 0.5 {
            wanted = landing.minX - leadingEdge
        } else if landing.minX >= context.workingFrame.maxX || opensStripEnd && landing.maxX > trailingEdge + 0.5 {
            wanted = landing.maxX - trailingEdge
        } else {
            return (0, pulledEnd)
        }
        let pointerX = pointer.cursor.x
        var lowest = min(0, min(landing.minX, target.minX) - pointerX)
        var highest = max(0, max(landing.maxX, target.maxX) - pointerX - 1)
        let slidesInWhole = edgeScrollReveals && (pullsStart || pullsEnd)
        if !slidesInWhole, target.width >= MoveConfiguration.liveCentreMinimumWidth - 0.5 {
            let third = target.width / 3
            if pointerX >= target.maxX - third {
                lowest = max(lowest, min(0, target.maxX - third - pointerX + 1))
            } else if pointerX < target.minX + third {
                highest = min(highest, max(0, target.minX + third - pointerX - 1))
            }
        }
        let shift = wanted.clamped(to: lowest ... highest)
        if pullsStart, shift < -0.5 {
            return (shift, .before)
        }
        if pullsEnd, shift > 0.5 {
            return (shift, .after)
        }
        return (shift, pulledEnd)
    }

    private func liveSpecialModeDecision(
        pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Action? {
        let cursor = pointer.cursor
        if move.stackMode {
            return liveStackDecision(cursor: cursor, strip: strip, move: &move, context: context)
        }
        guard !waitsForPointerMove(&move, at: cursor) else { return .nothing }
        if move.home == .stackSlot {
            return liveInStackDecision(cursor: cursor, strip: strip, move: &move, context: context)
        }
        return liveCentreDecision(pointer: pointer, strip: strip, move: &move, context: context)
    }

    func liveDropSpaceWidth(context: NiriInteractionContext) -> CGFloat {
        min(
            context.workingFrame.width * MoveConfiguration.liveDropSpaceShare,
            MoveConfiguration.liveDropSpaceMaximumWidth
        )
    }

    private func waitsForPointerMove(_ move: inout LiveColumnMove, at cursor: CGPoint) -> Bool {
        guard move.isStill(at: cursor) else {
            move.endPointerHold(.modifierRelease)
            return false
        }
        return true
    }

    private func markLiveChange(
        _ move: inout LiveColumnMove,
        target: NiriContainer,
        side: LiveColumnMove.Side,
        passed: LiveColumnMove.Passed? = nil
    ) -> LiveColumnMove.Step {
        if let passed {
            move.passed = passed
        }
        move.lockedTarget = .init(columnId: target.id, side: side)
        move.phase = .settling
        return .changed
    }

    func liveDropSpace(for move: LiveColumnMove) -> NiriContainer? {
        guard let dropSpaceId = move.dropSpaceId else { return nil }
        return liveColumn(withId: dropSpaceId, in: move.workspaceId)
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

    func liveEdgeScrollLimit(
        towardTrailingEdge: Bool,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> CGFloat? {
        guard isLiveColumnMoveActive(in: context.workspaceId) else { return nil }
        let strip = liveColumnStrip(context: context, state: state)
        guard let range = liveStripScrollRange(strip: strip, context: context) else { return nil }
        let pixel = 1.0 / displayScale(in: context.workspaceId)
        let shift = towardTrailingEdge ? range.upperBound : range.lowerBound
        guard abs(shift) >= pixel else { return nil }
        return state.viewOffset + shift
    }

    func liveColumnMoveHop(
        towardTrailingEdge: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriContainer? {
        guard var move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              !move.stackMode,
              move.home != .stackSlot,
              let dragged = liveDraggedColumn(for: move),
              let root = root(for: context.workspaceId)
        else { return nil }
        defer { replaceLiveColumnMove(with: move) }
        let hinted = move.showsLandingHint ? move.landing
            .flatMap { liveColumn(withId: $0.slot.columnId, in: move.workspaceId) } : nil
        if move.showsLandingHint {
            closeLiveLandingHint(move: &move, context: context, state: &state)
        }
        let dropSpace = liveDropSpace(for: move)
        let side: LiveColumnMove.Side = towardTrailingEdge ? .after : .before
        let columns = root.children.compactMap { $0 as? NiriContainer }
        guard let anchorIndex = columns.firstIndex(where: { $0 === (dropSpace ?? dragged) }) else { return nil }
        let strip = liveColumnStrip(context: context, state: state)
        let frame = context.workingFrame
        let placedById = Dictionary(
            strip.map { (ObjectIdentifier($0.column), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let placedColumn: (NiriContainer) -> LiveColumnMove.StripColumn? = { placedById[ObjectIdentifier($0)] }
        let isWindow: (NiriContainer) -> Bool = {
            $0 !== dragged && !$0.isLiveDropSpace && !$0.isLiveHomeSpot && placedColumn($0) != nil
        }
        let homeBeyondView = dropSpace == nil && hinted == nil && placedColumn(dragged).map { home in
            towardTrailingEdge ? home.minX >= frame.maxX - 0.5 : home.maxX <= frame.minX + 0.5
        } == true
        let ahead: [NiriContainer] = if homeBeyondView {
            towardTrailingEdge ? columns : columns.reversed()
        } else if towardTrailingEdge {
            Array(columns[(anchorIndex + 1)...])
        } else {
            Array(columns[..<anchorIndex].reversed())
        }
        let behindView: (LiveColumnMove.StripColumn) -> Bool = towardTrailingEdge
            ? { $0.maxX <= frame.minX + 0.5 }
            : { $0.minX >= frame.maxX - 0.5 }
        let onScreen: (LiveColumnMove.StripColumn) -> Bool = {
            $0.maxX > frame.minX + 0.5 && $0.minX < frame.maxX - 0.5
        }
        let windowsAhead = ahead.filter(isWindow).drop { placedColumn($0).map(behindView) ?? false }
        let reachable = windowsAhead.prefix { placedColumn($0).map(onScreen) ?? false }
        let passed = hinted ?? reachable.last ?? windowsAhead.first
        let beside: NiriContainer
        if let passed {
            beside = passed
        } else if dropSpace == nil, move.originClosedToward != nil {
            beside = dragged
        } else {
            return nil
        }
        let landing: NiriContainer
        if beside !== dragged,
           dragged.isLiveHomeSpot,
           move.home != .origin,
           moveLiveSpot(
               dragged,
               beside: beside,
               side: side,
               as: move.carry != nil ? .carried : .homeSpot(removing: dropSpace, pinning: beside),
               context: context,
               state: &state
           )
        {
            move.dropSpaceId = nil
            landing = dragged
        } else {
            guard let opened = openLiveDropSpace(
                existing: dropSpace,
                beside: beside,
                side: side,
                anchor: beside,
                context: context,
                state: &state
            ) else { return nil }
            move.dropSpaceId = opened.id
            landing = opened
        }
        let shift = liveEdgeRevealShift(
            showing: landing,
            checking: [side],
            slack: 0.5,
            strip: liveColumnStrip(context: context, state: state),
            context: context
        )
        animateLiveViewShift(shift, context: context, state: &state)
        move.endSideDwell()
        _ = markLiveChange(&move, target: beside, side: side)
        return beside
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

    func liveColumnMoveEnd(
        releasedFrame: CGRect? = nil,
        releasedAt cursor: CGPoint? = nil,
        stacking: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard var move = liveColumnMove, move.workspaceId == context.workspaceId else { return false }
        restoreWidenedLiveColumn(move.carry?.widenedColumn)
        if stacking, move.landing == nil, let cursor,
           !liveColumnMoveLandAtRelease(cursor, move: &move, context: context, state: &state)
        {
            liveColumnMoveToStripEnd(at: cursor, move: &move, context: context, state: &state)
        }
        if stacking || move.showsLandingHint, move.landing != nil {
            return liveStackDropBegin(
                releasedAt: releasedFrame,
                move: move,
                context: context,
                state: &state
            )
        }
        if move.landing != nil {
            placeLiveLanding(nil, move: &move, context: context, state: &state)
            liveColumnMove = move
        }
        if move.home == .stackSlot {
            return liveInStackEnd(
                releasedAt: releasedFrame,
                move: move,
                context: context,
                state: &state
            )
        }
        if let cursor {
            _ = liveColumnMoveUpdate(cursor: cursor, at: 0, immediate: true, context: context, state: &state)
            move = liveColumnMove ?? move
        }
        let dropSpace = liveDropSpace(for: move)
        guard let dragged = liveDraggedColumn(for: move) else {
            endLiveColumnMove()
            return true
        }

        retargetActiveColumn(to: dragged, context: context, state: &state)
        let before = primaryPositions(context: context, state: state)
        let viewBefore = liveViewPosition(positions: before, context: context, state: state)
        let landingBefore = dropSpace.flatMap { before[$0.id] }
            ?? before[dragged.id].map { $0 - (move.narrowedSlot?.leftCut ?? 0) }
        if let dropSpace,
           let root = root(for: context.workspaceId),
           let landingIndex = root.children.firstIndex(where: { $0 === dropSpace })
        {
            root.insertChild(dragged, at: landingIndex)
        }
        endLiveColumnMove()
        dragged.isLiveHomeSpot = false
        restoreLiveSizing(move.ownSizing, to: dragged)
        let tilesOrigin = projectedTilesOrigin(
            displayMode: dragged.displayMode,
            visibleWindowCount: projectedWindows(in: dragged, workspaceId: context.workspaceId).count
        )
        let releasedAt = viewBefore.flatMap { view in
            releasedFrame.map { $0.minX - tilesOrigin.x - context.workingFrame.minX + view }
        }
        animateLiveColumnChange(
            from: before,
            anchoredOn: dragged,
            animatingAnchorFrom: releasedAt ?? landingBefore,
            context: context,
            state: &state
        )
        growLiveWindowAfterDrop(move.windowId, in: dragged, releasedAt: releasedFrame, context: context, state: state)
        if let landed = primaryPositions(context: context, state: state)[dragged.id] {
            let preDragOffset = move.originalViewPosition - landed
            let stayOffset = viewBefore.flatMap { view in landingBefore.map { view - $0 } } ?? state.viewOffset
            let settledOffset = isLiveColumnFullyVisible(
                dragged,
                atOffset: preDragOffset,
                context: context,
                state: state
            )
                ? preDragOffset
                : stayOffset
            let final = liveDropFinalView(of: move.windowId, settledAt: settledOffset, context: context, state: state)
            let columns = columns(in: context.workspaceId)
            if final.activeColumnIndex != state.activeColumnIndex, columns.indices.contains(final.activeColumnIndex) {
                retargetActiveColumn(to: columns[final.activeColumnIndex], context: context, state: &state)
            }
            state.animateToOffset(
                final.viewOffset,
                motion: context.motion,
                scale: displayScale(in: context.workspaceId)
            )
        }
        state.selectedNodeId = move.windowId
        return true
    }

    func liveDropFinalView(
        of windowId: NodeId,
        settledAt offset: CGFloat,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> ViewportState {
        var settled = state
        settled.jumpOffset(to: offset)
        guard let window = findNode(by: windowId, in: context.workspaceId) else { return settled }
        settled.selectedNodeId = windowId
        ensureSelectionVisible(node: window, context: context, state: &settled)
        return settled
    }

    private func growLiveWindowAfterDrop(
        _ windowId: NodeId,
        in column: NiriContainer,
        releasedAt release: CGRect?,
        context: NiriInteractionContext,
        state: ViewportState
    ) {
        guard let release = release.flatMap({ liveReleaseOnScreen($0, context: context) }),
              let window = findNode(by: windowId, in: context.workspaceId) as? NiriWindow,
              let landed = liveWindowFrame(of: window, in: column, context: context, state: state)
        else { return }
        let start = CGRect(x: landed.minX, y: release.minY, width: landed.width, height: release.height)
        animateLiveWindow(window, from: start, to: landed, context: context)
    }

    func restoreLiveSizing(_ sizing: NiriContainerSizingState, to column: NiriContainer) {
        guard containerSizingState(for: column) != sizing else { return }
        applyContainerSizingState(sizing, to: column)
    }

    func liveViewPosition(
        positions: [NodeId: CGFloat],
        context: NiriInteractionContext,
        state: ViewportState
    ) -> CGFloat? {
        let columns = columns(in: context.workspaceId)
        guard columns.indices.contains(state.activeColumnIndex),
              let activePosition = positions[columns[state.activeColumnIndex].id]
        else { return nil }
        return activePosition + state.viewOffset
    }

    func isLiveColumnFullyVisible(
        _ column: NiriContainer,
        atOffset offset: CGFloat,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> Bool {
        var probe = state
        probe.viewOffset = offset
        guard let placed = liveColumnStrip(context: context, state: probe).first(where: { $0.column === column })
        else { return false }
        return placed.isFullyVisible(in: context.workingFrame)
    }

    func liveColumnMoveCancel(
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard var move = liveColumnMove, move.workspaceId == context.workspaceId else { return false }
        guard let root = root(for: context.workspaceId), liveDraggedColumn(for: move) != nil else {
            endLiveColumnMove()
            return false
        }
        if move.landing != nil {
            placeLiveLanding(nil, move: &move, context: context, state: &state)
        }
        if let original = liveColumn(withId: move.originalSlot.columnId, in: context.workspaceId) {
            retargetActiveColumn(to: original, context: context, state: &state)
        }
        restoreLiveOriginalSlot(&move)
        liveColumnMove = move
        guard let dragged = liveDraggedColumn(for: move) else {
            endLiveColumnMove()
            return false
        }

        let before = primaryPositions(context: context, state: state)
        endLiveColumnMove()
        let columnsById = Dictionary(uniqueKeysWithValues: root.columns.map { ($0.id, $0) })
        let restoredOrder = move.originalColumnOrder.compactMap { columnsById[$0] }
        for (index, column) in restoredOrder.enumerated() {
            root.insertChild(column, at: index)
        }
        restoreLiveSizing(move.ownSizing, to: dragged)
        animateLiveColumnChange(from: before, anchoredOn: dragged, context: context, state: &state)

        let original = move.originalViewport
        let columns = columns(in: context.workspaceId)
        if let originalActive = columns.first(where: { $0.id == move.originalActiveColumnId }) {
            retargetActiveColumn(to: originalActive, context: context, state: &state)
            state.animateToOffset(
                original.viewOffset,
                motion: context.motion,
                scale: displayScale(in: context.workspaceId)
            )
        }
        state.selectedNodeId = original.selectedNodeId
        return true
    }

    func liveColumnStrip(
        context: NiriInteractionContext,
        state: ViewportState
    ) -> [LiveColumnMove.StripColumn] {
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let geometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        guard let anchor = projectedViewportAnchor(state: state, geometry: geometry, in: context.workspaceId)
        else { return [] }
        let viewPosition = anchor.primaryPosition + state.viewOffset
        return geometry.columns.map { column in
            let minX = context.workingFrame.minX + column.primaryPosition - viewPosition
            let span = projectedPrimarySpan(
                for: column.projectedColumn,
                workingFrame: context.workingFrame,
                gap: context.gaps,
                orientation: context.orientation
            )
            return LiveColumnMove.StripColumn(column: column.projectedColumn.column, minX: minX, maxX: minX + span)
        }
    }

    func liveColumn(
        in strip: [LiveColumnMove.StripColumn],
        at cursor: CGPoint,
        ignoring dropSpace: NiriContainer?
    ) -> NiriContainer? {
        strip.first { $0.column !== dropSpace && $0.contains(x: cursor.x) }?.column
    }

    private func liveTarget(
        _ underPointer: NiriContainer?,
        side: LiveColumnMove.Side,
        dragged: NiriContainer,
        homeClosed: Bool,
        dropSpace: NiriContainer?,
        justPassed: NodeId?
    ) -> NiriContainer? {
        guard let target = underPointer, target.id != justPassed else { return nil }
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

    func liveTargetSide(
        _ target: NiriContainer,
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        awayFromHome: Bool,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Side {
        guard let placed = strip.first(where: { $0.column === target }) else { return .after }
        if awayFromHome, let ahead = liveColumnMove?.edgeScrollSide {
            return ahead
        }
        let visibleMinX = max(placed.minX, context.workingFrame.minX)
        let visibleMaxX = min(placed.maxX, context.workingFrame.maxX)
        let middle = visibleMaxX > visibleMinX ? (visibleMinX + visibleMaxX) / 2 : placed.midX
        return cursor.x < middle ? .before : .after
    }

    private func liveNeighbour(of column: NiriContainer, on side: LiveColumnMove.Side) -> NiriContainer? {
        (side == .before ? column.prevSibling() : column.nextSibling()) as? NiriContainer
    }

    func liveDraggedColumn(for move: LiveColumnMove) -> NiriContainer? {
        guard findNode(by: move.windowId, in: move.workspaceId) is NiriWindow else { return nil }
        return liveColumn(withId: move.homeColumnId, in: move.workspaceId)
    }

    func liveColumn(withId id: NodeId, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer? {
        findNode(by: id, in: workspaceId) as? NiriContainer
    }

    func removeLivePlaceholder(_ columnId: NodeId, in workspaceId: WorkspaceDescriptor.ID) {
        guard let column = liveColumn(withId: columnId, in: workspaceId),
              column.windowNodes.isEmpty,
              column.isLiveDropSpace || column.isLiveHomeSpot
        else { return }
        column.remove()
    }

    private func openLiveDropSpace(
        existing: NiriContainer?,
        beside target: NiriContainer,
        side: LiveColumnMove.Side,
        anchor: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriContainer? {
        guard let root = root(for: context.workspaceId),
              root.children.contains(where: { $0 === target }),
              root.children.contains(where: { $0 === anchor })
        else { return nil }
        retargetActiveColumn(to: anchor, context: context, state: &state)
        let before = primaryPositions(context: context, state: state)
        let dropSpace = existing ?? {
            let column = NiriContainer()
            column.isLiveDropSpace = true
            column.width = .fixed(liveDropSpaceWidth(context: context))
            return column
        }()
        dropSpace.detach()
        guard let targetIndex = root.children.firstIndex(where: { $0 === target }) else { return nil }
        root.insertChild(dropSpace, at: side == .before ? targetIndex : targetIndex + 1)
        dropSpace.cachedWidth = 0
        animateLivePinnedChange(from: before, pinning: anchor, context: context, state: &state)
        return dropSpace
    }

    private func moveLiveSpot(
        _ column: NiriContainer,
        beside target: NiriContainer,
        side: LiveColumnMove.Side,
        as spot: LiveColumnMove.SpotMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let root = root(for: context.workspaceId),
              column !== target,
              root.children.contains(where: { $0 === target }),
              root.children.contains(where: { $0 === column })
        else { return false }
        let anchor: NiriContainer
        switch spot {
        case .carried:
            anchor = target
        case let .homeSpot(_, pinned):
            guard column.isLiveHomeSpot,
                  isLiveColumnFullyVisible(column, atOffset: state.viewOffset, context: context, state: state)
            else { return false }
            anchor = pinned
        }
        retargetActiveColumn(to: anchor, context: context, state: &state)
        let before = primaryPositions(context: context, state: state)
        if case let .homeSpot(dropSpace?, _) = spot {
            dropSpace.detach()
        }
        column.detach()
        guard let targetIndex = root.children.firstIndex(where: { $0 === target }) else { return false }
        root.insertChild(column, at: side == .before ? targetIndex : targetIndex + 1)
        switch spot {
        case .carried:
            animateLiveColumnChange(from: before, anchoredOn: anchor, context: context, state: &state)
        case .homeSpot:
            animateLivePinnedChange(from: before, pinning: anchor, context: context, state: &state)
        }
        return true
    }

    private func closeLiveDropSpace(
        _ dropSpace: NiriContainer,
        anchor: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        retargetActiveColumn(to: anchor, context: context, state: &state)
        let before = primaryPositions(context: context, state: state)
        dropSpace.remove()
        animateLivePinnedChange(from: before, pinning: anchor, context: context, state: &state)
    }

    func animateLivePinnedChange(
        from before: [NodeId: CGFloat],
        pinning pinned: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        if let index = columnIndex(of: pinned, in: context.workspaceId) {
            state.activeColumnIndex = index
        }
        let after = primaryPositions(context: context, state: state)
        let drift = (after[pinned.id] ?? 0) - (before[pinned.id] ?? 0)
        for column in columns(in: context.workspaceId) {
            guard let previous = before[column.id], let current = after[column.id] else { continue }
            let displacement = previous - current + drift
            guard abs(displacement) > 0.001 else { continue }
            animateReorderedColumn(column, displacement: displacement, context: context)
        }
    }

    func animateLiveColumnChange(
        from before: [NodeId: CGFloat],
        anchoredOn anchor: NiriContainer,
        animatingAnchorFrom anchorStart: CGFloat? = nil,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let after = rebaseLiveView(from: before, anchoredOn: anchor, context: context, state: &state)
        for column in columns(in: context.workspaceId) {
            let start = column === anchor ? anchorStart ?? before[column.id] : before[column.id]
            guard let previous = start, let current = after[column.id] else { continue }
            let displacement = previous - current
            guard abs(displacement) > 0.001 else { continue }
            animateReorderedColumn(column, displacement: displacement, context: context)
        }
    }

    @discardableResult
    func rebaseLiveView(
        from before: [NodeId: CGFloat],
        anchoredOn anchor: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> [NodeId: CGFloat] {
        if let index = columnIndex(of: anchor, in: context.workspaceId) {
            state.activeColumnIndex = index
        }
        let after = primaryPositions(context: context, state: state)
        if let previous = before[anchor.id], let current = after[anchor.id] {
            state.rebaseOffset(by: previous - current)
        }
        return after
    }

    func retargetActiveColumn(
        to column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard let index = columnIndex(of: column, in: context.workspaceId) else { return }
        let columns = columns(in: context.workspaceId)
        let positions = primaryPositions(context: context, state: state)
        if columns.indices.contains(state.activeColumnIndex),
           let previous = positions[columns[state.activeColumnIndex].id],
           let current = positions[column.id]
        {
            state.rebaseOffset(by: previous - current)
        }
        state.activeColumnIndex = index
    }

    func keepVisibleLiveShift(
        showing column: NiriContainer,
        besideTargetUnder pointer: (target: NiriContainer, cursor: CGPoint),
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> CGFloat {
        guard let landing = strip.first(where: { $0.column === column }),
              let target = strip.first(where: { $0.column === pointer.target }),
              let stripRange = liveStripScrollRange(strip: strip, context: context)
        else { return 0 }
        let leadingEdge = context.workingFrame.minX + context.gaps
        let trailingEdge = context.workingFrame.maxX - context.gaps
        let pointerX = pointer.cursor.x
        let fullyShown = min(landing.maxX - trailingEdge, landing.minX - leadingEdge)
            ... max(landing.maxX - trailingEdge, landing.minX - leadingEdge)
        let wanted: CGFloat = landing.minX < leadingEdge || landing.maxX > trailingEdge
            ? (landing.midX - pointerX).clamped(to: fullyShown)
            : 0
        let underPointer = min(landing.minX, target.minX) ... max(landing.maxX, target.maxX)
        let lowest = max(stripRange.lowerBound, min(0, underPointer.lowerBound - pointerX))
        let highest = min(stripRange.upperBound, max(0, underPointer.upperBound - pointerX - 1))
        return wanted.clamped(to: lowest ... highest)
    }

    func liveEdgeRevealShift(
        showing column: NiriContainer,
        checking edges: [LiveColumnMove.Side],
        slack: CGFloat,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> CGFloat {
        guard let placed = strip.first(where: { $0.column === column }),
              let range = liveStripScrollRange(strip: strip, context: context)
        else { return 0 }
        for edge in edges {
            switch edge {
            case .before:
                let overshoot = placed.minX - (context.workingFrame.minX + context.gaps)
                if overshoot < -slack {
                    return overshoot.clamped(to: range)
                }
            case .after:
                let overshoot = placed.maxX - (context.workingFrame.maxX - context.gaps)
                if overshoot > slack {
                    return overshoot.clamped(to: range)
                }
            }
        }
        return 0
    }

    func liveStripScrollRange(
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> ClosedRange<CGFloat>? {
        guard let drift = stripEndsDrift(strip: strip, context: context) else { return nil }
        return min(0, drift.lowest) ... max(0, drift.highest)
    }

    func keptStripEndsDrift(
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> (lowest: CGFloat, highest: CGFloat)? {
        guard let first = strip.first, let last = strip.last,
              ViewportState.stripEndOffsets(
                  stripSpan: last.maxX - first.minX,
                  viewSpan: context.workingFrame.width,
                  gap: context.gaps
              ) != nil
        else { return nil }
        return stripEndsDrift(strip: strip, context: context)
    }

    func stripEndsDrift(
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> (lowest: CGFloat, highest: CGFloat)? {
        guard let first = strip.first, let last = strip.last else { return nil }
        return (
            first.minX - (context.workingFrame.minX + context.gaps),
            last.maxX - (context.workingFrame.maxX - context.gaps)
        )
    }
}
