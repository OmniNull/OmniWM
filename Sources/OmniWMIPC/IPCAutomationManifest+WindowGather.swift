// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let windowGatherActionDescriptors: [IPCWindowGatherActionDescriptor] = [
        .init(
            path: "window-gather",
            summary: "Atomically gather managed windows by windowIds or markNames (not both) into one leading Niri column.",
            arguments: ["windowIds", "markNames", "workspaceTarget"]
        )
    ]
}
