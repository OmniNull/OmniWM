// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension NiriLayoutEngine {
    func onScreenProjectedColumns(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        geometry: NiriSizingGeometry
    ) -> [NiriProjectedColumn] {
        let projected = projectedColumns(in: workspaceId)
        let relations = viewportRelations(of: projected, in: workspaceId, state: state, geometry: geometry)
        var onScreen: [NiriProjectedColumn] = []
        onScreen.reserveCapacity(projected.count)
        for index in projected.indices where relations[index] == .intersecting && !projected[index].windows.isEmpty {
            onScreen.append(projected[index])
        }
        return onScreen
    }

    func shrinkVisibleColumnsToFit(
        around resized: NiriContainer,
        onScreen: [NiriProjectedColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        guard onScreen.count > 1,
              let resizedIndex = onScreen.firstIndex(where: { $0.column === resized }),
              let targets = shrinkToFitTargets(onScreen, resizedIndex: resizedIndex, context: context)
        else { return }

        let workspace = ensureState(for: context.workspaceId)
        let resizedSpan = rawProjectedPrimarySpan(
            for: onScreen[resizedIndex],
            workingFrame: context.workingFrame,
            gap: context.gaps,
            orientation: context.orientation
        )
        for index in onScreen.indices {
            let column = onScreen[index].column
            if index == resizedIndex, targets[index] >= resizedSpan { continue }
            applyShrinkToFitSpan(targets[index], to: column, context: context)
            workspace.shrinkToFitColumnIds.insert(column.id)
        }
        workspace.shrinkToFitGeometry = NiriShrinkToFitGeometry(
            context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        alignViewport(toFirstOf: onScreen, context: context, state: &state)
    }

    func shrinkToFitTargets(
        _ onScreen: [NiriProjectedColumn],
        resizedIndex: Int,
        context: NiriInteractionContext
    ) -> [CGFloat]? {
        let workingSpan = context.orientation == .horizontal ? context.workingFrame.width : context.workingFrame.height
        let available = workingSpan - CGFloat(onScreen.count + 1) * context.gaps
        let constrained = { (span: CGFloat, index: Int) -> CGFloat in
            self.constrainedProjectedPrimarySpan(
                span,
                for: onScreen[index],
                workingFrame: context.workingFrame,
                gap: context.gaps,
                orientation: context.orientation
            )
        }
        let raw = onScreen.indices.map { index in
            rawProjectedPrimarySpan(
                for: onScreen[index],
                workingFrame: context.workingFrame,
                gap: context.gaps,
                orientation: context.orientation
            )
        }
        let others = onScreen.indices.filter { $0 != resizedIndex }
        let othersMinimum = others.reduce(CGFloat(0)) { $0 + constrained(0, $1) }
        var targets = raw
        targets[resizedIndex] = constrained(min(raw[resizedIndex], available - othersMinimum), resizedIndex)

        var free = others
        var budget = available - targets[resizedIndex]
        for _ in others.indices {
            let weight = free.reduce(CGFloat(0)) { $0 + raw[$1] }
            guard weight > 0 else { break }
            let pinned = free.filter { constrained(raw[$0] * budget / weight, $0) != raw[$0] * budget / weight }
            guard !pinned.isEmpty else {
                for index in free {
                    targets[index] = raw[index] * budget / weight
                }
                free = []
                break
            }
            for index in pinned {
                targets[index] = constrained(raw[index] * budget / weight, index)
                budget -= targets[index]
            }
            free.removeAll { pinned.contains($0) }
        }
        guard free.isEmpty else { return nil }
        let overflow = targets.reduce(0, +) - available
        if overflow > 0 {
            targets[resizedIndex] = constrained(targets[resizedIndex] - overflow, resizedIndex)
        }
        let tolerance = available.ulp * CGFloat(onScreen.count * 4)
        guard targets.reduce(0, +) <= available + tolerance else { return nil }
        return targets
    }

    func dropStaleShrinkToFit(
        _ columns: [NiriContainer],
        in workspace: NiriWorkspaceState,
        _ geometry: NiriShrinkToFitGeometry
    ) {
        guard !workspace.shrinkToFitColumnIds.isEmpty else { return }
        let stored = workspace.shrinkToFitGeometry
        let manualCount = geometry.orientation == .horizontal
            ? workspace.manualWidthColumnCount
            : workspace.manualHeightColumnCount
        if manualCount != nil, stored == geometry { return }
        if let stored, manualCount != nil || stored.orientation != geometry.orientation {
            for column in columns where workspace.shrinkToFitColumnIds.contains(column.id) {
                column.invalidateCachedPrimarySpan(orientation: stored.orientation)
                switch stored.orientation {
                case .horizontal: column.fittedWidth = nil
                case .vertical: column.fittedHeight = nil
                }
            }
        }
        workspace.shrinkToFitColumnIds.removeAll()
        workspace.shrinkToFitGeometry = nil
    }

    @discardableResult
    func releaseShrinkToFit(_ column: NiriContainer, in workspace: NiriWorkspaceState) -> Bool {
        guard workspace.shrinkToFitColumnIds.remove(column.id) != nil,
              let geometry = workspace.shrinkToFitGeometry
        else { return false }
        let proportionalSpan = geometry.span - geometry.gaps
        switch geometry.orientation {
        case .horizontal:
            if let fittedWidth = column.fittedWidth, proportionalSpan > 0, !column.isFullWidth {
                column.width = .proportion((fittedWidth + geometry.gaps) / proportionalSpan)
            }
            column.fittedWidth = nil
        case .vertical:
            if let fittedHeight = column.fittedHeight, proportionalSpan > 0, !column.isFullHeight {
                column.height = .proportion((fittedHeight + geometry.gaps) / proportionalSpan)
            }
            column.fittedHeight = nil
        }
        return true
    }

    private func applyShrinkToFitSpan(_ span: CGFloat, to column: NiriContainer, context: NiriInteractionContext) {
        switch context.orientation {
        case .horizontal:
            applyPrimarySpanFitWidth(
                span, fitted: true, to: column, in: context.workspaceId, motion: context.motion
            )
        case .vertical:
            applyPrimarySpanFitHeight(
                span, fitted: true, to: column, in: context.workspaceId, motion: context.motion
            )
        }
    }

    private func alignViewport(
        toFirstOf onScreen: [NiriProjectedColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let scale = displayScale(in: context.workspaceId)
        _ = withProjectedViewport(state: &state, context: context) { columns, projectedState in
            guard let firstIndex = columns.firstIndex(where: { $0 === onScreen.first?.column }) else { return }
            let keyPath = context.orientation.settledSpanKeyPath
            let firstPosition = projectedState.containerPosition(
                at: firstIndex, containers: columns, gap: context.gaps, sizeKeyPath: keyPath
            )
            let activePosition = projectedState.containerPosition(
                at: projectedState.activeColumnIndex, containers: columns, gap: context.gaps, sizeKeyPath: keyPath
            )
            projectedState.animateToOffset(
                firstPosition - context.gaps - activePosition,
                motion: context.motion,
                scale: scale
            )
        }
    }
}
