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
        holding region: CGRect? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard liveMoveWorkspaceId == nil,
              interactiveMoveBegin(token: token, startLocation: startLocation, allowsInsertion: true, in: workspaceId)
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
        withLiveMoveSource { _ in
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
        guard let move = interactiveMove,
              let changed = withLiveMoveSource({ source in
                  if liveMove?.acceptedRegion?.contains(currentLocation) == true { return false }
                  liveMove?.acceptedRegion = nil
                  let hit = updateInteractiveMoveTarget(
                      move, source: source, currentLocation: currentLocation, at: time, workspaceFrame: workspaceFrame
                  )
                  guard let pending = interactiveMove,
                        let region = hit.region ?? interactiveMoveTargetFrame(at: time),
                        applyInteractiveMoveTarget(pending) != nil
                  else { return false }
                  interactiveMoveClearTarget()
                  liveMove?.acceptedRegion = region
                  return true
              })
        else {
            interactiveMoveCancel()
            return false
        }
        return changed
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

    func withLiveMoveSource<Result>(_ body: (borrowing DwindleNode) -> Result) -> Result? {
        guard let move = interactiveMove,
              liveMoveWorkspaceId == move.workspaceId,
              liveMoveToken == move.token,
              let state = existingState(for: move.workspaceId),
              let source = state.leafByToken[move.token],
              !state.excludedTokens.contains(move.token),
              source.tile?.member(for: move.token)?.isFullscreen != true
        else { return nil }
        return body(source)
    }
}
