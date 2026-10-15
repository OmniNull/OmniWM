// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let windowGatherActionDescriptors: [IPCWindowGatherActionDescriptor] = [
        .init(
            path: "window-gather",
            summary: "Atomically gather explicit managed windows into one leading Niri column of an existing workspace.",
            arguments: ["windowIds", "workspaceTarget"]
        )
    ]
}
