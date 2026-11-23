// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import OmniWMIPC

extension ActionCatalog {
    static func appendAxisResizeBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "resizeGrow.horizontal",
                command: .dwindle(.resizeAlongAxis(.horizontal, true)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "grow"]
            ),
            action(
                id: "resizeGrow.vertical",
                command: .dwindle(.resizeAlongAxis(.vertical, true)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "grow"]
            ),
            action(
                id: "resizeShrink.horizontal",
                command: .dwindle(.resizeAlongAxis(.horizontal, false)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "shrink"]
            ),
            action(
                id: "resizeShrink.vertical",
                command: .dwindle(.resizeAlongAxis(.vertical, false)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "shrink"]
            )
        ])
    }

    static func appendFocusedResizeBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "resizeFocusedWindow.grow",
                command: .dwindle(.resizeFocusedWindow(true)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "grow"]
            ),
            action(
                id: "resizeFocusedWindow.shrink",
                command: .dwindle(.resizeFocusedWindow(false)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "shrink"]
            )
        ])
    }

    static func appendDirectionalResizeBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "resizeInDirection.left",
                command: .dwindle(.resizeInDirection(.left)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "left"]
            ),
            action(
                id: "resizeInDirection.right",
                command: .dwindle(.resizeInDirection(.right)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "right"]
            ),
            action(
                id: "resizeInDirection.up",
                command: .dwindle(.resizeInDirection(.up)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "up"]
            ),
            action(
                id: "resizeInDirection.down",
                command: .dwindle(.resizeInDirection(.down)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced,
                keywords: ["resize", "down"]
            )
        ])
    }

    static func appendPreselectionBindings(_ specs: inout [ActionSpec]) {
        specs.append(contentsOf: [
            action(
                id: "preselect.left",
                command: .dwindle(.preselect(.left)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "preselect.right",
                command: .dwindle(.preselect(.right)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "preselect.up",
                command: .dwindle(.preselect(.up)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "preselect.down",
                command: .dwindle(.preselect(.down)),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            ),
            action(
                id: "preselectClear",
                command: .dwindle(.preselectClear),
                category: .layout,
                binding: .unassigned,
                visibility: .advanced
            )
        ])
    }
}
