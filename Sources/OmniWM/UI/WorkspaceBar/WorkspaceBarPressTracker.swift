// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct WorkspaceBarPressTracker {
    enum EventKind: Equatable {
        case leftDown
        case leftDragged
        case leftUp
        case rightDown
    }

    enum Decision: Equatable {
        case passThrough
        case consume
        case showMenu(WorkspaceBarHitTarget)
        case moveFocusedWindow(WorkspaceDescriptor.ID)
        case activateWindow(WorkspaceDescriptor.ID, WindowToken)
        case beginDrag(WorkspaceDescriptor.ID, WindowToken)
        case continueDrag
        case endDrag
    }

    private enum Press: Equatable {
        case window(WorkspaceDescriptor.ID, WindowToken, origin: CGPoint)
        case dragging
        case consumedUntilRelease
    }

    static let dragThreshold: CGFloat = 6

    private var press: Press?

    mutating func handle(
        _ kind: EventKind,
        modifiers: NSEvent.ModifierFlags,
        target: WorkspaceBarHitTarget?,
        location: CGPoint = .zero
    ) -> Decision {
        switch kind {
        case .rightDown:
            guard press != .dragging else { return .consume }
            return target.map(Decision.showMenu) ?? .passThrough
        case .leftDown:
            return handleLeftDown(modifiers: modifiers, target: target, location: location)
        case .leftDragged:
            return handleDrag(location: location)
        case .leftUp:
            defer { press = nil }
            switch press {
            case let .window(workspaceId, token, _):
                return target == .window(workspaceId, token) ? .activateWindow(workspaceId, token) : .consume
            case .dragging:
                return .endDrag
            case .consumedUntilRelease:
                return .consume
            case nil:
                return .passThrough
            }
        }
    }

    private mutating func handleDrag(location: CGPoint) -> Decision {
        switch press {
        case let .window(workspaceId, token, origin)
            where hypot(location.x - origin.x, location.y - origin.y) >= Self.dragThreshold:
            press = .dragging
            return .beginDrag(workspaceId, token)
        case .dragging:
            return .continueDrag
        case nil:
            return .passThrough
        default:
            return .consume
        }
    }

    mutating func reset() {
        press = nil
    }

    private mutating func handleLeftDown(
        modifiers: NSEvent.ModifierFlags,
        target: WorkspaceBarHitTarget?,
        location: CGPoint
    ) -> Decision {
        press = nil
        guard let target else { return .passThrough }
        if modifiers.contains(.control) {
            press = .consumedUntilRelease
            return .showMenu(target)
        }
        if modifiers.contains(.shift), let workspaceId = target.workspaceId {
            press = .consumedUntilRelease
            return .moveFocusedWindow(workspaceId)
        }
        if case let .window(workspaceId, token) = target {
            press = .window(workspaceId, token, origin: location)
            return .consume
        }
        return .passThrough
    }
}
