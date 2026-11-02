// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func consumeOrExpelWindow(direction: Direction) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(consumeOrExpelWindow(handle: handle, direction: direction))
    }

    func consumeOrExpelWindow(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .left || direction == .right else { return .unchanged }
        return performStructuralMutation(handle: handle) { ctx, state in
            guard ctx.engine.consumeOrExpelWindow(
                ctx.windowNode,
                direction: direction,
                context: .init(
                    workspaceId: ctx.wsId,
                    motion: ctx.motion,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                ),
                state: &state,
                allowEdgeWrap: false
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                operation: .windowConsumedOrExpelled(token: ctx.windowNode.token)
            )
        }
    }

    func consumeWindowIntoColumn() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(consumeWindowIntoColumn(containing: handle))
    }

    func consumeWindowIntoColumn(containing handle: WindowHandle) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else {
                return nil
            }
            let projectedColumns = ctx.engine.projectedColumns(in: ctx.wsId)
            guard let projectedIndex = projectedColumns.firstIndex(where: { $0.column === column }),
                  projectedColumns.indices.contains(projectedIndex + 1),
                  let movedToken = projectedColumns[projectedIndex + 1].windows.last?.token
            else { return nil }
            guard ctx.engine.consumeWindowIntoColumn(
                focusedColumn: column,
                context: .init(
                    workspaceId: ctx.wsId,
                    motion: ctx.motion,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                ),
                state: &state
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                operation: .windowConsumedOrExpelled(token: movedToken)
            )
        }
    }

    func expelWindowFromColumn() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(expelWindowFromColumn(containing: handle))
    }

    func expelWindowFromColumn(containing handle: WindowHandle) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else {
                return nil
            }
            guard let movedToken = ctx.engine.projectedWindows(
                in: column,
                workspaceId: ctx.wsId
            ).first?.token else { return nil }
            guard ctx.engine.expelWindowFromColumn(
                focusedColumn: column,
                context: .init(
                    workspaceId: ctx.wsId,
                    motion: ctx.motion,
                    workingFrame: ctx.workingFrame,
                    gaps: ctx.gaps,
                    orientation: ctx.orientation
                ),
                state: &state
            ) else {
                return nil
            }
            return NiriStructuralMutation(
                operation: .windowConsumedOrExpelled(token: movedToken)
            )
        }
    }

    func moveColumn(direction: Direction) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumn(containing: handle, direction: direction))
    }

    func moveColumn(
        containing handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .direction(direction))
    }

    func moveColumnToFirst() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumnToFirst(containing: handle))
    }

    func moveColumnToFirst(containing handle: WindowHandle) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .first)
    }

    func moveColumnToLast() {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumnToLast(containing: handle))
    }

    func moveColumnToLast(containing handle: WindowHandle) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .last)
    }

    func moveColumn(toOneBasedIndex index: Int) {
        guard let handle = selectedWindowHandleInActiveWorkspace() else { return }
        commitNormalStructuralMutation(moveColumn(containing: handle, toOneBasedIndex: index))
    }

    func moveColumnToIndex(_ index: Int) {
        moveColumn(toOneBasedIndex: index)
    }

    func moveColumn(
        containing handle: WindowHandle,
        toOneBasedIndex index: Int
    ) -> StructuralMutationOutcome {
        moveColumn(containing: handle, target: .index(index))
    }

    func moveColumn(
        containing handle: WindowHandle,
        target: NiriColumnMoveTarget
    ) -> StructuralMutationOutcome {
        performStructuralMutation(handle: handle) { ctx, state in
            guard let column = ctx.engine.findColumn(containing: ctx.windowNode, in: ctx.wsId) else { return nil }
            let oldFrames = ctx.engine.captureWindowFrames(in: ctx.wsId)
            guard ctx.engine.moveColumn(
                column,
                target: target,
                context: ctx.interactionContext(motion: ctx.motion),
                state: &state
            ) else { return nil }
            ctx.prepareCapturedAnimation(oldFrames: oldFrames)
            raiseMovingColumn(column, keepingOnTop: ctx.windowNode)
            return NiriStructuralMutation(operation: .columnMoved)
        }
    }

    private func raiseMovingColumn(_ column: NiriContainer, keepingOnTop focused: NiriWindow) {
        guard let controller, controller.settings.niri.naturalWindowDrag else { return }
        let windowIds = column.windowNodes.map(\.token.windowId)
        traceWindowOrder("move-column raise before", windowIds)
        let raised = column.windowNodes.filter { $0 !== focused && !$0.isHiddenInTabbedMode } + [focused]
        for window in raised {
            guard let entry = controller.workspaceManager.entry(for: window.token),
                  let element = entry.axRef?.element
            else { continue }
            controller.windowFocusOperations.raiseWindow(element)
        }
        traceWindowOrder("move-column raise after", windowIds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.traceWindowOrder("move-column raise after 100ms", windowIds)
        }
    }

    private func traceWindowOrder(_ label: String, _ windowIds: [Int]) {
        guard MouseTrace.shared.isActive,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
              as? [[String: Any]]
        else { return }
        let normal = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let order = normal.compactMap { $0[kCGWindowNumber as String] as? Int }
        let ranks = windowIds.map { id in "\(id)@\(order.firstIndex(of: id).map(String.init) ?? "-")" }
        MouseTrace
            .record(
                "\(label) column=\(ranks.joined(separator: ",")) front=\(order.prefix(8).map(String.init).joined(separator: ","))"
            )
    }

    func moveColumnPreservingFocus(
        containing handle: WindowHandle,
        target: NiriColumnMoveTarget
    ) -> Bool {
        var moved = false
        withNiriWindowContext(.window(handle)) { engine, windowNode, context, state in
            let workspaceId = context.workspaceId
            guard let column = engine.findColumn(containing: windowNode, in: workspaceId) else { return }
            let focusedColumn = state.selectedNodeId
                .flatMap { engine.findNode(by: $0, in: workspaceId) }
                .flatMap(engine.column(of:))
            let oldFrames = engine.captureWindowFrames(in: workspaceId)
            let didMove = if let focusedColumn {
                engine.moveColumnPreservingFocus(
                    column,
                    target: target,
                    focused: focusedColumn,
                    context: context,
                    state: &state
                )
            } else {
                engine.moveColumn(column, target: target, context: context, state: &state)
            }
            guard didMove else { return }
            _ = engine.triggerMoveAnimations(
                in: workspaceId,
                oldFrames: oldFrames,
                newFrames: engine.captureWindowFrames(in: workspaceId),
                motion: context.motion
            )
            recordLayoutOperation(.columnMoved, in: workspaceId)
            requestLayoutCommandRelayout(in: workspaceId)
            startScrollAnimationIfNeeded(for: workspaceId, state: state, engine: engine)
            moved = true
        }
        return moved
    }

    @discardableResult
    func toggleColumnTabbed(target: WindowTarget) -> Bool {
        guard let controller else { return false }
        var toggled = false
        withNiriWindowContext(target) { engine, windowNode, context, state in
            let workspaceId = context.workspaceId
            guard let column = engine.column(of: windowNode) else { return }
            let movesFromRealPlaces = controller.settings.niri.naturalWindowDrag && context.orientation == .horizontal
            let previousPlaces = movesFromRealPlaces ? engine.liveWindowPlaces(in: [column], context: context) : [:]
            let shownTab = column.isTabbed ? engine.projectedActiveWindow(in: column, workspaceId: workspaceId) : nil
            guard engine.toggleColumnTabbed(
                column,
                in: workspaceId,
                motion: context.motion,
                orientation: context.orientation
            ) else { return }
            if movesFromRealPlaces {
                engine.animateDisplayChange(of: column, from: previousPlaces, onlyMoving: shownTab, context: context)
            }
            recordLayoutOperation(.displayModeChanged, in: workspaceId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
            if engine.hasAnyWindowAnimationsRunning(in: workspaceId) {
                controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
            }
            if case .focused = target {
                showColumnModeToast(engine: engine, workspaceId: workspaceId, state: state, motion: context.motion)
            }
            toggled = true
        }
        return toggled
    }
}
