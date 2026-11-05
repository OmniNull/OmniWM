// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class InvariantViolationOrderingTests: XCTestCase {
    func testDuplicateLookupUsesLastEntryWhileWindowDiagnosticsKeepInputOrder() {
        let violations = InvariantChecks.validate(snapshot: duplicateSnapshot())

        XCTAssertEqual(violations.map(\.code), [
            "duplicate_window_token",
            "selected_managed_token_destroyed",
            "external_focus_parent_matches_child",
            "external_focus_parent_destroyed",
            "pending_focus_token_missing",
            "pending_focus_request_without_workspace",
            "observed_workspace_mismatch",
            "desired_workspace_mismatch",
            "observed_monitor_missing",
            "desired_monitor_missing",
            "desired_mode_mismatch",
            "floating_phase_mode_mismatch",
            "destroyed_window_selected"
        ])
    }

    func testPendingRequestShapeFollowsReferenceDiagnostics() {
        var focus = FocusSessionSnapshot()
        focus.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: WindowToken(pid: 3, windowId: 30), workspaceId: .init(),
            monitorId: nil, requestId: nil
        )
        let snapshot = ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []), focusSession: focus, windows: []
        )

        XCTAssertEqual(InvariantChecks.validate(snapshot: snapshot).map(\.code), [
            "pending_focus_token_missing", "pending_focus_without_request"
        ])
        focus.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: nil, workspaceId: nil, monitorId: nil, requestId: 1
        )
        let missingIdentity = ReconcileSnapshot(
            topologyProfile: snapshot.topologyProfile, focusSession: focus, windows: []
        )
        XCTAssertEqual(InvariantChecks.validate(snapshot: missingIdentity).map(\.code), [
            "pending_focus_request_without_token", "pending_focus_request_without_workspace"
        ])
    }

    private func duplicateSnapshot() -> ReconcileSnapshot {
        let token = WindowToken(pid: 1, windowId: 10)
        let workspace = WorkspaceDescriptor.ID()
        let otherWorkspace = WorkspaceDescriptor.ID()
        let first = ReconcileWindowSnapshot(
            token: token, workspaceId: workspace, mode: .tiling, lifecyclePhase: .floating,
            observedState: .initial(workspaceId: otherWorkspace, monitorId: .init(displayId: 1)),
            desiredState: .initial(
                workspaceId: otherWorkspace, monitorId: .init(displayId: 1), disposition: .floating
            ),
            restoreWorkspaceId: nil
        )
        let last = ReconcileWindowSnapshot(
            token: token, workspaceId: workspace, mode: .tiling, lifecyclePhase: .destroyed,
            observedState: .initial(workspaceId: workspace, monitorId: nil),
            desiredState: .initial(workspaceId: workspace, monitorId: nil, disposition: .tiling),
            restoreWorkspaceId: nil
        )
        return ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: FocusSessionSnapshot(
                selectedManagedToken: token,
                nativeFocusOwner: .external(
                    pid: token.pid, windowId: token.windowId, verifiedManagedParentToken: token
                ),
                pendingManagedFocus: PendingManagedFocusSnapshot(
                    token: WindowToken(pid: 2, windowId: 20), workspaceId: nil,
                    monitorId: nil, requestId: 1
                )
            ),
            windows: [first, last]
        )
    }
}
