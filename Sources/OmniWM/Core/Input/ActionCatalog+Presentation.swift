// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import OmniWMIPC

extension ActionCatalog {
    static func appendPresentationBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "openCommandPalette",
                command: .openCommandPalette,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
                keywords: ["palette", "search", "commands", "menu"]
            ),
            action(
                id: "raiseAllFloatingWindows",
                command: .raiseAllFloatingWindows,
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["float", "floating", "raise"]
            ),
            action(
                id: "rescueOffscreenWindows",
                command: .rescueOffscreenWindows,
                category: .layout,
                binding: .unassigned,
                keywords: ["rescue", "offscreen", "off-screen"]
            ),
            IPCWindowStateCommand.toggleFloating.actionSpec(),
            IPCWindowStateCommand.close.actionSpec(),
            action(
                id: "openMenuAnywhere",
                command: .openMenuAnywhere,
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey)),
                keywords: ["menu", "anywhere"]
            ),
            setWindowMarkActionSpec,
            removeWindowMarkActionSpec,
            IPCPresentationCommand.workspaceBar.actionSpec(),
            IPCPresentationCommand.hiddenBar.actionSpec(),
            IPCPresentationCommand.quakeTerminal.actionSpec(),
            action(
                id: "toggleWorkspaceLayout",
                command: .workspace(.toggleLayout),
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["layout", "niri", "dwindle"]
            ),
            toggleAccordionActionSpec,
            IPCPresentationCommand.overview.actionSpec(),
            IPCPresentationCommand.systemStats.actionSpec()
        ])
    }

    private static var toggleAccordionActionSpec: ActionSpec {
        action(
            id: "toggleAccordion",
            command: .workspace(.toggleAccordion),
            category: .layout,
            binding: .unassigned,
            keywords: ["accordion", "niri"]
        )
    }

    private static var setWindowMarkActionSpec: ActionSpec {
        action(
            id: "setWindowMark",
            command: .windowMark(.set),
            category: .focus,
            binding: .unassigned,
            keywords: ["mark", "tag", "name", "focused window"]
        )
    }

    private static var removeWindowMarkActionSpec: ActionSpec {
        action(
            id: "removeWindowMark",
            command: .windowMark(.remove),
            category: .focus,
            binding: .unassigned,
            keywords: ["mark", "tag", "remove", "focused window"]
        )
    }
}
