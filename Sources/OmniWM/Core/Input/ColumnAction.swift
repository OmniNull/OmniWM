// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum ColumnAction: Equatable, Hashable {
    case moveToFirst
    case moveToLast
    case moveToIndex(Int)
    case moveToWorkspace(Int)
    case moveToWorkspaceUp
    case moveToWorkspaceDown
    case toggleTabbed
}

extension ColumnAction {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case let .moveToWorkspace(idx): LocalizedStringResource(
                "command.column.moveToWorkspace", defaultValue: "Move Column to Workspace \(idx + 1)",
                table: "Commands", bundle: .omniWM
            )
        case .moveToWorkspaceUp: LocalizedStringResource(
                "command.column.moveToWorkspaceUp", defaultValue: "Move Column to Workspace Up", table: "Commands",
                bundle: .omniWM
            )
        case .moveToWorkspaceDown: LocalizedStringResource(
                "command.column.moveToWorkspaceDown", defaultValue: "Move Column to Workspace Down", table: "Commands",
                bundle: .omniWM
            )
        case .moveToFirst: LocalizedStringResource(
                "command.column.moveToFirst", defaultValue: "Move Column to First", table: "Commands", bundle: .omniWM
            )
        case .moveToLast: LocalizedStringResource(
                "command.column.moveToLast", defaultValue: "Move Column to Last", table: "Commands", bundle: .omniWM
            )
        case let .moveToIndex(idx): LocalizedStringResource(
                "command.column.moveToIndex", defaultValue: "Move Column to Index \(idx)", table: "Commands",
                bundle: .omniWM
            )
        case .toggleTabbed: LocalizedStringResource(
                "command.column.toggleTabbed", defaultValue: "Toggle Column Tabbed", table: "Commands", bundle: .omniWM
            )
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .moveToFirst:
            .column(.moveToFirst)
        case .moveToLast:
            .column(.moveToLast)
        case .moveToIndex:
            .column(.moveToIndex)
        case .moveToWorkspace:
            .column(.moveToWorkspace)
        case .moveToWorkspaceUp:
            .column(.moveToWorkspaceUp)
        case .moveToWorkspaceDown:
            .column(.moveToWorkspaceDown)
        case .toggleTabbed:
            .column(.toggleTabbed)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .moveToFirst,
             .moveToLast,
             .moveToIndex,
             .moveToWorkspace,
             .moveToWorkspaceUp,
             .moveToWorkspaceDown,
             .toggleTabbed:
            .niri
        }
    }
}
