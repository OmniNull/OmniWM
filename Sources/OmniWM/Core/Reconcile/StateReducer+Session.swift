// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension StateReducer {
    static func reducePlacementNotes(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let existingEntry = context.existingEntry
        switch event {
        case let .niriPlacementsResolved(placements, _):
            plan.notes = ["niri_placements=\(placements.count)"]
        case let .dwindlePlacementsResolved(placements, _):
            plan.notes = ["dwindle_placements=\(placements.count)"]
        case let .layoutOperationPerformed(_, operation, _):
            plan.notes = ["layout_op=\(operation.summary)"]
        case let .managedReplacementMetadataChanged(_, workspaceId, monitorId, _, _):
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )
            plan.notes = ["managed_replacement_metadata_changed"]
        default:
            break
        }
    }

    static func reduceSessionNotes(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        switch event {
        case let .scratchpadMembershipChanged(_, index, _):
            plan.notes = ["scratchpad_membership=\(index.map(String.init(describing:)) ?? "none")"]
        case let .scratchpadRevealChanged(index, _):
            plan.notes = ["scratchpad_reveal=\(index.map(String.init(describing:)) ?? "none")"]
        case let .visibleWorkspacesChanged(sessions, _):
            plan.notes = ["visible_workspaces=\(sessions.count)"]
        case let .spaceTopologyChanged(topology, _):
            plan.notes = ["space_topology displays=\(topology.displays.count)"]
        case let .topologyChanged(displays, _):
            plan.notes = ["topology=\(displays.count)"]
        case .activeSpaceChanged:
            plan.notes = ["active_space_changed"]
        case .systemSleep:
            plan.notes = ["system_sleep"]
        case .systemWake:
            plan.notes = ["system_wake"]
        case .userCommand:
            plan.notes = ActionPlan.userCommandNotes
        default:
            break
        }
    }

    static func reduceViewport(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .viewportChanged(workspaceId, state, _):
            var viewport = state
            viewport.clearOffsetTransition()
            setViewport(viewport, for: workspaceId, currentSnapshot: currentSnapshot, plan: &plan)
        case let .viewportCommitted(workspaceId, state, _):
            var viewport = state
            viewport.clearOffsetTransition()
            setViewport(viewport, for: workspaceId, currentSnapshot: currentSnapshot, plan: &plan)
        case let .viewportForgotten(workspaceIds, _):
            let present = workspaceIds.filter { currentSnapshot.viewports[$0] != nil }
            if !present.isEmpty {
                plan.viewport = .remove(workspaceIds: present)
            }
        case let .selectionChanged(workspaceId, nodeId, _):
            var viewport = currentSnapshot.viewports[workspaceId] ?? ViewportState()
            viewport.selectedNodeId = nodeId
            setViewport(viewport, for: workspaceId, currentSnapshot: currentSnapshot, plan: &plan)
        default:
            break
        }
    }
}
