// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum DwindleMoveTarget: Equatable {
    case tile(WindowToken, direction: Direction?)
    case workspaceEdge(Direction, frame: CGRect)
}

struct DwindleInteractiveMove {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let startLocation: CGPoint
    let allowsInsertion: Bool
    var target: DwindleMoveTarget?

    var targetToken: WindowToken? {
        guard case let .tile(token, _) = target else { return nil }
        return token
    }

    var targetDirection: Direction? {
        switch target {
        case let .tile(_, direction): direction
        case let .workspaceEdge(direction, _): direction
        case nil: nil
        }
    }

    var isInsertion: Bool {
        targetDirection != nil
    }
}

extension DwindleLayoutEngine {
    func interactiveMoveBegin(
        token: WindowToken,
        startLocation: CGPoint,
        allowsInsertion: Bool = false,
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
            token: token, workspaceId: workspaceId, startLocation: startLocation, allowsInsertion: allowsInsertion
        )
        return true
    }

    func interactiveMoveUpdate(
        currentLocation: CGPoint,
        at time: TimeInterval,
        workspaceFrame: CGRect? = nil
    ) -> WindowToken? {
        guard let move = interactiveMove else { return nil }
        guard let source = findNode(for: move.token, in: move.workspaceId),
              !excludedTokens(in: move.workspaceId).contains(move.token),
              !isWindowFullscreen(move.token, in: move.workspaceId)
        else {
            interactiveMoveCancel()
            return nil
        }
        guard isInteractiveMoveTargetValid(move) else {
            interactiveMoveCancel()
            return nil
        }
        if let workspaceFrame, !workspaceFrame.contains(currentLocation) {
            interactiveMove?.target = nil
            return nil
        }
        if move.allowsInsertion, let workspaceFrame,
           let direction = workspaceEdgeDirection(at: currentLocation, in: workspaceFrame, from: move.startLocation),
           canInsertAtWorkspaceEdge(token: move.token, in: move.workspaceId)
        {
            interactiveMove?.target = .workspaceEdge(direction, frame: workspaceFrame)
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
        var direction: Direction?
        if move.allowsInsertion, let target,
           let frame = presentedFrame(for: target, in: move.workspaceId, at: time),
           frame.width > 0, frame.height > 0
        {
            direction = tileInsertionDirection(at: currentLocation, in: frame)
        }
        interactiveMove?.target = target.map { .tile($0, direction: direction) }
        return target
    }

    func interactiveMoveTargetFrame(at time: TimeInterval) -> CGRect? {
        guard let move = interactiveMove, let target = move.target else { return nil }
        let frame: CGRect
        switch target {
        case let .tile(token, _):
            guard let presented = presentedFrame(for: token, in: move.workspaceId, at: time) else { return nil }
            frame = presented
        case let .workspaceEdge(_, workspaceFrame):
            frame = workspaceFrame
        }
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
            return frame
        }
    }

    @discardableResult
    func interactiveMoveEnd() -> WindowToken? {
        guard let move = interactiveMove else { return nil }
        interactiveMove = nil
        if case let .workspaceEdge(direction, _) = move.target {
            return insertLeafTile(of: move.token, atWorkspaceEdge: direction, in: move.workspaceId) ? move.token : nil
        }
        guard let targetToken = move.targetToken,
              !excludedTokens(in: move.workspaceId).contains(move.token),
              !excludedTokens(in: move.workspaceId).contains(targetToken),
              !isWindowFullscreen(move.token, in: move.workspaceId),
              !isWindowFullscreen(targetToken, in: move.workspaceId)
        else { return nil }
        let changed: Bool
        if let direction = move.targetDirection {
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

    private func isInteractiveMoveTargetValid(_ move: DwindleInteractiveMove) -> Bool {
        switch move.target {
        case let .tile(token, _):
            findNode(for: token, in: move.workspaceId) != nil
                && !excludedTokens(in: move.workspaceId).contains(token)
                && !isWindowFullscreen(token, in: move.workspaceId)
        case .workspaceEdge:
            canInsertAtWorkspaceEdge(token: move.token, in: move.workspaceId)
        case nil:
            true
        }
    }

    private func tileInsertionDirection(at point: CGPoint, in frame: CGRect) -> Direction? {
        let horizontal = (point.x - frame.midX) / frame.width
        let vertical = (point.y - frame.midY) / frame.height
        guard max(abs(horizontal), abs(vertical)) > 0.2 else { return nil }
        return abs(horizontal) > abs(vertical)
            ? (horizontal < 0 ? .left : .right)
            : (vertical < 0 ? .down : .up)
    }

    private func workspaceEdgeDirection(at point: CGPoint, in frame: CGRect, from start: CGPoint) -> Direction? {
        guard hypot(point.x - start.x, point.y - start.y) >= 10 else { return nil }
        let horizontal = min(point.x - frame.minX, frame.maxX - point.x)
        let vertical = min(point.y - frame.minY, frame.maxY - point.y)
        let threshold = min(24, min(frame.width, frame.height) / 10)
        guard min(horizontal, vertical) <= threshold else { return nil }
        return horizontal <= vertical
            ? (point.x < frame.midX ? .left : .right)
            : (point.y < frame.midY ? .down : .up)
    }
}
