// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

enum WorkspaceBarHitTarget: Hashable {
    case workspace(WorkspaceDescriptor.ID)
    case window(WorkspaceDescriptor.ID, WindowToken)
    case scratchpad(Int)
}
