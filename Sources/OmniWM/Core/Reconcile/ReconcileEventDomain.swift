// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum ReconcileEventDomain {
    case window
    case focus
    case viewport
    case session
}

extension WMEvent {
    var reconcileDomain: ReconcileEventDomain {
        switch self {
        case .windowAdmitted,
             .windowRekeyed,
             .windowRemoved,
             .workspaceAssigned,
             .windowModeChanged,
             .floatingGeometryUpdated,
             .hostedWindowGeometryObserved,
             .floatingStateChanged,
             .manualLayoutOverrideChanged,
             .windowAdmissionHintsChanged,
             .topLevelInventoryObserved,
             .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .layoutOperationPerformed,
             .managedReplacementMetadataChanged,
             .hiddenApplicationsChanged,
             .windowMinimizedChanged,
             .windowNativeWithdrawalChanged,
             .appVisibilityInvalidated,
             .hiddenStateChanged,
             .nativeFullscreenTransition:
            .window
        case .focusLeaseChanged,
             .managedFocusRequested,
             .managedFocusConfirmed,
             .managedFocusCancelled,
             .nativeFocusOwnerChanged,
             .focusRemembered,
             .focusFallbackRemembered,
             .focusForgotten,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .nativeFullscreenPlaceholderSelected,
             .interactionMonitorChanged,
             .workspaceFocusCleared:
            .focus
        case .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .selectionChanged:
            .viewport
        case .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .visibleWorkspacesChanged,
             .spaceTopologyChanged,
             .topologyChanged,
             .activeSpaceChanged,
             .systemSleep,
             .systemWake,
             .userCommand:
            .session
        }
    }
}
