// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleTreeRequest: Equatable, Sendable {
    enum Node: Equatable, Sendable {
        case split(DwindleOrientation, ratio: Double)
        case leaf(members: Range<Int>, active: Int)
    }

    let workspaceId: WorkspaceDescriptor.ID
    let revision: UInt64
    let preselection: Direction?
    let nodes: [Node]
    let members: [WindowToken]

    static let nodeLimit = 2 * DwindleLayoutEngine.treeMemberLimit - 1
}

enum DwindleTreeRefusal: Equatable, Sendable {
    case invalid
    case staleRevision
    case wrongWorkspace
    case unknownWindow
    case membership
    case ineligible
    case busy
    case focusConflict
    case doesNotFit
}

enum DwindleTreeReplacement: Equatable, Sendable {
    case replaced
    case unchanged
    case refused(DwindleTreeRefusal)
}

extension DwindleLayoutEngine {
    func replacementSnapshot(
        _ request: DwindleTreeRequest,
        state: DwindleWorkspaceState,
        selected: WindowToken?,
        focused: WindowToken?
    ) -> DwindleLayoutSnapshot? {
        guard !request.nodes.isEmpty, request.nodes.count <= DwindleTreeRequest.nodeLimit,
              request.members.count <= Self.treeMemberLimit
        else { return nil }
        var snapshot = DwindleLayoutSnapshot(selected: selected, focused: focused, preselection: request.preselection)
        snapshot.nodes.reserveCapacity(request.nodes.count)
        snapshot.members.reserveCapacity(request.members.count)
        var next = 0
        guard appendReplacementNode(request, state: state, at: &next, to: &snapshot) != nil,
              next == request.nodes.count, snapshot.members.count == request.members.count
        else { return nil }
        return snapshot
    }

    private func appendReplacementNode(
        _ request: DwindleTreeRequest,
        state: DwindleWorkspaceState,
        at next: inout Int,
        to snapshot: inout DwindleLayoutSnapshot
    ) -> Int? {
        guard next < request.nodes.count else { return nil }
        let node = request.nodes[next]
        next += 1
        let slot = snapshot.nodes.count
        let id = slot == 0 ? state.root.id : UUID()
        switch node {
        case let .split(orientation, ratio):
            guard ratio.isFinite, DwindleSettings.physicalRatios.contains(CGFloat(ratio)) else { return nil }
            snapshot.nodes.append(DwindleLayoutSnapshot.Node(
                id: id, orientation: orientation, ratio: CGFloat(ratio), firstChild: nil, secondChild: nil,
                tileId: nil, members: 0 ..< 0, active: nil, expansion: nil
            ))
            guard let first = appendReplacementNode(request, state: state, at: &next, to: &snapshot) else { return nil }
            snapshot.nodes[slot].firstChild = first
            guard let second = appendReplacementNode(request, state: state, at: &next, to: &snapshot) else {
                return nil
            }
            snapshot.nodes[slot].secondChild = second
        case let .leaf(members, active):
            guard !members.isEmpty, members.lowerBound == snapshot.members.count,
                  members.upperBound <= request.members.count, (0 ..< members.count).contains(active)
            else { return nil }
            for index in members {
                snapshot.members.append(DwindleTileMember(token: request.members[index], isFullscreen: false))
            }
            let tokens = request.members[members]
            let existing = state.leafByToken[tokens[tokens.startIndex]]?.tile
            let tileId = existing.flatMap { tile in
                tile.members.count == tokens.count && tile.members.allSatisfy { tokens.contains($0.token) }
                    ? tile.id : nil
            } ?? UUID()
            snapshot.nodes.append(DwindleLayoutSnapshot.Node(
                id: id, orientation: nil, ratio: 1, firstChild: nil, secondChild: nil, tileId: tileId,
                members: members, active: request.members[members.lowerBound + active], expansion: nil
            ))
        }
        return slot
    }

    func detachedReplacementRoot(_ snapshot: borrowing DwindleLayoutSnapshot, at index: Int = 0) -> DwindleNode {
        let saved = snapshot.nodes[index]
        if let orientation = saved.orientation, let first = saved.firstChild, let second = saved.secondChild {
            let node = DwindleNode(kind: .split(orientation: orientation, ratio: saved.ratio))
            node.appendChild(detachedReplacementRoot(snapshot, at: first))
            node.appendChild(detachedReplacementRoot(snapshot, at: second))
            return node
        }
        let members = Array(snapshot.members[saved.members])
        let active = members.firstIndex { $0.token == saved.active } ?? 0
        return DwindleNode(kind: .leaf(tile: DwindleTile(members: members, activeIndex: active)))
    }
}
