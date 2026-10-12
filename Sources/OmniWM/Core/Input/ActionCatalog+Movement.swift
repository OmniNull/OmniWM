// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import OmniWMIPC

extension ActionCatalog {
    static func appendDirectionalMoveBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "move.left",
                command: .move(.left),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["group", "tab", "join", "extract"]
            ),
            action(
                id: "move.down",
                command: .move(.down),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["group", "tab", "join", "extract"]
            ),
            action(
                id: "move.up",
                command: .move(.up),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["group", "tab", "join", "extract"]
            ),
            action(
                id: "move.right",
                command: .move(.right),
                category: .move,
                binding: KeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | shiftKey)),
                keywords: ["group", "tab", "join", "extract"]
            )
        ])
    }

    static func appendWindowReorderBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "moveWindowDown",
                command: .windowMovement(.down),
                category: .move,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["move", "reorder", "group", "tab", "column", "container"]
            ),
            action(
                id: "moveWindowUp",
                command: .windowMovement(.up),
                category: .move,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["move", "reorder", "group", "tab", "column", "container"]
            ),
            action(
                id: "moveWindowDownOrToWorkspaceDown",
                command: .windowMovement(.downOrToWorkspaceDown),
                category: .move,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "moveWindowUpOrToWorkspaceUp",
                command: .windowMovement(.upOrToWorkspaceUp),
                category: .move,
                binding: .unassigned,
                visibility: .advanced
            )
        ])
    }

    static func appendColumnMembershipBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "consumeOrExpelWindowLeft",
                command: .windowMovement(.consumeOrExpelLeft),
                category: .move,
                binding: .unassigned,
                visibility: .unassignable
            ),
            action(
                id: "consumeOrExpelWindowRight",
                command: .windowMovement(.consumeOrExpelRight),
                category: .move,
                binding: .unassigned,
                visibility: .unassignable
            ),
            action(
                id: "consumeWindowIntoColumn",
                command: .windowMovement(.consumeIntoColumn),
                category: .move,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["consume", "pull", "next column", "focused column"]
            ),
            action(
                id: "expelWindowFromColumn",
                command: .windowMovement(.expelFromColumn),
                category: .move,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["expel", "push", "bottom window", "new column"]
            )
        ])
    }
}
