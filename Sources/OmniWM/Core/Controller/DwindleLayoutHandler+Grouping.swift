// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    private func groupWindowInDirection(
        _ token: WindowToken,
        direction: Direction,
        workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine
    ) -> WindowMoveOutcome {
        guard engine.tileCount(in: workspaceId) == 1
            || engine.tileFrame(for: token, in: workspaceId) != nil
        else {
            return .blocked
        }
        guard let neighbor = engine.findGeometricNeighbor(
            from: token,
            direction: direction,
            in: workspaceId
        ) else {
            return .atWorkspaceEdge
        }
        guard groupMembershipMutationIsAllowed(
            for: neighbor,
            engine: engine,
            workspaceId: workspaceId
        ) else {
            return .blocked
        }
        return engine.groupWindow(token, into: neighbor, in: workspaceId) ? .movedWithinWorkspace : .blocked
    }

    func moveWindow(direction: Direction) -> WindowMoveOutcome {
        var outcome = WindowMoveOutcome.blocked
        withDwindleContext(recordingHistory: true) { engine, workspaceId in
            guard let token = engine.projectedActiveToken(in: workspaceId) else { return }
            let sourceIsGrouped: Bool
            if let snapshot = engine.tileSnapshot(for: token, in: workspaceId) {
                sourceIsGrouped = snapshot.isGrouped
            } else {
                return
            }
            guard groupMembershipMutationIsAllowed(
                for: token,
                engine: engine,
                workspaceId: workspaceId,
                requiresAllMembers: !sourceIsGrouped
            )
            else {
                return
            }

            let moveOutcome: WindowMoveOutcome
            if sourceIsGrouped {
                moveOutcome = engine
                    .ungroupWindow(token, direction: direction, in: workspaceId) ? .movedWithinWorkspace : .blocked
            } else {
                moveOutcome = groupWindowInDirection(
                    token,
                    direction: direction,
                    workspaceId: workspaceId,
                    engine: engine
                )
            }
            guard moveOutcome == .movedWithinWorkspace else {
                outcome = moveOutcome
                return
            }

            outcome = .movedWithinWorkspace
            recordLayoutOperation(.groupMembershipChanged(token: token), in: workspaceId)
            commitGroupSelection(token, workspaceId: workspaceId, focusAfterLayout: true)
        }
        return outcome
    }

    @discardableResult
    func moveGroupMember(direction: Direction) -> Bool {
        var didMove = false
        withDwindleContext(recordingHistory: true) { engine, workspaceId in
            guard let token = engine.projectedActiveToken(in: workspaceId),
                  let destinationToken = groupMemberReorderDestination(
                      direction: direction,
                      engine: engine,
                      workspaceId: workspaceId
                  ),
                  groupMembershipMutationIsAllowed(
                      for: token,
                      engine: engine,
                      workspaceId: workspaceId,
                      requiresAllMembers: false
                  ),
                  groupMemberActivationIsAllowed(
                      destinationToken,
                      workspaceId: workspaceId
                  ),
                  engine.moveGroupMember(token, direction: direction, in: workspaceId)
            else {
                return
            }

            didMove = true
            recordLayoutOperation(.groupMemberMoved(token: token), in: workspaceId)
            updateRememberedGroupMember(token, workspaceId: workspaceId)
            controller?.surfaceReconciler.noteWorldChanged()
        }
        return didMove
    }

    private func groupMemberReorderDestination(
        direction: Direction,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let offset = groupMemberOffset(for: direction),
              let token = engine.projectedActiveToken(in: workspaceId),
              let snapshot = engine.tileSnapshot(for: token, in: workspaceId),
              let activeIndex = snapshot.members.firstIndex(where: { $0.token == token })
        else {
            return nil
        }
        let visibleMembers = snapshot.members.filter {
            groupMemberActivationIsAllowed($0.token, workspaceId: workspaceId)
        }
        guard let visibleIndex = visibleMembers.firstIndex(
            where: { $0.token == snapshot.members[activeIndex].token }
        ), visibleMembers.indices.contains(visibleIndex + offset)
        else {
            return nil
        }
        return visibleMembers[visibleIndex + offset].token
    }

    func focusGroupMember(
        direction: Direction,
        wraps: Bool,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let offset = groupMemberOffset(for: direction),
              let activeToken = engine.projectedActiveToken(in: workspaceId),
              let snapshot = engine.tileSnapshot(for: activeToken, in: workspaceId),
              let activeIndex = snapshot.members.firstIndex(where: { $0.token == activeToken }),
              snapshot.members.count > 1
        else {
            return false
        }

        for distance in 1 ..< snapshot.members.count {
            let candidateIndex = activeIndex + offset * distance
            let index: Int
            if wraps {
                index = (
                    candidateIndex % snapshot.members.count + snapshot.members.count
                ) % snapshot.members.count
            } else {
                guard snapshot.members.indices.contains(candidateIndex) else { break }
                index = candidateIndex
            }

            let token = snapshot.members[index].token
            guard groupMemberActivationIsAllowed(token, workspaceId: workspaceId) else {
                continue
            }
            guard engine.activateWindowOutcome(token, in: workspaceId) == .activated else {
                return false
            }

            recordLayoutOperation(.tabActivated(token: token), in: workspaceId)
            commitGroupSelection(token, workspaceId: workspaceId, focusAfterLayout: true)
            return true
        }
        return false
    }

    private func groupMemberOffset(for direction: Direction) -> Int? {
        switch direction {
        case .up:
            -1
        case .down:
            1
        case .left,
             .right:
            nil
        }
    }
}
