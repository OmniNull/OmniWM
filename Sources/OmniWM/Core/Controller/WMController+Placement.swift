// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func resolveWorkspaceForNewWindow(
        workspaceName: String? = nil,
        axRef: AXWindowRef,
        pid: pid_t,
        parentWindowId: UInt32? = nil,
        inheritTrackedParentWorkspace: Bool = false,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        placementMode: TrackedWindowMode,
        allowsFloatingSpawnPlacement: Bool = false,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        createPlacementContext: WindowCreatePlacementContext? = nil,
        appKitFrame: CGRect? = nil,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspacePlacementResolution {
        placementResolver.resolveWorkspacePlacement(
            window: WorkspacePlacementWindow(
                axRef: axRef,
                pid: pid,
                parentWindowId: parentWindowId,
                placementMode: placementMode,
                appKitFrame: appKitFrame,
                existingEntry: nil
            ),
            rules: WorkspacePlacementRules(
                workspaceName: workspaceName,
                inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
                structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
                allowsFloatingSpawnPlacement: allowsFloatingSpawnPlacement
            ),
            context: WorkspacePlacementContext(
                origin: placementOrigin,
                createPlacementContext: createPlacementContext,
                fallbackWorkspaceId: fallbackWorkspaceId,
                reevaluation: .automatic
            )
        )
    }

    func resolvedWorkspaceId(
        for evaluation: WindowDecisionEvaluation,
        axRef: AXWindowRef?,
        existingEntry: WindowState?,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        placementMode: TrackedWindowMode,
        placementContext: WorkspacePlacementContext,
        appKitFrame: CGRect? = nil
    ) -> WorkspaceDescriptor.ID {
        let inheritTrackedParentWorkspace = shouldInheritTrackedParentWorkspace(for: evaluation)
        let placementFrame = appKitFrame ?? WindowAdmissionGeometryEvidence.usableAppKitFrame(
            fromWindowServer: evaluation.facts.windowServer?.frame
        )
        return placementResolver.resolveWorkspacePlacement(
            window: WorkspacePlacementWindow(
                axRef: axRef,
                pid: evaluation.token.pid,
                parentWindowId: evaluation.facts.windowServer?.parentId,
                placementMode: placementMode,
                appKitFrame: placementFrame,
                existingEntry: existingEntry
            ),
            rules: WorkspacePlacementRules(
                workspaceName: evaluation.decision.workspaceName,
                inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
                structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
                allowsFloatingSpawnPlacement: allowsFloatingSpawnPlacement(
                    for: evaluation,
                    mode: placementMode
                )
            ),
            context: placementContext
        ).workspaceId
    }
}
