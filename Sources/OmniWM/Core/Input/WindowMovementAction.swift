// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum WindowMovementAction: Equatable, Hashable {
    case down
    case up
    case downOrToWorkspaceDown
    case upOrToWorkspaceUp
    case consumeOrExpelLeft
    case consumeOrExpelRight
    case consumeIntoColumn
    case expelFromColumn
}

extension WindowMovementAction {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .down: LocalizedStringResource(
                "command.window.reorderDown", defaultValue: "Move Window to Next Position", table: "Commands",
                bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.window.reorderUp", defaultValue: "Move Window to Previous Position", table: "Commands",
                bundle: .omniWM
            )
        case .downOrToWorkspaceDown: LocalizedStringResource(
                "command.window.downOrWorkspaceDown", defaultValue: "Move Window Down or to Workspace Down",
                table: "Commands", bundle: .omniWM
            )
        case .upOrToWorkspaceUp: LocalizedStringResource(
                "command.window.upOrWorkspaceUp", defaultValue: "Move Window Up or to Workspace Up", table: "Commands",
                bundle: .omniWM
            )
        case .consumeOrExpelLeft: LocalizedStringResource(
                "command.window.consumeOrExpelLeft", defaultValue: "Consume or Expel Window Left", table: "Commands",
                bundle: .omniWM
            )
        case .consumeOrExpelRight: LocalizedStringResource(
                "command.window.consumeOrExpelRight", defaultValue: "Consume or Expel Window Right", table: "Commands",
                bundle: .omniWM
            )
        case .consumeIntoColumn: LocalizedStringResource(
                "command.window.consumeIntoColumn",
                defaultValue: "Pull Top Window from Next Column into Focused Column",
                table: "Commands", bundle: .omniWM
            )
        case .expelFromColumn: LocalizedStringResource(
                "command.window.expelFromColumn",
                defaultValue: "Push Bottom Window from Focused Column into New Column",
                table: "Commands", bundle: .omniWM
            )
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .down:
            .windowMovement(.down)
        case .up:
            .windowMovement(.up)
        case .downOrToWorkspaceDown:
            .windowMovement(.downOrToWorkspaceDown)
        case .upOrToWorkspaceUp:
            .windowMovement(.upOrToWorkspaceUp)
        case .consumeOrExpelLeft:
            .windowMovement(.consumeOrExpelLeft)
        case .consumeOrExpelRight:
            .windowMovement(.consumeOrExpelRight)
        case .consumeIntoColumn:
            .windowMovement(.consumeIntoColumn)
        case .expelFromColumn:
            .windowMovement(.expelFromColumn)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .down,
             .up:
            .shared
        case .downOrToWorkspaceDown,
             .upOrToWorkspaceUp,
             .consumeOrExpelLeft,
             .consumeOrExpelRight,
             .consumeIntoColumn,
             .expelFromColumn:
            .niri
        }
    }
}
