// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation

enum WMEventSource: String, Equatable {
    case ax
    case workspaceManager
    case service
    case command
    case mouse
    case focusPolicy
    case layoutRefresh
}

enum NativeFullscreenLayoutChange: Equatable {
    case suspended(LayoutReason)
    case restored

    var isNativeFullscreenActive: Bool {
        self == .suspended(.nativeFullscreen)
    }
}

enum WMEvent: Equatable {
    case windowAdmitted(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode,
        target: WindowTarget,
        ruleEffects: ManagedWindowRuleEffects,
        admissionHints: ManagedWindowAdmissionHints,
        lifetimeAuthority: ManagedWindowLifetimeAuthority,
        adoptNativeFocus: Bool,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        source: WMEventSource,
        initialFrame: CGRect? = nil
    )
    case topLevelInventoryObserved(
        tokens: Set<WindowToken>,
        source: WMEventSource
    )
    case windowRekeyed(
        from: WindowToken,
        to: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        reason: ReplacementCorrelation.Reason,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        source: WMEventSource
    )
    case windowRemoved(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?,
        source: WMEventSource
    )
    case workspaceAssigned(
        token: WindowToken,
        from: WorkspaceDescriptor.ID?,
        to: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        source: WMEventSource
    )
    case windowModeChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode,
        source: WMEventSource
    )
    case hostedWindowGeometryObserved(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        frame: CGRect,
        source: WMEventSource
    )
    case floatingGeometryUpdated(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        referenceMonitorId: Monitor.ID?,
        frame: CGRect,
        normalizedOrigin: CGPoint?,
        restoreToFloating: Bool,
        source: WMEventSource
    )
    case floatingStateChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        state: FloatingState?,
        source: WMEventSource
    )
    case manualLayoutOverrideChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        layoutOverride: ManualWindowOverride?,
        source: WMEventSource
    )
    case windowAdmissionHintsChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        admissionHints: ManagedWindowAdmissionHints,
        source: WMEventSource
    )
    case niriPlacementsResolved(
        placements: [WindowToken: PersistedNiriPlacement],
        source: WMEventSource
    )
    case dwindlePlacementsResolved(
        placements: [WindowToken: PersistedDwindlePlacement],
        source: WMEventSource
    )
    case hiddenApplicationsChanged(
        pids: Set<pid_t>,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        source: WMEventSource
    )
    case appVisibilityInvalidated(
        pid: pid_t,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        source: WMEventSource
    )
    case windowMinimizedChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        minimized: Bool,
        source: WMEventSource
    )
    case windowNativeWithdrawalChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        withdrawn: Bool,
        source: WMEventSource
    )
    case hiddenStateChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        hiddenState: HiddenState?,
        source: WMEventSource
    )
    case nativeFullscreenTransition(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        change: NativeFullscreenLayoutChange,
        source: WMEventSource
    )
    case managedReplacementMetadataChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        metadata: ManagedReplacementMetadata?,
        source: WMEventSource
    )
    case topologyChanged(
        displays: [DisplayFingerprint],
        source: WMEventSource
    )
    case activeSpaceChanged(source: WMEventSource)
    case focusLeaseChanged(
        lease: FocusPolicyLease?,
        source: WMEventSource
    )
    case managedFocusRequested(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        requestId: UInt64,
        source: WMEventSource
    )
    case managedFocusConfirmed(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        requestId: UInt64?,
        source: WMEventSource
    )
    case managedFocusCancelled(
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        requestId: UInt64?,
        source: WMEventSource
    )
    case nativeFocusOwnerChanged(
        owner: NativeFocusOwner,
        preservePendingManagedFocus: Bool,
        source: WMEventSource
    )
    case focusRemembered(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        source: WMEventSource
    )
    case focusFallbackRemembered(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        source: WMEventSource
    )
    case focusForgotten(
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        source: WMEventSource
    )
    case suppressedFocusChanged(
        token: WindowToken?,
        source: WMEventSource
    )
    case systemModalFocusChanged(
        token: WindowToken?,
        source: WMEventSource
    )
    case workspaceFocusCleared(
        workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource
    )
    case nativeFullscreenPlaceholderSelected(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource
    )
    case interactionMonitorChanged(
        monitorId: Monitor.ID?,
        previousMonitorId: Monitor.ID?,
        source: WMEventSource
    )
    case layoutOperationPerformed(
        workspaceId: WorkspaceDescriptor.ID,
        operation: LayoutOperation,
        source: WMEventSource
    )
    case viewportChanged(
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        source: WMEventSource
    )
    case viewportCommitted(
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        source: WMEventSource
    )
    case viewportForgotten(
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        source: WMEventSource
    )
    case selectionChanged(
        workspaceId: WorkspaceDescriptor.ID,
        nodeId: NodeId,
        source: WMEventSource
    )
    case scratchpadMembershipChanged(
        token: WindowToken,
        index: ScratchpadIndex?,
        source: WMEventSource
    )
    case scratchpadRevealChanged(
        index: ScratchpadIndex?,
        source: WMEventSource
    )
    case visibleWorkspacesChanged(
        sessions: [Monitor.ID: MonitorSession],
        source: WMEventSource
    )
    case spaceTopologyChanged(
        topology: SpaceTopology,
        source: WMEventSource
    )
    case systemSleep(source: WMEventSource)
    case systemWake(source: WMEventSource)
    case userCommand(
        workspaceId: WorkspaceDescriptor.ID?,
        label: String,
        source: WMEventSource
    )
}

