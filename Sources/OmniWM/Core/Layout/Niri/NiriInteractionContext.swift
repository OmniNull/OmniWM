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

    var secondarySpan: CGFloat {
        orientation == .horizontal ? workingFrame.height : workingFrame.width
    }

    func primaryCoordinate(of point: CGPoint) -> CGFloat {
        orientation == .horizontal ? point.x : point.y
    }

    func secondaryCoordinate(of point: CGPoint) -> CGFloat {
        orientation == .horizontal ? point.y : point.x
    }

    func point(primary: CGFloat, secondary: CGFloat) -> CGPoint {
        orientation == .horizontal
            ? CGPoint(x: primary, y: secondary)
            : CGPoint(x: secondary, y: primary)
    }

    func primaryStart(of frame: CGRect) -> CGFloat {
        orientation == .horizontal ? frame.minX : frame.minY
    }

    func primaryEnd(of frame: CGRect) -> CGFloat {
        orientation == .horizontal ? frame.maxX : frame.maxY
    }

    func primarySpan(of frame: CGRect) -> CGFloat {
        orientation == .horizontal ? frame.width : frame.height
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
