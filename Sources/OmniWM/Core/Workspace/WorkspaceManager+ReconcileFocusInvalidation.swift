// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func auxiliaryFocusStateChanged(from previous: FocusSessionSnapshot) -> Bool {
        let current = focusSessionSnapshot
        return current.lastTiledFocusedByWorkspace != previous.lastTiledFocusedByWorkspace
            || current.lastFloatingFocusedByWorkspace != previous.lastFloatingFocusedByWorkspace
            || current.lastFocusedByWorkspace != previous.lastFocusedByWorkspace
            || current.lastTiledFocusedToken != previous.lastTiledFocusedToken
            || current.nativeFocusOwner != previous.nativeFocusOwner
            || current.suppressedFocusToken != previous.suppressedFocusToken
            || current.systemModalFocusToken != previous.systemModalFocusToken
    }

    func noteAuxiliaryFocusInvalidationIfNeeded(
        for event: WMEvent,
        previousFocus: FocusSessionSnapshot,
        plan: ActionPlan
    ) {
        switch event {
        case .managedFocusConfirmed,
             .windowModeChanged,
             .windowRekeyed:
            guard auxiliaryFocusStateChanged(from: previousFocus) else { return }
            let workspaceId = focusInvalidationWorkspaceId(for: focusSessionSnapshot)
            noteFocusInvalidation(previousWorkspaceId: workspaceId, currentWorkspaceId: workspaceId)
        case let .windowRemoved(_, eventWorkspaceId, _):
            guard auxiliaryFocusStateChanged(from: previousFocus) else { return }
            let previousWorkspaceId = eventWorkspaceId ?? focusInvalidationWorkspaceId(for: previousFocus)
            let currentWorkspaceId = focusInvalidationWorkspaceId(for: focusSessionSnapshot)
            noteFocusInvalidation(previousWorkspaceId: previousWorkspaceId, currentWorkspaceId: currentWorkspaceId)
        case .suppressedFocusChanged,
             .systemModalFocusChanged:
            guard plan.focusSession != nil else { return }
            let workspaceId = focusInvalidationWorkspaceId(for: focusSessionSnapshot)
            noteFocusInvalidation(
                previousWorkspaceId: workspaceId,
                currentWorkspaceId: workspaceId,
                surfaceScope: .border
            )
        case .nativeFullscreenPlaceholderSelected,
             .workspaceFocusCleared:
            guard plan.focusSession != nil else { return }
            noteFocusInvalidation(
                previousWorkspaceId: focusInvalidationWorkspaceId(for: previousFocus),
                currentWorkspaceId: focusInvalidationWorkspaceId(for: focusSessionSnapshot)
            )
        default:
            break
        }
    }
}
