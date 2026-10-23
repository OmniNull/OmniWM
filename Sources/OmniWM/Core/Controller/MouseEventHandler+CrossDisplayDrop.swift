// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct CrossDisplayDrop: Equatable {
    enum Placement: Equatable {
        case niriNewColumn(durableIndex: Int)
        case niriStack(target: WindowToken, after: Bool)
        case dwindleBeside(target: WindowToken, direction: Direction)
        case dwindleEdge(Direction)
        case dwindleSplitBoundary(DwindleNodeId)
        case swap(target: WindowToken)
        case workspace
    }

    let sourceToken: WindowToken
    let sourceWorkspaceId: WorkspaceDescriptor.ID
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: Monitor
    let placement: Placement
    let previewFrame: CGRect
}

enum MoveLocation: Equatable {
    case sourceDisplay
    case crossDisplay(CrossDisplayDrop)
    case cancel
}

extension MouseEventHandler {
    func classifyMoveLocation(_ point: CGPoint) -> MoveLocation {
        guard state.activeInteractionSource?.mouseButton != nil,
              let source = activeMoveSource()
        else {
            return .sourceDisplay
        }
        return classifyMoveLocation(point, sourceToken: source.token, sourceWorkspaceId: source.workspaceId)
    }

    func classifyMoveLocation(
        _ point: CGPoint,
        sourceToken: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID
    ) -> MoveLocation {
        guard let controller,
              let sourceMonitor = controller.workspaceManager.monitor(for: sourceWorkspaceId)
        else { return .sourceDisplay }
        let manager = controller.workspaceManager
        guard let monitor = manager.monitors.first(where: { $0.frame.contains(point) }),
              monitor.id != sourceMonitor.id
        else {
            return .sourceDisplay
        }
        guard let workspaceId = manager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              !hasPendingNativeFullscreenTransition(at: point),
              !isPointerDisplayShowingFullscreenSpace(at: point)
        else {
            return .cancel
        }
        let resolved = manager.activeLayoutKind(for: workspaceId) == .dwindle
            ? resolveDwindleDrop(at: point, in: workspaceId, monitor: monitor)
            : resolveNiriDrop(
                at: point,
                in: workspaceId,
                monitor: monitor,
                movesGroup: controller.crossDisplayDragUnit(for: sourceToken, in: sourceWorkspaceId).isGroup
            )
        guard let resolved else { return .cancel }
        return .crossDisplay(CrossDisplayDrop(
            sourceToken: sourceToken,
            sourceWorkspaceId: sourceWorkspaceId,
            workspaceId: workspaceId,
            monitor: monitor,
            placement: resolved.placement,
            previewFrame: resolved.previewFrame
        ))
    }

    func updateCrossDisplayHover(at location: CGPoint) -> Bool {
        let preview: CGRect?
        switch classifyMoveLocation(location) {
        case .sourceDisplay:
            return false
        case let .crossDisplay(drop):
            preview = drop.previewFrame
        case .cancel:
            preview = nil
        }
        state.dragGhostController?.updatePosition(cursorLocation: location)
        clearActiveMoveTarget()
        if let preview {
            state.dragGhostController?.showSwapTarget(frame: preview)
        } else {
            state.dragGhostController?.hideSwapTarget()
        }
        return true
    }

    func cancelActiveEngineMove() {
        if state.moveLayout == .dwindle {
            controller?.dwindleEngine?.interactiveMoveCancel()
        } else {
            controller?.niriEngine?.interactiveMoveCancel()
        }
    }

    private func activeMoveSource() -> (token: WindowToken, workspaceId: WorkspaceDescriptor.ID)? {
        if state.moveLayout == .dwindle {
            return controller?.dwindleEngine?.interactiveMove.map { ($0.token, $0.workspaceId) }
        }
        return controller?.niriEngine?.interactiveMove.map { ($0.windowToken, $0.workspaceId) }
    }

    private func clearActiveMoveTarget() {
        if state.moveLayout == .dwindle {
            controller?.dwindleEngine?.interactiveMoveClearTarget()
        } else {
            controller?.niriEngine?.interactiveMoveClearTarget()
        }
    }

    private func resolveNiriDrop(
        at point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        movesGroup: Bool
    ) -> (placement: CrossDisplayDrop.Placement, previewFrame: CGRect)? {
        guard let controller, let engine = controller.niriEngine else { return nil }
        let workingFrame = controller.niriInteractionGeometry(for: monitor).workingFrame
        guard workingFrame.contains(point) else { return nil }
        guard let hit = engine.hitTestMoveTarget(
                  point: point,
                  excludingWindowId: NodeId(),
                  allowsInsertion: true,
                  in: workspaceId
              ),
              let window = engine.findNode(by: hit.nodeId, in: workspaceId) as? NiriWindow,
              let frame = window.renderedFrame ?? window.frame,
              let column = engine.findColumn(containing: window, in: workspaceId),
              let columnIndex = engine.columnIndex(of: column, in: workspaceId)
        else {
            return (.workspace, workingFrame)
        }
        guard let direction = hit.direction else { return (.swap(target: hit.token), frame) }
        let preview = WindowMoveGeometry.targetFrame(in: frame, direction: direction)
        let orientation = resolvedNiriOrientation(engine: engine, workspaceId: workspaceId, monitor: monitor)
        if let step = direction.primaryStep(for: orientation) {
            return (.niriNewColumn(durableIndex: step > 0 ? columnIndex + 1 : columnIndex), preview)
        }
        guard !movesGroup else { return (.workspace, workingFrame) }
        return (.niriStack(target: hit.token, after: direction.secondaryStep(for: orientation) == 1), preview)
    }

    private func resolveDwindleDrop(
        at point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> (placement: CrossDisplayDrop.Placement, previewFrame: CGRect)? {
        guard let controller, let engine = controller.dwindleEngine else { return nil }
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let visible = engine.visibleTiles(in: workspaceId)
        guard workingFrame.contains(point), !visible.fullscreen else { return nil }
        if visible.any, let direction = engine.workspaceEdgeDirection(at: point, in: workingFrame, from: nil) {
            return (.dwindleEdge(direction), WindowMoveGeometry.targetFrame(in: workingFrame, direction: direction))
        }
        let now = controller.animationClock.now()
        if case let .splitBoundary(splitId, preview)? = engine.transferSplitBoundaryTarget(
            at: point, in: workspaceId, time: now
        ) {
            return (.dwindleSplitBoundary(splitId), preview)
        }
        guard let token = engine.hitTestFocusableWindow(point: point, in: workspaceId, at: now),
              let frame = engine.presentedFrame(for: token, in: workspaceId, at: now)
        else {
            return (.workspace, workingFrame)
        }
        guard let direction = WindowMoveGeometry.insertionDirection(at: point, in: frame) else {
            return (.swap(target: token), frame)
        }
        return (
            .dwindleBeside(target: token, direction: direction),
            WindowMoveGeometry.targetFrame(in: frame, direction: direction)
        )
    }
}
