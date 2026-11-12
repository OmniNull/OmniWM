// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum InvariantChecks {
    static func validate(snapshot: ReconcileSnapshot) -> [ReconcileInvariantViolation] {
        var violations: [ReconcileInvariantViolation] = []
        var windowByToken: [WindowToken: ReconcileWindowSnapshot] = [:]
        windowByToken.reserveCapacity(snapshot.windows.count)
        var duplicateTokens: Set<WindowToken> = []
        for window in snapshot.windows where windowByToken.updateValue(window, forKey: window.token) != nil {
            duplicateTokens.insert(window.token)
        }

        for token in duplicateTokens {
            violations.append(
                .init(
                    code: "duplicate_window_token",
                    message: "Window token \(token) appears more than once in the runtime snapshot."
                )
            )
        }

        snapshot.focusSession.appendInvariantViolations(windowByToken: windowByToken, to: &violations)

        for window in snapshot.windows {
            window.appendInvariantViolations(
                topology: snapshot.topologyProfile,
                focusSession: snapshot.focusSession,
                to: &violations
            )
        }
        validateLayouts(snapshot: snapshot, windowByToken: windowByToken, violations: &violations)
        return violations
    }

    private static func validateLayouts(
        snapshot: ReconcileSnapshot,
        windowByToken: [WindowToken: ReconcileWindowSnapshot],
        violations: inout [ReconcileInvariantViolation]
    ) {
        for (workspaceId, layout) in snapshot.layouts {
            for column in layout.columns {
                for tile in column.tiles {
                    guard let window = windowByToken[tile.token] else {
                        violations.append(
                            .init(
                                code: "layout_token_missing",
                                message: "Layout token \(tile.token) in workspace \(workspaceId.uuidString) is missing from the window registry."
                            )
                        )
                        continue
                    }
                    if window.workspaceId != workspaceId {
                        violations.append(
                            .init(
                                code: "layout_token_wrong_workspace",
                                message: "Layout token \(tile.token) is laid out in workspace \(workspaceId.uuidString) but the window registry has it in \(window.workspaceId.uuidString)."
                            )
                        )
                    }
                }
            }

            if let selectedNodeId = snapshot.viewports[workspaceId]?.selectedNodeId,
               layout.hasColumns,
               layout.token(for: selectedNodeId) == nil
            {
                violations.append(
                    .init(
                        code: "selection_unresolved",
                        message: "Selected node \(selectedNodeId) in workspace \(workspaceId.uuidString) does not resolve to any laid-out window."
                    )
                )
            }
        }
    }
}

extension FocusSessionSnapshot {
    fileprivate func appendInvariantViolations(
        windowByToken: [WindowToken: ReconcileWindowSnapshot],
        to violations: inout [ReconcileInvariantViolation]
    ) {
        validateManagedSelection(windowByToken: windowByToken, violations: &violations)
        validateExternalParent(windowByToken: windowByToken, violations: &violations)
        validatePendingFocusReferences(windowByToken: windowByToken, violations: &violations)
        validatePendingRequest(violations: &violations)
    }

    private func validateManagedSelection(
        windowByToken: [WindowToken: ReconcileWindowSnapshot],
        violations: inout [ReconcileInvariantViolation]
    ) {
        if let focusedToken = selectedManagedToken,
           windowByToken[focusedToken] == nil
        {
            violations.append(
                .init(
                    code: "selected_managed_token_missing",
                    message: "Selected managed token \(focusedToken) is missing from the runtime snapshot."
                )
            )
        }

        if let focusedToken = selectedManagedToken,
           let focusedWindow = windowByToken[focusedToken],
           focusedWindow.lifecyclePhase == .destroyed
        {
            violations.append(
                .init(
                    code: "selected_managed_token_destroyed",
                    message: "Selected managed token \(focusedToken) points to a destroyed window."
                )
            )
        }

        if case let .managed(nativeToken) = nativeFocusOwner {
            if windowByToken[nativeToken] == nil {
                violations.append(
                    .init(
                        code: "native_focus_token_missing",
                        message: "Native managed focus token \(nativeToken) is missing from the runtime snapshot."
                    )
                )
            }
            if selectedManagedToken != nativeToken {
                violations.append(
                    .init(
                        code: "native_focus_selection_mismatch",
                        message: "Native managed focus token \(nativeToken) does not match managed selection."
                    )
                )
            }
        }
    }

    private func validateExternalParent(
        windowByToken: [WindowToken: ReconcileWindowSnapshot],
        violations: inout [ReconcileInvariantViolation]
    ) {
        if case let .external(identity) = nativeFocusOwner,
           let parentToken = identity.verifiedManagedParentToken
        {
            if identity.exactToken == parentToken {
                violations.append(
                    .init(
                        code: "external_focus_parent_matches_child",
                        message: "Verified external-focus parent \(parentToken) matches the external child."
                    )
                )
            }
            if selectedManagedToken != parentToken {
                violations.append(
                    .init(
                        code: "external_focus_parent_selection_mismatch",
                        message: "Verified external-focus parent \(parentToken) does not match managed selection."
                    )
                )
            }
            if let parentWindow = windowByToken[parentToken] {
                if parentWindow.lifecyclePhase == .destroyed {
                    violations.append(
                        .init(
                            code: "external_focus_parent_destroyed",
                            message: "Verified external-focus parent \(parentToken) points to a destroyed window."
                        )
                    )
                }
            } else {
                violations.append(
                    .init(
                        code: "external_focus_parent_missing",
                        message: "Verified external-focus parent \(parentToken) is missing from the runtime snapshot."
                    )
                )
            }
        }
    }

