// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension WMEvent {
    var mutatesSnapshotAfterPlan: Bool {
        switch self {
        case .windowRemoved:
            true
        case .activeSpaceChanged,
             .appVisibilityInvalidated,
             .floatingGeometryUpdated,
             .hostedWindowGeometryObserved,
             .floatingStateChanged,
             .focusFallbackRemembered,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .hiddenApplicationsChanged,
             .windowMinimizedChanged,
             .windowNativeWithdrawalChanged,
             .hiddenStateChanged,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .managedReplacementMetadataChanged,
             .manualLayoutOverrideChanged,
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
             .systemSleep,
             .systemWake,
             .topLevelInventoryObserved,
             .topologyChanged,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .visibleWorkspacesChanged,
             .windowAdmissionHintsChanged,
             .windowAdmitted,
             .windowModeChanged,
             .windowRekeyed,
             .workspaceAssigned,
             .workspaceFocusCleared:
            false
        }
    }
}
