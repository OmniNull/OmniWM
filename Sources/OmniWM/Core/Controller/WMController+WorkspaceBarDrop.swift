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
        case let .niriMoveColumn(workspaceId, _),
             let .niriNewColumn(workspaceId, _),
             let .niriStack(workspaceId, _, _):
            return workspaceId == source.workspaceId
                ? commitWorkspaceBarReorder(action, source: source)
                : commitWorkspaceBarTransfer(action, source: source)
        case .noOp,
             .cancel:
            return false
        }
    }

    private func commitWorkspaceBarReorder(_ action: WorkspaceBarDropAction, source: WorkspaceBarDragSource) -> Bool {
        guard let handle = barDragHandle(source, in: source.workspaceId) else { return false }
        let workspaceId = source.workspaceId
        let changed: Bool
        switch action {
        case let .niriMoveColumn(_, oneBasedIndex):
            changed = niriLayoutHandler.moveColumn(containing: handle, toOneBasedIndex: oneBasedIndex).didMutate
        case let .niriNewColumn(_, gap):
            changed = durableColumnIndex(forGap: gap, in: workspaceId).map {
                niriLayoutHandler.insertWindowInNewColumn(handle: handle, insertIndex: $0, in: workspaceId)
            } ?? false
        case let .niriStack(_, target, position):
            changed = workspaceManager.handle(for: target).map {
                niriLayoutHandler.insertWindow(handle: handle, targetHandle: $0, position: position, in: workspaceId)
            } ?? false
        default:
            changed = false
        }
        if changed {
            completeWorkspaceBarReorder(handle.id, in: workspaceId)
        }
        return changed
    }

    private func commitWorkspaceBarTransfer(_ action: WorkspaceBarDropAction, source: WorkspaceBarDragSource) -> Bool {
        let actions = workspaceBarStructuralActions()
        switch action {
        case let .niriNewColumn(workspaceId, gap):
            guard let insertIndex = durableColumnIndex(forGap: gap, in: workspaceId) else { return false }
            return commitWorkspaceBarTransfer(
                source,
                into: .niriColumnInsert(workspaceId: workspaceId, insertIndex: insertIndex),
                actions: actions
            )
        case let .niriStack(workspaceId, target, position):
            guard let targetHandle = workspaceManager.handle(for: target) else { return false }
            return commitWorkspaceBarTransfer(
                source,
                into: .niriWindowInsert(
                    workspaceId: workspaceId,
                    targetHandle: targetHandle,
                    position: actions.niriInsertPositionToOverview(position)
                ),
                actions: actions
            )
        default:
            return false
        }
    }

    private func workspaceBarStructuralActions() -> OverviewStructuralActions {
        OverviewStructuralActions(
            wmController: self,
            windowFacts: OverviewWindowFacts(wmController: self, environment: OverviewEnvironment())
        )
    }

    private func commitWorkspaceBarTransfer(
        _ source: WorkspaceBarDragSource,
        into target: OverviewDragTarget,
        actions: OverviewStructuralActions
    ) -> Bool {
        guard let handle = barDragHandle(source, in: source.workspaceId),
              let monitorId = workspaceManager.monitorId(for: source.workspaceId)
        else {
            return false
        }
        let movesSelection = workspaceManager.selectedManagedToken == handle.id
        let session = OverviewStructuralActions.DragSession(
            handle: handle,
            windowId: handle.id.windowId,
            workspaceId: source.workspaceId,
            monitorId: monitorId,
            startPoint: .zero
        )
        switch actions.performDragAction(session: session, target: target) {
        case let .changed(mutation):
            finishWorkspaceBarTransfer(mutation, movesSelection: movesSelection)
            return true
        case let .awaitingAdmission(mutation, target):
            layoutRefreshController.commitWorkspaceTransition(
                affectedWorkspaces: mutation.affectedWorkspaceIds,
                postLayout: { [weak self] in
                    _ = actions.placeAdmittedWindow(mutation.selectedHandle, target: target)
                    self?.finishWorkspaceBarTransfer(mutation, movesSelection: movesSelection)
                },
                postLayoutInvalidated: { [weak self] in
                    self?.finishWorkspaceBarTransfer(mutation, movesSelection: movesSelection)
                }
            )
            return true
        case .placedFloating,
             .unchanged:
            return false
        }
    }

    private func finishWorkspaceBarTransfer(_ mutation: StructuralMutation, movesSelection: Bool) {
        let follows = movesSelection || settings.focus.followsWindowToMonitor
        workspaceNavigationHandler.finishWorkspaceMove(
            mutation,
            focusPolicy: follows ? .configured : .retainCurrent,
            focusOrigin: .pointerSelection
        )
        let destination = mutation.destinationWorkspaceId
        if mutation.scrollWorkspaceId != nil,
           workspaceManager.monitorId(for: destination).flatMap({ workspaceManager.activeWorkspace(on: $0)?.id })
           == destination
        {
            layoutRefreshController.startScrollAnimation(for: destination)
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
