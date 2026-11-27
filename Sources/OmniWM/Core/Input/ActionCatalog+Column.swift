// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import OmniWMAutomation
import OmniWMIPC

extension ActionCatalog {
    static func appendColumnWorkspaceBindings(_ specs: inout [ActionSpec]) {
        for idx in 0 ..< 9 {
            specs.append(
                action(
                    id: "moveColumnToWorkspace.\(idx)",
                    command: .column(.moveToWorkspace(idx)),
                    category: .workspace,
                    binding: .unassigned,
                    visibility: .advanced
                )
            )
        }
    }

    static func appendFullscreenBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            IPCFullscreenCommand.managed.actionSpec(),
            IPCFullscreenCommand.native.actionSpec()
        ])
    }

    static func appendDirectionalColumnBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "moveColumn.left",
                command: .moveColumn(.left),
                category: .column,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_LeftArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                ),
                visibility: .advanced,
                keywords: ["container", "tile", "group"]
            ),
            action(
                id: "moveColumn.right",
                command: .moveColumn(.right),
                category: .column,
                binding: KeyBinding(
                    keyCode: UInt32(kVK_RightArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                ),
                visibility: .advanced,
                keywords: ["container", "tile", "group"]
            ),
            action(
                id: "moveColumn.up",
                command: .moveColumn(.up),
                category: .column,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["container", "tile", "group"]
            ),
            action(
                id: "moveColumn.down",
                command: .moveColumn(.down),
                category: .column,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["container", "tile", "group"]
            )
        ])
    }

    static func appendColumnOrderBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "moveColumnToFirst",
                command: .column(.moveToFirst),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_Home), modifiers: UInt32(optionKey | controlKey))
            ),
            action(
                id: "moveColumnToLast",
                command: .column(.moveToLast),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_End), modifiers: UInt32(optionKey | controlKey))
            ),
            action(
                id: "toggleColumnTabbed",
                command: .column(.toggleTabbed),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey))
            )
        ])
    }

    static func appendColumnEdgeFocusBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "focusColumnFirst",
                command: .focusNavigation(.columnFirst),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_Home), modifiers: UInt32(optionKey))
            ),
            action(
                id: "focusColumnLast",
                command: .focusNavigation(.columnLast),
                category: .focus,
                binding: KeyBinding(keyCode: UInt32(kVK_End), modifiers: UInt32(optionKey))
            )
        ])
    }

    static func appendColumnIndexMoveBindings(_ specs: inout [ActionSpec]) {
        for idx in 1 ... 9 {
            specs.append(
                action(
                    id: "moveColumnToIndex.\(idx)",
                    command: .column(.moveToIndex(idx)),
                    category: .column,
                    binding: .unassigned,
                    visibility: .advanced
                )
            )
        }
    }
}
