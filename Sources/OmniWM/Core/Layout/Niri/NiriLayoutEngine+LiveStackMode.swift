// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnMoveCloseLandingForEdgeScroll(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        assertSanctionedMutation()
        guard var move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              move.landing != nil
        else { return false }
        defer { liveColumnMove = move }
        move.pointerHold = nil
        move.endCentreDwell()
        return placeLiveLanding(nil, move: &move, context: context, state: &state)
    }

    func liveWindowSpans(in column: NiriContainer, context: NiriInteractionContext) -> [LiveColumnMove.WindowSpan] {
        liveWindowSpans(
            in: column,
            windows: projectedWindows(in: column, workspaceId: context.workspaceId),
            context: context
        )
    }

    private func liveWindowSpans(
        in column: NiriContainer,
        windows: borrowing [NiriWindow],
        context: NiriInteractionContext
    ) -> [LiveColumnMove.WindowSpan] {
        guard !windows.isEmpty else { return [] }
        let isTabbed = column.isTabbed && windows.count > 1
        let horizontal = context.orientation == .horizontal
        let available = horizontal ? context.workingFrame.height : availableWindowWidth(
            in: column, projectedWindowCount: windows.count, workingFrame: context.workingFrame
        )
        let spans = resolveWindowSpans(
            container: column,
            windows: windows,
            axis: NiriAxisLayout(
                availableSpace: available,
                gap: context.gaps,
                isTabbed: isTabbed,
                orientation: context.orientation
            ),
            secondarySpanOverride: nil
        )
        var position = context.gaps + (horizontal
            ? context.workingFrame.minY
            : context.workingFrame.maxX - available)
        var result: [LiveColumnMove.WindowSpan] = []
        for (window, span) in zip(windows, spans) {
            result.append(.init(window: window, minY: position, maxY: position + span.value))
            if !isTabbed {
                position += span.value + context.gaps
            }
        }
        return result
    }

    func liveStackDropBegin(
        releasedAt release: CGRect?,
        move: LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let dropped = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow
        guard let landing = move.landing,
              let window = dropped,
              let column = liveColumn(withId: landing.columnId, in: move.workspaceId),
              window.parent === column
        else {
            dropped?.deferredMinimumOrientation = nil
            if let parent = dropped?.parent as? NiriContainer {
                clearLiveSpanOverrides(in: [parent])
                if let dropped {
                    joinHeldLiveTabs(after: dropped, in: parent, move: move, context: context)
                }
            }
            endLiveColumnMove()
            return false
        }
        replaceLiveStackDrop(with: .init(
            workspaceId: move.workspaceId,
            windowId: move.windowId,
            homeColumnId: move.homeColumnId,
            dropSpaceId: move.dropSpaceId,
            targetColumnId: column.id,
            originalViewPosition: move.carry == nil ? move.originalViewPosition : nil
        ))
        endLiveColumnMove()
        slideLiveWindows(in: [column], skipping: window, context: context) {
            clearLiveSpanOverrides(in: [column])
            joinHeldLiveTabs(after: window, in: column, move: move, context: context)
        }
        widenLiveStackForDrop(
            column,
            for: window,
            home: liveColumn(withId: move.homeColumnId, in: move.workspaceId),
            context: context,
            state: &state
        )
        settleLiveWindow(window, in: column, releasedAt: release, context: context, state: &state)
        return true
    }

    func settleLiveWindow(
        _ window: NiriWindow,
        in column: NiriContainer,
        releasedAt release: CGRect?,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        activateWindow(window.id, in: context.workspaceId)
        retargetActiveColumn(to: column, context: context, state: &state)
        state.selectedNodeId = window.id
        if let release,
           let landed = liveWindowFrame(of: window, in: column, context: context, state: state)
        {
            animateLiveWindow(window, from: release, to: landed, leavingColumnVertically: true, context: context)
        }
    }

    func liveStackDropAbandon(in workspaceId: WorkspaceDescriptor.ID) {
        guard liveStackDrop?.workspaceId == workspaceId else { return }
        assertSanctionedMutation()
        endLiveStackDrop()
    }

    func liveStackDropFinish(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        assertSanctionedMutation()
        guard let drop = liveStackDrop, drop.workspaceId == context.workspaceId else { return false }
        guard let target = liveColumn(withId: drop.targetColumnId, in: drop.workspaceId) else {
            endLiveStackDrop()
            return false
        }
        let before = primaryPositions(context: context, state: state)
        endLiveStackDrop()
        animateLiveColumnChange(from: before, anchoredOn: target, context: context, state: &state)
        retargetActiveColumn(to: target, context: context, state: &state)
        if let original = drop.originalViewPosition,
           let landed = primaryPositions(context: context, state: state)[target.id],
           isLiveColumnFullyVisible(target, atOffset: original - landed, context: context, state: state)
        {
            var atOriginal = state
            atOriginal.jumpOffset(to: original - landed)
            let centring = fittingStripDrift(liveColumnStrip(context: context, state: atOriginal), context: context)
            state.animateToOffset(
                original - landed + (centring ?? 0),
                motion: context.motion,
                scale: displayScale(in: context.workspaceId)
            )
            return true
        }
        let revealed = state.viewOffset + liveEdgeRevealShift(
            showing: target,
            checking: [.before, .after],
            slack: 0,
            strip: liveColumnStrip(context: context, state: state),
            context: context
        )
        var final = liveDropFinalView(of: drop.windowId, settledAt: revealed, context: context, state: state)
        final.jumpOffset(to: final.viewOffset + liveStripEndsShift(context: context, state: final))
        state.animateToOffset(final.viewOffset, motion: context.motion, scale: displayScale(in: context.workspaceId))
        return true
    }

    private func liveStripEndsShift(context: NiriInteractionContext, state: ViewportState) -> CGFloat {
        let strip = liveColumnStrip(context: context, state: state)
        if let centred = fittingStripDrift(strip, context: context) {
            return centred
        }
        guard let ends = stripEndsDrift(strip: strip, context: context) else { return 0 }
        if ends.lowest > 0 {
            return ends.lowest
        }
        guard keptStripEndsDrift(strip: strip, context: context) != nil else { return 0 }
        return min(0, ends.highest)
    }

    func endLiveColumnMove() {
        replaceLiveColumnMove(with: nil)
    }

    func replaceLiveColumnMove(with move: LiveColumnMove?) {
        let previous = liveColumnMove
        liveColumnMove = move
        if let previous {
            releaseLivePlaceholders(of: previous)
        }
    }

    func endLiveStackDrop() {
        replaceLiveStackDrop(with: nil)
    }

    func replaceLiveStackDrop(with drop: LiveColumnMove.StackDrop?) {
        let previous = liveStackDrop
        liveStackDrop = drop
        if let previous {
            releaseLivePlaceholders(of: previous)
        }
    }

    private func releaseLivePlaceholders(of previous: LiveColumnMove) {
        if let slot = previous.narrowedSlot,
           liveColumnMove?.narrowedSlot?.columnId != slot.columnId,
           liveStackDrop?.homeColumnId != slot.columnId
        {
            widenLiveSlot(slot, in: previous.workspaceId)
        }
        if let dropSpaceId = previous.dropSpaceId,
           liveColumnMove?.dropSpaceId != dropSpaceId,
           liveStackDrop?.dropSpaceId != dropSpaceId
        {
            removeLivePlaceholder(dropSpaceId, in: previous.workspaceId)
        }
        if liveColumnMove == nil, liveStackDrop?.homeColumnId != previous.homeColumnId {
            removeLivePlaceholder(previous.homeColumnId, in: previous.workspaceId)
        }
        if liveColumnMove == nil, liveStackDrop?.windowId != previous.windowId {
            if let kept = previous.keptWidths {
                kept.restore(in: ensureState(for: previous.workspaceId))
            }
            if let saved = previous.mateHeight,
               let mate = findNode(by: saved.windowId, in: previous.workspaceId) as? NiriWindow,
               mate.secondarySizing(orientation: saved.orientation) != saved.height
            {
                saved.apply(to: mate)
            }
        }
    }

    private func releaseLivePlaceholders(of previous: LiveColumnMove.StackDrop) {
        if liveStackDrop?.homeColumnId != previous.homeColumnId {
            removeLivePlaceholder(previous.homeColumnId, in: previous.workspaceId)
        }
        if let dropSpaceId = previous.dropSpaceId, liveStackDrop?.dropSpaceId != dropSpaceId {
            removeLivePlaceholder(dropSpaceId, in: previous.workspaceId)
        }
    }

    func isLiveStackDropPending(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        liveStackDrop?.workspaceId == workspaceId
    }

    func slideLiveWindows<Result>(
        in columns: [NiriContainer],
        skipping skipped: NiriWindow,
        context: NiriInteractionContext,
        _ change: () -> Result
    ) -> Result {
        let before = liveWindowPlaces(in: columns, context: context)
        let result = change()
        let after = liveWindowPlaces(in: columns, context: context)
        for (id, previous) in before where id != skipped.id {
            guard let current = after[id],
                  let node = findNode(by: id, in: context.workspaceId) as? NiriWindow
            else { continue }
            animateLiveWindow(node, from: previous, to: current, context: context)
        }
        return result
    }

    func isLiveHeldTab(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let heldTabs = liveColumnMove?.heldTabs, !heldTabs.isEmpty,
              liveColumnMove?.workspaceId == workspaceId
        else { return false }
        for tab in heldTabs where tab.token == token {
            return true
        }
        return false
    }

    func liveHeldTabTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        guard let move = liveColumnMove, move.workspaceId == workspaceId, !move.heldTabs.isEmpty else { return [] }
        return Set(move.heldTabs.map(\.token))
    }

    func joinHeldLiveTabs(
        after window: NiriWindow,
        in column: NiriContainer,
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) {
        guard !move.heldTabs.isEmpty else { return }
        var previous = window
        for tab in move.heldTabs where tab !== window && findNode(for: tab.token, in: move.workspaceId) === tab {
            tab.detach()
            column.insertAfter(tab, reference: previous)
            tab.isHiddenInTabbedMode = column.isTabbed
            previous = tab
        }
        guard !column.isTabbed else { return }
        for member in column.windowNodes {
            member.setSecondarySizing(.default, orientation: context.orientation)
        }
    }

    func liveStackChoice(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.StackChoice {
        guard let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow else { return .keep }
        guard let column = liveColumn(in: strip, at: cursor, ignoring: liveDropSpace(for: move), context: context),
              column.id != move.homeColumnId || move.home == .stackSlot,
              projectedWindows(in: column, workspaceId: move.workspaceId).contains(where: { $0 !== window })
        else { return .home }

        if column.isTabbed {
            guard let shown = projectedActiveWindow(in: column, workspaceId: move.workspaceId),
                  shown !== window else { return .home }
            return .land(.init(columnId: column.id, targetWindowId: shown.id, above: false))
        }
        let spans = liveWindowSpans(in: column, context: context)
        let secondary = context.secondaryCoordinate(of: cursor)
        guard let nearest = spans.min(by: { $0.distance(toY: secondary) < $1.distance(toY: secondary) })
        else { return .home }
        if nearest.window === window {
            return .keep
        }
        let others = spans.filter { $0.window !== window }
        guard let hitIndex = others.firstIndex(where: { $0.window === nearest.window }) else { return .home }
        let hit = others[hitIndex]
        let above = secondary >= (hit.minY + hit.maxY) / 2
        guard !above, hitIndex > 0 else {
            return .land(.init(columnId: column.id, targetWindowId: hit.window.id, above: above))
        }
        return .land(.init(columnId: column.id, targetWindowId: others[hitIndex - 1].window.id, above: true))
    }

    func isLiveStackSuppressed(
        at cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> Bool {
        guard let hold = move.pointerHold,
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let column = window.parent as? NiriContainer,
              liveColumn(in: strip, at: cursor, ignoring: liveDropSpace(for: move), context: context) === column
        else { return false }
        return hold.holds(at: cursor)
    }

    func holdsLiveStackSuppression(
        _ move: inout LiveColumnMove,
        at cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> Bool {
        guard move.pointerHold != nil else { return false }
        if isLiveStackSuppressed(at: cursor, strip: strip, move: move, context: context) { return true }
        move.pointerHold = nil
        return false
    }

    func armLiveStackSuppression(_ move: inout LiveColumnMove, at cursor: CGPoint, context: NiriInteractionContext) {
        guard let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let column = window.parent as? NiriContainer,
              !column.isTabbed
        else { return }
        let secondary = context.secondaryCoordinate(of: cursor)
        let slot = liveWindowSpans(in: column, context: context).first { $0.window === window }
        if slot?.contains(y: secondary) != true {
            move.pointerHold = .init(point: cursor)
        }
    }

    func liveWindowPlaces(
        in columns: [NiriContainer],
        context: NiriInteractionContext
    ) -> [NodeId: CGRect] {
        var places: [NodeId: CGRect] = [:]
        for column in columns {
            let windows = projectedWindows(in: column, workspaceId: context.workspaceId)
            let tilesX = projectedTilesOrigin(displayMode: column.displayMode, visibleWindowCount: windows.count).x
            for span in liveWindowSpans(in: column, windows: windows, context: context) {
                places[span.window.id] = context.orientation == .horizontal
                    ? CGRect(x: tilesX, y: span.minY, width: 0, height: span.maxY - span.minY)
                    : CGRect(x: span.minY, y: 0, width: span.maxY - span.minY, height: 0)
            }
        }
        return places
    }

    func liveWindowFrame(
        of window: NiriWindow,
        in column: NiriContainer,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> CGRect? {
        guard let placed = liveColumnStrip(context: context, state: state).first(where: { $0.column === column }),
              let place = liveWindowPlaces(in: [column], context: context)[window.id]
        else { return nil }
        let frame = context.orientation == .horizontal
            ? CGRect(x: placed.minX + place.minX, y: place.minY, width: placed.width - place.minX, height: place.height)
            : CGRect(x: place.minX, y: placed.minX, width: place.width, height: placed.width)
        return frame.roundedToPhysicalPixels(scale: displayScale(in: context.workspaceId))
    }

    func animateLiveViewShift(_ shift: CGFloat, context: NiriInteractionContext, state: inout ViewportState) {
        guard abs(shift) > 0.001 else { return }
        state.animateToOffset(
            state.viewOffset + shift,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
    }

    func animateLiveWindow(
        _ window: NiriWindow,
        from previous: CGRect,
        to current: CGRect,
        leavingColumnVertically: Bool = false,
        context: NiriInteractionContext
    ) {
        let displacement = CGPoint(x: previous.minX - current.minX, y: previous.minY - current.minY)
        let heightDelta = previous.height - current.height
        let moves = abs(displacement.x) > 0.001 || abs(displacement.y) > 0.001
        let resizesHeight = previous.height > 0 && abs(heightDelta) > 0.5
        let widthDelta = previous.width - current.width
        let resizesWidth = context.orientation == .vertical && previous.width > 0 && abs(widthDelta) > 0.5
        guard moves || resizesHeight || resizesWidth else { return }
        let config = context.motion.scaled(windowMovementAnimationConfig)
        let refreshRate = displayRefreshRate(in: context.workspaceId)
        if moves {
            window.animateMoveFrom(
                displacement: displacement,
                leavingColumnIn: leavingColumnVertically ? context.orientation : nil,
                clock: animationClock,
                config: config,
                displayRefreshRate: refreshRate,
                animated: context.motion.animationsEnabled
            )
        }
        if resizesHeight {
            window.animateHeightFrom(
                delta: heightDelta,
                clock: animationClock,
                config: config,
                displayRefreshRate: refreshRate,
                animated: context.motion.animationsEnabled
            )
        }
        if resizesWidth {
            window.animateWidthFrom(
                delta: widthDelta,
                clock: animationClock,
                config: config,
                displayRefreshRate: refreshRate,
                animated: context.motion.animationsEnabled
            )
        }
    }
}
