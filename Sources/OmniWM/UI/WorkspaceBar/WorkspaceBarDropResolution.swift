// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct WorkspaceBarDragSource: Equatable {
    let tokens: [WindowToken]
    let workspaceId: WorkspaceDescriptor.ID
    let isFloating: Bool
}

struct WorkspaceBarDropGeometry: Equatable {
    struct Placement: Equatable {
        let column: Int
        let row: Int
        let columnTileCount: Int
    }

    struct Icon: Equatable {
        let tokens: [WindowToken]
        let frame: CGRect
        let appName: String
        let placement: Placement?
    }

    struct Workspace: Equatable {
        let id: WorkspaceDescriptor.ID
        let name: String
        let layout: ActiveLayoutKind
        let hitFrame: CGRect
        let icons: [Icon]
        let columnCount: Int
    }

    let workspaces: [Workspace]
}

enum WorkspaceBarDropAction: Equatable {
    case niriMoveColumn(WorkspaceDescriptor.ID, oneBasedIndex: Int)
    case niriNewColumn(WorkspaceDescriptor.ID, gap: Int)
    case niriStack(WorkspaceDescriptor.ID, target: WindowToken, position: InsertPosition)
    case dwindleSwap(WorkspaceDescriptor.ID, target: WindowToken)
    case moveToWorkspace(WorkspaceDescriptor.ID)
    case noOp
    case cancel
}

enum WorkspaceBarDropHighlight: Equatable {
    case workspace(WorkspaceDescriptor.ID)
    case gap(WorkspaceDescriptor.ID, beforeIcon: Int)
    case icon(WorkspaceDescriptor.ID, WindowToken)
}

struct WorkspaceBarDropResolution: Equatable {
    let action: WorkspaceBarDropAction
    let label: String
    let highlights: [WorkspaceBarDropHighlight]

    static let cancelled = WorkspaceBarDropResolution(
        action: .cancel,
        label: String(localized: "Can’t drop here"),
        highlights: []
    )
}

enum WorkspaceBarDropResolver {
    private enum Zone: Equatable {
        case gap(beforeIcon: Int)
        case icon(Int, InsertPosition)
    }

    static func resolve(
        source: WorkspaceBarDragSource,
        at point: CGPoint,
        in geometry: WorkspaceBarDropGeometry
    ) -> WorkspaceBarDropResolution {
        guard let workspace = geometry.workspaces.first(where: { $0.hitFrame.contains(point) }) else {
            return .cancelled
        }
        if workspace.id == source.workspaceId {
            return resolveWithinWorkspace(source: source, at: point, in: workspace)
        }
        if let positional = resolveIntoOtherWorkspace(source: source, at: point, in: workspace) {
            return positional
        }
        return WorkspaceBarDropResolution(
            action: .moveToWorkspace(workspace.id),
            label: String(localized: "Move to \(workspace.name)"),
            highlights: [.workspace(workspace.id)]
        )
    }

    private static func resolveWithinWorkspace(
        source: WorkspaceBarDragSource,
        at point: CGPoint,
        in workspace: WorkspaceBarDropGeometry.Workspace
    ) -> WorkspaceBarDropResolution {
        guard !source.isFloating, let token = source.tokens.first, source.tokens.count == 1 else {
            return noOp
        }
        switch workspace.layout {
        case .dwindle:
            return resolveDwindleSwap(token: token, at: point, in: workspace)
        case .niri:
            guard let sourcePlacement = workspace.icons.first(where: { $0.tokens == [token] })?.placement,
                  let zone = zone(at: point, in: workspace.icons)
            else {
                return noOp
            }
            return resolveNiri(
                token: token,
                sourcePlacement: sourcePlacement,
                zone: zone,
                in: workspace
            )
        }
    }

    private static func resolveIntoOtherWorkspace(
        source: WorkspaceBarDragSource,
        at point: CGPoint,
        in workspace: WorkspaceBarDropGeometry.Workspace
    ) -> WorkspaceBarDropResolution? {
        let positional = workspace.icons.filter { $0.placement != nil }
        guard !source.isFloating,
              source.tokens.count == 1,
              workspace.layout == .niri,
              let first = positional.first,
              let last = positional.last,
              point.x >= first.frame.minX - 4,
              point.x <= last.frame.maxX + 4,
              let zone = zone(at: point, in: workspace.icons)
        else {
            return nil
        }
        switch zone {
        case let .icon(index, position):
            guard let target = workspace.icons[index].tokens.first else { return nil }
            return WorkspaceBarDropResolution(
                action: .niriStack(workspace.id, target: target, position: position),
                label: String(localized: "Stack with \(workspace.icons[index].appName)"),
                highlights: [.workspace(workspace.id), .icon(workspace.id, target)]
            )
        case let .gap(beforeIcon):
            return WorkspaceBarDropResolution(
                action: .niriNewColumn(workspace.id, gap: columnGap(beforeIcon: beforeIcon, in: workspace)),
                label: String(localized: "New column in \(workspace.name)"),
                highlights: [.workspace(workspace.id), .gap(workspace.id, beforeIcon: beforeIcon)]
            )
        }
    }

