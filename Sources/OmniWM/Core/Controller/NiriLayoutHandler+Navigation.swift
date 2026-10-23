// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func focusNeighbor(direction: Direction) -> Bool {
        guard let controller else { return false }
        guard let engine = controller.niriEngine else { return false }
        guard let wsId = controller.activeWorkspace()?.id else { return false }

        var state = controller.workspaceManager.niriViewportState(for: wsId)
        guard let currentId = state.selectedNodeId,
              let currentNode = engine.findNode(by: currentId, in: wsId)
        else {
            return recoverNeighborSelection(in: wsId, engine: engine, controller: controller, state: &state)
        }

        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return false }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let orientation = resolvedOrientation(
            for: wsId,
            monitor: monitor,
            engine: engine
        )
        let options = NodeActivationOptions(
            activateWindow: false,
            ensureVisible: false,
            layoutRefresh: false,
            axFocus: false
        )

        let target = controller.workspaceManager.withEngineMutationScope { () -> (node: NiriNode, suppressed: Bool)? in
            let context = NiriInteractionContext(
                workspaceId: wsId,
                motion: controller.motionPolicy.snapshot(),
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap,
                orientation: orientation
            )
            return prepareNeighborSelection(
                currentNode, direction: direction, context: context, state: &state, options: options
            )
        }
        guard let target else { return false }
        if target.suppressed {
            requestLayoutCommandRelayout(in: wsId)
            return false
        }
        completeNeighborFocus(
            target.node,
            workspaceId: wsId,
            state: state,
            options: options,
            navigation: (direction, orientation)
        )
        return true
    }

    private func recoverNeighborSelection(
        in wsId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        controller: WMController,
        state: inout ViewportState
    ) -> Bool {
        var recovered = false
        if let lastFocused = controller.workspaceManager.lastFocusedToken(in: wsId),
           !controller.isManagedWindowSuppressedByMacOS(lastFocused),
           let lastNode = engine.findNode(for: lastFocused, in: wsId)
        {
            activateNode(
                lastNode, in: wsId, state: &state,
                options: .init(
                    activateWindow: false,
                    ensureVisible: false,
                    layoutRefresh: false,
                    startAnimation: false
                )
            )
            recovered = true
        } else if let firstEntry = controller.workspaceManager.tiledEntries(in: wsId).first(where: {
                      !controller.isManagedWindowSuppressedByMacOS($0.token)
                  }),
                  let firstNode = engine.findNode(for: firstEntry.token, in: wsId)
        {
            activateNode(
                firstNode, in: wsId, state: &state,
                options: .init(
                    activateWindow: false,
                    ensureVisible: false,
                    layoutRefresh: false,
                    startAnimation: false
                )
            )
            recovered = true
        }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        return recovered
    }

    private func completeNeighborFocus(
        _ newNode: NiriNode,
        workspaceId wsId: WorkspaceDescriptor.ID,
        state: ViewportState,
        options: NodeActivationOptions,
        navigation: (direction: Direction, orientation: Monitor.Orientation)
    ) {
        guard let controller else { return }
        completeNodeActivation(newNode, in: wsId, state: state, options: options)
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        let isPrimaryNavigation = navigation.direction.primaryStep(for: navigation.orientation) != nil
        focusSelectedWindowAndRequestRelayout(
            in: wsId,
            raisesWindow: !isPrimaryNavigation,
            defersRetryRaise: isPrimaryNavigation
        )
    }

    private func prepareNeighborSelection(
        _ currentNode: NiriNode,
        direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState,
        options: NodeActivationOptions
    ) -> (node: NiriNode, suppressed: Bool)? {
        guard let controller, let engine = controller.niriEngine else { return nil }
        let wsId = context.workspaceId
        guard let node = engine.focusTarget(
            direction: direction,
            currentSelection: currentNode,
            context: context,
            state: &state
        ) else { return nil }
        let targetIsSuppressed = (node as? NiriWindow).map {
            controller.isManagedWindowSuppressedByMacOS($0.token)
        } ?? false
        if !targetIsSuppressed {
            prepareNodeActivation(node, in: wsId, state: &state, options: options)
        }
        return (node, targetIsSuppressed)
    }
}
