// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnMoveStackModeChanged(
        held: Bool,
        cursor: CGPoint,
        duringEdgeScroll: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        assertSanctionedMutation()
        guard var move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              held != move.stackMode,
              !(held && move.isWholeColumn)
        else { return .unchanged }
        defer { liveColumnMove = move }

        move.stackMode = held
        move.hover = nil
        move.stackSuppressPoint = nil
        if held {
            move.awaitsPointerMoveFrom = nil
            guard !duringEdgeScroll else { return .unchanged }
            let strip = liveColumnStrip(context: context, state: state)
            return liveStackUpdate(cursor: cursor, strip: strip, move: &move, context: context, state: &state)
        }
        move.awaitsPointerMoveFrom = duringEdgeScroll ? nil : cursor
        guard move.landing != nil, placeLiveLanding(nil, move: &move, context: context, state: &state) else {
            return .unchanged
        }
        move.phase = .settling
        return .changed
    }

    func liveColumnMoveCloseLandingForEdgeScroll(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        assertSanctionedMutation()
        guard var move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              move.stackMode,
              move.landing != nil
        else { return false }
        defer { liveColumnMove = move }
        move.stackSuppressPoint = nil
        return placeLiveLanding(nil, move: &move, context: context, state: &state)
    }

    func liveColumnMoveLandAtRelease(
        _ cursor: CGPoint,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let strip = liveColumnStrip(context: context, state: state)
        guard case let .land(landing) = liveStackChoice(cursor: cursor, strip: strip, move: move, context: context)
        else { return false }
        return placeLiveLanding(landing, move: &move, context: context, state: &state)
    }

    func liveStackUpdate(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        guard !holdsLiveStackSuppression(&move, at: cursor, strip: strip) else { return .unchanged }
        let landing: LiveColumnMove.Landing?
        switch liveStackChoice(cursor: cursor, strip: strip, move: move, context: context) {
        case .keep:
            return .unchanged
        case .home:
            landing = nil
        case let .land(target):
            landing = target
        }
        guard landing != move.landing,
              placeLiveLanding(landing, move: &move, context: context, state: &state)
        else { return .unchanged }
        if landing != nil {
            armLiveStackSuppression(&move, at: cursor, context: context)
        }
        move.phase = .settling
        return .changed
    }

    func liveStackWouldChange(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> Bool {
        let columnId = liveColumn(in: strip, at: cursor, ignoring: liveDropSpace(for: move))?.id
        if let probe = liveStackProbe, probe.columnId == columnId, probe.cursor == cursor {
            return probe.wouldChange
        }
        let wouldChange = liveStackChoiceChanges(cursor: cursor, strip: strip, move: move, context: context)
        liveStackProbe = .init(columnId: columnId, cursor: cursor, wouldChange: wouldChange)
        return wouldChange
    }

    private func liveStackChoiceChanges(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> Bool {
        if isLiveStackSuppressed(at: cursor, strip: strip, move: move) {
            return false
        }
        switch liveStackChoice(cursor: cursor, strip: strip, move: move, context: context) {
        case .keep:
            return false
        case .home:
            return move.landing != nil
        case let .land(target):
            return target != move.landing
        }
    }

    func liveWindowSpans(in column: NiriContainer, context: NiriInteractionContext) -> [LiveColumnMove.WindowSpan] {
        let windows = projectedWindows(in: column, workspaceId: context.workspaceId)
        guard !windows.isEmpty else { return [] }
        let isTabbed = column.isTabbed && windows.count > 1
        let spans = resolveWindowSpans(
            container: column,
            windows: windows,
            axis: NiriAxisLayout(
                availableSpace: context.workingFrame.height,
                gap: context.gaps,
                isTabbed: isTabbed,
                orientation: .horizontal
            ),
            secondarySpanOverride: nil
        )
        var position = context.workingFrame.minY + context.gaps
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
        guard let landing = move.landing,
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let column = liveColumn(withId: landing.columnId, in: move.workspaceId),
              window.parent === column
        else {
            liveColumnMove = nil
            return false
        }
        liveStackDrop = .init(
            workspaceId: move.workspaceId,
            windowId: move.windowId,
            homeColumnId: move.homeColumnId,
            dropSpaceId: move.dropSpaceId,
            targetColumnId: column.id
        )
        liveColumnMove = nil
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
        if let release = release.flatMap({ liveReleaseOnScreen($0, context: context) }),
           let landed = liveWindowFrame(of: window, in: column, context: context, state: state)
        {
            animateLiveWindow(window, from: release, to: landed, context: context)
        }
    }

    func liveReleaseOnScreen(_ release: CGRect, context: NiriInteractionContext) -> CGRect? {
        let minY = max(release.minY, context.workingFrame.minY)
        let maxY = min(release.maxY, context.workingFrame.maxY)
        guard maxY > minY else { return nil }
        return CGRect(x: release.minX, y: minY, width: release.width, height: maxY - minY)
    }

    func liveStackDropFinish(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        assertSanctionedMutation()
        guard let drop = liveStackDrop, drop.workspaceId == context.workspaceId else { return false }
        guard let target = liveColumn(withId: drop.targetColumnId, in: drop.workspaceId) else {
            liveStackDrop = nil
            return false
        }
        let before = primaryPositions(context: context, state: state)
        liveStackDrop = nil
        animateLiveColumnChange(from: before, anchoredOn: target, context: context, state: &state)
        animateLiveViewShift(
            liveColumnRevealShift(target, context: context, state: state),
            context: context,
            state: &state
        )
        return true
    }

    func releaseLivePlaceholders(of previous: LiveColumnMove) {
        if let slot = previous.narrowedSlot, liveColumnMove?.narrowedSlot?.columnId != slot.columnId {
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
        if liveColumnMove == nil, liveStackDrop?.windowId != previous.windowId,
           let saved = previous.mateHeight,
           let mate = findNode(by: saved.windowId, in: previous.workspaceId) as? NiriWindow,
           mate.height != saved.height
        {
            mate.height = saved.height
        }
    }

    func releaseLivePlaceholders(of previous: LiveColumnMove.StackDrop) {
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

    @discardableResult
    func placeLiveLanding(
        _ landing: LiveColumnMove.Landing?,
        height fixedHeight: CGFloat? = nil,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let home = liveDraggedColumn(for: move),
              let source = findColumn(containing: window, in: move.workspaceId)
        else { return false }
        let target = landing.flatMap { liveColumn(withId: $0.columnId, in: move.workspaceId) }
        let affected = [source, target ?? home]
        let columnsBefore = primaryPositions(context: context, state: state)
        let placed = slideLiveWindows(in: affected, skipping: window, context: context) {
            restoreLiveMateHeight(&move)
            guard relocateLiveWindow(window, to: landing, from: source, move: move, context: context) else {
                return false
            }
            if let fixedHeight {
                window.height = .fixed(fixedHeight)
            } else {
                shareLiveColumn(target, with: window, move: &move)
            }
            return true
        }
        guard placed else { return false }
        move.landing = landing
        animateLiveColumnChange(from: columnsBefore, anchoredOn: home, context: context, state: &state)
        return true
    }

    private func shareLiveColumn(_ column: NiriContainer?, with window: NiriWindow, move: inout LiveColumnMove) {
        guard let column, !column.isTabbed else { return }
        let mates = column.windowNodes.filter { $0 !== window }
        guard mates.count == 1, let mate = mates.first, mate.height != .default else { return }
        move.mateHeight = .init(windowId: mate.id, height: mate.height)
        mate.height = .default
    }

    private func restoreLiveMateHeight(_ move: inout LiveColumnMove) {
        guard let saved = move.mateHeight else { return }
        move.mateHeight = nil
        (findNode(by: saved.windowId, in: move.workspaceId) as? NiriWindow)?.height = saved.height
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

    private func relocateLiveWindow(
        _ window: NiriWindow,
        to landing: LiveColumnMove.Landing?,
        from source: NiriContainer,
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> Bool {
        guard let home = liveDraggedColumn(for: move) else { return false }
        let target = landing.flatMap { liveColumn(withId: $0.columnId, in: move.workspaceId) }
        let sourceActive = source !== home && source.isTabbed
            ? projectedActiveWindow(in: source, workspaceId: move.workspaceId)
            : nil
        if let landing, let target {
            guard insertLiveLanding(window, at: landing, in: target, home: home, context: context) else {
                return false
            }
            if target === home {
                move.ownWindowSizing.apply(to: window)
            }
        } else {
            returnLiveWindowHome(window, to: home, move: move)
        }
        if let sourceActive, source !== target, sourceActive.parent === source {
            activateWindow(sourceActive.id, in: move.workspaceId)
            source.cachedWidth = 0
        }
        return true
    }

    private func insertLiveLanding(
        _ window: NiriWindow,
        at landing: LiveColumnMove.Landing,
        in column: NiriContainer,
        home: NiriContainer,
        context: NiriInteractionContext
    ) -> Bool {
        guard let targetWindow = findNode(by: landing.targetWindowId, in: context.workspaceId) as? NiriWindow
        else { return false }
        let homeWidth = home.cachedWidth
        let shownTab = column.isTabbed ? projectedActiveWindow(in: column, workspaceId: context.workspaceId) : nil
        guard stackWindow(
            window,
            beside: targetWindow,
            position: !column.isTabbed && landing.above ? .after : .before,
            removingEmptySource: false,
            in: context.workspaceId,
            geometry: context.sizingGeometry
        ) else { return false }

        if let shownTab, shownTab.parent === column {
            activateWindow(shownTab.id, in: context.workspaceId)
            column.cachedWidth = 0
        } else {
            window.isHiddenInTabbedMode = false
        }
        if home.windowNodes.isEmpty, !home.isLiveHomeSpot {
            home.isLiveHomeSpot = true
            home.width = .fixed(homeWidth)
            home.cachedWidth = 0
        }
        return true
    }

    private func returnLiveWindowHome(_ window: NiriWindow, to home: NiriContainer, move: LiveColumnMove) {
        if let source = window.parent as? NiriContainer, source.isTabbed {
            source.cachedWidth = 0
        }
        home.insertChild(window, at: move.inStack ? move.homeSlotIndex : 0)
        move.ownWindowSizing.apply(to: window)
        window.isHiddenInTabbedMode = false
        if move.inStack {
            activateWindow(window.id, in: move.workspaceId)
            home.cachedWidth = 0
            return
        }
        guard move.homeColumnId == move.originalSlot.columnId else { return }
        home.isLiveHomeSpot = false
        restoreLiveSizing(move.ownSizing, to: home)
    }

    private func liveStackChoice(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.StackChoice {
        guard let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow else { return .keep }
        guard let column = liveColumn(in: strip, at: cursor, ignoring: liveDropSpace(for: move)),
              column.id != move.homeColumnId || move.inStack,
              projectedWindows(in: column, workspaceId: move.workspaceId).contains(where: { $0 !== window }),
              columnCanAcceptTransfer(
                  column,
                  adding: window,
                  removing: window,
                  in: move.workspaceId,
                  geometry: context.sizingGeometry
              )
        else { return .home }

        if column.isTabbed {
            guard let shown = projectedActiveWindow(in: column, workspaceId: move.workspaceId),
                  shown !== window else { return .home }
            return .land(.init(columnId: column.id, targetWindowId: shown.id, above: false))
        }
        let spans = liveWindowSpans(in: column, context: context)
        if spans.contains(where: { $0.window === window && $0.contains(y: cursor.y) }) {
            return .keep
        }
        let others = spans.filter { $0.window !== window }
        guard let hitIndex = others.firstIndex(where: { $0.contains(y: cursor.y) }) else {
            return liveFreeArea(at: cursor, strip: strip, move: move, context: context) == nil ? .keep : .home
        }
        let hit = others[hitIndex]
        let above = cursor.y >= (hit.minY + hit.maxY) / 2
        guard !above, hitIndex > 0 else {
            return .land(.init(columnId: column.id, targetWindowId: hit.window.id, above: above))
        }
        return .land(.init(columnId: column.id, targetWindowId: others[hitIndex - 1].window.id, above: true))
    }

    func isLiveStackSuppressed(
        at cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove
    ) -> Bool {
        guard let point = move.stackSuppressPoint,
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let column = window.parent as? NiriContainer,
              liveColumn(in: strip, at: cursor, ignoring: liveDropSpace(for: move)) === column
        else { return false }
        return hypot(cursor.x - point.x, cursor.y - point.y) < moveConfiguration.liveStackSuppressDistance
    }

    func holdsLiveStackSuppression(
        _ move: inout LiveColumnMove,
        at cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn]
    ) -> Bool {
        guard move.stackSuppressPoint != nil else { return false }
        if isLiveStackSuppressed(at: cursor, strip: strip, move: move) { return true }
        move.stackSuppressPoint = nil
        return false
    }

    func armLiveStackSuppression(_ move: inout LiveColumnMove, at cursor: CGPoint, context: NiriInteractionContext) {
        guard let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let column = window.parent as? NiriContainer,
              !column.isTabbed
        else { return }
        let slot = liveWindowSpans(in: column, context: context).first { $0.window === window }
        if slot?.contains(y: cursor.y) != true {
            move.stackSuppressPoint = cursor
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
            for span in liveWindowSpans(in: column, context: context) {
                places[span.window.id] = CGRect(x: tilesX, y: span.minY, width: 0, height: span.maxY - span.minY)
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
        return CGRect(
            x: placed.minX + place.minX,
            y: place.minY,
            width: placed.maxX - placed.minX - place.minX,
            height: place.height
        ).roundedToPhysicalPixels(scale: displayScale(in: context.workspaceId))
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
        context: NiriInteractionContext
    ) {
        let displacement = CGPoint(x: previous.minX - current.minX, y: previous.minY - current.minY)
        let heightDelta = previous.height - current.height
        let moves = abs(displacement.x) > 0.001 || abs(displacement.y) > 0.001
        let resizes = previous.height > 0 && abs(heightDelta) > 0.5
        guard moves || resizes else { return }
        let config = context.motion.scaled(windowMovementAnimationConfig)
        let refreshRate = displayRefreshRate(in: context.workspaceId)
        if moves {
            window.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: config,
                displayRefreshRate: refreshRate,
                animated: context.motion.animationsEnabled
            )
        }
        if resizes {
            window.animateHeightFrom(
                delta: heightDelta,
                clock: animationClock,
                config: config,
                displayRefreshRate: refreshRate,
                animated: context.motion.animationsEnabled
            )
        }
    }

    private func liveColumnRevealShift(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> CGFloat {
        let strip = liveColumnStrip(context: context, state: state)
        guard let placed = strip.first(where: { $0.column === column }),
              let range = liveStripScrollRange(strip: strip, context: context)
        else { return 0 }
        let leadingEdge = context.workingFrame.minX + context.gaps
        let trailingEdge = context.workingFrame.maxX - context.gaps
        let wanted: CGFloat = if placed.minX < leadingEdge {
            placed.minX - leadingEdge
        } else if placed.maxX > trailingEdge {
            placed.maxX - trailingEdge
        } else {
            0
        }
        return wanted.clamped(to: range)
    }
}
