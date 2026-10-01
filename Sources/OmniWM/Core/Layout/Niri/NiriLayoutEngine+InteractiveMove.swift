// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func interactiveMoveBegin(
        windowId: NodeId,
        windowToken: WindowToken,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard interactiveMove == nil else { return false }
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId, in: context.workspaceId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: context.workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: context.workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        interactiveMove = InteractiveMove(
            windowId: windowId,
            windowToken: windowToken,
            workspaceId: context.workspaceId,
            startMouseLocation: startLocation,
            originalColumnIndex: colIdx,
            originalFrame: windowNode.renderedFrame ?? windowNode.frame ?? .zero,
            isInsertMode: isInsertMode,
            orientation: context.orientation,
            gaps: context.gaps,
            currentHoverTarget: nil
        )

        let cols = columns(in: context.workspaceId)
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let settings = effectiveSettings(in: context.workspaceId)
        state.transitionToColumn(
            colIdx,
            columns: cols,
            context: context,
            animate: false,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
            scale: displayScale(in: context.workspaceId),
            viewFrame: monitorForWorkspace(context.workspaceId)?.frame
        )

        return true
    }

    func interactiveMoveUpdate(currentLocation: CGPoint) -> MoveHoverTarget? {
        guard var move = interactiveMove else { return nil }
        guard findNode(by: move.windowId, in: move.workspaceId) != nil else {
            interactiveMoveCancel()
            return nil
        }

        let dragDistance = hypot(
            currentLocation.x - move.startMouseLocation.x,
            currentLocation.y - move.startMouseLocation.y
        )
        guard dragDistance >= moveConfiguration.dragThreshold else {
            return nil
        }

        let hoverTarget = hitTestMoveTarget(
            point: currentLocation,
            excludingWindowId: move.windowId,
            isInsertMode: move.isInsertMode,
            orientation: move.orientation,
            in: move.workspaceId
        )

        move.currentHoverTarget = hoverTarget
        interactiveMove = move

        return hoverTarget
    }

    func interactiveMoveEnd(
        at _: CGPoint,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        guard let move = interactiveMove else { return false }
        defer { interactiveMove = nil }

        guard let target = move.currentHoverTarget else {
            return false
        }

        let context = NiriInteractionContext(
            workspaceId: move.workspaceId,
            motion: motion,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: move.orientation
        )
        switch target {
        case let .window(targetNodeId, _, position):
            switch position {
            case .swap:
                return swapWindowsByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    context: context,
                    state: &state
                )
            case .before,
                 .after:
                return insertWindowByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    position: position,
                    context: context,
                    state: &state
                )
            }

        case .columnGap,
             .workspaceEdge:
            return false
        }
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func hitTestMoveTarget(
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool = false,
        orientation: Monitor.Orientation,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        for column in hitTestColumns(in: workspaceId) {
            for window in hitTestCandidates(in: column, workspaceId: workspaceId) {
                guard window.id != excludingWindowId,
                      !isExcludedFromProjection(window.token, in: workspaceId),
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if frame.contains(point) {
                    let position: InsertPosition = if isInsertMode {
                        switch orientation {
                        case .horizontal:
                            point.y < frame.midY ? .before : .after
                        case .vertical:
                            point.x < frame.midX ? .before : .after
                        }
                    } else {
                        .swap
                    }
                    return .window(
                        nodeId: window.id,
                        token: window.token,
                        insertPosition: position
                    )
                }
            }
        }

        return nil
    }

    func swapWindowsByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId, in: context.workspaceId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId, in: context.workspaceId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: context.workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: context.workspaceId)
        else {
            return false
        }

        if sourceColumn.id == targetColumn.id {
            sourceWindow.swapWith(targetWindow)

            if sourceColumn.isTabbed {
                sourceColumn.clampActiveTileIdx()
            }
        } else {
            guard let sourceIdx = sourceColumn.children.firstIndex(where: { $0.id == sourceWindowId }),
                  let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId })
            else {
                return false
            }

            guard columnCanAcceptTransfer(
                targetColumn,
                adding: sourceWindow,
                removing: targetWindow,
                in: context.workspaceId,
                geometry: context.sizingGeometry
            ), columnCanAcceptTransfer(
                sourceColumn,
                adding: targetWindow,
                removing: sourceWindow,
                in: context.workspaceId,
                geometry: context.sizingGeometry
            ) else {
                return false
            }

            swapColumnMembers(
                source: (sourceWindow, sourceColumn), target: (targetWindow, targetColumn),
                indices: (sourceIdx, targetIdx)
            )
        }

        ensureSelectionVisible(
            node: sourceWindow,
            context: context,
            state: &state
        )

        return true
    }

    private func swapColumnMembers(
        source: (window: NiriWindow, column: NiriContainer),
        target: (window: NiriWindow, column: NiriContainer),
        indices: (source: Int, target: Int)
    ) {
        let sourceSize = source.window.size
        let sourceHeight = source.window.height
        let targetSize = target.window.size
        let targetHeight = target.window.height

        source.window.detach()
        target.window.detach()

        source.column.insertChild(target.window, at: indices.source)
        target.column.insertChild(source.window, at: indices.target)

        source.window.size = targetSize
        source.window.height = targetHeight
        target.window.size = sourceSize
        target.window.height = sourceHeight

        if source.column.isTabbed {
            source.column.clampActiveTileIdx()
        }
        if target.column.isTabbed {
            target.column.clampActiveTileIdx()
        }
    }

    func insertWindowByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        position: InsertPosition,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let sourceWindow = findNode(by: sourceWindowId, in: context.workspaceId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId, in: context.workspaceId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: context.workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: context.workspaceId)
        else {
            return false
        }

        guard let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) else {
            return false
        }

        let sameColumn = sourceColumn.id == targetColumn.id
        let sourceColumnWillBeEmpty = sourceColumn.children.count == 1 && !sameColumn

        if !sameColumn {
            guard columnCanAcceptTransfer(
                targetColumn,
                adding: sourceWindow,
                in: context.workspaceId,
                geometry: context.sizingGeometry
            ) else {
                return false
            }
        }

        sourceWindow.detach()

        let insertIdx: Int
        if sameColumn {
            let currentTargetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) ?? targetIdx
            insertIdx = position == .before ? currentTargetIdx : currentTargetIdx + 1
        } else {
            insertIdx = position == .before ? targetIdx : targetIdx + 1
        }

        targetColumn.insertChild(sourceWindow, at: insertIdx)

        sourceWindow.size = 1.0
        sourceWindow.height = .default

        finishMoveColumns(sourceColumn, target: targetColumn, removeSource: sourceColumnWillBeEmpty)

        ensureSelectionVisible(
            node: sourceWindow,
            context: context,
            state: &state
        )

        return true
    }

    private func finishMoveColumns(
        _ sourceColumn: NiriContainer,
        target targetColumn: NiriContainer,
        removeSource: Bool
    ) {
        if removeSource {
            sourceColumn.remove()
        }

        if sourceColumn.isTabbed {
            sourceColumn.clampActiveTileIdx()
        }
        if targetColumn.isTabbed {
            targetColumn.clampActiveTileIdx()
        }
    }

    func insertionDropzoneFrame(
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect? {
        guard let targetWindow = findNode(by: targetWindowId, in: workspaceId) as? NiriWindow,
              let targetFrame = targetWindow.renderedFrame ?? targetWindow.frame,
              let column = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return nil
        }

        let windows = column.windowNodes
        let postInsertionCount = windows.count + 1
        let firstFrame = windows.first?.renderedFrame ?? windows.first?.frame
        let lastFrame = windows.last?.renderedFrame ?? windows.last?.frame
        let totalGaps = CGFloat(postInsertionCount - 1) * gaps

        switch orientation {
        case .horizontal:
            guard let bottom = firstFrame?.minY, let top = lastFrame?.maxY else { return nil }
            let columnHeight = top - bottom
            let newHeight = max(0, (columnHeight - totalGaps) / CGFloat(postInsertionCount))
            let y: CGFloat = switch position {
            case .before:
                max(bottom, targetFrame.minY - gaps - newHeight)
            case .after:
                targetFrame.maxY + gaps
            case .swap:
                targetFrame.minY
            }
            return CGRect(x: targetFrame.minX, y: y, width: targetFrame.width, height: newHeight)
        case .vertical:
            guard let left = firstFrame?.minX, let right = lastFrame?.maxX else { return nil }
            let rowWidth = right - left
            let newWidth = max(0, (rowWidth - totalGaps) / CGFloat(postInsertionCount))
            let x: CGFloat = switch position {
            case .before:
                max(left, targetFrame.minX - gaps - newWidth)
            case .after:
                targetFrame.maxX + gaps
            case .swap:
                targetFrame.minX
            }
            return CGRect(x: x, y: targetFrame.minY, width: newWidth, height: targetFrame.height)
        }
    }
}
