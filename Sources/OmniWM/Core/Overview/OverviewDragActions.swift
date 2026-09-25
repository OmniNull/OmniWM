// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

extension OverviewStructuralActions {
    enum DragMutationOutcome {
        case changed(StructuralMutation)
        case placedFloating(StructuralMutation, CGRect)
        case awaitingAdmission(StructuralMutation, OverviewDragTarget)
        case unchanged
    }

    struct DragSession {
        let handle: WindowHandle
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID
        let startPoint: CGPoint
    }
}

extension OverviewStructuralActions {
    func performDragAction(session: DragSession, target: OverviewDragTarget) -> DragMutationOutcome {
        guard let wmController,
              let entry = windowFacts.visibleManagedEntry(for: session.handle),
              entry.workspaceId == session.workspaceId,
              windowFacts.isStructurallyMutable(entry)
        else {
            return .unchanged
        }

        switch target {
        case let .floatingPlacement(destination, frame, _):
            guard entry.mode == .floating, frame.size.hasFinitePositiveDimensions(),
                  frame.origin.x.isFinite, frame.origin.y.isFinite
            else { return .unchanged }
            return placeFloatingWindow(session: session, destination: destination, frame: frame)

        case let .newWorkspace(monitorId):
            guard let workspace = wmController.workspaceNavigationHandler.createOverviewWorkspace(on: monitorId) else {
                return .unchanged
            }
            let outcome = performDragAction(session: session, target: .workspaceMove(workspaceId: workspace.id))
            if case .unchanged = outcome { wmController.workspaceManager.removeWorkspaces([workspace.id]) }
            return outcome

        case let .workspaceMove(targetWsId):
            guard targetWsId != session.workspaceId else { return .unchanged }
            guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                handle: session.handle,
                toWorkspaceId: targetWsId
            ) else { return .unchanged }
            return .changed(mutation)

        case let .niriWindowInsert(targetWsId, targetHandle, position):
            return insertWindow(
                session: session,
                target: target,
                targetWsId: targetWsId,
                targetHandle: targetHandle,
                position: position
            )

        case let .niriColumnInsert(targetWsId, insertIndex):
            return insertColumn(session: session, target: target, targetWsId: targetWsId, insertIndex: insertIndex)
        }
    }

    private func placeFloatingWindow(
        session: DragSession,
        destination: OverviewFloatingDestination,
        frame: CGRect
    ) -> DragMutationOutcome {
        guard let wmController else { return .unchanged }
        switch destination {
        case let .newWorkspace(monitorId):
            guard let workspace = wmController.workspaceNavigationHandler.createOverviewWorkspace(on: monitorId) else {
                return .unchanged
            }
            let outcome = placeFloatingWindow(session: session, destination: .workspace(workspace.id), frame: frame)
            if case .unchanged = outcome { wmController.workspaceManager.removeWorkspaces([workspace.id]) }
            return outcome
        case let .workspace(workspaceId):
            guard wmController.workspaceManager.descriptor(for: workspaceId) != nil,
                  let monitor = wmController.workspaceManager.monitorForWorkspace(workspaceId)
            else { return .unchanged }
            let mutation: StructuralMutation
            if workspaceId == session.workspaceId {
                mutation = StructuralMutation(
                    sourceWorkspaceId: session.workspaceId,
                    destinationWorkspaceId: workspaceId,
                    selectedHandle: session.handle,
                    movedTokens: [session.handle.id],
                    scrollWorkspaceId: nil
                )
            } else {
                guard case let .changed(transfer) = wmController.workspaceNavigationHandler.moveWindow(
                    handle: session.handle,
                    toWorkspaceId: workspaceId
                ) else { return .unchanged }
                mutation = transfer
            }
            return .placedFloating(mutation, FloatingFrameGeometry.clamped(frame, in: monitor.visibleFrame))
        }
    }

    private func insertWindow(
        session: DragSession,
        target: OverviewDragTarget,
        targetWsId: WorkspaceDescriptor.ID,
        targetHandle: WindowHandle,
        position: InsertPosition
    ) -> DragMutationOutcome {
        guard let wmController else { return .unchanged }
        guard windowFacts.isNiriLayout(workspaceId: targetWsId),
              let targetEntry = windowFacts.visibleManagedEntry(for: targetHandle),
              windowFacts.isStructurallyMutable(targetEntry)
        else {
            return .unchanged
        }
        var transferMutation: StructuralMutation?
        if targetWsId != session.workspaceId {
            guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                handle: session.handle,
                toWorkspaceId: targetWsId
            ) else { return .unchanged }
            transferMutation = mutation
            if !windowFacts.isNiriLayout(workspaceId: session.workspaceId) {
                return .awaitingAdmission(mutation, target)
            }
        }
        let niriPosition = overviewInsertPositionToNiri(position)
        guard wmController.niriLayoutHandler.insertWindow(
            handle: session.handle,
            targetHandle: targetHandle,
            position: niriPosition,
            in: targetWsId,
            source: .mouse
        ) else {
            return transferMutation.map(DragMutationOutcome.changed) ?? .unchanged
        }
        return .changed(insertionMutation(session: session, destination: targetWsId))
    }

    private func insertColumn(
        session: DragSession,
        target: OverviewDragTarget,
        targetWsId: WorkspaceDescriptor.ID,
        insertIndex: Int
    ) -> DragMutationOutcome {
        guard let wmController else { return .unchanged }
        guard windowFacts.isNiriLayout(workspaceId: targetWsId) else { return .unchanged }
        let shouldInheritSizing = targetWsId != session.workspaceId
            && windowFacts.isNiriLayout(workspaceId: session.workspaceId)
        let sizingPolicy: NiriLayoutEngine.NewContainerSizingPolicy = shouldInheritSizing
            ? .inheritSource
            : .workspaceDefault
        var transferMutation: StructuralMutation?
        if targetWsId != session.workspaceId {
            guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                handle: session.handle,
                toWorkspaceId: targetWsId
            ) else { return .unchanged }
            transferMutation = mutation
            if !windowFacts.isNiriLayout(workspaceId: session.workspaceId) {
                return .awaitingAdmission(mutation, target)
            }
        }
        guard wmController.niriLayoutHandler.insertWindowInNewColumn(
            handle: session.handle,
            insertIndex: insertIndex,
            in: targetWsId,
            sizingPolicy: sizingPolicy,
            source: .mouse
        ) else {
            return transferMutation.map(DragMutationOutcome.changed) ?? .unchanged
        }
        return .changed(insertionMutation(session: session, destination: targetWsId))
    }

    private func insertionMutation(session: DragSession, destination: WorkspaceDescriptor.ID) -> StructuralMutation {
        StructuralMutation(
            sourceWorkspaceId: session.workspaceId,
            destinationWorkspaceId: destination,
            selectedHandle: session.handle,
            movedTokens: [session.handle.id],
            scrollWorkspaceId: destination
        )
    }

    func overviewInsertPositionToNiri(_ position: InsertPosition) -> InsertPosition {
        switch position {
        case .before:
            return .after
        case .after:
            return .before
        case .swap:
            return .swap
        }
    }

    func niriInsertPositionToOverview(_ position: InsertPosition) -> InsertPosition {
        overviewInsertPositionToNiri(position)
    }

    func placeAdmittedWindow(_ handle: WindowHandle, target: OverviewDragTarget) -> Bool {
        guard let wmController else { return false }
        switch target {
        case let .niriWindowInsert(workspaceId, targetHandle, position):
            guard windowFacts.visibleManagedEntry(for: targetHandle) != nil else { return false }
            return wmController.niriLayoutHandler.insertWindow(
                handle: handle,
                targetHandle: targetHandle,
                position: overviewInsertPositionToNiri(position),
                in: workspaceId,
                source: .mouse
            )
        case let .niriColumnInsert(workspaceId, insertIndex):
            let admittedColumnIndex = wmController.niriEngine
                .flatMap { engine in
                    engine.findNode(for: handle, in: workspaceId)
                        .flatMap { engine.findColumn(containing: $0, in: workspaceId) }
                        .flatMap { column in
                            column.windowNodes.count == 1
                                ? engine.columnIndex(of: column, in: workspaceId)
                                : nil
                        }
                }
            return wmController.niriLayoutHandler.insertWindowInNewColumn(
                handle: handle,
                insertIndex: Self.deferredColumnInsertIndex(
                    requestedIndex: insertIndex,
                    admittedColumnIndex: admittedColumnIndex
                ),
                in: workspaceId,
                sizingPolicy: .workspaceDefault,
                source: .mouse
            )
        case .floatingPlacement,
             .workspaceMove,
             .newWorkspace:
            return false
        }
    }

    static func deferredColumnInsertIndex(
        requestedIndex: Int,
        admittedColumnIndex: Int?
    ) -> Int {
        if let admittedColumnIndex, admittedColumnIndex < requestedIndex {
            return requestedIndex + 1
        }
        return requestedIndex
    }
}