    private func validatePendingFocusReferences(
        windowByToken: [WindowToken: ReconcileWindowSnapshot],
        violations: inout [ReconcileInvariantViolation]
    ) {
        if let pendingToken = pendingManagedFocus.token,
           windowByToken[pendingToken] == nil
        {
            violations.append(
                .init(
                    code: "pending_focus_token_missing",
                    message: "Pending focus token \(pendingToken) is missing from the runtime snapshot."
                )
            )
        }

        if let pendingToken = pendingManagedFocus.token,
           let pendingWorkspaceId = pendingManagedFocus.workspaceId,
           let pendingWindow = windowByToken[pendingToken],
           pendingWindow.workspaceId != pendingWorkspaceId
        {
            violations.append(
                .init(
                    code: "pending_focus_workspace_mismatch",
                    message: "Pending focus token \(pendingToken) is in workspace \(pendingWindow.workspaceId.uuidString), not pending workspace \(pendingWorkspaceId.uuidString)."
                )
            )
        }
    }

    private func validatePendingRequest(violations: inout [ReconcileInvariantViolation]) {
        if pendingManagedFocus.requestId != nil,
           pendingManagedFocus.token == nil
        {
            violations.append(
                .init(
                    code: "pending_focus_request_without_token",
                    message: "Pending managed focus request has a request id but no token."
                )
            )
        }

        if pendingManagedFocus.requestId != nil,
           pendingManagedFocus.workspaceId == nil
        {
            violations.append(
                .init(
                    code: "pending_focus_request_without_workspace",
                    message: "Pending managed focus request has a request id but no workspace."
                )
            )
        }

        if pendingManagedFocus.requestId == nil,
           pendingManagedFocus != .empty
        {
            violations.append(
                .init(
                    code: "pending_focus_without_request",
                    message: "Pending managed focus exists without a request id."
                )
            )
        }
    }
}

extension ReconcileWindowSnapshot {
    fileprivate func appendInvariantViolations(
        topology: TopologyProfile, focusSession: FocusSessionSnapshot,
        to violations: inout [ReconcileInvariantViolation]
    ) {
        validateWorkspace(violations: &violations)
        validateMonitors(topology: topology, violations: &violations)
        validateLifecycle(focusSession: focusSession, violations: &violations)
    }

    private func validateWorkspace(violations: inout [ReconcileInvariantViolation]) {
        if let observedWorkspaceId = self.observedState.workspaceId,
           observedWorkspaceId != self.workspaceId
        {
            violations.append(
                .init(
                    code: "observed_workspace_mismatch",
                    message: "Observed workspace \(observedWorkspaceId.uuidString) does not match entry workspace \(self.workspaceId.uuidString) for \(self.token)."
                )
            )
        }

        if let desiredWorkspaceId = self.desiredState.workspaceId,
           desiredWorkspaceId != self.workspaceId
        {
            violations.append(
                .init(
                    code: "desired_workspace_mismatch",
                    message: "Desired workspace \(desiredWorkspaceId.uuidString) does not match entry workspace \(self.workspaceId.uuidString) for \(self.token)."
                )
            )
        }

        if let restoreWorkspaceId,
           restoreWorkspaceId != self.workspaceId
        {
            violations.append(
                .init(
                    code: "restore_workspace_mismatch",
                    message: "Restore intent workspace \(restoreWorkspaceId.uuidString) does not match entry workspace \(self.workspaceId.uuidString) for \(self.token)."
                )
            )
        }
    }

    private func validateMonitors(topology: TopologyProfile, violations: inout [ReconcileInvariantViolation]) {
        if let observedMonitorId = self.observedState.monitorId,
           !topology.containsDisplay(observedMonitorId.displayId)
        {
            violations.append(
                .init(
                    code: "observed_monitor_missing",
                    message: "Observed monitor \(observedMonitorId) is missing from the topology for \(self.token)."
                )
            )
        }

        if let desiredMonitorId = self.desiredState.monitorId,
           !topology.containsDisplay(desiredMonitorId.displayId)
        {
            violations.append(
                .init(
                    code: "desired_monitor_missing",
                    message: "Desired monitor \(desiredMonitorId) is missing from the topology for \(self.token)."
                )
            )
        }
    }

    private func validateLifecycle(
        focusSession: FocusSessionSnapshot,
        violations: inout [ReconcileInvariantViolation]
    ) {
        if let desiredDisposition = self.desiredState.disposition,
           desiredDisposition != self.mode,
           self.lifecyclePhase != .replacing,
           self.lifecyclePhase != .destroyed
        {
            violations.append(
                .init(
                    code: "desired_mode_mismatch",
                    message: "Desired mode \(desiredDisposition) does not match entry mode \(self.mode) for \(self.token)."
                )
            )
        }

        switch self.lifecyclePhase {
        case .floating where self.mode != .floating:
            violations.append(
                .init(
                    code: "floating_phase_mode_mismatch",
                    message: "Floating lifecycle phase must carry floating mode for \(self.token)."
                )
            )
        case .tiled where self.mode != .tiling:
            violations.append(
                .init(
                    code: "tiled_phase_mode_mismatch",
                    message: "Tiled lifecycle phase must carry tiling mode for \(self.token)."
                )
            )
        case .destroyed where focusSession.selectedManagedToken == self.token:
            violations.append(
                .init(
                    code: "destroyed_window_selected",
                    message: "Destroyed window \(self.token) is still selected."
                )
            )
        default:
            break
        }
    }
}
