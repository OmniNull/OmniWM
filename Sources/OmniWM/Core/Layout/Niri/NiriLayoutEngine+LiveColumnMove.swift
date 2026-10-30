// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnMoveBegin(
        windowId: NodeId,
        windowToken: WindowToken,
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
              column.windowNodes.count == 1,
              projectedColumns(in: context.workspaceId).count > 1
        else { return false }

        let columns = columns(in: context.workspaceId)
        let positions = primaryPositions(context: context, state: state)
        let activeColumn = columns.indices.contains(state.activeColumnIndex) ? columns[state.activeColumnIndex] : column
        liveColumnMove = LiveColumnMove(
            windowId: windowId,
            windowToken: windowToken,
            workspaceId: context.workspaceId,
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
        at time: TimeInterval,
        immediate: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        guard var move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              let dragged = liveDraggedColumn(for: move)
        else { return .unchanged }
        defer { liveColumnMove = move }

        let dropSpace = liveDropSpace(for: move)
        let strip = liveColumnStrip(context: context, state: state)
        let previousHover = move.hover
        move.hover = nil
        let underPointer = liveColumn(in: strip, at: cursor, ignoring: dropSpace)
        let side = underPointer.map {
            liveTargetSide($0, cursor: cursor, strip: strip, home: dragged, awayFromHome: immediate, context: context)
        } ?? .after
        if let underPointer, move.lockedTarget != .init(columnId: underPointer.id, side: side) {
            move.lockedTarget = nil
        }
        guard let target = liveTarget(underPointer, side: side, dragged: dragged, dropSpace: dropSpace),
              move.lockedTarget != .init(columnId: target.id, side: side)
        else {
            return .unchanged
        }
        let delay = moveConfiguration.liveHoverDelay
        if !immediate, delay > 0 {
            let hover = previousHover?.columnId == target.id && previousHover?.side == side
                ? previousHover
                : .init(columnId: target.id, side: side, since: time)
            let until = (hover?.since ?? time) + delay
            guard time >= until else {
                move.hover = hover
                return .hovering(until: until)
            }
        }

        if target === dragged, let dropSpace {
            closeLiveDropSpace(dropSpace, home: dragged, context: context, state: &state)
            move.dropSpaceId = nil
            return markLiveChange(&move, target: target, side: side)
        }
        if let dropSpace, liveNeighbour(of: target, on: side) === dragged {
            closeLiveDropSpace(dropSpace, home: dragged, context: context, state: &state)
            move.dropSpaceId = nil
            scrollLiveLandingUnderPointer(dragged, target: target, cursor: cursor, context: context, state: &state)
            return markLiveChange(&move, target: target, side: side)
        }
        if !immediate,
           moveLiveHomeSpot(dragged, beside: target, side: side, removing: dropSpace, context: context, state: &state)
        {
            move.dropSpaceId = nil
            return markLiveChange(&move, target: target, side: side)
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
        scrollLiveLandingUnderPointer(opened, target: target, cursor: cursor, context: context, state: &state)
        return markLiveChange(&move, target: target, side: side)
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

    private func markLiveChange(
        _ move: inout LiveColumnMove,
        target: NiriContainer,
        side: LiveColumnMove.Side
    ) -> LiveColumnMove.Step {
        move.lockedTarget = .init(columnId: target.id, side: side)
        move.phase = .settling
        move.swapCount += 1
        return .changed
    }

    func liveDropSpace(for move: LiveColumnMove) -> NiriContainer? {
        guard let dropSpaceId = move.dropSpaceId else { return nil }
        return columns(in: move.workspaceId).first { $0.id == dropSpaceId }
    }

    func isLiveColumnMoveActive(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        liveColumnMove?.workspaceId == workspaceId
    }

    func isLiveDraggedWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let move = liveColumnMove else { return false }
        return move.windowToken == token && move.workspaceId == workspaceId
    }

    func liveColumnMoveSettled() {
        liveColumnMove?.phase = .dragging
    }

    func liveColumnMoveEnd(
        releasedAtScreenX releaseX: CGFloat? = nil,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let move = liveColumnMove, move.workspaceId == context.workspaceId else { return false }
        let dropSpace = liveDropSpace(for: move)
        guard let dragged = liveDraggedColumn(for: move) else {
            liveColumnMove = nil
            return true
        }

        let before = primaryPositions(context: context, state: state)
        let viewBefore = liveViewPosition(positions: before, context: context, state: state)
        let landingBefore = dropSpace.flatMap { before[$0.id] } ?? before[dragged.id]
        if let dropSpace,
           let root = root(for: context.workspaceId),
           let landingIndex = root.children.firstIndex(where: { $0 === dropSpace })
        {
            root.insertChild(dragged, at: landingIndex)
        }
        liveColumnMove = nil
        let releasedAt = viewBefore.flatMap { view in releaseX.map { $0 - context.workingFrame.minX + view } }
        animateLiveColumnChange(
            from: before,
            anchoredOn: dragged,
            animatingAnchorFrom: releasedAt ?? landingBefore,
            context: context,
            state: &state
        )
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
        state.selectedNodeId = move.windowId
        return true
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
        return placed.minX >= context.workingFrame.minX - 0.5 && placed.maxX <= context.workingFrame.maxX + 0.5
    }

    func liveColumnMoveCancel(
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let move = liveColumnMove, move.workspaceId == context.workspaceId else { return false }
        guard let root = root(for: context.workspaceId),
              let dragged = liveDraggedColumn(for: move)
        else {
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

    private func liveDraggedColumn(for move: LiveColumnMove) -> NiriContainer? {
        guard let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow else { return nil }
        return findColumn(containing: window, in: move.workspaceId)
    }

    private func liveColumn(
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
        dropSpace: NiriContainer?
    ) -> NiriContainer? {
        guard let target = underPointer else { return nil }
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
        if awayFromHome,
           let children = target.parent?.children,
           let targetIndex = children.firstIndex(where: { $0 === target }),
           let homeIndex = children.firstIndex(where: { $0 === home })
        {
            return targetIndex > homeIndex ? .after : .before
        }
        guard let placed = strip.first(where: { $0.column === target }) else { return .after }
        let visibleMinX = max(placed.minX, context.workingFrame.minX)
        let visibleMaxX = min(placed.maxX, context.workingFrame.maxX)
        let middle = visibleMaxX > visibleMinX ? (visibleMinX + visibleMaxX) / 2 : placed.midX
        return cursor.x < middle ? .before : .after
    }

    private func liveNeighbour(of column: NiriContainer, on side: LiveColumnMove.Side) -> NiriContainer? {
        guard let children = column.parent?.children,
              let index = children.firstIndex(where: { $0 === column })
        else { return nil }
        let neighbourIndex = side == .before ? index - 1 : index + 1
        guard children.indices.contains(neighbourIndex) else { return nil }
        return children[neighbourIndex] as? NiriContainer
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
            column.width = .fixed(min(
                context.workingFrame.width * moveConfiguration.liveDropSpaceShare,
                moveConfiguration.liveDropSpaceMaximumWidth
            ))
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

    private func animateLiveColumnChange(
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
    private func rebaseLiveView(
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

    private func retargetActiveColumn(
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

    private func keepVisibleLiveShift(
        showing column: NiriContainer,
        besideTargetUnder pointer: (target: NiriContainer, cursor: CGPoint),
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> CGFloat {
        guard let landing = strip.first(where: { $0.column === column }),
              let target = strip.first(where: { $0.column === pointer.target }),
              let first = strip.first,
              let last = strip.last
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
        let lowest = max(
            min(0, first.minX - (context.workingFrame.minX + context.gaps)),
            min(0, underPointer.lowerBound - pointerX)
        )
        let highest = min(
            max(0, last.maxX - (context.workingFrame.maxX - context.gaps)),
            max(0, underPointer.upperBound - pointerX - 1)
        )
        return wanted.clamped(to: lowest ... highest)
    }
}
