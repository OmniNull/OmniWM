// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func structuralReplacementMatch(
        token: WindowToken, candidate: ManagedReplacementCandidateFacts,
        capturedInventory: CapturedWindowServerInventory? = nil
    ) -> StructuralReplacementMatch? {
        guard let controller,
              let fallbackWorkspaceId = controller.activeWorkspace()?.id
              ?? controller.workspaceManager.primaryWorkspace()?.id
              ?? controller.workspaceManager.workspaces.first?.id
        else { return nil }
        let baseMetadata = makeManagedReplacementMetadata(
            bundleId: candidate.bundleId, workspaceId: fallbackWorkspaceId,
            mode: candidate.mode, facts: candidate.facts
        )
        guard managedReplacementCorrelationPolicy(for: baseMetadata) != nil else { return nil }
        var search = StructuralReplacementSearch(
            handler: self, candidate: candidate, capturedInventory: capturedInventory, baseMetadata: baseMetadata
        )
        guard visitPendingReplacementDestroys(pid: token.pid, visit: { search.inspectPendingDestroy($0) }) else {
            return nil
        }
        for entry in controller.workspaceManager.entries(forPid: token.pid) where entry.token != token {
            if !search.inspectLiveEntry(entry) { return nil }
        }
        return search.match
    }
}

@MainActor
private struct StructuralReplacementSearch {
    let handler: AXEventHandler
    let candidate: ManagedReplacementCandidateFacts
    let capturedInventory: CapturedWindowServerInventory?
    let baseMetadata: ManagedReplacementMetadata
    private(set) var match: AXEventHandler.StructuralReplacementMatch?
    private var visibleWindowIds: Set<Int>?

    init(
        handler: AXEventHandler, candidate: ManagedReplacementCandidateFacts,
        capturedInventory: CapturedWindowServerInventory?, baseMetadata: ManagedReplacementMetadata
    ) {
        self.handler = handler
        self.candidate = candidate
        self.capturedInventory = capturedInventory
        self.baseMetadata = baseMetadata
    }

    mutating func inspectPendingDestroy(_ destroy: AXEventHandler.PreparedDestroy) -> Bool {
        let metadata = destroy.replacementMetadata
        if matches(metadata, oldToken: destroy.token),
           !recordMatch(token: destroy.token, workspaceId: metadata.workspaceId, source: .pendingDestroy)
        { return false }
        return true
    }

    mutating func inspectLiveEntry(_ entry: WindowState) -> Bool {
        guard capturedInventory != nil || !entry.observedState.isMinimized,
              oldLiveTokenIsInvisible(entry.token)
        else { return true }
        let cachedMetadata = handler.cachedManagedReplacementMetadata(for: entry, fallbackBundleId: candidate.bundleId)
        if matches(cachedMetadata, oldToken: entry.token),
           !recordMatch(token: entry.token, workspaceId: cachedMetadata.workspaceId, source: .liveInvisible)
        { return false }
        if match?.token == entry.token { return true }
        let liveMetadata = handler.overlayWindowServerInfo(windowServerInfo(for: entry.windowId), onto: cachedMetadata)
        if liveMetadata != cachedMetadata,
           matches(liveMetadata, oldToken: entry.token),
           !recordMatch(token: entry.token, workspaceId: liveMetadata.workspaceId, source: .liveInvisible)
        { return false }
        return true
    }

    private mutating func oldLiveTokenIsInvisible(_ token: WindowToken) -> Bool {
        if let capturedInventory {
            if let authoritativeWindowIds = capturedInventory.authoritativeWindowIds {
                return authoritativeWindowIds.contains(token.windowId)
                    && (capturedInventory.authoritativePIDs?.contains(token.pid) ?? true)
                    && capturedInventory.infoByWindowId[token.windowId] == nil
            }
            return !capturedInventory.infoByWindowId.isEmpty
                && capturedInventory.infoByWindowId[token.windowId] == nil
        }
        if visibleWindowIds == nil {
            visibleWindowIds = Set(handler.visibleWindowInfoProvider().map { Int($0.id) })
        }
        guard let visibleWindowIds, !visibleWindowIds.isEmpty else { return false }
        return !visibleWindowIds.contains(token.windowId)
    }

    private func windowServerInfo(for windowId: Int) -> WindowServerInfo? {
        if let capturedInventory { return capturedInventory.infoByWindowId[windowId] }
        return UInt32(exactly: windowId).flatMap(handler.resolveWindowInfo)
    }

    private mutating func recordMatch(
        token: WindowToken, workspaceId: WorkspaceDescriptor.ID,
        source: AXEventHandler.StructuralReplacementMatchSource
    ) -> Bool {
        if let match { return match.token == token }
        match = .init(token: token, workspaceId: workspaceId, source: source)
        return true
    }

    private func matches(_ oldMetadata: ManagedReplacementMetadata, oldToken: WindowToken) -> Bool {
        var newMetadata = baseMetadata
        newMetadata.workspaceId = oldMetadata.workspaceId
        return handler.managedReplacementMetadataMatches(
            oldToken: oldToken, old: oldMetadata, new: newMetadata, newFacts: candidate.facts
        )
    }
}
