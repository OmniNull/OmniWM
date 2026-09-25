// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func rememberFocus(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let mode = windowMode(for: token) ?? .tiling
        let changed = focusSessionSnapshot.lastFocusedByWorkspace[workspaceId] != token
            || focusSessionSnapshot.focusFallbackToken(in: workspaceId, mode: mode) != token
        guard changed else { return false }
        recordReconcileEvent(
            .focusRemembered(
                token: token,
                workspaceId: workspaceId,
                mode: mode,
                source: .workspaceManager
            )
        )
        return true
    }

    @discardableResult
    private func rememberFocusFallback(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let mode = windowMode(for: token) ?? .tiling
        guard focusSessionSnapshot.focusFallbackToken(in: workspaceId, mode: mode) != token else { return false }
        recordReconcileEvent(
            .focusFallbackRemembered(
                token: token,
                workspaceId: workspaceId,
                mode: mode,
                source: .workspaceManager
            )
        )
        return true
    }

    @discardableResult
    func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> Bool {
        var changed = false

        if let nodeId {
            let currentSelection = niriViewportState(for: workspaceId).selectedNodeId
            if currentSelection != nodeId {
                recordReconcileEvent(
                    .selectionChanged(
                        workspaceId: workspaceId,
                        nodeId: nodeId,
                        source: .workspaceManager
                    )
                )
                changed = true
            }
        }

        if let focusedToken {
            changed = rememberFocus(focusedToken, in: workspaceId) || changed
        }

        return changed
    }

    @discardableResult
    func applySessionPatch(_ patch: WorkspaceSessionPatch) -> Bool {
        guard isSeqCurrent(
            patch.plannedSeq,
            for: patch.workspaceId,
            domains: .layoutCommit
        ) else {
            return false
        }

        var changed = false

        if var viewportState = patch.viewportState {
            normalizeNiriRefreshRate(&viewportState, for: patch.workspaceId)
            recordReconcileEvent(
                .viewportCommitted(
                    workspaceId: patch.workspaceId,
                    state: viewportState,
                    source: .workspaceManager
                )
            )
            changed = true
        }

        if let rememberedFocusToken = patch.rememberedFocusToken {
            if isSeqCurrent(
                patch.plannedSeq,
                for: patch.workspaceId,
                domains: .focusCommit
            ) {
                changed = rememberFocusFallback(rememberedFocusToken, in: patch.workspaceId) || changed
            }
        }

        return changed
    }

    func lastFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        focusSessionSnapshot.lastTiledFocusedByWorkspace[workspaceId]
    }

    func lastFloatingFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        focusSessionSnapshot.lastFloatingFocusedByWorkspace[workspaceId]
    }

    func preferredFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let pendingToken = eligibleFocusCandidate(
            focusSessionSnapshot.pendingManagedFocus.token,
            in: workspaceId,
            mode: .tiling
        ),
            focusSessionSnapshot.pendingManagedFocus.workspaceId == workspaceId
        {
            return pendingToken
        }

        if let remembered = eligibleFocusCandidate(
            focusSessionSnapshot.lastTiledFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .tiling
        ) {
            return remembered
        }

        if let confirmed = eligibleFocusCandidate(
            focusSessionSnapshot.selectedManagedToken,
            in: workspaceId,
            mode: .tiling
        ) {
            return confirmed
        }

        return windowQueries.firstWindow(in: workspaceId, mode: .tiling) {
            isFocusResolutionEligible($0, in: workspaceId, mode: .tiling)
        }?.token
    }

    func resolveWorkspaceFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let mostRecent = focusSessionSnapshot.lastFocusedByWorkspace[workspaceId],
           let mode = windowMode(for: mostRecent),
           let remembered = eligibleFocusCandidate(mostRecent, in: workspaceId, mode: mode)
        {
            return remembered
        }

        if let remembered = eligibleFocusCandidate(
            focusSessionSnapshot.lastTiledFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .tiling
        ) {
            return remembered
        }
        if let preferredTiled = preferredFocusToken(in: workspaceId) {
            return preferredTiled
        }
        if let rememberedFloating = eligibleFocusCandidate(
            focusSessionSnapshot.lastFloatingFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .floating
        ) {
            return rememberedFloating
        }
        if let confirmed = eligibleFocusCandidate(
            focusSessionSnapshot.selectedManagedToken,
            in: workspaceId,
            mode: .floating
        ) {
            return confirmed
        }
        return windowQueries.firstWindow(in: workspaceId, mode: .floating) {
            isFocusResolutionEligible($0, in: workspaceId, mode: .floating)
        }?.token
    }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> WindowToken? {
        if let token = resolveWorkspaceFocusToken(in: workspaceId) {
            _ = rememberFocus(token, in: workspaceId)
            return token
        }

        let focus = focusSessionSnapshot
        let clearsPending = focus.pendingManagedFocus != .empty
            && focus.pendingManagedFocus.workspaceId == workspaceId
        let clearsFocused = focus.selectedManagedToken.flatMap { entry(for: $0)?.workspaceId } == workspaceId
        if clearsPending || clearsFocused,
           applyFocusReconcileEvent(.workspaceFocusCleared(workspaceId: workspaceId, source: .workspaceManager))
        {
            notifySessionStateChanged()
        }

        return nil
    }

    var suppressedFocusToken: WindowToken? {
        focusSessionSnapshot.suppressedFocusToken
    }

    var systemModalFocusToken: WindowToken? {
        focusSessionSnapshot.systemModalFocusToken
    }

    var renderableFocusToken: WindowToken? {
        nativeManagedFocusToken
    }

    func focusInvalidationWorkspaceId(for focus: FocusSessionSnapshot) -> WorkspaceDescriptor.ID? {
        focus.pendingManagedFocus.workspaceId
            ?? focus.selectedManagedToken.flatMap { windowQueries.entry(for: $0)?.workspaceId }
    }

    func noteFocusInvalidation(
        previousWorkspaceId: WorkspaceDescriptor.ID?,
        currentWorkspaceId: WorkspaceDescriptor.ID?,
        surfaceScope: SessionSurfaceInvalidationScope = .full
    ) {
        if let currentWorkspaceId {
            noteInvalidation(
                workspaceId: currentWorkspaceId,
                domains: .focus,
                surfaceScope: surfaceScope
            )
        }
        if let previousWorkspaceId, previousWorkspaceId != currentWorkspaceId {
            noteInvalidation(
                workspaceId: previousWorkspaceId,
                domains: .focus,
                surfaceScope: surfaceScope
            )
        }
        if previousWorkspaceId == nil, currentWorkspaceId == nil {
            noteInvalidation(workspaceId: nil, domains: .focus, surfaceScope: surfaceScope)
        }
    }
}
