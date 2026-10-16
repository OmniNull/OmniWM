// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func selectedWindowHandleInActiveWorkspace() -> WindowHandle? {
        guard let controller,
              let workspaceId = controller.activeWorkspace()?.id,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
              let engine = controller.niriEngine,
              let window = engine.projectedSelectedWindow(
                  state: controller.workspaceManager.niriViewportState(for: workspaceId),
                  in: workspaceId
              ),
              let handle = controller.workspaceManager.handle(for: window.token)
        else {
            return nil
        }
        return handle
    }

    func performStructuralMutation(
        handle: WindowHandle,
        operation: (NiriOperationContext, inout ViewportState) -> NiriStructuralMutation?
    ) -> StructuralMutationOutcome {
        guard let context = structuralMutationContext(for: handle) else { return .unchanged }
        let controller = context.controller
        let engine = context.engine
        let workspaceId = context.wsId
        let windowNode = context.windowNode
        let monitor = context.monitor
        var completedMutation: NiriStructuralMutation?
        var committedState: ViewportState?

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            let originalState = state
            state.selectedNodeId = windowNode.id
            guard let mutation = operation(context, &state) else {
                state = originalState
                return
            }

            restoreStructuralSelection(context: context, state: &state)
            completedMutation = mutation
            committedState = state
        }

        guard let completedMutation, let committedState else { return .unchanged }

        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: windowNode.id,
            focusedToken: handle.id,
            in: workspaceId,
            onMonitor: monitor.id
        )
        recordLayoutOperation(completedMutation.operation, in: workspaceId)

        let scrollWorkspaceId = hasPendingNiriAnimationWork(
            state: committedState,
            driver: controller.workspaceManager.animationDriver,
            engine: engine,
            workspaceId: workspaceId
        ) ? workspaceId : nil

        return .changed(
            StructuralMutation(
                sourceWorkspaceId: workspaceId,
                destinationWorkspaceId: workspaceId,
                selectedHandle: handle,
                scrollWorkspaceId: scrollWorkspaceId
            )
        )
    }

    func commitNormalStructuralMutation(_ outcome: StructuralMutationOutcome) {
        guard let controller, case let .changed(mutation) = outcome else { return }
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: mutation.affectedWorkspaceIds
        )
        if let scrollWorkspaceId = mutation.scrollWorkspaceId {
            controller.layoutRefreshController.startScrollAnimation(for: scrollWorkspaceId)
        }
    }

    private func structuralMutationContext(for handle: WindowHandle) -> NiriOperationContext? {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: handle.id),
              controller.workspaceManager.handle(for: handle.id) === handle,
              !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token),
              controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              let engine = controller.niriEngine,
              !engine.isExcludedFromProjection(handle.id, in: entry.workspaceId),
              let windowNode = engine.findNode(for: handle, in: entry.workspaceId),
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        else {
            return nil
        }

        let workspaceId = entry.workspaceId
        let workingFrame = controller.niriWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = resolvedOrientation(
            for: workspaceId,
            monitor: monitor,
            engine: engine
        )
        return NiriOperationContext(
            controller: controller,
            engine: engine,
            motion: controller.motionPolicy.snapshot(),
            wsId: workspaceId,
            windowNode: windowNode,
            monitor: monitor,
            orientation: orientation,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    private func restoreStructuralSelection(context: NiriOperationContext, state: inout ViewportState) {
        let engine = context.engine
        let workspaceId = context.wsId
        let windowNode = context.windowNode
        engine.activateWindow(windowNode.id, in: workspaceId)
        state.selectedNodeId = windowNode.id
        if engine.projectionExclusions(in: workspaceId).isEmpty {
            engine.ensureSelectionVisible(
                node: windowNode,
                context: context.interactionContext(motion: context.motion),
                state: &state
            )
        } else {
            engine.ensureProjectedSelectionVisible(
                node: windowNode,
                context: context.interactionContext(motion: context.motion),
                state: &state,
                animationConfig: nil,
                fromContainerIndex: nil
            )
        }
    }
}
