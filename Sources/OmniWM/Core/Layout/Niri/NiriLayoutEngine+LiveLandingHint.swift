// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct LiveSpanOverride: Equatable {
    let span: CGFloat
    let ignoresMinimum: Bool
}

extension NiriLayoutEngine {
    func liveSpanOverrideInput(_ override: LiveSpanOverride, for window: NiriWindow) -> NiriAxisSolver.Input {
        NiriAxisSolver.Input(
            weight: max(0.1, window.heightWeight),
            minConstraint: override.ignoresMinimum ? 0 : window.constraints.normalized().minSize.height,
            maxConstraint: 0,
            hasMaxConstraint: false,
            isConstraintFixed: false,
            hasFixedValue: true,
            fixedValue: override.span
        )
    }

    func liveCentreUpdate(
        pointer: (cursor: CGPoint, time: TimeInterval?),
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step? {
        guard stacksOnWindowCentres, !move.stackMode else { return nil }
        let time = pointer.time
        switch liveCentreChoice(cursor: pointer.cursor, strip: strip, move: move, context: context) {
        case .keep:
            return move.landingIsHint ? .unchanged : nil
        case .home:
            move.centreWait = nil
            guard move.landingIsHint else { return nil }
            closeLiveLandingHint(move: &move, context: context, state: &state)
            return .changed
        case let .land(landing):
            move.hover = nil
            if move.landingIsHint {
                guard landing != move.landing else { return .unchanged }
                if landing.columnId == move.landing?.columnId {
                    return showLiveLandingHint(landing, move: &move, context: context, state: &state)
                        ? .changed
                        : .unchanged
                }
                closeLiveLandingHint(move: &move, context: context, state: &state)
                move.centreWait = time.map { .init(columnId: landing.columnId, since: $0) }
                return .changed
            }
            guard let time else { return nil }
            let since = move.centreWait?.columnId == landing.columnId ? move.centreWait?.since ?? time : time
            move.centreWait = .init(columnId: landing.columnId, since: since)
            let until = since + moveConfiguration.liveCentreStackDelay
            guard time >= until else { return .hovering(until: until) }
            return showLiveLandingHint(landing, move: &move, context: context, state: &state) ? .changed : .unchanged
        }
    }

    func liveCentreWouldChange(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> Bool? {
        guard stacksOnWindowCentres, !move.stackMode else { return nil }
        switch liveCentreChoice(cursor: cursor, strip: strip, move: move, context: context) {
        case .keep:
            return move.landingIsHint ? false : nil
        case let .land(landing):
            return move.landingIsHint ? landing != move.landing : nil
        case .home:
            return move.landingIsHint ? true : nil
        }
    }

    func liveCentreChoice(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.StackChoice {
        guard stacksOnWindowCentres,
              !move.isWholeColumn,
              !move.inStack,
              let column = liveColumn(in: strip, at: cursor, ignoring: liveDropSpace(for: move)),
              column.id != move.homeColumnId,
              let placed = strip.first(where: { $0.column === column }),
              placed.width >= moveConfiguration.liveCentreMinimumWidth - 0.5
        else { return .home }
        let hintedHere = move.landingIsHint && move.landing?.columnId == column.id
        let margin = hintedHere ? moveConfiguration.liveCentreExitMargin : 0
        let third = placed.width / 3
        guard cursor.x >= placed.minX + third - margin, cursor.x < placed.maxX - third + margin else {
            return .home
        }
        return liveStackChoice(cursor: cursor, strip: strip, move: move, context: context)
    }

    @discardableResult
    func showLiveLandingHint(
        _ landing: LiveColumnMove.Landing,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let wasHint = move.landingIsHint
        move.landingIsHint = true
        guard placeLiveLanding(landing, move: &move, context: context, state: &state) else {
            move.landingIsHint = wasHint && move.landing != nil
            return false
        }
        move.hover = nil
        move.lockedTarget = nil
        move.phase = .settling
        return true
    }

    func closeLiveLandingHint(
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        move.landingIsHint = false
        if move.landing != nil {
            placeLiveLanding(nil, move: &move, context: context, state: &state)
        }
        move.hover = nil
        move.phase = .settling
    }

    func liveLandingHintHeight(context: NiriInteractionContext) -> CGFloat {
        max(
            context.workingFrame.height * moveConfiguration.liveLandingHintShare,
            moveConfiguration.liveLandingHintMinimumHeight
        )
    }

    func liveHintBaseSpans(
        in column: NiriContainer,
        without window: NiriWindow,
        context: NiriInteractionContext
    ) -> [NodeId: CGFloat] {
        let spans = liveWindowSpans(in: column, context: context)
        let others = spans.filter { $0.window !== window }
        let freed = spans.first(where: { $0.window === window }).map { $0.maxY - $0.minY + context.gaps } ?? 0
        let total = others.reduce(CGFloat.zero) { $0 + $1.maxY - $1.minY }
        var base: [NodeId: CGFloat] = [:]
        for span in others {
            let height = span.maxY - span.minY
            base[span.window.id] = height + (total > 0 ? freed * height / total : 0)
        }
        return base
    }

    func applyLiveLandingHint(
        _ window: NiriWindow,
        in column: NiriContainer,
        base: [NodeId: CGFloat],
        context: NiriInteractionContext
    ) {
        guard !column.isTabbed else { return }
        let windows = projectedWindows(in: column, workspaceId: context.workspaceId)
        guard let index = windows.firstIndex(where: { $0 === window }),
              windows.allSatisfy({ $0 === window || base[$0.id] != nil })
        else { return }
        let neighbours = [index - 1, index + 1].filter { windows.indices.contains($0) }.map { windows[$0] }
        guard !neighbours.isEmpty else { return }
        let hint = liveLandingHintHeight(context: context)
        let taken = (hint + context.gaps) / CGFloat(neighbours.count)
        for other in windows where other !== window {
            let height = base[other.id] ?? 0
            let span = neighbours.contains(where: { $0 === other }) ? height - taken : height
            other.liveSpanOverride = .init(span: max(1, span), ignoresMinimum: false)
        }
        window.liveSpanOverride = .init(span: hint, ignoresMinimum: true)
    }

    func releaseLiveLandingState(of move: LiveColumnMove) {
        guard let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow else { return }
        let wasDeferred = window.defersMinimumWidth
        window.defersMinimumWidth = false
        guard let column = window.parent as? NiriContainer else { return }
        clearLiveSpanOverrides(in: [column])
        if wasDeferred {
            clampColumnWidthToBounds(column, in: move.workspaceId, motion: .disabled)
        }
    }

    func clearLiveSpanOverrides(in columns: [NiriContainer]) {
        for column in columns {
            for window in column.windowNodes {
                window.liveSpanOverride = nil
            }
        }
    }
}
