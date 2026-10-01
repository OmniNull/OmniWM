// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func cancelInteractiveResize(
        for column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let resize = interactiveResize, resize.workspaceId == workspaceId else { return }
        guard let resizeWindow = findNode(by: resize.windowId, in: workspaceId) as? NiriWindow,
              let resizeColumn = findColumn(containing: resizeWindow, in: workspaceId),
              resizeColumn === column
        else {
            return
        }

        clearInteractiveResize()
    }

    func hitTestCandidates(
        in column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> [NiriWindow] {
        let windows = column.children.compactMap { $0 as? NiriWindow }
        guard column.isTabbed,
              let active = projectedActiveWindow(in: column, workspaceId: workspaceId)
        else { return windows }
        return [active] + windows.filter { $0 !== active }
    }

    func hitTestTiled(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        for column in hitTestColumns(in: workspaceId) {
            for window in hitTestCandidates(in: column, workspaceId: workspaceId) {
                guard isProjectedFocusableWindow(window, in: workspaceId),
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if frame.contains(point) {
                    return window
                }
            }
        }

        return nil
    }

    func hitTestFocusableWindow(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        var firstVisibleMatch: NiriWindow?

        for column in hitTestColumns(in: workspaceId) {
            for window in hitTestCandidates(in: column, workspaceId: workspaceId) {
                guard isProjectedFocusableWindow(window, in: workspaceId),
                      let frame = window.renderedFrame ?? window.frame,
                      frame.contains(point)
                else {
                    continue
                }

                if window.isFullscreen {
                    return window
                }

                if firstVisibleMatch == nil {
                    firstVisibleMatch = window
                }
            }
        }

        return firstVisibleMatch
    }

    private func interactiveResizeStartWidth(
        for column: NiriContainer,
        window: NiriWindow,
        workspaceId: WorkspaceDescriptor.ID
    ) -> CGFloat {
        if column.cachedWidth > 0 {
            return column.cachedWidth
        }
        if let width = column.frame?.width, width > 0 {
            return width
        }
        if let width = column.renderedFrame?.width, width > 0 {
            return width
        }
        if let width = window.frame?.width, width > 0 {
            let tabOffset = projectedWindows(in: column, workspaceId: workspaceId).count > 1
                ? renderStyle.tabIndicatorWidth
                : 0
            return width + tabOffset
        }
        return projectedWidthBounds(for: column, workspaceId: workspaceId).min
    }

    private func interactiveResizeStartHeight(
        for column: NiriContainer,
        window: NiriWindow,
        workspaceId: WorkspaceDescriptor.ID
    ) -> CGFloat {
        if column.cachedHeight > 0 {
            return column.cachedHeight
        }
        if let height = column.frame?.height, height > 0 {
            return height
        }
        if let height = column.renderedFrame?.height, height > 0 {
            return height
        }
        if let height = window.frame?.height, height > 0 {
            return height
        }
        return projectedHeightBounds(for: column, workspaceId: workspaceId).min
    }

    func calculateHorizontalPixelsPerWeightUnit(
        column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        guard !windows.isEmpty else { return 0 }

        let totalWeight = windows.reduce(CGFloat(0)) { $0 + $1.widthWeight }
        guard totalWeight > 0 else { return 0 }

        let tabOffset = column.isTabbed && windows.count > 1 ? renderStyle.tabIndicatorWidth : 0
        let totalGaps = CGFloat(windows.count + 1) * gaps.horizontal
        let usableWidth = monitorFrame.width - tabOffset - totalGaps

        return usableWidth / totalWeight
    }

    func interactiveResizeBegin(
        windowId: NodeId,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation,
        viewOffset: CGFloat? = nil
    ) -> Bool {
        guard interactiveResize == nil else { return false }
        guard interactiveMove == nil else { return false }

        guard let windowNode = findNode(by: windowId, in: workspaceId) as? NiriWindow else { return false }
        guard isProjectedFocusableWindow(windowNode, in: workspaceId) else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }
        if windowNode.isFullscreen {
            return false
        }

        if windowNode.constraints.isFixed {
            return false
        }

        let baseline = interactiveResizeBaseline(
            windowNode,
            column: column,
            edges: edges,
            workspaceId: workspaceId,
            orientation: orientation
        )
        let isLeadingPrimaryEdge = switch orientation {
        case .horizontal: edges.contains(.left)
        case .vertical: edges.contains(.bottom)
        }

        interactiveResize = InteractiveResize(
            windowId: windowId,
            workspaceId: workspaceId,
            originalContainerSpan: baseline.containerSpan,
            originalWindowBaseline: baseline.window,
            edges: edges,
            startMouseLocation: startLocation,
            columnIndex: colIdx,
            orientation: orientation,
            originalViewOffset: isLeadingPrimaryEdge ? viewOffset : nil
        )

        NiriLayoutTrace.record(
            .resize,
            workspaceId: workspaceId,
            "begin win=\(windowId) col=\(colIdx) edges=\(String(describing: edges))"
        )
        return true
    }

    private func interactiveResizeBaseline(
        _ windowNode: NiriWindow, column: NiriContainer, edges: ResizeEdge,
        workspaceId: WorkspaceDescriptor.ID, orientation: Monitor.Orientation
    ) -> (containerSpan: CGFloat?, window: InteractiveResize.WindowBaseline?) {
        let originalContainerSpan: CGFloat?
        let originalWindowBaseline: InteractiveResize.WindowBaseline?
        switch orientation {
        case .horizontal:
            originalContainerSpan = edges.hasHorizontal
                ? interactiveResizeStartWidth(for: column, window: windowNode, workspaceId: workspaceId)
                : nil
            originalWindowBaseline = edges.hasVertical ? .weight(windowNode.size) : nil
        case .vertical:
            originalContainerSpan = edges.hasVertical
                ? interactiveResizeStartHeight(for: column, window: windowNode, workspaceId: workspaceId)
                : nil
            if edges.hasHorizontal,
               let singleWindowContext = singleWindowLayoutContext(
                   in: workspaceId,
                   excluding: projectionExclusions(in: workspaceId)
               ),
               singleWindowContext.container === column
            {
                originalWindowBaseline = .fixedPixels(
                    windowNode.resolvedWidth
                        ?? windowNode.frame?.width
                        ?? windowNode.renderedFrame?.width
                        ?? windowNode.widthWeight
                )
            } else {
                originalWindowBaseline = edges.hasHorizontal ? .weight(windowNode.widthWeight) : nil
            }
        }
        return (originalContainerSpan, originalWindowBaseline)
    }

    func interactiveResizeUpdate(
        currentLocation: CGPoint,
        monitorFrame: CGRect,
        gaps: LayoutGaps,
        viewportState: ((inout ViewportState) -> Void) -> Void = { _ in }
    ) -> Bool {
        guard let resize = interactiveResize else { return false }

        guard let windowNode = findNode(by: resize.windowId, in: resize.workspaceId) as? NiriWindow else {
            clearInteractiveResize()
            return false
        }

        guard let column = findColumn(containing: windowNode, in: resize.workspaceId) else {
            clearInteractiveResize()
            return false
        }

        let delta = CGPoint(
            x: currentLocation.x - resize.startMouseLocation.x,
            y: currentLocation.y - resize.startMouseLocation.y
        )

        let context = ResizeUpdateContext(resize: resize, delta: delta, monitorFrame: monitorFrame, gaps: gaps)
        switch resize.orientation {
        case .horizontal:
            let widthChanged = resizeHorizontalColumn(column, context: context, viewportState: viewportState)
            let heightChanged = resizeHorizontalWindow(windowNode, column: column, context: context)
            return widthChanged || heightChanged
        case .vertical:
            let widthChanged = resizeVerticalWindow(windowNode, column: column, context: context)
            let heightChanged = resizeVerticalColumn(column, context: context, viewportState: viewportState)
            return widthChanged || heightChanged
        }
    }

    func projectedWidthBounds(
        for column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (min: CGFloat, max: CGFloat?) {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        var minimum: CGFloat = 1
        var maximum: CGFloat?
        for window in windows {
            let constraints = window.constraints.normalized()
            minimum = max(minimum, constraints.minSize.width)
            if constraints.hasMaxWidth {
                maximum = min(maximum ?? constraints.maxSize.width, constraints.maxSize.width)
            }
        }
        let contentInset = column.isTabbed && windows.count > 1 ? tabContentInset(for: column) : 0
        return (
            minimum + contentInset,
            maximum.map { max($0, minimum) + contentInset }
        )
    }

    func projectedHeightBounds(
        for column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (min: CGFloat, max: CGFloat?) {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        var minimum: CGFloat = 1
        var maximum: CGFloat?
        for window in windows {
            let constraints = window.constraints.normalized()
            minimum = max(minimum, constraints.minSize.height)
            if constraints.hasMaxHeight {
                maximum = min(maximum ?? constraints.maxSize.height, constraints.maxSize.height)
            }
        }
        return (minimum, maximum.map { max($0, minimum) })
    }

    func clearInteractiveResize() {
        interactiveResize = nil
    }

    func interactiveResizeEnd(
        windowId: NodeId? = nil,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        assertSanctionedMutation()
        guard let resize = interactiveResize else { return }

        if let windowId, windowId != resize.windowId {
            return
        }

        interactiveResize = nil
        if let windowNode = findNode(by: resize.windowId, in: resize.workspaceId) as? NiriWindow {
            ensureSelectionVisible(
                node: windowNode,
                context: .init(
                    workspaceId: resize.workspaceId,
                    motion: motion,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: resize.orientation
                ),
                state: &state
            )
            if resize.originalContainerSpan != nil {
                recoverSettledCoverage(
                    context: .init(
                        workspaceId: resize.workspaceId,
                        motion: motion,
                        workingFrame: workingFrame,
                        gaps: gaps,
                        orientation: resize.orientation
                    ),
                    state: &state
                )
            }
        }

        NiriLayoutTrace.record(.resize, workspaceId: resize.workspaceId, "end win=\(resize.windowId)")
    }
}
