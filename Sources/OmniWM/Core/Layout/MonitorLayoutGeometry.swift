// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct MonitorLayoutFrames {
    let workingFrame: CGRect
    let borderSafeFillFrame: CGRect
    let fullscreenLayoutFrame: CGRect
    var roomGapLimits: [WorkspaceBarRoom.Edge: CGFloat] = [:]
}

struct NiriInteractionGeometry {
    let workingFrame: CGRect
    let innerGap: CGFloat
    let scale: CGFloat
}
