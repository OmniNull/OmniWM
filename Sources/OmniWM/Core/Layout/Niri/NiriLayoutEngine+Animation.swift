// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    struct ColumnRemovalResult {
        let fallbackSelectionId: NodeId?
        let restorePreviousViewOffset: CGFloat?
    }

    func animateColumnsForRemoval(
        columnIndex removedIdx: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> ColumnRemovalResult {
        let cols = columns(in: context.workspaceId)
        guard removedIdx >= 0, removedIdx < cols.count else {
            return ColumnRemovalResult(
                fallbackSelectionId: nil,
                restorePreviousViewOffset: nil
            )
        }

        let activeIdx = state.activeColumnIndex
        let primarySpan = switch context.orientation {
        case .horizontal: cols[removedIdx].cachedWidth
        case .vertical: cols[removedIdx].cachedHeight
        }
        let viewportOffset = primarySpan + context.gaps
        let postRemovalCount = cols.count - 1

        animateColumnsAroundRemoval(
            columns: cols,
            removedIdx: removedIdx,
            activeIdx: activeIdx,
            offset: viewportOffset,
            context: context
        )

        let removingNode = cols[removedIdx].windowNodes.first
        let fallback = removingNode.flatMap { fallbackSelectionOnRemoval(removing: $0.id, in: context.workspaceId) }

        var restorePreviousViewOffset: CGFloat?
        if removedIdx < activeIdx {
            state.activeColumnIndex = activeIdx - 1
            state.rebaseOffset(by: viewportOffset)
        } else if removedIdx == activeIdx,
                  let prevOffset = state.activatePrevColumnOnRemoval
        {
            let newActiveIdx = max(0, activeIdx - 1)
            state.activeColumnIndex = newActiveIdx
            restorePreviousViewOffset = prevOffset
        } else if removedIdx == activeIdx {
            let newActiveIdx = min(activeIdx, max(0, postRemovalCount - 1))
            state.activeColumnIndex = newActiveIdx
        }
        state.activatePrevColumnOnRemoval = nil
        return ColumnRemovalResult(
            fallbackSelectionId: fallback,
            restorePreviousViewOffset: restorePreviousViewOffset
        )
    }

    func animateColumnsAroundRemoval(
        columns cols: [NiriContainer],
        removedIdx: Int,
        activeIdx: Int,
        offset: CGFloat,
        context: NiriInteractionContext
    ) {
        guard removedIdx >= 0, removedIdx < cols.count else { return }

        guard context.motion.animationsEnabled else {
            resetColumnMoveAnimations(cols, in: context.workspaceId)
            return
        }

        let animatedColumns: ArraySlice<NiriContainer>
        let displacement: CGFloat
        if activeIdx <= removedIdx {
            guard removedIdx + 1 < cols.count else { return }
            animatedColumns = cols[(removedIdx + 1)...]
            displacement = offset
        } else {
            animatedColumns = cols[..<removedIdx]
            displacement = -offset
        }

        let movement = switch context.orientation {
        case .horizontal: CGPoint(x: displacement, y: 0)
        case .vertical: CGPoint(x: 0, y: displacement)
        }
        for col in animatedColumns where !col.offsetMoveAnimCurrent(displacement, orientation: context.orientation) {
            col.animateMoveFrom(
                displacement: movement,
                clock: animationClock,
                config: context.motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        }
    }

    func animateColumnsForAddition(
        columnIndex addedIdx: Int,
        context: NiriInteractionContext,
        state: ViewportState
    ) {
        let cols = columns(in: context.workspaceId)
        guard addedIdx >= 0, addedIdx < cols.count else { return }

        let addedCol = cols[addedIdx]
        let activeIdx = state.activeColumnIndex

        let primarySpan = addedColumnSpan(addedCol, context: context)

        guard context.motion.animationsEnabled else {
            resetColumnMoveAnimations(cols, in: context.workspaceId)
            return
        }

        let offset = primarySpan + context.gaps

        let animatedColumns: ArraySlice<NiriContainer>
        let displacement: CGFloat
        if activeIdx <= addedIdx {
            animatedColumns = cols[(addedIdx + 1)...]
            displacement = -offset
        } else {
            animatedColumns = cols[..<addedIdx]
            displacement = offset
        }
        for col in consume animatedColumns where !col.offsetMoveAnimCurrent(
            displacement,
            orientation: context.orientation
        ) {
            let movement = switch context.orientation {
            case .horizontal: CGPoint(x: displacement, y: 0)
            case .vertical: CGPoint(x: 0, y: displacement)
            }
            col.animateMoveFrom(
                displacement: movement,
                clock: animationClock,
                config: context.motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        }
    }

    private func addedColumnSpan(_ addedCol: NiriContainer, context: NiriInteractionContext) -> CGFloat {
        switch context.orientation {
        case .horizontal:
            if addedCol.cachedWidth <= 0 {
                addedCol.resolveAndCacheWidth(
                    workingAreaWidth: context.workingFrame.width,
                    gaps: context.gaps,
                    contentInset: tabContentInset(for: addedCol)
                )
            }
            return addedCol.cachedWidth
        case .vertical:
            if addedCol.cachedHeight <= 0 {
                addedCol.resolveAndCacheHeight(workingAreaHeight: context.workingFrame.height, gaps: context.gaps)
            }
            return addedCol.cachedHeight
        }
    }

    private func resetColumnMoveAnimations(_ columns: [NiriContainer], in workspaceId: WorkspaceDescriptor.ID) {
        for col in columns {
            col.animateMoveFrom(
                displacement: .zero,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate(in: workspaceId),
                animated: false
            )
        }
    }

    func tickAllColumnAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        return Self.tickColumnAnimations(ContiguousArray(root.columns), at: time)
    }

    private static func tickColumnAnimations(_ columns: ContiguousArray<NiriContainer>, at time: TimeInterval) -> Bool {
        var anyRunning = false
        for column in columns {
            if column.tickMoveAnimation(at: time) { anyRunning = true }
            if column.tickWidthAnimation(at: time) { anyRunning = true }
            if column.tickHeightAnimation(at: time) { anyRunning = true }
        }
        return anyRunning
    }

    func hasAnyColumnAnimationsRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        return root.columns.contains {
            $0.hasMoveAnimationRunning || $0.hasWidthAnimationRunning || $0.hasHeightAnimationRunning
        }
    }

    @discardableResult
    func cancelAnimations(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        var hadAnimations = false
        for column in root.columns {
            hadAnimations = hadAnimations || column.hasMoveAnimationRunning || column.hasWidthAnimationRunning
                || column.hasHeightAnimationRunning
            column.stopAnimations()
        }
        for window in root.allWindows {
            hadAnimations = hadAnimations || window.hasMoveAnimationsRunning
            window.stopMoveAnimations()
        }
        return hadAnimations
    }

    func calculateCombinedLayoutWithVisibility(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil,
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil,
        isSettled: Bool = false,
        excludedTokens: Set<WindowToken>? = nil
    ) -> LayoutResult {
        let area = workingArea ?? WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            fullscreenLayoutFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let hiddenPlacementMonitors = monitors.values.map(HiddenPlacementMonitorContext.init)

        let orientation = self.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation

        return calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitor.visibleFrame,
            screenFrame: monitor.frame,
            gaps: gaps.asTuple,
            scale: area.scale,
            workingArea: area,
            orientation: orientation,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            viewOffsetOverride: viewOffsetOverride,
            settledVisibilityOffset: settledVisibilityOffset,
            isSettled: isSettled,
            excludedTokens: excludedTokens
        )
    }

    func calculateCombinedLayoutUsingPools(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil,
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil,
        isSettled: Bool = false,
        excludedTokens: Set<WindowToken>? = nil,
        edgePictures: NiriEdgePictureState = .none,
        recordsPresentationGeometry: Bool = false
    ) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
        layoutPool.frames.removeAll(keepingCapacity: true)
        layoutPool.hiddenHandles.removeAll(keepingCapacity: true)

        let area = workingArea ?? WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            fullscreenLayoutFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let hiddenPlacementMonitors = monitors.values.map(HiddenPlacementMonitorContext.init)

        let orientation = self.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation

        calculateLayoutInto(
            result: &layoutPool,
            state: state,
            workspaceId: workspaceId,
            geometry: NiriLayoutGeometry(workingArea: area, gaps: gaps, orientation: orientation),
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            viewOffsetOverride: viewOffsetOverride,
            settledVisibilityOffset: settledVisibilityOffset,
            isSettled: isSettled,
            excludedTokens: excludedTokens, edgePictures: edgePictures,
            recordsPresentationGeometry: recordsPresentationGeometry
        )

        return (layoutPool.frames, layoutPool.hiddenHandles)
    }

    func captureWindowFrames(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedTokens: Set<WindowToken> = []
    ) -> [WindowToken: CGRect] {
        guard let root = root(for: workspaceId) else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        for window in root.allWindows where !excludedTokens.contains(window.token) {
            if let frame = window.renderedFrame ?? window.frame {
                frames[window.token] = frame
            }
        }
        return frames
    }

    func triggerMoveAnimations(
        in workspaceId: WorkspaceDescriptor.ID,
        oldFrames: [WindowToken: CGRect],
        newFrames: [WindowToken: CGRect],
        motion: MotionSnapshot,
        yContainmentFrame: CGRect? = nil,
        threshold: CGFloat = 1.0
    ) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        var anyAnimationStarted = false

        for window in root.allWindows {
            guard let oldFrame = oldFrames[window.token],
                  let newFrame = newFrames[window.token]
            else {
                continue
            }

            let dx = oldFrame.origin.x - newFrame.origin.x
            let dy = oldFrame.origin.y - newFrame.origin.y

            if abs(dx) > threshold || abs(dy) > threshold {
                window.animateMoveFrom(
                    displacement: CGPoint(x: dx, y: dy),
                    yContainmentFrame: yContainmentFrame,
                    clock: animationClock,
                    config: motion.scaled(windowMovementAnimationConfig),
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
                anyAnimationStarted = true
            }
        }

        return anyAnimationStarted
    }

    func hasAnyWindowAnimationsRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        return root.allWindows.contains { $0.hasMoveAnimationsRunning }
    }

    func tickAllWindowAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        return Self.tickWindowAnimations(ContiguousArray(root.allWindows), at: time)
    }

    private static func tickWindowAnimations(_ windows: ContiguousArray<NiriWindow>, at time: TimeInterval) -> Bool {
        var anyRunning = false
        for window in windows where window.tickMoveAnimations(at: time) {
            anyRunning = true
        }
        return anyRunning
    }

    func animateProjectedColumns(
        from previous: NiriProjectedGeometrySnapshot,
        to current: NiriProjectedGeometrySnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        orientation: Monitor.Orientation
    ) {
        for geometry in current.columns {
            let column = geometry.projectedColumn.column
            guard motion.animationsEnabled else {
                column.animateMoveFrom(
                    displacement: .zero,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: false
                )
                continue
            }
            guard let previousGeometry = previous.column(containing: column) else { continue }
            let displacement = switch orientation {
            case .horizontal:
                CGPoint(x: previousGeometry.primaryPosition - geometry.primaryPosition, y: 0)
            case .vertical:
                CGPoint(x: 0, y: previousGeometry.primaryPosition - geometry.primaryPosition)
            }
            guard displacement != .zero else { continue }
            column.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: workspaceId),
                animated: motion.animationsEnabled
            )
        }
    }
}
