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
    }

    private enum Press: Equatable {
        case window(WorkspaceDescriptor.ID, WindowToken)
        case consumedUntilRelease
    }

    private var press: Press?

    mutating func handle(
        _ kind: EventKind,
        modifiers: NSEvent.ModifierFlags,
        target: WorkspaceBarHitTarget?
    ) -> Decision {
        switch kind {
        case .rightDown:
            return target.map(Decision.showMenu) ?? .passThrough
        case .leftDown:
            return handleLeftDown(modifiers: modifiers, target: target)
        case .leftDragged:
            return press == nil ? .passThrough : .consume
        case .leftUp:
            defer { press = nil }
            switch press {
            case let .window(workspaceId, token):
                return target == .window(workspaceId, token) ? .activateWindow(workspaceId, token) : .consume
            case .consumedUntilRelease:
                return .consume
            case nil:
                return .passThrough
            }
        }
    }

    mutating func reset() {
        press = nil
    }

    private mutating func handleLeftDown(
        modifiers: NSEvent.ModifierFlags,
        target: WorkspaceBarHitTarget?
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
            press = .window(workspaceId, token)
            return .consume
        }
        return .passThrough
    }
}
