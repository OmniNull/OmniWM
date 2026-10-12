// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

struct LayoutResult {
    var frames: [WindowToken: CGRect]
    var hiddenHandles: [WindowToken: HideSide]
}

struct NiriContainerPlacement {
    let canonicalRect: CGRect
    let renderedRect: CGRect
    let secondarySpanOverride: CGFloat?
}

extension NiriLayoutEngine {
    func calculateLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation,
        isSettled: Bool = false,
        excludedTokens: Set<WindowToken>? = nil
    ) -> [WindowToken: CGRect] {
        calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation,
            isSettled: isSettled,
            excludedTokens: excludedTokens
        ).frames
    }

    func calculateLayoutWithVisibility(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = [],
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil,
        isSettled: Bool = false,
        excludedTokens: Set<WindowToken>? = nil
    ) -> LayoutResult {
        var result = LayoutResult(frames: [:], hiddenHandles: [:])
        let gaps = LayoutGaps(horizontal: gaps.horizontal, vertical: gaps.vertical)
        let geometry: NiriLayoutGeometry
        if let workingArea {
            geometry = NiriLayoutGeometry(workingArea: workingArea, gaps: gaps, orientation: orientation)
        } else {
            geometry = NiriLayoutGeometry(
                monitorFrame: monitorFrame,
                screenFrame: screenFrame,
                scale: scale,
                gaps: gaps,
                orientation: orientation
            )
        }
        calculateLayoutInto(
            result: &result,
            state: state,
            workspaceId: workspaceId,
            geometry: geometry,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            viewOffsetOverride: viewOffsetOverride,
            settledVisibilityOffset: settledVisibilityOffset,
            isSettled: isSettled,
            excludedTokens: excludedTokens
        )
        return result
    }

    func calculateLayoutInto(
        result: inout LayoutResult,
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        geometry: NiriLayoutGeometry,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = [],
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil,
        isSettled: Bool = false,
        excludedTokens: Set<WindowToken>? = nil
    ) {
        if let excludedTokens { setProjectionExclusions(excludedTokens, in: workspaceId) }
        let excludedTokens = projectionExclusions(in: workspaceId)
        let projectedColumns = projectedColumns(in: workspaceId)
        guard !projectedColumns.isEmpty else { return }
        let context = NiriCalculationContext(
            geometry: geometry, time: animationTime ?? CACurrentMediaTime(),
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        )
        clearExcludedColumnFrames(in: workspaceId, excluding: excludedTokens)
        if animationTime == nil {
            reconcilePrimarySpanFit(
                in: workspaceId,
                workingFrame: context.area.workingFrame,
                gaps: context.primaryGap,
                orientation: context.orientation,
                motion: nil
            )
        }
        if let single = singleWindowLayoutContext(in: workspaceId, excluding: excludedTokens) {
            layoutSingleWindow(single, context: context, result: &result)
            return
        }
        let prepared = prepareLayoutColumns(
            projectedColumns, area: context.area, primaryGap: context.primaryGap,
            time: context.time, orientation: context.orientation
        )
        let sampling = NiriViewportSampling(
            viewOffset: viewOffsetOverride ?? state.viewOffset,
            settledVisibilityOffset: settledVisibilityOffset,
            isSettled: isSettled
        )
        let pass = columnLayoutPass(
            selection: NiriViewportSelection(state: state, workspaceId: workspaceId), columns: projectedColumns,
            prepared: prepared, context: context, sampling: sampling
        )
        for index in projectedColumns.indices {
            layoutProjectedColumn(
                projectedColumns[index], prepared: prepared[index], at: index, pass: pass, result: &result
            )
        }
    }

    func prepareLayoutColumns(
        _ projectedColumns: [NiriProjectedColumn],
        area: WorkingAreaContext,
        primaryGap: CGFloat,
        time: TimeInterval,
        orientation: Monitor.Orientation
    ) -> [NiriPreparedLayoutColumn] {
        for projectedColumn in projectedColumns
            where projectedColumn.windows.count == projectedColumn.column.windowNodes.count
        {
            switch orientation {
            case .horizontal:
                if projectedColumn.column.cachedWidth <= 0 {
                    projectedColumn.column.resolveAndCacheWidth(
                        workingAreaWidth: area.workingFrame.width,
                        gaps: primaryGap,
                        contentInset: projectedColumn.windows.count > 1
                            ? tabContentInset(for: projectedColumn.column)
                            : 0
                    )
                }
            case .vertical:
                if projectedColumn.column.cachedHeight <= 0 {
                    projectedColumn.column.resolveAndCacheHeight(
                        workingAreaHeight: area.workingFrame.height,
                        gaps: primaryGap
                    )
                }
            }
        }

        var columns: [NiriPreparedLayoutColumn] = []
        columns.reserveCapacity(projectedColumns.count)
        var runningPos: CGFloat = 0
        for projectedColumn in projectedColumns {
            let span = projectedPrimarySpan(
                for: projectedColumn,
                workingFrame: area.workingFrame,
                gap: primaryGap,
                orientation: orientation
            )
            columns.append(NiriPreparedLayoutColumn(
                span: span,
                renderOffset: projectedColumn.column.renderOffset(at: time),
                position: runningPos
            ))
            runningPos += span + primaryGap
        }

        return columns
    }

    func layoutContainer(
        container: NiriContainer,
        windows: [NiriWindow],
        placement: NiriContainerPlacement,
        context: NiriContainerLayoutContext,
        result: inout [WindowToken: CGRect]
    ) {
        let layoutFrames = context.frames
        let secondaryGap = context.secondaryGap
        container.frame = placement.canonicalRect
        container.renderedFrame = placement.renderedRect

        guard !windows.isEmpty else { return }

        let isTabbed = container.isTabbed && windows.count > 1
        let tabOffset = isTabbed ? renderStyle.tabIndicatorWidth : 0
        let containerFrames = NiriContainerLayoutFrames(
            canonicalRect: placement.canonicalRect,
            renderedRect: placement.renderedRect,
            tabOffset: tabOffset,
            layoutFrames: layoutFrames
        )

        let availableSpace = containerFrames.secondarySpan()

        let resolvedSpans = resolveWindowSpans(
            container: container,
            windows: windows,
            axis: NiriAxisLayout(
                availableSpace: availableSpace,
                gap: secondaryGap,
                isTabbed: isTabbed,
                orientation: layoutFrames.orientation
            ),
            secondarySpanOverride: placement.secondarySpanOverride
        )

        var pos = containerFrames.secondaryStart(gap: secondaryGap)

        for i in 0 ..< windows.count {
            let window = windows[i]
            let span = resolvedSpans[i].value
            let sizingMode = window.sizingMode

            let layout = containerFrames.windowLayout(
                for: sizingMode,
                position: pos,
                span: span,
                layoutFrames: layoutFrames
            )
            let renderedFrame = window.applyLayout(
                layout,
                sizingMode: sizingMode,
                within: containerFrames,
                at: context.time
            )
            result[window.token] = renderedFrame

            if !isTabbed {
                pos += span
                if i < windows.count - 1 {
                    pos += secondaryGap
                }
            }
        }
    }

    func resolveWindowSpans(
        container: NiriContainer,
        windows: [NiriWindow],
        axis: NiriAxisLayout,
        secondarySpanOverride: CGFloat?
    ) -> [NiriAxisSolver.Output] {
        if let secondarySpanOverride, windows.count == 1 {
            return [.init(value: secondarySpanOverride, wasConstrained: false)]
        }
        guard !windows.isEmpty else { return [] }

        let cacheKey = NiriAxisSolveKey(
            containerId: container.id,
            containerRevision: container.axisSolveRevision,
            configurationRevision: axisSolveConfigurationRevision,
            availableSpace: axis.availableSpace,
            gap: axis.gap,
            isTabbed: axis.isTabbed,
            isVertical: axis.orientation == .vertical
        )
        let outputs: [NiriAxisSolver.Output]
        if let cached = axisSolveCache[cacheKey] {
            outputs = cached
        } else {
            let inputs = windows.map { window in
                axisSolverInput(for: window, axis: axis)
            }
            let hardOutputs = NiriAxisSolver.solve(
                windows: inputs,
                availableSpace: axis.availableSpace,
                gapSize: axis.gap,
                isTabbed: axis.isTabbed
            )
            outputs = packedSecondarySpans(
                windows: windows,
                inputs: inputs,
                hardOutputs: hardOutputs,
                axis: axis
            )
            if axisSolveCache.count >= 256 {
                axisSolveCache.removeAll(keepingCapacity: true)
            }
            axisSolveCache[cacheKey] = outputs
        }

        for (i, output) in outputs.enumerated() {
            switch axis.orientation {
            case .horizontal:
                windows[i].heightFixedByConstraint = output.wasConstrained
            case .vertical:
                windows[i].widthFixedByConstraint = output.wasConstrained
            }
        }

        return outputs
    }

    private func packedSecondarySpans(
        windows: [NiriWindow],
        inputs: [NiriAxisSolver.Input],
        hardOutputs: [NiriAxisSolver.Output],
        axis: NiriAxisLayout
    ) -> [NiriAxisSolver.Output] {
        let gapCount = axis.isTabbed ? 2 : windows.count + 1
        let usableSpace = max(0, axis.availableSpace - axis.gap * CGFloat(gapCount))
        var packedInputs = inputs
        var floorSum: CGFloat = 0
        var packed = false
        for index in windows.indices {
            let input = inputs[index]
            var floor = max(NiriAxisSolver.minimumRenderableSpan, input.minConstraint)
            if let hinted = windows[index].packingHints.secondary(for: axis.orientation)?
                .floor(for: hardOutputs[index].value, limit: usableSpace),
                hinted > floor
            {
                floor = hinted
                packed = true
                packedInputs[index] = NiriAxisSolver.Input(
                    weight: input.weight,
                    minConstraint: hinted,
                    maxConstraint: input.maxConstraint,
                    hasMaxConstraint: input.hasMaxConstraint,
                    isConstraintFixed: input.isConstraintFixed,
                    hasFixedValue: input.hasFixedValue,
                    fixedValue: input.fixedValue
                )
            }
            floorSum += axis.isTabbed ? 0 : floor
        }
        guard packed, floorSum <= usableSpace + 0.001 else { return hardOutputs }
        return NiriAxisSolver.solve(
            windows: packedInputs,
            availableSpace: axis.availableSpace,
            gapSize: axis.gap,
            isTabbed: axis.isTabbed
        )
    }

    private func axisSolverInput(
        for window: NiriWindow,
        axis: NiriAxisLayout
    ) -> NiriAxisSolver.Input {
        let specification = switch axis.orientation {
        case .horizontal: window.height
        case .vertical: window.windowWidth
        }
        let fixedValue: CGFloat?
        switch specification {
        case let .fixed(value):
            fixedValue = value
        case .auto:
            fixedValue = nil
        case let .preset(index):
            fixedValue = resolvePresetSpan(
                presetWindowSecondarySpans,
                index: index,
                availableSpace: axis.availableSpace,
                gap: axis.gap
            )
        }
        return window.axisSolverInput(
            orientation: axis.orientation,
            hasFixedValue: !specification.isAuto,
            fixedValue: fixedValue
        )
    }

    func resolvePresetSpan(
        _ presets: [PresetSize],
        index: Int,
        availableSpace: CGFloat,
        gap: CGFloat
    ) -> CGFloat? {
        guard presets.indices.contains(index) else { return nil }
        switch presets[index].kind {
        case let .proportion(proportion):
            return (availableSpace - gap) * proportion - gap
        case let .fixed(value):
            return value
        }
    }
}
