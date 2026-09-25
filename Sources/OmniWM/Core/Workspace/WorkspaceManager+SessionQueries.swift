// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    var interactionMonitorId: Monitor.ID? {
        focusSessionSnapshot.interactionMonitorId
    }

    var previousInteractionMonitorId: Monitor.ID? {
        focusSessionSnapshot.previousInteractionMonitorId
    }

    var selectedManagedToken: WindowToken? {
        focusSessionSnapshot.selectedManagedToken
    }

    var nativeFocusOwner: NativeFocusOwner {
        focusSessionSnapshot.nativeFocusOwner
    }

    var nativeManagedFocusToken: WindowToken? {
        focusSessionSnapshot.nativeFocusOwner.managedToken
    }

    var lastTiledFocusedToken: WindowToken? {
        focusSessionSnapshot.lastTiledFocusedToken
    }

    func mostRecentlyFocusedTiledToken(excluding token: WindowToken) -> WindowToken? {
        focusSessionSnapshot.tiledFocusHistory.first { candidate in
            candidate != token && (windowMode(for: candidate) ?? .tiling) == .tiling && entry(for: candidate) != nil
        }
    }

    func mostRecentlyFocusedHandle(forPid pid: pid_t) -> WindowHandle? {
        let entries = entries(forPid: pid).filter { $0.layoutReason == .standard }
        let eligibleTokens = Set(entries.map(\.token))
        guard !eligibleTokens.isEmpty else { return nil }

        func handleIfEligible(_ token: WindowToken?) -> WindowHandle? {
            guard let token, eligibleTokens.contains(token) else { return nil }
            return handle(for: token)
        }

        if let handle = handleIfEligible(selectedManagedToken) { return handle }
        for token in focusSessionSnapshot.tiledFocusHistory {
            if let handle = handleIfEligible(token) { return handle }
        }
        if let interactionMonitorId,
           let workspaceId = activeWorkspace(on: interactionMonitorId)?.id,
           let handle = handleIfEligible(focusSessionSnapshot.lastFocusedByWorkspace[workspaceId])
        {
            return handle
        }
        for monitor in monitors where monitor.id != interactionMonitorId {
            if let workspaceId = activeWorkspace(on: monitor.id)?.id,
               let handle = handleIfEligible(focusSessionSnapshot.lastFocusedByWorkspace[workspaceId])
            {
                return handle
            }
        }
        for workspaceId in focusSessionSnapshot.lastFocusedByWorkspace.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            if let handle = handleIfEligible(focusSessionSnapshot.lastFocusedByWorkspace[workspaceId]) {
                return handle
            }
        }
        return entries.min { $0.windowId < $1.windowId }.flatMap { handle(for: $0.token) }
    }

    var selectedManagedHandle: WindowHandle? {
        selectedManagedToken.flatMap { windowQueries.handle(for: $0) }
    }

    var pendingFocusedToken: WindowToken? {
        focusSessionSnapshot.pendingManagedFocus.token
    }

    var pendingFocusedHandle: WindowHandle? {
        pendingFocusedToken.flatMap { windowQueries.handle(for: $0) }
    }

    var pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? {
        focusSessionSnapshot.pendingManagedFocus.workspaceId
    }

    var pendingFocusedMonitorId: Monitor.ID? {
        focusSessionSnapshot.pendingManagedFocus.monitorId
    }

    func scratchpadMembers(in index: ScratchpadIndex) -> [WindowToken] {
        scratchpadState.membersBySlot[index] ?? []
    }

    func occupiedScratchpadIndices() -> [ScratchpadIndex] {
        scratchpadState.membersBySlot.keys.sorted()
    }

    func isScratchpadToken(_ token: WindowToken) -> Bool {
        scratchpadIndex(for: token) != nil
    }

    func revealedScratchpadIndex() -> ScratchpadIndex? {
        scratchpadState.revealedIndex
    }

    @discardableResult
    func setScratchpadMembership(_ token: WindowToken, to index: ScratchpadIndex?) -> Bool {
        updateScratchpadMembership(token, to: index, notify: true)
    }

    @discardableResult
    func clearScratchpadIfMatches(_ token: WindowToken) -> Bool {
        updateScratchpadMembership(token, to: nil, notify: true)
    }

    @discardableResult
    func setRevealedScratchpad(_ index: ScratchpadIndex?) -> Bool {
        guard scratchpadState.revealedIndex != index else { return false }
        if let index, scratchpadState.membersBySlot[index] == nil { return false }
        recordReconcileEvent(.scratchpadRevealChanged(index: index, source: .workspaceManager))
        notifySessionStateChanged()
        drainPendingRuntimeMonitorOverrideClears()
        return true
    }
}