extension WMEvent {
    @MainActor
    private static let placeholderAXElement = AXUIElementCreateSystemWide()

    @MainActor
    func strippingAXReferences() -> WMEvent {
        switch self {
        case let .windowAdmitted(
            token,
            workspaceId,
            monitorId,
            mode,
            target,
            ruleEffects,
            admissionHints,
            lifetimeAuthority,
            adoptNativeFocus,
            metadata,
            source,
            initialFrame
        ):
            .windowAdmitted(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode,
                target: target.axRef.map {
                    .external(AXWindowRef(element: Self.placeholderAXElement, windowId: $0.windowId))
                } ?? target,
                ruleEffects: ruleEffects,
                admissionHints: admissionHints,
                lifetimeAuthority: lifetimeAuthority,
                adoptNativeFocus: adoptNativeFocus,
                managedReplacementMetadata: metadata,
                source: source,
                initialFrame: initialFrame
            )
        case let .windowRekeyed(from, to, workspaceId, monitorId, reason, newAXRef, metadata, source):
            .windowRekeyed(
                from: from,
                to: to,
                workspaceId: workspaceId,
                monitorId: monitorId,
                reason: reason,
                newAXRef: AXWindowRef(element: Self.placeholderAXElement, windowId: newAXRef.windowId),
                managedReplacementMetadata: metadata,
                source: source
            )
        default:
            self
        }
    }

    var token: WindowToken? {
        switch self {
        case let .windowAdmitted(token, _, _, _, _, _, _, _, _, _, _, _),
             let .windowRemoved(token, _, _),
             let .workspaceAssigned(token, _, _, _, _),
             let .windowModeChanged(token, _, _, _, _),
             let .floatingGeometryUpdated(token, _, _, _, _, _, _),
             let .hostedWindowGeometryObserved(token, _, _, _, _),
             let .floatingStateChanged(token, _, _, _),
             let .manualLayoutOverrideChanged(token, _, _, _),
             let .windowAdmissionHintsChanged(token, _, _, _),
             let .hiddenStateChanged(token, _, _, _, _),
             let .windowMinimizedChanged(token, _, _, _),
             let .windowNativeWithdrawalChanged(token, _, _, _),
             let .nativeFullscreenTransition(token, _, _, _, _),
             let .managedReplacementMetadataChanged(token, _, _, _, _),
             let .managedFocusRequested(token, _, _, _, _),
             let .managedFocusConfirmed(token, _, _, _, _):
            token
        case let .windowRekeyed(_, to, _, _, _, _, _, _):
            to
        case let .managedFocusCancelled(token, _, _, _):
            token
        case .activeSpaceChanged,
             .appVisibilityInvalidated,
             .focusFallbackRemembered,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .hiddenApplicationsChanged,
             .nativeFocusOwnerChanged,
             .nativeFullscreenPlaceholderSelected,
             .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .selectionChanged,
             .spaceTopologyChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .systemSleep,
             .systemWake,
             .topLevelInventoryObserved,
             .topologyChanged,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .visibleWorkspacesChanged,
             .workspaceFocusCleared:
            nil
        }
    }

