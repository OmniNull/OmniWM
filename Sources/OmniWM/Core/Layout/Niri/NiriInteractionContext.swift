// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct NiriInteractionContext {
    let workspaceId: WorkspaceDescriptor.ID
    let motion: MotionSnapshot
    let workingFrame: CGRect
    let gaps: CGFloat
    let orientation: Monitor.Orientation

    var primaryOrigin: CGFloat {
        orientation == .horizontal ? workingFrame.minX : workingFrame.minY
    }

    var primaryEnd: CGFloat {
        orientation == .horizontal ? workingFrame.maxX : workingFrame.maxY
    }

    var primarySpan: CGFloat {
        orientation == .horizontal ? workingFrame.width : workingFrame.height
    }

    var sizingGeometry: NiriSizingGeometry {
        NiriSizingGeometry(workingFrame: workingFrame, gaps: gaps, orientation: orientation)
    }

    func oriented(_ orientation: Monitor.Orientation) -> NiriInteractionContext {
        NiriInteractionContext(
            workspaceId: workspaceId,
            motion: motion,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }
}

struct NiriWorkspaceDestination {
    let workspaceId: WorkspaceDescriptor.ID
    let orientation: Monitor.Orientation
}
