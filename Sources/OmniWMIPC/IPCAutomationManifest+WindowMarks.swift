// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let windowMarkActionDescriptors: [IPCWindowMarkActionDescriptor] = [
        .init(
            path: "window mark set <name>",
            name: .set,
            summary: "Name the focused managed window with a runtime-only global mark.",
            arguments: ["name"]
        ),
        .init(
            path: "window mark list [--json]",
            name: .list,
            summary: "List runtime-only marks and their live workspace and window context."
        ),
        .init(
            path: "window mark focus <name>",
            name: .focus,
            summary: "Focus the live managed window identified by a global mark.",
            arguments: ["name"]
        ),
        .init(
            path: "window mark summon <name>",
            name: .summon,
            summary: "Summon a marked managed window to the right of the focused window.",
            arguments: ["name"]
        ),
        .init(
            path: "window mark remove <name>",
            name: .remove,
            summary: "Remove a runtime-only window mark.",
            arguments: ["name"]
        )
    ]
}
