// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension WMEvent {
    var requiresRuntimeInvalidation: Bool {
        switch self {
        case .activeSpaceChanged,
             .appVisibilityInvalidated,
             .floatingStateChanged,
             .hiddenApplicationsChanged,
             .windowMinimizedChanged,
             .windowNativeWithdrawalChanged,
             .layoutOperationPerformed,
             .manualLayoutOverrideChanged,
             .systemSleep,
             .systemWake,
             .topologyChanged:
            true
        case .floatingGeometryUpdated,
             .hostedWindowGeometryObserved,
             .focusFallbackRemembered,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .hiddenStateChanged,
             .interactionMonitorChanged,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .managedReplacementMetadataChanged,
             .nativeFocusOwnerChanged,
             .nativeFullscreenPlaceholderSelected,
             .nativeFullscreenTransition,
             .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .selectionChanged,
             .spaceTopologyChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .topLevelInventoryObserved,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .visibleWorkspacesChanged,
             .windowAdmitted,
             .windowAdmissionHintsChanged,
             .windowModeChanged,
             .windowRekeyed,
             .windowRemoved,
             .workspaceAssigned,
             .workspaceFocusCleared:
            false
        }
    }
}