    private static func resolveDwindleSwap(
        token: WindowToken,
        at point: CGPoint,
        in workspace: WorkspaceBarDropGeometry.Workspace
    ) -> WorkspaceBarDropResolution {
        guard let icon = workspace.icons.first(where: { $0.frame.contains(point) }),
              icon.tokens.count == 1,
              let target = icon.tokens.first,
              target != token
        else {
            return noOp
        }
        return WorkspaceBarDropResolution(
            action: .dwindleSwap(workspace.id, target: target),
            label: String(localized: "Swap with \(icon.appName)"),
            highlights: [.workspace(workspace.id), .icon(workspace.id, target)]
        )
    }

    private static func resolveNiri(
        token: WindowToken,
        sourcePlacement: WorkspaceBarDropGeometry.Placement,
        zone: Zone,
        in workspace: WorkspaceBarDropGeometry.Workspace
    ) -> WorkspaceBarDropResolution {
        switch zone {
        case let .icon(index, position):
            let icon = workspace.icons[index]
            guard let target = icon.tokens.first,
                  let targetPlacement = icon.placement,
                  target != token,
                  !stackIsNoOp(source: sourcePlacement, target: targetPlacement, position: position)
            else {
                return noOp
            }
            return WorkspaceBarDropResolution(
                action: .niriStack(workspace.id, target: target, position: position),
                label: String(localized: "Stack with \(icon.appName)"),
                highlights: [.workspace(workspace.id), .icon(workspace.id, target)]
            )
        case let .gap(beforeIcon):
            let gap = columnGap(beforeIcon: beforeIcon, in: workspace)
            let staysInPlace = sourcePlacement.columnTileCount == 1
                && (gap == sourcePlacement.column || gap == sourcePlacement.column + 1)
            guard !staysInPlace else { return noOp }
            let action: WorkspaceBarDropAction = sourcePlacement.columnTileCount == 1
                ? .niriMoveColumn(
                    workspace.id,
                    oneBasedIndex: (gap > sourcePlacement.column ? gap - 1 : gap) + 1
                )
                : .niriNewColumn(workspace.id, gap: gap)
            return WorkspaceBarDropResolution(
                action: action,
                label: String(localized: "New column"),
                highlights: [.workspace(workspace.id), .gap(workspace.id, beforeIcon: beforeIcon)]
            )
        }
    }

    private static func zone(at point: CGPoint, in icons: [WorkspaceBarDropGeometry.Icon]) -> Zone? {
        let positional = icons.indices.filter { icons[$0].placement != nil }
        guard let last = positional.last else { return nil }
        var previous: Int?
        for index in positional {
            let frame = icons[index].frame
            let band = min(6, frame.width / 4)
            if point.x < frame.minX + band {
                return boundary(before: index, previous: previous, icons: icons)
            }
            if point.x <= frame.maxX - band {
                return .icon(index, point.x < frame.midX ? .before : .after)
            }
            previous = index
        }
        return .gap(beforeIcon: last + 1)
    }

    private static func boundary(
        before index: Int,
        previous: Int?,
        icons: [WorkspaceBarDropGeometry.Icon]
    ) -> Zone {
        guard let previous,
              let current = icons[index].placement,
              let prior = icons[previous].placement,
              current.column == prior.column
        else {
            return .gap(beforeIcon: index)
        }
        return .icon(index, .before)
    }

    private static func columnGap(beforeIcon index: Int, in workspace: WorkspaceBarDropGeometry.Workspace) -> Int {
        let icons = workspace.icons
        guard icons.indices.contains(index), let placement = icons[index].placement else {
            return workspace.columnCount
        }
        return placement.column
    }

    private static func stackIsNoOp(
        source: WorkspaceBarDropGeometry.Placement,
        target: WorkspaceBarDropGeometry.Placement,
        position: InsertPosition
    ) -> Bool {
        guard source.column == target.column else { return false }
        switch position {
        case .before: return target.row == source.row + 1
        case .after: return target.row == source.row - 1
        case .swap: return false
        }
    }

    private static let noOp = WorkspaceBarDropResolution(action: .noOp, label: "", highlights: [])
}
