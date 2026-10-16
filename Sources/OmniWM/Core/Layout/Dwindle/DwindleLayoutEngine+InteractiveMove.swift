// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleInteractiveMove {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let startLocation: CGPoint
    let isInsertMode: Bool
    var targetToken: WindowToken?
    var targetDirection: Direction?
}

extension DwindleLayoutEngine {
    func interactiveMoveBegin(
        token: WindowToken,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard interactiveResize == nil,
              interactiveMove == nil,
              !excludedTokens(in: workspaceId).contains(token),
              let leaf = findNode(for: token, in: workspaceId),
              leaf.isLeaf,
              !isWindowFullscreen(token, in: workspaceId)
        else { return false }
        interactiveMove = DwindleInteractiveMove(
            token: token, workspaceId: workspaceId, startLocation: startLocation, isInsertMode: isInsertMode
        )
        return true
    }

    func interactiveMoveUpdate(currentLocation: CGPoint, at time: TimeInterval) -> WindowToken? {
        guard let move = interactiveMove else { return nil }
        guard let source = findNode(for: move.token, in: move.workspaceId),
              !excludedTokens(in: move.workspaceId).contains(move.token),
              !isWindowFullscreen(move.token, in: move.workspaceId)
        else {
            interactiveMoveCancel()
            return nil
        }
        if let target = move.targetToken,
           findNode(for: target, in: move.workspaceId) == nil
           || excludedTokens(in: move.workspaceId).contains(target)
           || isWindowFullscreen(target, in: move.workspaceId)
        {
            interactiveMoveCancel()
            return nil
        }
        let target = hitTestFocusableWindow(point: currentLocation, in: move.workspaceId, at: time)
            .flatMap { candidate -> WindowToken? in
                guard let node = findNode(for: candidate, in: move.workspaceId),
                      node !== source,
                      !isWindowFullscreen(candidate, in: move.workspaceId)
                else { return nil }
                return candidate
            }
        interactiveMove?.targetToken = target
        interactiveMove?.targetDirection = nil
        if move.isInsertMode, let target,
           let frame = presentedFrame(for: target, in: move.workspaceId, at: time),
           frame.width > 0, frame.height > 0
        {
            let horizontal = (currentLocation.x - frame.midX) / frame.width
            let vertical = (currentLocation.y - frame.midY) / frame.height
            interactiveMove?.targetDirection = abs(horizontal) > abs(vertical)
                ? (horizontal < 0 ? .left : .right)
                : (vertical < 0 ? .down : .up)
        }
        return target
    }

    func interactiveMoveTargetFrame(at time: TimeInterval) -> CGRect? {
        guard let move = interactiveMove, let target = move.targetToken,
              let frame = presentedFrame(for: target, in: move.workspaceId, at: time)
        else { return nil }
        guard move.isInsertMode else { return frame }
        switch move.targetDirection {
        case .left:
            return frame.divided(atDistance: frame.width / 2, from: .minXEdge).slice
        case .right:
            return frame.divided(atDistance: frame.width / 2, from: .maxXEdge).slice
        case .up:
            return frame.divided(atDistance: frame.height / 2, from: .maxYEdge).slice
        case .down:
            return frame.divided(atDistance: frame.height / 2, from: .minYEdge).slice
        case nil:
            return nil
        }
    }

    @discardableResult
    func interactiveMoveEnd() -> WindowToken? {
        guard let move = interactiveMove else { return nil }
        interactiveMove = nil
        guard let targetToken = move.targetToken,
              !excludedTokens(in: move.workspaceId).contains(move.token),
              !excludedTokens(in: move.workspaceId).contains(targetToken),
              !isWindowFullscreen(move.token, in: move.workspaceId),
              !isWindowFullscreen(targetToken, in: move.workspaceId)
        else { return nil }
        let changed: Bool
        if move.isInsertMode {
            guard let direction = move.targetDirection else { return nil }
            changed = insertLeafTile(of: move.token, beside: targetToken, direction: direction, in: move.workspaceId)
        } else {
            changed = swapLeafTiles(of: move.token, and: targetToken, in: move.workspaceId)
        }
        guard changed else { return nil }
        return targetToken
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }
}
