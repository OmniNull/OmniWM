// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct WorkspaceBarDropLayout: Equatable {
    let layout: ActiveLayoutKind
    let placements: [WindowToken: WorkspaceBarDropGeometry.Placement]
    let columnCount: Int
}

extension WMController {
    func workspaceBarDropLayout(for workspaceId: WorkspaceDescriptor.ID) -> WorkspaceBarDropLayout {
        let layout = workspaceManager.activeLayoutKind(for: workspaceId)
        guard layout == .niri, let engine = niriEngine else {
            return WorkspaceBarDropLayout(layout: layout, placements: [:], columnCount: 0)
        }
        let columns = engine.projectedColumns(in: workspaceId)
        var placements: [WindowToken: WorkspaceBarDropGeometry.Placement] = [:]
        for (columnIndex, column) in columns.enumerated() {
            for (row, window) in column.windows.enumerated() {
                placements[window.token] = .init(column: columnIndex, row: row, columnTileCount: column.windows.count)
            }
        }
        return WorkspaceBarDropLayout(layout: layout, placements: placements, columnCount: columns.count)
    }

    func canDragWorkspaceBarWindow(_ token: WindowToken) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else { return false }
        return entry.layoutReason == .standard
            && !workspaceManager.isWindowSuppressedByMacOS(token)
            && !isManagedWindowSuspendedForNativeFullscreen(token)
    }

    @discardableResult
    func commitWorkspaceBarDrop(_ action: WorkspaceBarDropAction, source: WorkspaceBarDragSource) -> Bool {
        switch action {
        case let .moveToWorkspace(workspaceId):
            return workspaceNavigationHandler.moveWindowsFromBar(source.tokens, toWorkspaceId: workspaceId)
        case let .dwindleSwap(workspaceId, target):
            guard let token = barDragToken(source, in: workspaceId) else { return false }
            return dwindleLayoutHandler.swapWindows(token, with: target, in: workspaceId)
        case let .niriMoveColumn(workspaceId, oneBasedIndex):
            guard let handle = barDragHandle(source, in: workspaceId),
                  niriLayoutHandler.moveColumn(containing: handle, toOneBasedIndex: oneBasedIndex).didMutate
            else {
                return false
            }
            completeWorkspaceBarReorder(handle.id, in: workspaceId)
            return true
        case let .niriNewColumn(workspaceId, gap):
            guard let handle = barDragHandle(source, in: workspaceId),
                  let insertIndex = durableColumnIndex(forGap: gap, in: workspaceId),
                  niriLayoutHandler.insertWindowInNewColumn(handle: handle, insertIndex: insertIndex, in: workspaceId)
            else {
                return false
            }
            completeWorkspaceBarReorder(handle.id, in: workspaceId)
            return true
        case let .niriStack(workspaceId, target, position):
            guard let handle = barDragHandle(source, in: workspaceId),
                  let targetHandle = workspaceManager.handle(for: target),
                  niriLayoutHandler.insertWindow(
                      handle: handle,
                      targetHandle: targetHandle,
                      position: position,
                      in: workspaceId
                  )
            else {
                return false
            }
            completeWorkspaceBarReorder(handle.id, in: workspaceId)
            return true
        case .noOp,
             .cancel:
            return false
        }
    }

    private func barDragToken(
        _ source: WorkspaceBarDragSource,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard source.tokens.count == 1,
              let token = source.tokens.first,
              workspaceManager.entry(for: token)?.workspaceId == workspaceId
        else {
            return nil
        }
        return token
    }

    private func barDragHandle(
        _ source: WorkspaceBarDragSource,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowHandle? {
        barDragToken(source, in: workspaceId).flatMap { workspaceManager.handle(for: $0) }
    }

    private func durableColumnIndex(forGap gap: Int, in workspaceId: WorkspaceDescriptor.ID) -> Int? {
        guard let columns = niriEngine?.projectedColumns(in: workspaceId), let last = columns.last else { return nil }
        return columns.indices.contains(gap) ? columns[gap].durableIndex : last.durableIndex + 1
    }

    private func completeWorkspaceBarReorder(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        let monitorId = workspaceManager.monitorId(for: workspaceId)
        let isActive = monitorId.flatMap { workspaceManager.activeWorkspace(on: $0)?.id } == workspaceId
        if let node = niriEngine?.findNode(for: token, in: workspaceId) {
            _ = workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: token,
                in: workspaceId,
                onMonitor: monitorId
            )
        }
        layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId]) { [weak self] in
            guard isActive,
                  let self,
                  activeWorkspace()?.id == workspaceId || monitorId.flatMap({
                      workspaceManager.activeWorkspace(on: $0)?.id
                  }) == workspaceId,
                  workspaceManager.entry(for: token)?.workspaceId == workspaceId
            else {
                return
            }
            focusWindow(token, origin: .pointerSelection)
        }
        if isActive,
           workspaceManager.animationDriver.hasMotion(in: workspaceId)
           || niriEngine?.hasAnyWindowAnimationsRunning(in: workspaceId) == true
        {
            layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }
}
