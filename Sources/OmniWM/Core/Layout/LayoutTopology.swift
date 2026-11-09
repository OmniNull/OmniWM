// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ActiveLayoutKind: String, Equatable {
    case niri
    case dwindle
}

struct LayoutTopology: Equatable {
    struct Tile: Equatable {
        let nodeId: NodeId
        let token: WindowToken
        let isFullscreen: Bool
    }

    struct Column: Equatable {
        let tiles: [Tile]
    }

    var columns: [Column] = []
    var dwindleFullscreenTokens: Set<WindowToken> = []
}

extension LayoutTopology {
    var hasColumns: Bool {
        !columns.isEmpty
    }

    func containsNiriWindow(_ token: WindowToken) -> Bool {
        columns.contains { column in
            column.tiles.contains { $0.token == token }
        }
    }

    func token(for nodeId: NodeId) -> WindowToken? {
        for column in columns {
            if let tile = column.tiles.first(where: { $0.nodeId == nodeId }) {
                return tile.token
            }
        }
        return nil
    }

    func isFullscreen(_ token: WindowToken) -> Bool {
        if dwindleFullscreenTokens.contains(token) {
            return true
        }
        return columns.contains { column in
            column.tiles.contains { $0.token == token && $0.isFullscreen }
        }
    }
}

extension NiriLayoutEngine {
    func topologyColumns(in workspaceId: WorkspaceDescriptor.ID) -> [LayoutTopology.Column] {
        columns(in: workspaceId).map { column in
            LayoutTopology.Column(
                tiles: column.windowNodes.map {
                    LayoutTopology.Tile(nodeId: $0.id, token: $0.token, isFullscreen: $0.isFullscreen)
                }
            )
        }
    }
}
