// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension WorldStore {
    func reconcileNiriMembership(
        for token: WindowToken,
        keeping authoritativeWorkspaceId: WorkspaceDescriptor.ID?,
        monitors: [Monitor]
    ) {
        guard let engine = niriEngine else { return }
        let authoritativePlacement = authoritativeWorkspaceId.flatMap {
            engine.persistedPlacement(for: token, in: $0)
        }
        let staleWorkspaceIds = engine.workspaceIds(containing: token)
            .filter { $0 != authoritativeWorkspaceId }
            .sorted { $0.uuidString < $1.uuidString }
        if let authoritativeWorkspaceId,
           let authoritativePlacement,
           !staleWorkspaceIds.isEmpty
        {
            let placements = engine.persistedPlacementsInColumn(
                containing: token,
                in: authoritativeWorkspaceId
            )
            if placements.isEmpty {
                _ = storeNiriPlacement(
                    authoritativePlacement,
                    detached: false,
                    for: token,
                    monitors: monitors
                )
            } else {
                _ = storeNiriPlacements(
                    placements,
                    in: authoritativeWorkspaceId,
                    detachedToken: nil,
                    monitors: monitors
                )
            }
        } else if let staleWorkspaceId = staleWorkspaceIds.first {
            preserveDetachedNiriPlacement(
                for: token,
                in: staleWorkspaceId,
                engine: engine,
                monitors: monitors
            )
        }
        for staleWorkspaceId in staleWorkspaceIds {
            repairViewportSelection(in: staleWorkspaceId, removing: token, engine: engine)
            engine.removeWindow(token: token, in: staleWorkspaceId)
        }
    }

    private func preserveDetachedNiriPlacement(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        monitors: [Monitor]
    ) {
        let placements = engine.persistedPlacementsInColumn(
            containing: token,
            in: workspaceId
        )
        if placements[token] != nil {
            _ = storeNiriPlacements(
                placements,
                in: workspaceId,
                detachedToken: token,
                monitors: monitors
            )
        } else if let placement = engine.persistedPlacement(for: token, in: workspaceId) {
            _ = storeNiriPlacement(
                placement,
                detached: true,
                for: token,
                monitors: monitors
            )
        }
    }

    @discardableResult
    private func storeNiriPlacements(
        _ placements: [WindowToken: PersistedNiriPlacement],
        in workspaceId: WorkspaceDescriptor.ID,
        detachedToken: WindowToken?,
        monitors: [Monitor]
    ) -> Bool {
        var changed = false
        for (token, placement) in placements {
            if token != detachedToken {
                guard let entry = windows.entry(for: token),
                      entry.mode == .tiling,
                      entry.workspaceId == workspaceId
                else {
                    continue
                }
            }
            changed = storeNiriPlacement(
                placement,
                detached: token == detachedToken,
                for: token,
                monitors: monitors
            ) || changed
        }
        return changed
    }

    @discardableResult
    func captureDetachedNiriPlacement(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        monitors: [Monitor]
    ) -> Bool {
        assertInCommit("captureDetachedNiriPlacement")
        return captureNiriPlacements(
            for: token,
            in: workspaceId,
            detachedToken: token,
            monitors: monitors
        )
    }

    @discardableResult
    func captureLiveNiriPlacements(
        containing tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        monitors: [Monitor]
    ) -> Bool {
        assertInCommit("captureLiveNiriPlacements")
        guard let engine = niriEngine else { return false }
        var visitedTokens = Set<WindowToken>()
        var changed = false
        for token in tokens where visitedTokens.insert(token).inserted {
            let placements = engine.persistedPlacementsInColumn(
                containing: token,
                in: workspaceId
            )
            visitedTokens.formUnion(placements.keys)
            changed = storeNiriPlacements(
                placements,
                in: workspaceId,
                detachedToken: nil,
                monitors: monitors
            ) || changed
        }
        return changed
    }

    func captureNiriPlacements(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        detachedToken: WindowToken?,
        monitors: [Monitor]
    ) -> Bool {
        guard let engine = niriEngine else { return false }
        let placements = engine.persistedPlacementsInColumn(
            containing: token,
            in: workspaceId
        )
        guard !placements.isEmpty else { return false }
        return storeNiriPlacements(
            placements,
            in: workspaceId,
            detachedToken: detachedToken,
            monitors: monitors
        )
    }

    private func repairViewportSelection(
        in workspaceId: WorkspaceDescriptor.ID,
        removing token: WindowToken,
        engine: NiriLayoutEngine
    ) {
        guard let node = engine.findNode(for: token, in: workspaceId),
              var state = viewports[workspaceId]
        else { return }
        if state.selectedNodeId == node.id {
            state.selectedNodeId = engine.fallbackSelectionOnRemoval(removing: node.id, in: workspaceId)
            applyViewportPlan(.set(workspaceId: workspaceId, state: state))
            return
        }
        guard let column = engine.column(of: node),
              column.windowNodes.count == 1,
              let removedColumnIndex = engine.columnIndex(of: column, in: workspaceId),
              removedColumnIndex < state.activeColumnIndex
        else { return }
        state.activeColumnIndex -= 1
        applyViewportPlan(.set(workspaceId: workspaceId, state: state))
    }

    func captureNiriPlacements(
        from engine: NiriLayoutEngine,
        monitors: [Monitor]
    ) -> Bool {
        let entries = windows.allEntries()
        let authoritativeWorkspaceIds = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.token, $0.workspaceId) }
        )
        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(entries.count)
        for workspaceId in engine.workspaceIds().sorted(by: { $0.uuidString < $1.uuidString }) {
            for (token, placement) in engine.persistedPlacements(in: workspaceId)
                where placements[token] == nil || authoritativeWorkspaceIds[token] == workspaceId
            {
                placements[token] = placement
            }
        }

        var captured = false
        for entry in entries {
            if let placement = placements[entry.token] {
                captured = storeNiriPlacement(
                    placement,
                    detached: true,
                    for: entry.token,
                    monitors: monitors
                ) || captured
            }
        }
        return captured
    }

    func refreshProjectionExclusions(
        in workspaceIds: Set<WorkspaceDescriptor.ID>
    ) {
        for workspaceId in workspaceIds {
            let tiledEntries = windows.windows(in: workspaceId).filter { $0.mode == .tiling }
            let authoritativeTokens = Set(tiledEntries.lazy.map(\.token))
            let excludedTokens = Set(tiledEntries.lazy.filter {
                self.hiddenAppPIDs.contains($0.pid) || $0.observedState.isNativeSuppressed
            }.map(\.token))
            niriEngine?.setProjectionExclusions(excludedTokens, in: workspaceId)
            dwindleEngine?.setExcludedTokens(
                excludedTokens,
                authoritativeTokens: authoritativeTokens,
                in: workspaceId
            )
        }
    }

    func canUpdateAdmissionHints(for token: WindowToken) -> Bool {
        guard let entry = windows.entry(for: token) else { return true }
        guard entry.restoreIntent?.detachedNiriContainerSizingState == nil,
              entry.restoreIntent?.niriPlacement == nil
        else {
            return false
        }
        return niriEngine?.workspaceIds(containing: token).isEmpty ?? true
    }
}
