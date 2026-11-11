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

    func liveCentreDecision(
        pointer: LiveColumnMove.Pointer,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Action? {
        let time = pointer.time
        switch liveCentreChoice(cursor: pointer.cursor, strip: strip, move: move, context: context) {
        case .keep:
            return move.landing != nil ? .nothing : nil
        case .home:
            move.endCentreDwell()
            return move.landing != nil ? .closeHint : nil
        case let .land(landing):
            move.endSideDwell()
            if move.landing != nil {
                guard landing != move.landing else { return .nothing }
                if landing.columnId == move.landing?.columnId {
                    return .showHint(landing, tracesRefusal: false)
                }
                return .switchHint(columnId: landing.columnId, dwellSince: time)
            }
            guard let time else { return nil }
            let since = move.dwell?.start(on: landing.columnId, in: .centre) ?? time
            move.dwell = .init(columnId: landing.columnId, region: .centre, since: since)
            let until = since + liveCentreStackDelay
            guard pointer.slowed || time >= until else { return .hovering(until: until) }
            return .showHint(landing, tracesRefusal: true)
        }
    }

    func liveCentreChoice(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.StackChoice {
        guard move.home != .stackSlot,
              !move.pointerInEdgeZone,
              let column = liveColumn(in: strip, at: cursor, ignoring: liveDropSpace(for: move)),
              column.id != move.homeColumnId,
              let placed = strip.first(where: { $0.column === column }),
              placed.width >= MoveConfiguration.liveCentreMinimumWidth - 0.5
        else { return .home }
        let hintedHere = move.landing?.columnId == column.id
        let margin = hintedHere ? MoveConfiguration.liveCentreExitMargin : 0
        let third = placed.width / 3
        guard cursor.x >= placed.minX + third - margin, cursor.x < placed.maxX - third + margin else {
            return .home
        }
        return liveStackChoice(cursor: cursor, strip: strip, move: move, context: context)
    }

    @discardableResult
    func showLiveLandingHint(
        _ landing: LiveColumnMove.LandingSlot,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard placeLiveLanding(landing, move: &move, context: context, state: &state) else {
            return false
        }
        if let hinted = liveColumn(withId: landing.columnId, in: move.workspaceId) {
            closeOpenLiveDropSpace(move: &move, anchor: hinted, context: context, state: &state)
        }
        move.endSideDwell()
        move.lockedTarget = nil
        move.phase = .settling
        return true
    }

    func closeLiveLandingHint(
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        if move.landing != nil {
            placeLiveLanding(nil, move: &move, context: context, state: &state)
        }
        move.endSideDwell()
        move.phase = .settling
    }

    func liveLandingHintHeight(besideWindowCount count: Int, context: NiriInteractionContext) -> CGFloat {
        let share = count == 1
            ? MoveConfiguration.liveLandingHintSingleWindowShare
            : MoveConfiguration.liveLandingHintShare
        return max(context.workingFrame.height * share, MoveConfiguration.liveLandingHintMinimumHeight)
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
        let hint = liveLandingHintHeight(besideWindowCount: windows.count - 1, context: context)
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
