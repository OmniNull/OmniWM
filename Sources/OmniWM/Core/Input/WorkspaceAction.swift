// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation
import OmniWMIPC

enum WorkspaceAction: Equatable, Hashable {
    case moveTo(Int)
    case moveToOnMonitor(Int, Direction)
    case moveUp
    case moveDown
    case moveToMonitor(Direction)
    case switchTo(Int)
    case switchAnywhere(Int)
    case switchSlot(Int)
    case moveToSlot(Int)
    case next
    case previous
    case moveWorkspaceToMonitor(Direction)
    case swapWithMonitor(Direction)
    case backAndForth
    case toggleLayout
    case setLayout(LayoutType)
}

extension WorkspaceAction {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case let .moveTo(idx): LocalizedStringResource(
                "command.workspace.moveTo", defaultValue: "Move Focused Window to Workspace \(idx + 1)",
                table: "Commands", bundle: .omniWM
            )
        case let .moveToOnMonitor(index, direction): Self.moveToMonitorTitle(direction, workspaceIndex: index)
        case .moveUp: LocalizedStringResource(
                "command.workspace.moveWindowUp", defaultValue: "Move Focused Window to Workspace Up",
                table: "Commands", bundle: .omniWM
            )
        case .moveDown: LocalizedStringResource(
                "command.workspace.moveWindowDown", defaultValue: "Move Focused Window to Workspace Down",
                table: "Commands", bundle: .omniWM
            )
        case let .switchTo(idx): LocalizedStringResource(
                "command.workspace.switchTo", defaultValue: "Switch to Workspace \(idx + 1)", table: "Commands",
                bundle: .omniWM
            )
        case let .switchAnywhere(index): LocalizedStringResource(
                "command.workspace.switchAnywhere", defaultValue: "Focus Workspace \(index + 1) Across Monitors",
                table: "Commands", bundle: .omniWM
            )
        case let .switchSlot(slot): LocalizedStringResource(
                "command.workspace.switchSlot", defaultValue: "Switch to Workspace Slot \(slot)", table: "Commands",
                bundle: .omniWM
            )
        case let .moveToSlot(slot): LocalizedStringResource(
                "command.workspace.moveToSlot", defaultValue: "Move Focused Window to Workspace Slot \(slot)",
                table: "Commands", bundle: .omniWM
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
        case let .setLayout(layout): Self.layoutTitle(layout)
        case .toggleLayout: Self.layoutTitle(nil)
        }
    }

    private static func layoutTitle(_ layout: LayoutType?) -> LocalizedStringResource {
        if let layout {
            return LocalizedStringResource(
                "command.workspace.setLayout", defaultValue: "Set Workspace Layout to \(layout.displayName)",
                table: "Commands", bundle: .omniWM
            )
        }
        return LocalizedStringResource(
            "command.workspace.toggleLayout", defaultValue: "Toggle Workspace Layout", table: "Commands",
            bundle: .omniWM
        )
    }

    private static func moveToMonitorTitle(
        _ direction: Direction,
        workspaceIndex: Int? = nil
    ) -> LocalizedStringResource {
        if let workspaceIndex {
            return switch direction {
            case .left: LocalizedStringResource(
                    "command.workspace.moveToOnMonitor.left",
                    defaultValue: "Move Focused Window to Workspace \(workspaceIndex + 1) on the Monitor to the Left",
                    table: "Commands", bundle: .omniWM
                )
            case .right: LocalizedStringResource(
                    "command.workspace.moveToOnMonitor.right",
                    defaultValue: "Move Focused Window to Workspace \(workspaceIndex + 1) on the Monitor to the Right",
                    table: "Commands", bundle: .omniWM
                )
            case .up: LocalizedStringResource(
                    "command.workspace.moveToOnMonitor.up",
                    defaultValue: "Move Focused Window to Workspace \(workspaceIndex + 1) on the Monitor Above",
                    table: "Commands", bundle: .omniWM
                )
            case .down: LocalizedStringResource(
                    "command.workspace.moveToOnMonitor.down",
                    defaultValue: "Move Focused Window to Workspace \(workspaceIndex + 1) on the Monitor Below",
                    table: "Commands", bundle: .omniWM
                )
            }
        }
        return switch direction {
        case .left: LocalizedStringResource(
                "command.workspace.moveWindowToMonitor.left", defaultValue: "Move Focused Window to Monitor on Left",
                table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.workspace.moveWindowToMonitor.right", defaultValue: "Move Focused Window to Monitor on Right",
                table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.workspace.moveWindowToMonitor.up", defaultValue: "Move Focused Window to Monitor Above",
                table: "Commands", bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.workspace.moveWindowToMonitor.down", defaultValue: "Move Focused Window to Monitor Below",
                table: "Commands", bundle: .omniWM
            )
        }
    }

    private static func moveWorkspaceToMonitorTitle(_ direction: Direction) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource(
                "command.workspace.moveToMonitor.left", defaultValue: "Move Workspace to Monitor on Left",
                table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.workspace.moveToMonitor.right", defaultValue: "Move Workspace to Monitor on Right",
                table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.workspace.moveToMonitor.up", defaultValue: "Move Workspace to Monitor Above",
                table: "Commands", bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.workspace.moveToMonitor.down", defaultValue: "Move Workspace to Monitor Below",
                table: "Commands", bundle: .omniWM
            )
        }
    }

    private static func swapWithMonitorTitle(_ direction: Direction) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource(
                "command.workspace.swapWithMonitor.left", defaultValue: "Swap Workspace with Monitor on Left",
                table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.workspace.swapWithMonitor.right", defaultValue: "Swap Workspace with Monitor on Right",
                table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.workspace.swapWithMonitor.up", defaultValue: "Swap Workspace with Monitor Above",
                table: "Commands", bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.workspace.swapWithMonitor.down", defaultValue: "Swap Workspace with Monitor Below",
                table: "Commands", bundle: .omniWM
            )
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .switchTo:
            .workspace(.switchTo)
        case .switchAnywhere:
            .workspace(.switchAnywhere)
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
        case .moveToOnMonitor:
            .workspace(.moveToOnMonitor)
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
        case .setLayout:
            .workspaceLayout(.set)
        case .toggleLayout:
            .workspaceLayout(.toggle)
        }
    }

    var compatibility: LayoutCompatibility {
        .shared
    }
}
