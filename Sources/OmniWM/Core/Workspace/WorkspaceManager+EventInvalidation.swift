// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceManager {
    func noteInvalidation(for event: WMEvent) {
        switch event.reconcileDomain {
        case .window: noteWindowInvalidation(for: event)
        case .focus: noteFocusEventInvalidation(for: event)
        case .session: noteSessionEventInvalidation(for: event)
        case .viewport: break
        }
    }

    private func noteHiddenStateInvalidation(
        _ hiddenState: HiddenState?,
        of token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        let isLayoutEdge = switch hiddenState?.reason {
        case .none,
             .layoutTransient:
            !isScratchpadToken(token) && windowQueries.layoutReason(for: token) == .standard
        case .workspaceInactive,
             .scratchpad:
            false
        }
        noteInvalidation(
            workspaceId: workspaceId,
            domains: [.workspace, .layout, .focus],
            surfaceScope: isLayoutEdge ? .layoutEdge : .full
        )
    }

    private func noteWindowInvalidation(for event: WMEvent) {
        switch event {
        case let .windowAdmitted(_, workspaceId, _, _, _, _, _, _, _, _, _, _),
             let .windowModeChanged(_, workspaceId, _, _, _),
             let .windowMinimizedChanged(_, workspaceId, _, _),
             let .windowNativeWithdrawalChanged(_, workspaceId, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])

        case let .managedReplacementMetadataChanged(_, workspaceId, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: [.layout, .focus])

        case let .hiddenStateChanged(token, workspaceId, _, hiddenState, _):
            noteHiddenStateInvalidation(hiddenState, of: token, in: workspaceId)

        case let .floatingGeometryUpdated(_, workspaceId, _, _, _, _, _),
             let .hostedWindowGeometryObserved(_, workspaceId, _, _, _):
            noteInvalidation(
                workspaceId: workspaceId,
                domains: [.workspace, .layout],
                surfaceScope: .border
            )

        case let .floatingStateChanged(_, workspaceId, _, _),
             let .manualLayoutOverrideChanged(_, workspaceId, _, _),
             let .layoutOperationPerformed(workspaceId, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: .layout)

        case .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .topLevelInventoryObserved:
            break

        case let .hiddenApplicationsChanged(_, affectedWorkspaceIds, _):
            noteInvalidation(
                workspaceIds: affectedWorkspaceIds,
                domains: [.workspace, .layout, .focus, .fullscreen]
            )

        case let .appVisibilityInvalidated(_, affectedWorkspaceIds, _):
            noteInvalidation(workspaceIds: affectedWorkspaceIds, domains: [.focus])

        case .windowAdmissionHintsChanged:
            break

        case let .windowRekeyed(_, _, workspaceId, _, _, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])

        case let .workspaceAssigned(_, fromWorkspaceId, toWorkspaceId, _, _):
            noteInvalidation(workspaceId: toWorkspaceId, domains: [.workspace, .layout, .focus])
            if let fromWorkspaceId {
                noteInvalidation(workspaceId: fromWorkspaceId, domains: [.workspace, .layout, .focus])
            }

        case let .windowRemoved(token, workspaceId, _):
            noteInvalidation(
                workspaceId: workspaceId ?? windowQueries.entry(for: token)?.workspaceId,
                domains: [.workspace, .layout, .focus, .fullscreen]
            )

        case let .nativeFullscreenTransition(_, workspaceId, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])

        default: preconditionFailure("Expected a Window event")
        }
    }

    private func noteFocusEventInvalidation(for event: WMEvent) {
        switch event {
        case let .managedFocusRequested(_, workspaceId, _, _, _),
             let .managedFocusConfirmed(_, workspaceId, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: .focus)

        case let .managedFocusCancelled(token, workspaceId, _, _):
            noteInvalidation(
                workspaceId: workspaceId ?? token.flatMap { windowQueries.entry(for: $0)?.workspaceId },
                domains: .focus
            )

        case let .focusRemembered(_, workspaceId, _, _),
             let .focusFallbackRemembered(_, workspaceId, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: .focus)

        case .focusForgotten,
             .interactionMonitorChanged,
             .nativeFullscreenPlaceholderSelected,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .workspaceFocusCleared:
            break

        case .focusLeaseChanged:
            noteInvalidation(workspaceId: nil, domains: .focus, surfaceScope: .border)

        case .nativeFocusOwnerChanged:
            noteInvalidation(workspaceId: nil, domains: .focus, surfaceScope: .border)

        default: preconditionFailure("Expected a FocusEvent event")
        }
    }

    private func noteSessionEventInvalidation(for event: WMEvent) {
        switch event {
        case .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .spaceTopologyChanged,
             .userCommand,
             .visibleWorkspacesChanged:
            break
        case .topologyChanged,
             .activeSpaceChanged,
             .systemSleep,
             .systemWake:
            noteInvalidation(workspaceId: nil, domains: [.workspace, .layout, .focus, .fullscreen])
        default: preconditionFailure("Expected a SessionEvent event")
        }
    }

    func eventRequiresRuntimeInvalidation(_ event: WMEvent) -> Bool {
        event.requiresRuntimeInvalidation
    }

    func invalidateLayout(for ids: Set<WorkspaceDescriptor.ID>) {
        noteInvalidation(workspaceIds: ids, domains: .layout)
    }

    func invalidateAllLayouts() {
        noteInvalidation(workspaceId: nil, domains: .layout)
    }
}
