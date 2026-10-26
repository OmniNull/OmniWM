// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension NiriLayoutEngine {
    @discardableResult
    func centerColumn(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        assertSanctionedMutation()
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let scale = displayScale(in: context.workspaceId)
        let viewFrame = monitorForWorkspace(context.workspaceId)?.frame
        return withProjectedViewport(
            state: &state,
            context: context
        ) { columns, projectedState in
            let singleOrigin = singleWindowGestureOrigin(context: context)
            projectedState.rebaseOffset(by: singleOrigin)
            defer { projectedState.rebaseOffset(by: -singleOrigin) }
            let activeIndex = projectedState.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
            projectedState.activeColumnIndex = activeIndex
            cancelInteractiveResize(for: columns[activeIndex], in: context.workspaceId)
            let targetOffset = projectedState.computeCenteredOffset(
                containerIndex: activeIndex,
                containers: columns,
                context: context,
                viewFrame: viewFrame,
                scale: scale
            )
            projectedState.preservesGestureOffset = false
            projectedState.animateToOffset(
                targetOffset,
                motion: context.motion,
                scale: scale
            )
            return true
        } ?? false
    }

    @discardableResult
    func centerVisibleColumns(context: NiriInteractionContext, state: inout ViewportState) -> Bool {
        assertSanctionedMutation()
        let settings = effectiveSettings(in: context.workspaceId)
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let viewportSpan: CGFloat = switch context.orientation {
        case .horizontal: context.workingFrame.width
        case .vertical: context.workingFrame.height
        }

        let scale = displayScale(in: context.workspaceId)
        let viewFrame = monitorForWorkspace(context.workspaceId)?.frame
        return withProjectedViewport(
            state: &state,
            context: context
        ) { columns, projectedState in
            let singleOrigin = singleWindowGestureOrigin(context: context)
            projectedState.rebaseOffset(by: singleOrigin)
            defer { projectedState.rebaseOffset(by: -singleOrigin) }
            guard projectedState.preservesGestureOffset
                || (settings.centerFocusedColumn != .always
                    && (!settings.alwaysCenterSingleColumn || columns.count > 1))
            else {
                return false
            }

            let activeIndex = projectedState.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
            projectedState.activeColumnIndex = activeIndex
            guard let targetOffset = centeredVisibleColumnsOffset(
                columns: columns,
                state: projectedState,
                geometry: NiriViewportGeometry(
                    gap: context.gaps,
                    viewportSpan: viewportSpan,
                    orientation: context.orientation,
                    workingArea: context.workingFrame,
                    viewFrame: viewFrame,
                    scale: scale
                )
            ) ?? (projectedState.preservesGestureOffset ? projectedState.computeCenteredOffset(
                containerIndex: activeIndex,
                containers: columns,
                context: context,
                viewFrame: viewFrame,
                scale: scale
            ) : nil) else { return false }
            cancelInteractiveResize(for: columns[activeIndex], in: context.workspaceId)

            projectedState.animateToOffset(targetOffset, motion: context.motion, scale: scale)
            projectedState.ensureContainerVisible(
                containerIndex: activeIndex,
                containers: columns,
                context: context,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
                scale: scale,
                viewFrame: viewFrame
            )
            return true
        } ?? false
    }

    private func centeredVisibleColumnsOffset(
        columns: [NiriContainer],
        state: ViewportState,
        geometry: NiriViewportGeometry
    ) -> CGFloat? {
        let areas = ViewportFittingAreas(geometry: geometry)
        let gap = geometry.gap
        let sizeKeyPath = areas.orientation.settledSpanKeyPath
        let activePosition = state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let viewStart = activePosition + state.viewOffset
        let workingStart = areas.origin(of: areas.working)
        let workingSpan = areas.span(of: areas.working)

        var spanTaken: CGFloat = 0
        var firstVisiblePosition: CGFloat?
        var activeContainerPosition: CGFloat?

        for (idx, column) in columns.enumerated() {
            let position = state.containerPosition(
                at: idx,
                containers: columns,
                gap: gap,
                sizeKeyPath: sizeKeyPath
            )
            if position < viewStart + workingStart + gap {
                continue
            }

            if firstVisiblePosition == nil {
                firstVisiblePosition = position
            }

            let span = column[keyPath: sizeKeyPath]
            if viewStart + workingStart + workingSpan < position + span + gap {
                break
            }

            if idx == state.activeColumnIndex {
                activeContainerPosition = position
            }

            spanTaken += span + gap
        }

        guard let firstVisiblePosition, let activeContainerPosition else { return nil }
        let freeSpace = workingSpan - spanTaken + gap
        let newViewStart = firstVisiblePosition - freeSpace / 2 - workingStart
        return newViewStart - activeContainerPosition
    }
}
