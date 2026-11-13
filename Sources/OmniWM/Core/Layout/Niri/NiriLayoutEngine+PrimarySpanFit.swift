// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension NiriLayoutEngine {
    func reconcilePrimarySpanFit(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        motion: MotionSnapshot?
    ) {
        let columns = columns(in: workspaceId)
        let workspace = ensureState(for: workspaceId)
        let manualCountKey: ReferenceWritableKeyPath<NiriWorkspaceState, Int?> = orientation == .horizontal
            ? \.manualWidthColumnCount : \.manualHeightColumnCount
        let hasPreviousFit = columns.contains {
            orientation == .horizontal ? $0.fittedWidth != nil : $0.fittedHeight != nil
        }
        let visibleCount = effectiveVisibleContainerCount(in: workspaceId)
        let exclusions = projectionExclusions(in: workspaceId)
        if exclusions.isEmpty, columns.count >= visibleCount, !hasPreviousFit,
           workspace.manualWidthColumnCount == nil, workspace.manualHeightColumnCount == nil,
           workspace.shrinkToFitColumnIds.isEmpty
        {
            return
        }

        let projected = projectedColumns(in: workspaceId).filter { !$0.windows.isEmpty }
        let count = projected.count
        if workspace.manualWidthColumnCount != count { workspace.manualWidthColumnCount = nil }
        if workspace.manualHeightColumnCount != count { workspace.manualHeightColumnCount = nil }
        dropStaleShrinkToFit(columns, in: workspace, .init(workingFrame, gaps: gaps, orientation: orientation))
        let isSingleWindow = count == 1 && projected[0].windows.count == 1
        let manual = workspace[keyPath: manualCountKey] != nil && !isSingleWindow
        let canFit = !manual && count > 0 && count < visibleCount && !isSingleWindow
        guard canFit || hasPreviousFit else { return }

        clearExcludedPrimarySpanFits(columns, excluding: exclusions, orientation: orientation)
        let rawSpans = projected.map {
            rawProjectedPrimarySpan(for: $0, workingFrame: workingFrame, gap: gaps, orientation: orientation)
        }
        let rawTotal = rawSpans.reduce(0, +)
        let workingSpan = orientation == .horizontal ? workingFrame.width : workingFrame.height
        let availableSpan = workingSpan - CGFloat(count + 1) * gaps
        let fits = canFit && rawTotal > 0 && rawTotal < availableSpan
        let context = NiriInteractionContext(
            workspaceId: workspaceId,
            motion: isSingleWindow ? .disabled : motion ?? .disabled,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let targets = fits
            ? primarySpanFitTargets(projected, rawSpans: rawSpans, availableSpan: availableSpan, context: context)
            : rawSpans
        applyPrimarySpanFitTargets(projected, targets: targets, fits: fits, manual: manual, context: context)
    }

    private func applyPrimarySpanFitTargets(
        _ projected: [NiriProjectedColumn],
        targets: [CGFloat],
        fits: Bool,
        manual: Bool,
        context: NiriInteractionContext
    ) {
        for index in projected.indices {
            let column = projected[index].column
            let previousFit = context.orientation == .horizontal ? column.fittedWidth : column.fittedHeight
            guard fits || previousFit != nil else { continue }
            let retainedFit = manual ? previousFit : nil
            let target = retainedFit.map {
                constrainedProjectedPrimarySpan(
                    $0, for: projected[index], workingFrame: context.workingFrame, gap: context.gaps,
                    orientation: context.orientation
                )
            } ?? targets[index]
            let fitted = fits || retainedFit != nil
            switch context.orientation {
            case .horizontal:
                applyPrimarySpanFitWidth(
                    target,
                    fitted: fitted,
                    to: column,
                    in: context.workspaceId,
                    motion: context.motion
                )
            case .vertical:
                applyPrimarySpanFitHeight(
                    target,
                    fitted: fitted,
                    to: column,
                    in: context.workspaceId,
                    motion: context.motion
                )
            }
        }
    }

    func beginManualPrimarySpanResize(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) {
        let workspace = ensureState(for: workspaceId)
        releaseShrinkToFit(column, in: workspace)
        switch orientation {
        case .horizontal:
            if workspace.manualWidthColumnCount == nil {
                workspace.manualWidthColumnCount = projectedColumns(in: workspaceId).count
            }
            if let fittedWidth = column.fittedWidth {
                column.width = .fixed(column.settledWidth > 0 ? column.settledWidth : fittedWidth)
                column.presetWidthIdx = nil
                column.fittedWidth = nil
            }
        case .vertical:
            if workspace.manualHeightColumnCount == nil {
                workspace.manualHeightColumnCount = projectedColumns(in: workspaceId).count
            }
            if let fittedHeight = column.fittedHeight {
                column.height = .fixed(column.cachedHeight > 0 ? column.cachedHeight : fittedHeight)
                column.fittedHeight = nil
            }
        }
    }

    func primarySpanFitTargets(
        _ projected: [NiriProjectedColumn],
        rawSpans: [CGFloat],
        availableSpan: CGFloat,
        context: NiriInteractionContext
    ) -> [CGFloat] {
        let maximums = primarySpanFitMaximums(projected, orientation: context.orientation)
        var targets = proportionalPrimarySpanFit(
            rawSpans, maximums: maximums, availableSpan: availableSpan
        )
        for index in projected.indices {
            targets[index] = constrainedProjectedPrimarySpan(
                targets[index],
                for: projected[index],
                workingFrame: context.workingFrame,
                gap: context.gaps,
                orientation: context.orientation
            )
        }
        return targets
    }

    func primarySpanFitMaximums(
        _ projected: [NiriProjectedColumn], orientation: Monitor.Orientation
    ) -> [CGFloat?] {
        projected.map { column -> CGFloat? in
            let inset = orientation == .horizontal && column.windows.count > 1
                ? tabContentInset(for: column.column) : 0
            return projectedPrimaryBounds(
                of: column.windows, orientation: orientation, contentInset: inset
            ).max
        }
    }

    private func clearExcludedPrimarySpanFits(
        _ columns: [NiriContainer],
        excluding exclusions: Set<WindowToken>,
        orientation: Monitor.Orientation
    ) {
        guard !exclusions.isEmpty else { return }
        for column in columns where column.windowNodes.allSatisfy({ exclusions.contains($0.token) }) {
            let wasFitted = orientation == .horizontal
                ? column.fittedWidth != nil
                : column.fittedHeight != nil
            if wasFitted {
                column.invalidateCachedPrimarySpan(orientation: orientation)
                switch orientation {
                case .horizontal: column.fittedWidth = nil
                case .vertical: column.fittedHeight = nil
                }
            }
        }
    }

    func proportionalPrimarySpanFit(
        _ spans: [CGFloat],
        maximums: [CGFloat?],
        availableSpan: CGFloat
    ) -> [CGFloat] {
        var targets = spans
        var remainingSpan = availableSpan
        var remainingWeight = spans.reduce(0, +)
        var capped = Array(repeating: false, count: spans.count)
        for _ in spans.indices {
            guard remainingWeight > 0 else { break }
            let scale = remainingSpan / remainingWeight
            var foundCap = false
            for index in spans.indices where !capped[index] {
                if let maximum = maximums[index], spans[index] * scale > maximum {
                    targets[index] = maximum
                    remainingSpan -= maximum
                    remainingWeight -= spans[index]
                    capped[index] = true
                    foundCap = true
                }
            }
            if !foundCap {
                for index in spans.indices where !capped[index] {
                    targets[index] = spans[index] * scale
                }
                return targets
            }
        }
        return targets
    }

    func applyPrimarySpanFitWidth(
        _ target: CGFloat,
        fitted: Bool,
        to column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot?
    ) {
        let wasFitted = column.fittedWidth != nil
        let changed = abs(column.settledWidth - target) > 0.0001
        let animated = changed && column.cachedWidth > 0 && motion?.animationsEnabled == true
        column.fittedWidth = fitted || (wasFitted && (animated || column.widthAnimation != nil)) ? target : nil
        guard changed else { return }
        column.animateWidthTo(
            newWidth: target,
            clock: animationClock,
            config: (motion ?? .disabled).scaled(windowMovementAnimationConfig),
            displayRefreshRate: displayRefreshRate(in: workspaceId),
            animated: animated
        )
    }

    func applyPrimarySpanFitHeight(
        _ target: CGFloat,
        fitted: Bool,
        to column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot?
    ) {
        let wasFitted = column.fittedHeight != nil
        let changed = abs(column.settledHeight - target) > 0.0001
        let animated = changed && column.cachedHeight > 0 && motion?.animationsEnabled == true
        column.fittedHeight = fitted || (wasFitted && (animated || column.heightAnimation != nil)) ? target : nil
        guard changed else { return }
        column.animateHeightTo(
            newHeight: target,
            clock: animationClock,
            config: (motion ?? .disabled).scaled(windowMovementAnimationConfig),
            displayRefreshRate: displayRefreshRate(in: workspaceId),
            animated: animated
        )
    }
}

