// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let dwindleActionDescriptors: [IPCDwindleActionDescriptor] = [
        .init(
            path: "dwindle replace <tree>",
            name: .replace,
            summary: "Replace the interaction workspace's Dwindle tree in one checked change. The tree has the dwindle-tree query's shape and revision and lists each tiled window once.",
            arguments: ["tree"]
        )
    ]
}
