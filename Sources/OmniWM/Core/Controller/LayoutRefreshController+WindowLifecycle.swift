// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

@MainActor
extension LayoutRefreshController {
    func restoreNativeFullscreenAfterStructuralReplacement(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        appFullscreen: Bool
    ) {
        guard !appFullscreen,
              let workspaceManager = controller?.workspaceManager
        else {
            return
        }
        let trackedToken = workspaceManager.entry(for: newToken) == nil
            ? oldToken
            : newToken
        guard workspaceManager.nativeFullscreenRecord(for: trackedToken) != nil
            || workspaceManager.layoutReason(for: trackedToken) == .nativeFullscreen
        else {
            return
        }
        _ = workspaceManager.restoreNativeFullscreenRecord(for: trackedToken)
        markNativeFullscreenRestoredForFrameApply(trackedToken)
        _ = controller?.reconcileScratchpadMemberAfterNativeFullscreenExit(trackedToken)
    }

    func exactNativeFullscreenRetirementKeys(
        scope: RescanScope,
        trackedEntries: [WindowState]
    ) -> Set<WindowToken> {
        guard case let .targeted(_, _, nativeSpaceWindowIdsByPID) = scope,
              let workspaceManager = controller?.workspaceManager
        else { return [] }
        return Set(
            trackedEntries.lazy
                .filter {
                    $0.layoutReason == .nativeFullscreen
                        && nativeSpaceWindowIdsByPID[$0.pid]?.contains($0.windowId) == true
                        && workspaceManager.spaceTopology.spaceForWindow($0.windowId) == nil
                }
                .map(\.token)
        )
    }

    func yieldToDeferredCreate(
        _ assessment: DeferredCreateAssessment,
        scope: RescanScope,
        capturedInventory: CapturedWindowServerInventory,
        seenKeys: inout Set<WindowToken>
    ) -> Bool {
        guard let controller,
              assessment.entry == nil,
              let windowId = UInt32(exactly: assessment.token.windowId),
              controller.axEventHandler.isCreatedWindowDeferred(windowId)
        else {
            return false
        }
        guard let mode = assessment.mode else {
            if !assessment.factsAreDeferred {
                controller.axEventHandler.recordDeferredReplacementAssessment(
                    windowId: windowId,
                    scope: scope
                )
            }
            return true
        }
        if let match = controller.axEventHandler.structuralReplacementMatch(
            token: assessment.token,
            candidate: .init(bundleId: assessment.bundleId, mode: mode, facts: assessment.facts),
            capturedInventory: capturedInventory
        ) {
            seenKeys.insert(match.token)
            controller.axEventHandler.protectDeferredReplacement(
                windowId: windowId,
                token: match.token,
                scope: scope
            )
        }
        controller.axEventHandler.recordDeferredReplacementAssessment(
            windowId: windowId,
            scope: scope
        )
        return true
    }

    func preserveHiddenWindowsDuringTargetedFullRescan(
        _ entries: [WindowState],
        eligibleKeys: Set<WindowToken>,
        windowServerInfoByWindowId: [Int: WindowServerInfo],
        seenKeys: inout Set<WindowToken>
    ) {
        guard let controller else { return }
        // An app can order its window out without destroying it, so the window server still
        // lists it. Only windows OmniWM hid itself are kept.
        for entry in entries
            where eligibleKeys.contains(entry.token)
            && controller.workspaceManager.hiddenState(for: entry.token) != nil
            && !entry.observedState.isNativeWithdrawn
            && windowServerInfoByWindowId[entry.windowId]?.pid == entry.pid
        {
            seenKeys.insert(entry.token)
        }
    }

    func confirmedMissingEntriesDuringFullRescan(
        seenKeys: Set<WindowToken>,
        eligibleKeys: Set<WindowToken>?,
        nativeFullscreenRetirementKeys: Set<WindowToken> = [],
        permitsMissingRetirement: Bool
    ) -> [WindowState] {
        if permitsMissingRetirement {
            return confirmedMissingEntries(
                keys: seenKeys,
                eligibleKeys: eligibleKeys,
                nativeFullscreenRetirementKeys: nativeFullscreenRetirementKeys,
                requiredConsecutiveMisses: 2
            )
        }
        _ = confirmedMissingEntries(
            keys: seenKeys,
            eligibleKeys: [],
            nativeFullscreenRetirementKeys: [],
            requiredConsecutiveMisses: 2
        )
        return []
    }

