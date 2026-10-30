// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import OmniWMIPC

extension ActionCatalog {
    static func appendSizeCycleBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "cycleSizeForward",
                command: .sizing(.cycleSizeForward),
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(optionKey)),
                visibility: .advanced
            ),
            action(
                id: "cycleSizeBackward",
                command: .sizing(.cycleSizeBackward),
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(optionKey)),
                visibility: .advanced
            )
        ])
    }

    static func appendWindowSpanCycleBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "cycleWindowPrimarySpanForward",
                command: .sizing(.cycleWindowPrimarySpanForward),
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowPrimarySpanBackward",
                command: .sizing(.cycleWindowPrimarySpanBackward),
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowSecondarySpanForward",
                command: .sizing(.cycleWindowSecondarySpanForward),
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "cycleWindowSecondarySpanBackward",
                command: .sizing(.cycleWindowSecondarySpanBackward),
                category: .column,
                binding: .unassigned,
                visibility: .advanced
            )
        ])
    }

    static func appendContainerSpanBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "toggleContainerFullPrimarySpan",
                command: .sizing(.toggleContainerFullPrimarySpan),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(
                id: "expandContainerToAvailablePrimarySpan",
                command: .sizing(.expandContainerToAvailablePrimarySpan),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | controlKey)),
                visibility: .advanced
            ),
            action(
                id: "resetWindowSecondarySpan",
                command: .sizing(.resetWindowSecondarySpan),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | controlKey)),
                visibility: .advanced
            )
        ])
    }

    static func appendSpanAdjustmentBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "resizeContainerPrimarySpan.shrink",
                command: .sizing(.resizeContainerPrimarySpan(grow: false)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey)),
                visibility: .advanced,
                keywords: ["shrink container", "decrease", "resize primary span"]
            ),
            action(
                id: "resizeContainerPrimarySpan.grow",
                command: .sizing(.resizeContainerPrimarySpan(grow: true)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey)),
                visibility: .advanced,
                keywords: ["grow container", "increase", "resize primary span"]
            ),
            action(
                id: "resizeWindowPrimarySpan.shrink",
                command: .sizing(.resizeWindowPrimarySpan(grow: false)),
                category: .column,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["shrink window", "decrease", "resize primary span"]
            ),
            action(
                id: "resizeWindowPrimarySpan.grow",
                command: .sizing(.resizeWindowPrimarySpan(grow: true)),
                category: .column,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["grow window", "increase", "resize primary span"]
            ),
            action(
                id: "resizeWindowSecondarySpan.shrink",
                command: .sizing(.resizeWindowSecondarySpan(grow: false)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey | shiftKey)),
                visibility: .advanced,
                keywords: ["shrink window", "decrease", "resize secondary span"]
            ),
            action(
                id: "resizeWindowSecondarySpan.grow",
                command: .sizing(.resizeWindowSecondarySpan(grow: true)),
                category: .column,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey | shiftKey)),
                visibility: .advanced,
                keywords: ["grow window", "increase", "resize secondary span"]
            )
        ])
    }

    static func appendSplitStructureBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "balanceSizes",
                command: .sizing(.balanceSizes),
                category: .layout,
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey))
            ),
            action(id: "moveToRoot", command: .dwindle(.moveToRoot), category: .layout, binding: .unassigned),
            action(id: "toggleSplit", command: .dwindle(.toggleSplit), category: .layout, binding: .unassigned),
            action(id: "swapSplit", command: .dwindle(.swapSplit), category: .layout, binding: .unassigned)
        ])
    }

    static func appendUndoResizeBinding(_ specs: inout [ActionSpec]) {
        specs.append(action(
            id: "undoResize",
            command: .sizing(.undoResize),
            category: .layout,
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey | cmdKey)),
            visibility: .niriSettings,
            keywords: ["undo", "resize", "edge", "border", "restore size"]
        ))
    }
}
