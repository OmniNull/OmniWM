// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum WorkspacePlacementRung: String, Sendable {
    case existingEntry = "existing_entry"
    case structuralReplacement = "structural_replacement"
    case trackedParent = "tracked_parent"
    case workspaceRule = "workspace_rule"
    case pendingFocusContext = "pending_focus_context"
    case interactionWorkspace = "interaction_workspace"
    case focusedContext = "focused_context"
    case nativeSpace = "native_space"
    case floatingSpawn = "floating_spawn"
    case liveManagedFocus = "live_managed_focus"
    case frame = "frame"
    case axFrame = "ax_frame"
    case interactionMonitor = "interaction_monitor"
    case fallbackWorkspace = "fallback_workspace"
    case defaultWorkspace = "default_workspace"
}

enum WorkspacePlacementOrigin: Equatable, Sendable {
    case liveCreate
    case discovery
}

enum WorkspaceRuleSkipReason: String, Sendable {
    case workspaceNotMaterialized = "workspace_not_materialized"
    case appAlreadyHasEntries = "app_already_has_entries"
}

struct WorkspacePlacementResolution: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let rung: WorkspacePlacementRung
    var ruleSkipReason: WorkspaceRuleSkipReason?
}

struct WorkspacePlacementWindow {
    let axRef: AXWindowRef?
    let pid: pid_t?
    let parentWindowId: UInt32?
    let placementMode: TrackedWindowMode
    let appKitFrame: CGRect?
    let existingEntry: WindowState?
}

struct WorkspacePlacementRules {
    let workspaceName: String?
    let inheritTrackedParentWorkspace: Bool
    let structuralReplacementWorkspaceId: WorkspaceDescriptor.ID?
    let allowsFloatingSpawnPlacement: Bool
}

struct WorkspacePlacementContext {
    let origin: WorkspacePlacementOrigin
    let createPlacementContext: WindowCreatePlacementContext?
    let fallbackWorkspaceId: WorkspaceDescriptor.ID?
    let reevaluation: WindowRuleReevaluationContext
}