    func confirmedMissingEntries(
        keys activeKeys: Set<WindowToken>,
        eligibleKeys: Set<WindowToken>? = nil,
        nativeFullscreenRetirementKeys: Set<WindowToken> = [],
        requiredConsecutiveMisses: Int = 1
    ) -> [WindowState] {
        guard let workspaceManager = controller?.workspaceManager else { return [] }
        let threshold = max(1, requiredConsecutiveMisses)
        let scopedEntries = if let eligibleKeys {
            eligibleKeys.compactMap { workspaceManager.entry(for: $0) }
        } else {
            workspaceManager.allEntries()
        }
        let knownEntries = scopedEntries.filter {
            $0.lifetimeAuthority == .axTopLevelInventory
                || nativeFullscreenRetirementKeys.contains($0.token)
        }

        for token in activeKeys {
            guard let handle = workspaceManager.handle(for: token) else { continue }
            layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
        }

        var confirmedMissing: [WindowState] = []
        confirmedMissing.reserveCapacity(knownEntries.count)
        for entry in knownEntries where !activeKeys.contains(entry.token) {
            guard let handle = workspaceManager.handle(for: entry.token) else { continue }
            if (
                entry.layoutReason == .nativeFullscreen
                    && !nativeFullscreenRetirementKeys.contains(entry.token)
            )
                || workspaceManager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
            {
                layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
                continue
            }
            let misses = (layoutState.consecutiveMissCountByHandle[handle] ?? 0) + 1
            if misses >= threshold {
                confirmedMissing.append(entry)
                layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
            } else {
                layoutState.consecutiveMissCountByHandle[handle] = misses
            }
        }

        let staleHandles = layoutState.consecutiveMissCountByHandle.keys.filter {
            workspaceManager.handle(for: $0.id) !== $0
        }
        for handle in staleHandles {
            layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
        }

        return confirmedMissing.sorted {
            if $0.pid == $1.pid {
                return $0.windowId < $1.windowId
            }
            return $0.pid < $1.pid
        }
    }

    func resetMissingDetectionCounts() {
        layoutState.consecutiveMissCountByHandle.removeAll(keepingCapacity: true)
    }

    func recordWindowPresence(_ handle: WindowHandle) {
        layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
    }

    func makeNiriRemovalSeeds(
        from payloads: [WindowRemovalPayload]
    ) -> [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] {
        var seeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]
        for payload in payloads {
            switch payload.layoutType {
            case .dwindle:
                continue
            case .niri,
                 .defaultLayout:
                let existing = seeds[payload.workspaceId]
                var removedNodeIds = existing?.removedNodeIds ?? []
                if let removedNodeId = payload.removedNodeId {
                    removedNodeIds.append(removedNodeId)
                }
                let mergedOldFrames = (existing?.oldFrames ?? [:])
                    .merging(payload.niriOldFrames) { current, _ in current }
                seeds[payload.workspaceId] = NiriWindowRemovalSeed(
                    removedNodeIds: removedNodeIds,
                    oldFrames: mergedOldFrames,
                    removedColumn: existing?.removedColumn == true || payload.removedNiriColumn
                )
            }
        }
        return seeds
    }

    static func shouldReadmitTrackedWindow(
        entry: WindowState,
        target: WindowReadmissionTarget,
        shouldPreservePreFullscreenState: Bool,
        appFullscreen: Bool
    ) -> Bool {
        shouldPreservePreFullscreenState
            || appFullscreen
            || entry.workspaceId != target.workspaceId
            || entry.mode != target.mode
            || entry.ruleEffects != target.ruleEffects
    }

    func observedWindowFrame(_ entry: WindowState) -> CGRect? {
        fastFrame(for: entry.token, axRef: entry.axRef)
    }

    func markNativeFullscreenRestoredForFrameApply(_ token: WindowToken) {
        nativeFullscreenRestoredFrameApplyTokens.insert(token)
    }

    func rekeyNativeFullscreenRestoredFrameApply(
        from oldToken: WindowToken,
        to newToken: WindowToken
    ) {
        guard nativeFullscreenRestoredFrameApplyTokens.remove(oldToken) != nil else { return }
        nativeFullscreenRestoredFrameApplyTokens.insert(newToken)
    }

    func consumeNativeFullscreenRestoredFrameApply(for token: WindowToken) -> Bool {
        nativeFullscreenRestoredFrameApplyTokens.remove(token) != nil
    }
}
