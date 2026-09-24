// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum WorkspaceAction: Equatable, Hashable {
    case moveTo(Int)
    case moveUp
    case moveDown
    case moveToMonitor(Direction)
    case switchTo(Int)
    case switchSlot(Int)
    case moveToSlot(Int)
    case next
    case previous
    case moveWorkspaceToMonitor(Direction)
    case swapWithMonitor(Direction)
    case backAndForth
    case toggleLayout
}

extension WorkspaceAction {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case let .moveTo(idx): LocalizedStringResource(
                "command.workspace.moveTo", defaultValue: "Move to Workspace \(idx + 1)", table: "Commands",
                bundle: .omniWM
            )
        case .moveUp: LocalizedStringResource(
                "command.workspace.moveWindowUp", defaultValue: "Move Window to Workspace Up", table: "Commands",
                bundle: .omniWM
            )
        case .moveDown: LocalizedStringResource(
                "command.workspace.moveWindowDown", defaultValue: "Move Window to Workspace Down", table: "Commands",
                bundle: .omniWM
            )
        case let .switchTo(idx): LocalizedStringResource(
                "command.workspace.switchTo", defaultValue: "Switch to Workspace \(idx + 1)", table: "Commands",
                bundle: .omniWM
            )
        case let .switchSlot(slot): LocalizedStringResource(
                "command.workspace.switchSlot", defaultValue: "Switch to Workspace Slot \(slot)", table: "Commands",
                bundle: .omniWM
            )
        case let .moveToSlot(slot): LocalizedStringResource(
                "command.workspace.moveToSlot", defaultValue: "Move to Workspace Slot \(slot)", table: "Commands",
                bundle: .omniWM
            )
        case .next: LocalizedStringResource(
                "command.workspace.next", defaultValue: "Switch to Next Workspace", table: "Commands", bundle: .omniWM
            )
        case .previous: LocalizedStringResource(
                "command.workspace.previous", defaultValue: "Switch to Previous Workspace", table: "Commands",
                bundle: .omniWM
            )
        case let .moveToMonitor(direction): Self.moveToMonitorTitle(direction)
        case let .moveWorkspaceToMonitor(direction): Self.moveWorkspaceToMonitorTitle(direction)
        case let .swapWithMonitor(direction): Self.swapWithMonitorTitle(direction)
        case .backAndForth: LocalizedStringResource(
                "command.workspace.backAndForth", defaultValue: "Switch to Last Active Workspace", table: "Commands",
                bundle: .omniWM
            )
        case .toggleLayout: LocalizedStringResource(
                "command.workspace.toggleLayout", defaultValue: "Toggle Workspace Layout", table: "Commands",
                bundle: .omniWM
            )
        }
    }

    private static func moveToMonitorTitle(_ direction: Direction) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource(
                "command.workspace.moveWindowToMonitor.left", defaultValue: "Move Window to Left Monitor",
                table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.workspace.moveWindowToMonitor.right", defaultValue: "Move Window to Right Monitor",
                table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.workspace.moveWindowToMonitor.up", defaultValue: "Move Window to Up Monitor",
                table: "Commands", bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.workspace.moveWindowToMonitor.down", defaultValue: "Move Window to Down Monitor",
                table: "Commands", bundle: .omniWM
            )
        }
    }

    private static func moveWorkspaceToMonitorTitle(_ direction: Direction) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource(
                "command.workspace.moveToMonitor.left", defaultValue: "Move Workspace to Left Monitor",
                table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.workspace.moveToMonitor.right", defaultValue: "Move Workspace to Right Monitor",
                table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.workspace.moveToMonitor.up", defaultValue: "Move Workspace to Up Monitor", table: "Commands",
                bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.workspace.moveToMonitor.down", defaultValue: "Move Workspace to Down Monitor",
                table: "Commands", bundle: .omniWM
            )
        }
    }

    private static func swapWithMonitorTitle(_ direction: Direction) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource(
                "command.workspace.swapWithMonitor.left", defaultValue: "Swap Workspace with Left Monitor",
                table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.workspace.swapWithMonitor.right", defaultValue: "Swap Workspace with Right Monitor",
                table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.workspace.swapWithMonitor.up", defaultValue: "Swap Workspace with Up Monitor",
                table: "Commands", bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.workspace.swapWithMonitor.down", defaultValue: "Swap Workspace with Down Monitor",
                table: "Commands", bundle: .omniWM
            )
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .switchTo:
            .workspace(.switchTo)
        case .switchSlot:
            .workspace(.switchSlot)
        case .moveToSlot:
            .workspace(.moveToSlot)
        case .next:
            .workspace(.next)
        case .previous:
            .workspace(.previous)
        case .backAndForth:
            .workspace(.backAndForth)
        case .moveTo:
            .workspace(.moveTo)
        case .moveUp:
            .workspace(.moveUp)
        case .moveDown:
            .workspace(.moveDown)
        case .moveToMonitor:
            .workspace(.moveToMonitor)
        case .moveWorkspaceToMonitor:
            nil
        case .swapWithMonitor:
            .swapWorkspaceWithMonitor
        case .toggleLayout:
            .workspaceLayout(.toggle)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .moveTo,
             .moveUp,
             .moveDown,
             .moveToMonitor,
             .switchTo,
             .switchSlot,
             .moveToSlot,
             .next,
             .previous,
             .moveWorkspaceToMonitor,
             .swapWithMonitor,
             .backAndForth,
             .toggleLayout:
            .shared
        }
    }
}
