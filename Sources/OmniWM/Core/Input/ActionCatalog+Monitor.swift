// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import OmniWMAutomation
import OmniWMIPC

extension ActionCatalog {
    private static let workspaceMonitorMoveKeywords = ["display", "home monitor", "force", "runtime override"]
    private static let windowMonitorMoveKeywords = [
        "display", "adjacent monitor", "send window", "active workspace", "current workspace"
    ]

    static func appendMonitorFocusBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            IPCMonitorFocusCommand.next.actionSpec(),
            IPCMonitorFocusCommand.previous.actionSpec(),
            IPCMonitorFocusCommand.last.actionSpec()
        ])
    }

    static func appendWorkspaceMonitorBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "moveWorkspaceToMonitor.left",
                command: .workspace(.moveWorkspaceToMonitor(.left)),
                category: .monitor,
                binding: .unassigned,
                keywords: workspaceMonitorMoveKeywords
            ),
            action(
                id: "moveWorkspaceToMonitor.right",
                command: .workspace(.moveWorkspaceToMonitor(.right)),
                category: .monitor,
                binding: .unassigned,
                keywords: workspaceMonitorMoveKeywords
            ),
            action(
                id: "moveWorkspaceToMonitor.up",
                command: .workspace(.moveWorkspaceToMonitor(.up)),
                category: .monitor,
                binding: .unassigned,
                keywords: workspaceMonitorMoveKeywords
            ),
            action(
                id: "moveWorkspaceToMonitor.down",
                command: .workspace(.moveWorkspaceToMonitor(.down)),
                category: .monitor,
                binding: .unassigned,
                keywords: workspaceMonitorMoveKeywords
            )
        ])
    }

    static func appendWindowMonitorBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "moveWindowToMonitor.left",
                command: .workspace(.moveToMonitor(.left)),
                category: .monitor,
                binding: .unassigned,
                keywords: windowMonitorMoveKeywords
            ),
            action(
                id: "moveWindowToMonitor.right",
                command: .workspace(.moveToMonitor(.right)),
                category: .monitor,
                binding: .unassigned,
                keywords: windowMonitorMoveKeywords
            ),
            action(
                id: "moveWindowToMonitor.up",
                command: .workspace(.moveToMonitor(.up)),
                category: .monitor,
                binding: .unassigned,
                keywords: windowMonitorMoveKeywords
            ),
            action(
                id: "moveWindowToMonitor.down",
                command: .workspace(.moveToMonitor(.down)),
                category: .monitor,
                binding: .unassigned,
                keywords: windowMonitorMoveKeywords
            )
        ])
    }
}
