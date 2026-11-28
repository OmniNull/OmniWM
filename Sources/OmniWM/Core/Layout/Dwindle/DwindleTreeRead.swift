// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum DwindleTreeAccess {
    case unavailable
    case tooLarge
    case ready(DwindleLayoutEngine)
}

enum DwindleTreeRead {
    case unavailable
    case refused
    case read(preselection: Direction?, revision: UInt64)
}

extension WorkspaceManager {
    func dwindleTreeAccess(for workspaceId: WorkspaceDescriptor.ID) -> DwindleTreeAccess {
        guard activeLayoutKind(for: workspaceId) == .dwindle, let engine = dwindleEngine else { return .unavailable }
        let installed = engine.windowCount(in: workspaceId)
        guard installed == windowQueries.tokens(in: workspaceId, mode: .tiling).count else { return .unavailable }
        return installed <= DwindleLayoutEngine.treeMemberLimit ? .ready(engine) : .tooLarge
    }
}

extension DwindleLayoutEngine {
    static let treeMemberLimit = 256

    func readTree(
        in workspaceId: WorkspaceDescriptor.ID,
        hasher: consuming Hasher,
        admission: (WindowToken) -> UInt64?,
        split: (DwindleOrientation, CGFloat) -> Bool,
        leaf: ([DwindleTileMember], Int) -> Bool
    ) -> DwindleTreeRead {
        hasher.combine(workspaceId)
        guard let state = existingState(for: workspaceId) else {
            return .read(preselection: nil, revision: UInt64(bitPattern: Int64(hasher.finalize())))
        }
        hasher.combine(state.root.id)
        var stale = false
        let complete = readTree(state.root, hasher: &hasher, admission: { token in
            guard let serial = admission(token) else {
                stale = true
                return nil
            }
            return serial
        }, split: split, leaf: leaf)
        guard complete else { return stale ? .unavailable : .refused }
        hasher.combine(state.preselection)
        return .read(preselection: state.preselection, revision: UInt64(bitPattern: Int64(hasher.finalize())))
    }

    private func readTree(
        _ node: DwindleNode,
        hasher: inout Hasher,
        admission: (WindowToken) -> UInt64?,
        split: (DwindleOrientation, CGFloat) -> Bool,
        leaf: ([DwindleTileMember], Int) -> Bool
    ) -> Bool {
        switch node.kind {
        case let .split(orientation, ratio):
            hasher.combine(false)
            hasher.combine(orientation)
            hasher.combine(Double(ratio).bitPattern)
            guard split(orientation, ratio), let first = node.firstChild(), let second = node.secondChild() else {
                return false
            }
            return readTree(first, hasher: &hasher, admission: admission, split: split, leaf: leaf)
                && readTree(second, hasher: &hasher, admission: admission, split: split, leaf: leaf)
        case let .leaf(tile):
            hasher.combine(true)
            guard let tile else { return node.parent == nil }
            return readLeaf(tile.members, active: tile.activeIndex, hasher: &hasher, admission: admission, leaf: leaf)
        }
    }

    private func readLeaf(
        _ members: [DwindleTileMember],
        active: Int,
        hasher: inout Hasher,
        admission: (WindowToken) -> UInt64?,
        leaf: ([DwindleTileMember], Int) -> Bool
    ) -> Bool {
        hasher.combine(members.count)
        hasher.combine(active)
        for index in members.indices {
            guard let serial = admission(members[index].token) else { return false }
            hasher.combine(members[index].token)
            hasher.combine(serial)
        }
        return leaf(members, active)
    }
}