    var summary: String {
        switch self {
        case let .windowAdmitted(token, workspaceId, _, mode, _, _, _, _, _, _, _, _):
            "window_admitted token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode)"
        case let .topLevelInventoryObserved(tokens, _):
            "top_level_inventory_observed count=\(tokens.count)"
        case let .windowRekeyed(from, to, workspaceId, _, reason, _, _, _):
            "window_rekeyed from=\(from) to=\(to) workspace=\(workspaceId.uuidString) reason=\(reason.rawValue)"
        case let .windowRemoved(token, workspaceId, _):
            "window_removed token=\(token) workspace=\(workspaceId?.uuidString ?? "nil")"
        case let .workspaceAssigned(token, from, to, _, _):
            "workspace_assigned token=\(token) from=\(from?.uuidString ?? "nil") to=\(to.uuidString)"
        case let .windowModeChanged(token, workspaceId, _, mode, _):
            "window_mode_changed token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode)"
        case let .hostedWindowGeometryObserved(token, workspaceId, _, frame, _):
            "hosted_window_geometry_observed token=\(token) workspace=\(workspaceId.uuidString) frame=\(frame.debugDescription)"
        case let .floatingGeometryUpdated(token, workspaceId, _, frame, _, restoreToFloating, _):
            "floating_geometry_updated token=\(token) workspace=\(workspaceId.uuidString) frame=\(frame.debugDescription) restore=\(restoreToFloating)"
        case let .floatingStateChanged(token, workspaceId, state, _):
            "floating_state_changed token=\(token) workspace=\(workspaceId.uuidString) state=\(state != nil)"
        case let .manualLayoutOverrideChanged(token, workspaceId, layoutOverride, _):
            "manual_layout_override_changed token=\(token) workspace=\(workspaceId.uuidString) override=\(layoutOverride.map(\.rawValue) ?? "nil")"
        case let .windowAdmissionHintsChanged(token, workspaceId, admissionHints, _):
            "window_admission_hints_changed token=\(token) workspace=\(workspaceId.uuidString) initial_niri_container_primary_span=\(admissionHints.initialNiriContainerPrimarySpan.map { String($0) } ?? "nil")"
        case let .niriPlacementsResolved(placements, _):
            "niri_placements_resolved count=\(placements.count)"
        case let .dwindlePlacementsResolved(placements, _):
            "dwindle_placements_resolved count=\(placements.count)"
        case let .hiddenApplicationsChanged(pids, affectedWorkspaceIds, _):
            "hidden_applications_changed pids=\(pids.count) workspaces=\(affectedWorkspaceIds.count)"
        case let .appVisibilityInvalidated(pid, affectedWorkspaceIds, _):
            "app_visibility_invalidated pid=\(pid) workspaces=\(affectedWorkspaceIds.count)"
        case let .hiddenStateChanged(token, workspaceId, _, hiddenState, _):
            "hidden_state_changed token=\(token) workspace=\(workspaceId.uuidString) hidden=\(hiddenState != nil)"
        case let .windowMinimizedChanged(token, workspaceId, minimized, _):
            "window_minimized token=\(token) workspace=\(workspaceId.uuidString) minimized=\(minimized)"
        case let .windowNativeWithdrawalChanged(token, workspaceId, withdrawn, _):
            "window_native_withdrawal token=\(token) workspace=\(workspaceId.uuidString) withdrawn=\(withdrawn)"
        case let .nativeFullscreenTransition(token, workspaceId, _, change, _):
            "native_fullscreen token=\(token) workspace=\(workspaceId.uuidString) active=\(change.isNativeFullscreenActive)"
        case let .managedReplacementMetadataChanged(token, workspaceId, monitorId, _, _):
            "managed_replacement_metadata_changed token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId))"
        case let .topologyChanged(displays, _):
            "topology_changed displays=\(displays.count)"
        case .activeSpaceChanged:
            "active_space_changed"
        case let .focusLeaseChanged(lease, _):
            "focus_lease_changed owner=\(lease?.owner.rawValue ?? "nil") reason=\(lease?.reason ?? "")"
        case let .managedFocusRequested(token, workspaceId, monitorId, requestId, _):
            "managed_focus_requested token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId)) request=\(requestId)"
        case let .managedFocusConfirmed(token, workspaceId, monitorId, requestId, _):
            "managed_focus_confirmed token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId)) request=\(requestId.map { String($0) } ?? "nil")"
        case let .managedFocusCancelled(token, workspaceId, requestId, _):
            "managed_focus_cancelled token=\(token.map(String.init(describing:)) ?? "nil") workspace=\(workspaceId?.uuidString ?? "nil") request=\(requestId.map { String($0) } ?? "nil")"
        case let .nativeFocusOwnerChanged(owner, preservePendingManagedFocus, _):
            "native_focus_owner_changed owner=\(owner) preserve_pending=\(preservePendingManagedFocus)"
        case let .focusRemembered(token, workspaceId, mode, _):
            "focus_remembered token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode)"
        case let .focusFallbackRemembered(token, workspaceId, mode, _):
            "focus_fallback_remembered token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode)"
        case let .focusForgotten(workspaceIds, _):
            "focus_forgotten workspaces=\(workspaceIds.count)"
        case let .suppressedFocusChanged(token, _):
            "suppressed_focus_changed token=\(token.map(String.init(describing:)) ?? "nil")"
        case let .systemModalFocusChanged(token, _):
            "system_modal_focus_changed token=\(token.map(String.init(describing:)) ?? "nil")"
        case let .workspaceFocusCleared(workspaceId, _):
            "workspace_focus_cleared workspace=\(workspaceId.uuidString)"
        case let .nativeFullscreenPlaceholderSelected(token, workspaceId, _):
            "native_fullscreen_placeholder_selected token=\(token) workspace=\(workspaceId.uuidString)"
        case let .interactionMonitorChanged(monitorId, previousMonitorId, _):
            "interaction_monitor_changed monitor=\(String(describing: monitorId)) previous=\(String(describing: previousMonitorId))"
        case let .layoutOperationPerformed(workspaceId, operation, _):
            "layout_operation workspace=\(workspaceId.uuidString) op=\(operation.summary)"
        case let .viewportChanged(workspaceId, state, _):
            "viewport_changed workspace=\(workspaceId.uuidString) selected=\(state.selectedNodeId.map(String.init(describing:)) ?? "nil") column=\(state.activeColumnIndex) target=\(state.viewOffset)"
        case let .viewportCommitted(workspaceId, state, _):
            "viewport_committed workspace=\(workspaceId.uuidString) selected=\(state.selectedNodeId.map(String.init(describing:)) ?? "nil") column=\(state.activeColumnIndex)"
        case let .viewportForgotten(workspaceIds, _):
            "viewport_forgotten workspaces=\(workspaceIds.count)"
        case let .selectionChanged(workspaceId, nodeId, _):
            "selection_changed workspace=\(workspaceId.uuidString) node=\(nodeId)"
        case let .scratchpadMembershipChanged(token, index, _):
            "scratchpad_membership_changed token=\(token) index=\(index.map(String.init(describing:)) ?? "nil")"
        case let .scratchpadRevealChanged(index, _):
            "scratchpad_reveal_changed index=\(index.map(String.init(describing:)) ?? "nil")"
        case let .visibleWorkspacesChanged(sessions, _):
            "visible_workspaces_changed monitors=\(sessions.count)"
        case let .spaceTopologyChanged(topology, _):
            "space_topology_changed displays=\(topology.displays.count) windows=\(topology.windowSpace.count)"
        case .systemSleep:
            "system_sleep"
        case .systemWake:
            "system_wake"
        case let .userCommand(workspaceId, label, _):
            "user_command label=\(label) workspace=\(workspaceId?.uuidString ?? "nil")"
        }
    }
}