extension NiriLayoutEngine {
    func rawProjectedPrimarySpan(
        for projectedColumn: NiriProjectedColumn,
        workingFrame: CGRect,
        gap: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        let column = projectedColumn.column

        let availableSpace = orientation == .horizontal ? workingFrame.width : workingFrame.height
        let spec: ProportionalSize
        let isFull: Bool
        switch orientation {
        case .horizontal:
            spec = column.width
            isFull = column.isFullWidth
        case .vertical:
            spec = column.height
            isFull = column.isFullHeight
        }

        let effectiveSpec = isFull ? ProportionalSize.proportion(1) : spec
        let rawSpan: CGFloat = switch effectiveSpec {
        case let .proportion(proportion):
            (availableSpace - gap) * proportion - gap
        case let .fixed(fixed):
            fixed
        }

        return constrainedProjectedPrimarySpan(
            rawSpan,
            for: projectedColumn,
            workingFrame: workingFrame,
            gap: gap,
            orientation: orientation
        )
    }

    func constrainedProjectedPrimarySpan(
        _ span: CGFloat,
        for projectedColumn: NiriProjectedColumn,
        workingFrame: CGRect,
        gap: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        let windows = projectedColumn.windows
        let availableSpace = orientation == .horizontal ? workingFrame.width : workingFrame.height
        let contentInset = orientation == .horizontal && windows.count > 1
            ? tabContentInset(for: projectedColumn.column)
            : 0
        let bounds = projectedPrimaryBounds(of: windows, orientation: orientation, contentInset: contentInset)
        let clamped = NiriContainer.packedPrimarySpan(
            max(span, bounds.min),
            windows: windows,
            orientation: orientation,
            limit: availableSpace - gap * 2,
            contentInset: contentInset
        )
        return bounds.max.map { min(clamped, $0) } ?? clamped
    }
}
