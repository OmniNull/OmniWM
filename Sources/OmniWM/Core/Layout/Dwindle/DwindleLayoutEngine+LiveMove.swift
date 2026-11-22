// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleLiveMove: ~Copyable {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    var before: DwindleLayoutSnapshot?
    var acceptedRegion: CGRect?
    var floatingFrame: CGRect?

    init(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        before: consuming DwindleLayoutSnapshot,
        acceptedRegion: CGRect?
    ) {
        self.token = token
        self.workspaceId = workspaceId
        self.before = consume before
        self.acceptedRegion = acceptedRegion
    }
}

extension DwindleLayoutEngine {
    var liveMoveWorkspaceId: WorkspaceDescriptor.ID? {
        liveMove?.workspaceId
    }

    var liveMoveToken: WindowToken? {
        liveMove?.token
    }

    func liveMoveBegin(
        token: WindowToken,
        startLocation: CGPoint,
        startFrame: CGRect? = nil,
        holding region: CGRect? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard liveMoveWorkspaceId == nil,
              interactiveMoveBegin(
                  token: token, startLocation: startLocation, startFrame: startFrame, allowsInsertion: true,
                  in: workspaceId
              )
        else { return false }
        guard let before = layoutSnapshot(in: workspaceId) else {
            interactiveMoveCancel()
            return false
        }
        liveMove = DwindleLiveMove(
            token: token, workspaceId: workspaceId, before: consume before, acceptedRegion: region
        )
        return true
    }

    func liveMoveHoldsTarget(at point: CGPoint) -> Bool {
        withLiveMoveSource { _, _ in
            liveMove?.acceptedRegion?.contains(point) == true
        } ?? false
    }

    func liveMoveUpdate(
        currentLocation: CGPoint,
        at time: TimeInterval,
        workspaceFrame: CGRect
    ) -> Bool {
        assertSanctionedMutation()
        guard liveMoveWorkspaceId != nil else { return false }
        guard let region = prepareLiveMoveTarget(at: currentLocation, time: time, workspaceFrame: workspaceFrame)
        else { return false }
        return applyLiveMoveTarget(in: region)
    }

    func prepareLiveMoveTarget(at point: CGPoint, time: TimeInterval, workspaceFrame: CGRect) -> CGRect? {
        guard let move = interactiveMove,
              let region = withLiveMoveSource({ source, _ -> CGRect? in
                  if liveMove?.acceptedRegion?.contains(point) == true { return nil }
                  liveMove?.acceptedRegion = nil
                  let hit = updateInteractiveMoveTarget(
                      move, source: source, currentLocation: point, at: time, workspaceFrame: workspaceFrame
                  )
                  return hit.region ?? interactiveMoveTargetFrame(at: time)
              })
        else {
            interactiveMoveCancel()
            return nil
        }
        return region
    }

    func applyLiveMoveTarget(in region: CGRect) -> Bool {
        assertSanctionedMutation()
        guard let move = interactiveMove, applyInteractiveMoveTarget(move) != nil else { return false }
        interactiveMoveClearTarget()
        liveMove?.acceptedRegion = region
        return true
    }

    func endCarriedLiveMove(at time: TimeInterval) -> WorkspaceDescriptor.ID? {
        assertSanctionedMutation()
        guard let carried = interactiveMove, let frame = carried.floatingFrame,
              withLiveMoveSource({ _, state in state.pendingMovementFrameSeeds[carried.token] = frame }) != nil
        else { return liveMoveCancel(at: time) }
        return liveMoveEnd()
    }

    func liveMoveEnd(recordingHistory: Bool = true) -> WorkspaceDescriptor.ID? {
        assertSanctionedMutation()
        guard var move = liveMove.take() else { return nil }
        interactiveMoveCancel()
        let workspaceId = move.workspaceId
        if move.floatingFrame != nil {
            _ = activateWindow(move.token, in: workspaceId)
        }
        let before = move.before.take()
        if recordingHistory { recordLayoutChange(in: workspaceId, since: consume before) }
        return workspaceId
    }

    func liveMoveCancel(at time: TimeInterval) -> WorkspaceDescriptor.ID? {
        assertSanctionedMutation()
        guard var move = liveMove.take(), let before = move.before.take() else { return nil }
        interactiveMoveCancel()
        restoreLayoutSnapshot(before, in: move.workspaceId, at: time)
        return move.workspaceId
    }

    func withLiveMoveSource<Result>(
        _ body: (borrowing DwindleNode, borrowing DwindleWorkspaceState) -> Result
    ) -> Result? {
        guard let move = interactiveMove,
              liveMoveWorkspaceId == move.workspaceId,
              liveMoveToken == move.token,
              let state = existingState(for: move.workspaceId),
              let source = state.leafByToken[move.token],
              !state.excludedTokens.contains(move.token),
              let tile = source.tile
        else { return nil }
        let member = move.startFrame == nil
            ? tile.member(for: move.token) : visibleMember(in: tile, excluding: state.excludedTokens)
        guard let member, member.token == move.token, !member.isFullscreen else { return nil }
        return body(source, state)
    }
}
