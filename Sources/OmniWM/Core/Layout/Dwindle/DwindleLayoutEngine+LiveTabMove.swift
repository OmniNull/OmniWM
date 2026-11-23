// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleTabMoveTarget {
    let token: WindowToken
    let index: Int
}

extension DwindleLayoutEngine {
    var liveTabMoveToken: WindowToken? {
        guard liveMove?.floatingFrame != nil else { return nil }
        return liveMoveToken
    }

    var liveTabMoveFloatingFrame: CGRect? {
        liveMove?.floatingFrame
    }

    func liveMoveSetFloatingFrame(_ frame: CGRect) {
        assertSanctionedMutation()
        liveMove?.floatingFrame = frame
    }

    func liveTabMoveBegin(
        token: WindowToken,
        startLocation: CGPoint,
        holding region: CGRect? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard liveMoveBegin(token: token, startLocation: startLocation, holding: region, in: workspaceId)
        else { return false }
        if let state = existingState(for: workspaceId), let tile = state.leafByToken[token]?.tile {
            keepLiveTabPeerVisible(tile, token: token, state: state)
        }
        return true
    }

    func liveTabMoveUpdate(
        currentLocation: CGPoint,
        at time: TimeInterval,
        workspaceFrame: CGRect,
        railTarget: DwindleTabMoveTarget?
    ) -> Bool {
        assertSanctionedMutation()
        guard let move = interactiveMove, liveTabMoveToken == move.token else { return false }
        return withLiveMoveSource { source, state in
            if let railTarget {
                liveMove?.acceptedRegion = nil
                return joinLiveTab(move.token, target: railTarget, state: state, in: move.workspaceId)
            }
            if liveMove?.acceptedRegion?.contains(currentLocation) == true { return false }
            liveMove?.acceptedRegion = nil
            guard workspaceFrame.contains(currentLocation) else { return false }
            let hit = updateInteractiveMoveTarget(
                move, source: source, currentLocation: currentLocation, at: time, workspaceFrame: workspaceFrame
            )
            guard let pending = interactiveMove else { return false }
            if case let .tile(target, nil) = pending.target,
               let tile = state.leafByToken[target]?.tile,
               let frame = presentedFrame(for: target, in: move.workspaceId, at: time)
            {
                let changed = joinLiveTab(
                    move.token, target: .init(token: target, index: tile.activeIndex + 1), state: state,
                    in: move.workspaceId
                )
                if changed { liveMove?.acceptedRegion = frame }
                interactiveMoveClearTarget()
                return changed
            }
            return insertLiveTab(pending, source: source, region: hit.region, location: currentLocation, at: time)
        } ?? false
    }

    private func joinLiveTab(
        _ token: WindowToken,
        target: DwindleTabMoveTarget,
        state: DwindleWorkspaceState,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard !state.excludedTokens.contains(target.token),
              let source = state.leafByToken[token],
              let destination = state.leafByToken[target.token], let tile = destination.tile,
              !isWindowFullscreen(target.token, in: workspaceId)
        else { return false }
        let peer = tile.activeToken == token ? nil : tile.activeToken
        let joined = source !== destination
        if joined, !groupWindow(token, into: target.token, in: workspaceId) { return false }
        let changed = tile.reorder(token, to: min(max(0, target.index), tile.members.count - 1))
        if let peer { _ = tile.activate(peer) }
        keepLiveTabPeerVisible(tile, token: token, state: state)
        return joined || changed
    }

    private func insertLiveTab(
        _ move: DwindleInteractiveMove,
        source: borrowing DwindleNode,
        region: CGRect?,
        location: CGPoint,
        at time: TimeInterval
    ) -> Bool {
        let frame = source.presentedFrame(at: time)
        let targetRegion = region ?? interactiveMoveTargetFrame(at: time)
        var detached = false
        if source.tile?.isGrouped == true {
            guard let frame else { return false }
            let direction = move.targetDirection
                ?? WindowMoveGeometry.insertionDirection(at: location, in: frame)
                ?? (location.x < frame.midX ? .left : .right)
            detached = ungroupWindow(move.token, direction: direction, in: move.workspaceId)
            guard detached else { return false }
        }
        let changed = applyInteractiveMoveTarget(move) != nil
        interactiveMoveClearTarget()
        if changed || detached { liveMove?.acceptedRegion = targetRegion ?? frame }
        return changed || detached
    }

    private func keepLiveTabPeerVisible(
        _ tile: DwindleTile,
        token: WindowToken,
        state: DwindleWorkspaceState
    ) {
        guard tile.activeToken == token, tile.isGrouped else { return }
        for index in tile.members.indices {
            let peer = tile.members[index].token
            if peer != token, !state.excludedTokens.contains(peer) {
                _ = tile.activate(peer)
                return
            }
        }
    }
}
