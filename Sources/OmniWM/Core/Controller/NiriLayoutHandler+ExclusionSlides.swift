// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutHandler {
    private struct ExclusionChange {
        let columns: [NiriContainer]
        let columnIds: [NodeId]
        let widths: [ProportionalSize]
        let previous: Set<WindowToken>
        let current: Set<WindowToken>

        var hiddenColumns: [Int] {
            columns.indices.filter { showed(columns[$0]) && !shows(columns[$0]) }
        }

        var shownColumns: [Int] {
            columns.indices.filter {
                !showed(columns[$0]) && shows(columns[$0]) && !columns[$0].windowNodes.isEmpty
            }
        }

        var changedStacks: [NiriContainer] {
            columns.filter { column in
                showed(column) && shows(column)
                    && column.windowNodes.contains { previous.contains($0.token) != current.contains($0.token) }
            }
        }

        private func showed(_ column: NiriContainer) -> Bool {
            column.shownWindow(excluding: previous) != nil
        }

        private func shows(_ column: NiriContainer) -> Bool {
            column.shownWindow(excluding: current) != nil
        }
    }

    func slideAroundExclusionChanges(
        from previousExclusions: Set<WindowToken>?,
        pass: NiriLayoutPass,
        state: inout ViewportState,
        snapshot: NiriWorkspaceSnapshot
    ) {
        let exclusions = snapshot.excludedTokens
        guard snapshot.hasCompletedInitialRefresh,
              snapshot.isActiveWorkspace,
              let previousExclusions,
              previousExclusions != exclusions
        else { return }
        let columns = pass.engine.columns(in: pass.wsId)
        let columnIds = columns.map(\.id)
        let liveColumnIds = Set(columnIds)
        viewsBeforeExclusion[pass.wsId] = viewsBeforeExclusion[pass.wsId]?.filter { liveColumnIds.contains($0.key) }
        let change = ExclusionChange(
            columns: columns,
            columnIds: columnIds,
            widths: columns.map(\.width),
            previous: previousExclusions,
            current: exclusions
        )
        let hidden = change.hiddenColumns
        let shown = change.shownColumns
        rememberStackFrames(of: change, in: pass.wsId)
        guard !hidden.isEmpty || !shown.isEmpty else { return }
        NiriLayoutTrace.record(.viewport, workspaceId: pass.wsId, {
            let ids: ([Int]) -> String = { indices in
                indices.map { columns[$0].traceWindowIds }.joined(separator: ",")
            }
            return "exclusion-slide hidden=[\(ids(hidden))] shown=[\(ids(shown))] "
                + "active=\(state.activeColumnIndex) scrollPath=\(snapshot.useScrollAnimationPath)"
        }())
        slideAroundHiddenColumns(hidden, change: change, pass: pass, state: &state)
        slideAroundShownColumns(shown, change: change, pass: pass, state: &state)
    }

    private func rememberStackFrames(of change: ExclusionChange, in workspaceId: WorkspaceDescriptor.ID) {
        let changedStacks = change.changedStacks
        guard !changedStacks.isEmpty else { return }
        var frames: [WindowToken: CGRect] = [:]
        for window in changedStacks.flatMap(\.windowNodes) where !change.previous.contains(window.token) {
            if let frame = window.frame {
                frames[window.token] = frame
            }
        }
        stackFramesBeforeExclusion[workspaceId] = frames
    }

    private func slideAroundHiddenColumns(
        _ hidden: [Int],
        change: ExclusionChange,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        for index in hidden {
            viewsBeforeExclusion[pass.wsId, default: [:]][change.columns[index].id] = ExcludedColumnView(
                before: viewPosition(state, columns: change.columns, exclusions: change.previous, pass: pass),
                columnIds: change.columnIds,
                widths: change.widths
            )
            if index == state.activeColumnIndex {
                reanchorView(awayFrom: index, change: change, pass: pass, state: &state)
            }
            pass.engine.animateColumnsAroundRemoval(
                columns: change.columns,
                removedIdx: index,
                activeIdx: state.activeColumnIndex,
                offset: change.columns[index][keyPath: pass.primarySpanKeyPath] + pass.gap,
                context: pass.interactionContext
            )
        }
    }

    private func slideAroundShownColumns(
        _ shown: [Int],
        change: ExclusionChange,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        var undoing: [(index: Int, before: CGFloat)] = []
        var opening: [Int] = []
        for index in shown {
            let remembered = viewsBeforeExclusion[pass.wsId]?.removeValue(forKey: change.columns[index].id)
            let undoes = remembered.map { view in
                view.columnIds == change.columnIds && view.widths == change.widths
            } == true
            NiriLayoutTrace.record(.viewport, workspaceId: pass.wsId, {
                "exclusion-undo column=\(index) undo=\(undoes ? "yes" : remembered == nil ? "no(none)" : "no(changed)")"
            }())
            if undoes, let before = remembered?.before {
                undoing.append((index, before))
            } else {
                opening.append(index)
            }
        }
        if let first = undoing.first {
            restoreView(to: first.before, returning: undoing.map(\.index), change: change, pass: pass, state: &state)
        }
        for index in opening {
            if index < state.activeColumnIndex {
                anchorView(at: index, change: change, pass: pass, state: &state)
            }
            slideAside(
                change.columns[(index + 1)...],
                by: change.columns[index][keyPath: pass.primarySpanKeyPath] + pass.gap,
                pass: pass
            )
        }
    }

    private func stripPositions(
        _ columns: [NiriContainer],
        exclusions: Set<WindowToken>,
        pass: NiriLayoutPass
    ) -> [CGFloat] {
        var positions: [CGFloat] = []
        positions.reserveCapacity(columns.count + 1)
        var total: CGFloat = 0
        for column in columns {
            positions.append(total)
            if column.shownWindow(excluding: exclusions) != nil {
                total += column[keyPath: pass.primarySpanKeyPath] + pass.gap
            }
        }
        positions.append(total)
        return positions
    }

    private func viewPosition(
        _ state: ViewportState,
        columns: [NiriContainer],
        exclusions: Set<WindowToken>,
        pass: NiriLayoutPass
    ) -> CGFloat {
        viewPosition(state, in: stripPositions(columns, exclusions: exclusions, pass: pass))
    }

    private func viewPosition(_ state: ViewportState, in positions: [CGFloat]) -> CGFloat {
        positions[min(max(state.activeColumnIndex, 0), positions.count - 1)] + state.viewOffset
    }

    private func restoreView(
        to before: CGFloat,
        returning returningIndices: [Int],
        change: ExclusionChange,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        let positionsNow = stripPositions(change.columns, exclusions: change.previous, pass: pass)
        let viewNow = viewPosition(state, in: positionsNow)
        resolvePrimaryContainerSpansIfNeeded(pass: pass)
        guard let index = returningIndices.first else { return }
        let positionsThen = stripPositions(change.columns, exclusions: change.current, pass: pass)
        state.rebaseOffset(by: before - positionsThen[index] - state.viewOffset)
        state.activeColumnIndex = index
        if let window = change.columns[index].shownWindow(excluding: change.current) {
            state.selectedNodeId = window.id
        }
        for (other, column) in change.columns.enumerated() where !returningIndices.contains(other)
            && column.shownWindow(excluding: change.current) != nil
        {
            let shift = (positionsNow[other] - viewNow) - (positionsThen[other] - before)
            slide(column, from: shift, pass: pass)
        }
    }

    private func reanchorView(
        awayFrom index: Int,
        change: ExclusionChange,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        let isShown: (Int) -> Bool = { candidate in
            change.columns[candidate].shownWindow(excluding: change.current) != nil
        }
        guard let anchor = (0 ..< index).reversed().first(where: isShown)
            ?? ((index + 1) ..< change.columns.count).first(where: isShown)
        else { return }
        let positions = stripPositions(change.columns, exclusions: change.previous, pass: pass)
        state.rebaseOffset(by: viewPosition(state, in: positions) - positions[anchor] - state.viewOffset)
        state.activeColumnIndex = anchor
    }

    private func anchorView(
        at index: Int,
        change: ExclusionChange,
        pass: NiriLayoutPass,
        state: inout ViewportState
    ) {
        let positions = stripPositions(change.columns, exclusions: change.current, pass: pass)
        state.rebaseOffset(by: positions[state.activeColumnIndex] - positions[index + 1])
        state.activeColumnIndex = index
        if let window = change.columns[index].shownWindow(excluding: change.current) {
            state.selectedNodeId = window.id
        }
    }

    private func slideAside(_ columns: ArraySlice<NiriContainer>, by offset: CGFloat, pass: NiriLayoutPass) {
        for column in columns {
            slide(column, from: -offset, pass: pass)
        }
    }

    private func slide(_ column: NiriContainer, from shift: CGFloat, pass: NiriLayoutPass) {
        guard abs(shift) > 0.5, !column.offsetMoveAnimCurrent(shift, orientation: pass.orientation) else { return }
        pass.engine.animateReorderedColumn(column, displacement: shift, context: pass.interactionContext)
    }
}
