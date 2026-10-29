// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnMoveBegin(
        windowId: NodeId,
        windowToken: WindowToken,
        pullsTab: Bool = false,
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
        else { return false }
        let isWholeColumn = column.isTabbed && !pullsTab
        let inStack = projectedWindows(in: column, workspaceId: context.workspaceId).count > 1 && !isWholeColumn
        guard inStack || projectedColumns(in: context.workspaceId).count > 1 else { return false }

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
            inStack: inStack,
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
        liveColumnMove?.sideBySideIds = sideBySideVisibleColumns(around: column, context: context, state: state)
        retargetActiveColumn(to: column, context: context, state: &state)
        state.selectedNodeId = windowId
        return true
    }

    func liveColumnMoveUpdate(
        cursor: CGPoint,
        at time: TimeInterval,
        immediate: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        guard let move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              liveDraggedColumn(for: move) != nil
        else { return .unchanged }
        let strip = liveColumnStrip(context: context, state: state)
        let closed = closeLiveSlotAroundPointer(cursor: cursor, strip: strip, context: context, state: &state)
        let current = closed ?? strip
        let step = liveColumnMoveStep(
            cursor: cursor,
            at: immediate ? nil : time,
            strip: current,
            context: context,
            state: &state
        )
        let narrowed = narrowOffScreenHomeSlot(strip: step == .changed ? nil : current, context: context, state: &state)
        return closed != nil || narrowed ? .changed : step
    }

    private func liveColumnMoveStep(
        cursor: CGPoint,
        at time: TimeInterval?,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        guard var move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              let dragged = liveDraggedColumn(for: move)
        else { return .unchanged }
        defer { liveColumnMove = move }
        let immediate = time == nil

        let dropSpace = liveDropSpace(for: move)
        if let step = liveSpecialModeUpdate(
            cursor: cursor,
            strip: strip,
            move: &move,
            context: context,
            state: &state
        ) {
            return step
        }
        let previousHover = move.hover
        move.hover = nil
        if liveFreeArea(at: cursor, strip: strip, move: move, context: context) != nil {
            return .unchanged
        }
        let underPointer = liveColumnOrStripEnd(in: strip, at: cursor, ignoring: dropSpace, context: context)
        let overDropSpace = strip.contains { $0.column === dropSpace && $0.contains(x: cursor.x) }
        move.passed = move.passed.map { $0.extended(to: cursor.x) }.flatMap { passed in
            !passed.hasComeBack(at: cursor.x) && (overDropSpace || underPointer?.id == passed.columnId)
                ? passed
                : nil
        }
        let side = underPointer.map {
            liveTargetSide($0, cursor: cursor, strip: strip, home: dragged, awayFromHome: immediate, context: context)
        } ?? .after
        if let underPointer, move.lockedTarget != .init(columnId: underPointer.id, side: side) {
            move.lockedTarget = nil
        }
        guard let target = liveTarget(
                  underPointer,
                  side: side,
                  dragged: dragged,
                  dropSpace: dropSpace,
                  justPassed: move.passed?.columnId
              ),
              move.lockedTarget != .init(columnId: target.id, side: side)
        else {
            return .unchanged
        }
        let delay = moveConfiguration.liveHoverDelay
        if let time, delay > 0 {
            let hover = previousHover?.columnId == target.id && previousHover?.side == side
                ? previousHover
                : .init(columnId: target.id, side: side, since: time)
            let until = (hover?.since ?? time) + delay
            guard time >= until else {
                move.hover = hover
                return .hovering(until: until)
            }
        }
        let sideBySide = move.sideBySideIds.contains(target.id)
        let passed = livePassed(target, side: side, strip: strip, cursor: cursor)

        if target === dragged, let dropSpace {
            closeLiveDropSpace(dropSpace, home: dragged, context: context, state: &state)
            move.dropSpaceId = nil
            releaseLiveStripEnd(&move, context: context, state: &state)
            return markLiveChange(&move, target: target, side: side)
        }
        if let dropSpace, liveNeighbour(of: target, on: side) === dragged {
            closeLiveDropSpace(dropSpace, home: dragged, context: context, state: &state)
            move.dropSpaceId = nil
            releaseLiveStripEnd(&move, context: context, state: &state)
            scrollLiveLandingUnderPointer(dragged, target: target, cursor: cursor, context: context, state: &state)
            return markLiveChange(&move, target: target, side: side, passed: sideBySide ? passed : nil)
        }
        if !immediate,
           !sideBySide,
           moveLiveHomeSpot(dragged, beside: target, side: side, removing: dropSpace, context: context, state: &state)
        {
            move.dropSpaceId = nil
            return markLiveChange(&move, target: target, side: side, passed: passed)
        }
        guard let opened = openLiveDropSpace(
            existing: dropSpace,
            beside: target,
            side: side,
            home: dragged,
            context: context,
            state: &state
        ) else { return .unchanged }
        move.dropSpaceId = opened.id
        holdLiveStripEnd(
            &move,
            opening: dropSpace == nil,
            beside: target,
            side: side,
            home: dragged,
            strip: strip,
            context: context,
            state: &state
        )
        scrollLiveLandingUnderPointer(opened, target: target, cursor: cursor, context: context, state: &state)
        return markLiveChange(&move, target: target, side: side, passed: sideBySide ? passed : nil)
    }

    private func scrollLiveLandingUnderPointer(
        _ landing: NiriContainer,
        target: NiriContainer,
        cursor: CGPoint,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let shift = keepVisibleLiveShift(
            showing: landing,
            besideTargetUnder: (target, cursor),
            strip: liveColumnStrip(context: context, state: state),
            context: context
        )
        state.animateToOffset(
            state.viewOffset + shift,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
    }

    private func holdLiveStripEnd(
        _ move: inout LiveColumnMove,
        opening: Bool,
        beside target: NiriContainer,
        side: LiveColumnMove.Side,
        home: NiriContainer,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard opening, !move.dropSpaceKeepsStripEnd, side == .after else { return }
        let windows = strip.filter { !$0.column.isLiveDropSpace }
        guard windows.count == 2,
              windows.first?.column === home,
              windows.last?.column === target,
              windows.allSatisfy({ $0.isFullyVisible(in: context.workingFrame) })
        else { return }
        move.dropSpaceKeepsStripEnd = true
        shiftLiveView(by: liveDropSpaceWidth(context: context) + context.gaps, context: context, state: &state)
    }

    private func releaseLiveStripEnd(
        _ move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard move.dropSpaceKeepsStripEnd else { return }
        move.dropSpaceKeepsStripEnd = false
        shiftLiveView(by: -(liveDropSpaceWidth(context: context) + context.gaps), context: context, state: &state)
    }

    private func shiftLiveView(by shift: CGFloat, context: NiriInteractionContext, state: inout ViewportState) {
        state.animateToOffset(
            state.viewOffset + shift,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
    }

    private func liveSpecialModeUpdate(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step? {
        if move.stackMode {
            return liveStackUpdate(cursor: cursor, strip: strip, move: &move, context: context, state: &state)
        }
        guard !waitsForPointerMove(&move, at: cursor) else { return .unchanged }
        guard move.inStack else { return nil }
        return liveInStackUpdate(cursor: cursor, strip: strip, move: &move, context: context, state: &state)
    }

    func liveDropSpaceWidth(context: NiriInteractionContext) -> CGFloat {
        min(
            context.workingFrame.width * moveConfiguration.liveDropSpaceShare,
            moveConfiguration.liveDropSpaceMaximumWidth
        )
    }

    private func waitsForPointerMove(_ move: inout LiveColumnMove, at cursor: CGPoint) -> Bool {
        guard move.isStill(at: cursor) else {
            move.awaitsPointerMoveFrom = nil
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
        move.swapCount += 1
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
        guard let move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              let dragged = liveDraggedColumn(for: move)
        else { return false }
        if move.stackMode {
            return liveStackWouldChange(cursor: cursor, strip: strip, move: move, context: context)
        }
        if move.isStill(at: cursor) {
            return false
        }
        if move.inStack {
            return liveInStackWouldChange(cursor: cursor, strip: strip, move: move, context: context)
        }
        if liveFreeArea(at: cursor, strip: strip, move: move, context: context) != nil {
            return false
        }
        let dropSpace = liveDropSpace(for: move)
        guard let underPointer = liveColumnOrStripEnd(in: strip, at: cursor, ignoring: dropSpace, context: context)
        else { return false }
        let side = liveTargetSide(
            underPointer,
            cursor: cursor,
            strip: strip,
            home: dragged,
            awayFromHome: true,
            context: context
        )
        guard let target = liveTarget(
            underPointer,
            side: side,
            dragged: dragged,
            dropSpace: dropSpace,
            justPassed: move.passed?.columnId
        ) else { return false }
        return move.lockedTarget != .init(columnId: target.id, side: side)
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

    func liveColumnMoveEnd(
        releasedFrame: CGRect? = nil,
        releasedAt cursor: CGPoint? = nil,
        stacking: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard var move = liveColumnMove, move.workspaceId == context.workspaceId else { return false }
        if let cursor, liveColumnMoveDropIntoFreeArea(at: cursor, move: &move, context: context, state: &state) {
            return liveStackDropBegin(releasedAt: releasedFrame, move: move, context: context, state: &state)
        }
        if stacking, move.landing == nil, let cursor,
           !liveColumnMoveLandAtRelease(cursor, move: &move, context: context, state: &state)
        {
            liveColumnMoveToStripEnd(at: cursor, move: &move, context: context, state: &state)
        }
        if stacking, move.landing != nil {
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
        if move.inStack {
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
            liveColumnMove = nil
            return true
        }

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
        liveColumnMove = nil
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
            state.animateToOffset(
                settledOffset,
                motion: context.motion,
                scale: displayScale(in: context.workspaceId)
            )
        }
        if let cursor, let releasedFrame {
            moveLoneWindowIntoItsSpace(
                dragged,
                cursor: cursor,
                releasedFrame: releasedFrame,
                context: context,
                state: state
            )
        }
        state.selectedNodeId = move.windowId
        return true
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

    private func liveViewPosition(
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

    private func isLiveColumnFullyVisible(
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
            liveColumnMove = nil
            return false
        }
        if move.landing != nil {
            placeLiveLanding(nil, move: &move, context: context, state: &state)
        }
        restoreLiveOriginalSlot(&move)
        liveColumnMove = move
        guard let dragged = liveDraggedColumn(for: move) else {
            liveColumnMove = nil
            return false
        }

        let before = primaryPositions(context: context, state: state)
        liveColumnMove = nil
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
        dropSpace: NiriContainer?,
        justPassed: NodeId?
    ) -> NiriContainer? {
        guard let target = underPointer, target.id != justPassed else { return nil }
        if target === dragged { return dropSpace == nil ? nil : target }
        switch liveNeighbour(of: target, on: side) {
        case let neighbour? where neighbour === dropSpace: return nil
        case let neighbour? where neighbour === dragged: return dropSpace == nil ? nil : target
        default: return target
        }
    }

    func liveTargetSide(
        _ target: NiriContainer,
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        home: NiriContainer,
        awayFromHome: Bool,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Side {
        guard let placed = strip.first(where: { $0.column === target }) else { return .after }
        let landing = strip.first(where: { $0.column.isLiveDropSpace })?.column ?? home
        if liveColumnMove?.sideBySideIds.contains(target.id) == true, !(awayFromHome && landing === home) {
            let depth = moveConfiguration.liveSideBySideDepth
            if target.prevSibling() === landing {
                return cursor.x - placed.minX >= depth ? .after : .before
            }
            if target.nextSibling() === landing {
                return placed.maxX - cursor.x >= depth ? .before : .after
            }
        }
        if awayFromHome, let ahead = liveColumnMove?.edgeScrollSide {
            return ahead
        }
        if awayFromHome,
           let children = target.parent?.children,
           let targetIndex = children.firstIndex(where: { $0 === target }),
           let homeIndex = children.firstIndex(where: { $0 === home })
        {
            return targetIndex > homeIndex ? .after : .before
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
        home: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriContainer? {
        guard let root = root(for: context.workspaceId),
              root.children.contains(where: { $0 === target }),
              root.children.contains(where: { $0 === home })
        else { return nil }
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
        animateLiveColumnChange(from: before, anchoredOn: home, context: context, state: &state)
        return dropSpace
    }

    private func moveLiveHomeSpot(
        _ home: NiriContainer,
        beside target: NiriContainer,
        side: LiveColumnMove.Side,
        removing dropSpace: NiriContainer?,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let root = root(for: context.workspaceId),
              root.children.contains(where: { $0 === target }),
              root.children.contains(where: { $0 === home }),
              isLiveColumnFullyVisible(home, atOffset: state.viewOffset, context: context, state: state)
        else { return false }
        let before = primaryPositions(context: context, state: state)
        let originalPlaces = [home, dropSpace].compactMap { $0 }.compactMap { column in
            root.children.firstIndex { $0 === column }.map { (index: $0, column: column) }
        }.sorted { $0.index < $1.index }
        dropSpace?.detach()
        home.detach()
        if let targetIndex = root.children.firstIndex(where: { $0 === target }) {
            root.insertChild(home, at: side == .before ? targetIndex : targetIndex + 1)
        }
        var probe = state
        rebaseLiveView(from: before, anchoredOn: home, context: context, state: &probe)
        guard isLiveColumnFullyVisible(home, atOffset: probe.viewOffset, context: context, state: probe) else {
            home.detach()
            for place in originalPlaces {
                root.insertChild(place.column, at: place.index)
            }
            return false
        }
        animateLiveColumnChange(from: before, anchoredOn: home, context: context, state: &state)
        return true
    }

    private func closeLiveDropSpace(
        _ dropSpace: NiriContainer,
        home: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let before = primaryPositions(context: context, state: state)
        dropSpace.remove()
        animateLiveColumnChange(from: before, anchoredOn: home, context: context, state: &state)
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

    func liveStripScrollRange(
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> ClosedRange<CGFloat>? {
        guard let drift = stripEndsDrift(strip: strip, context: context) else { return nil }
        return min(0, drift.lowest) ... max(0, drift.highest)
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
