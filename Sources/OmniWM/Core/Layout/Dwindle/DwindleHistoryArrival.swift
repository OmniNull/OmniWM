// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum DwindleHistoryArrival {
    case member(DwindleTileMember, excluded: Bool)
    case tile(DwindleTransferredTile)

    var activeToken: WindowToken {
        switch self {
        case let .member(member, _): member.token
        case let .tile(transferred): transferred.tile.activeToken
        }
    }

    func contains(_ token: WindowToken) -> Bool {
        switch self {
        case let .member(member, _): member.token == token
        case let .tile(transferred): transferred.tile.member(for: token) != nil
        }
    }

    func existingTile(with id: DwindleTileId) -> DwindleTile? {
        guard case let .tile(transferred) = self, transferred.tile.id == id else { return nil }
        return transferred.tile
    }

    func restoreExclusions(into tokens: inout Set<WindowToken>) {
        switch self {
        case let .member(member, excluded):
            if excluded { tokens.insert(member.token) }
        case let .tile(transferred):
            tokens.formUnion(transferred.excludedTokens)
        }
    }
}
