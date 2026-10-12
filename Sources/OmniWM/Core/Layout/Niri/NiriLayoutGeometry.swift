// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct NiriLayoutGeometry {
    private enum Area {
        case working(WorkingAreaContext)
        case monitor(workingFrame: CGRect, viewFrame: CGRect?, scale: CGFloat)
    }

    private let area: Area
    let gaps: LayoutGaps
    let orientation: Monitor.Orientation

    init(workingArea: WorkingAreaContext, gaps: LayoutGaps, orientation: Monitor.Orientation) {
        area = .working(workingArea)
        self.gaps = gaps
        self.orientation = orientation
    }

    init(
        monitorFrame: CGRect,
        screenFrame: CGRect?,
        scale: CGFloat,
        gaps: LayoutGaps,
        orientation: Monitor.Orientation
    ) {
        area = .monitor(workingFrame: monitorFrame, viewFrame: screenFrame, scale: scale)
        self.gaps = gaps
        self.orientation = orientation
    }

    func resolveWorkingArea() -> WorkingAreaContext {
        switch area {
        case let .working(workingArea):
            workingArea
        case let .monitor(workingFrame, viewFrame, scale):
            WorkingAreaContext(
                workingFrame: workingFrame,
                viewFrame: viewFrame ?? workingFrame,
                scale: scale
            )
        }
    }

    func axisGaps() -> (primary: CGFloat, secondary: CGFloat) {
        switch orientation {
        case .horizontal: (gaps.horizontal, gaps.vertical)
        case .vertical: (gaps.vertical, gaps.horizontal)
        }
    }
}

struct NiriPreparedLayoutColumn {
    let span: CGFloat
    let renderOffset: CGPoint
    let position: CGFloat
}

struct NiriColumnVisibility {
    let canonicalRect: CGRect
    let visibleRect: CGRect
    let state: ContainerVisibilityState
}

struct NiriLayoutViewport {
    private let area: WorkingAreaContext
    private let orientation: Monitor.Orientation
    private let workspaceOffset: CGFloat
    private let viewPositions: [CGFloat]
    private let revealMargin: CGFloat

    init(
        area: WorkingAreaContext,
        orientation: Monitor.Orientation,
        workspaceOffset: CGFloat,
        viewPositions: [CGFloat],
        revealMargin: CGFloat
    ) {
        self.area = area
        self.orientation = orientation
        self.workspaceOffset = workspaceOffset
        self.viewPositions = viewPositions
        self.revealMargin = revealMargin
    }

    func columnVisibility(
        for column: NiriPreparedLayoutColumn,
        at idx: Int,
        viewPosition viewPos: CGFloat,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> NiriColumnVisibility {
        let renderOffset = column.renderOffset
        let canonicalContainerRect = area.canonicalContainerRect(
            position: column.position,
            span: column.span,
            orientation: orientation
        )
        let visibilityRect = area.visibleRenderedContainerRect(
            canonicalRect: canonicalContainerRect,
            viewPosition: viewPos,
            workspaceOffset: workspaceOffset,
            renderOffset: renderOffset,
            orientation: orientation
        )
        var visibilityState = sampledContainerVisibilityState(
            canonicalRect: canonicalContainerRect,
            renderOffset: renderOffset,
            fallback: idx == 0 ? .minimum : .maximum,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        )
        if case .visible = visibilityState {
            let clampedVisibilityRect = NiriMonitorPlaneGeometry.clampedFrame(
                visibilityRect,
                screenClampRect: area.viewFrame,
                orientation: orientation
            )
            if let liveOverflowEdge = NiriMonitorPlaneGeometry.overflowEdgeIntersectingNeighboringMonitor(
                clampedVisibilityRect,
                viewportFrame: area.workingFrame,
                orientation: orientation,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            ) {
                visibilityState = .hidden(liveOverflowEdge)
            }
        }
        return NiriColumnVisibility(
            canonicalRect: canonicalContainerRect,
            visibleRect: visibilityRect,
            state: visibilityState
        )
    }

    func sampledContainerVisibilityState(
        canonicalRect: CGRect,
        renderOffset: CGPoint,
        fallback: AxisHideEdge,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> ContainerVisibilityState {
        var settledHidden: ContainerVisibilityState?
        for viewPosition in viewPositions {
            let sampleRect = area.visibleRenderedContainerRect(
                canonicalRect: canonicalRect,
                viewPosition: viewPosition,
                workspaceOffset: workspaceOffset,
                renderOffset: renderOffset,
                orientation: orientation
            )
            let sampleState = containerVisibilityState(
                for: sampleRect,
                fallback: fallback,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
            if case .visible = sampleState {
                return .visible
            }
            if settledHidden == nil {
                settledHidden = sampleState
            }
        }
        return settledHidden ?? .hidden(fallback)
    }

    private func containerVisibilityState(
        for renderedRect: CGRect,
        fallback: AxisHideEdge,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> ContainerVisibilityState {
        let defaultHideEdge = area.hiddenEdge(
            for: renderedRect,
            fallback: fallback,
            orientation: orientation
        )
        let revealViewport = switch orientation {
        case .horizontal: area.workingFrame.insetBy(dx: -revealMargin, dy: 0)
        case .vertical: area.workingFrame.insetBy(dx: 0, dy: -revealMargin)
        }
        guard containerIntersectsViewport(
            renderedRect,
            viewportFrame: revealViewport
        ) else {
            return .hidden(defaultHideEdge)
        }
        if let overflowEdge = NiriMonitorPlaneGeometry.overflowEdgeIntersectingNeighboringMonitor(
            renderedRect,
            viewportFrame: area.workingFrame,
            orientation: orientation,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) {
            return .hidden(overflowEdge)
        }
        return .visible
    }

    private func containerIntersectsViewport(
        _ containerRect: CGRect,
        viewportFrame: CGRect
    ) -> Bool {
        switch orientation {
        case .horizontal:
            containerRect.maxX > viewportFrame.minX && containerRect.minX < viewportFrame.maxX
        case .vertical:
            containerRect.maxY > viewportFrame.minY && containerRect.minY < viewportFrame.maxY
        }
    }
}

struct NiriLayoutFrames {
    let scale: CGFloat
    let viewFrame: CGRect
    let orientation: Monitor.Orientation
    let canonicalMaximizedRect: CGRect
    let renderedMaximizedRect: CGRect
    let canonicalFullscreenRect: CGRect
    let renderedFullscreenRect: CGRect

    init(area: WorkingAreaContext, workspaceOffset: CGFloat, orientation: Monitor.Orientation) {
        scale = area.scale
        canonicalMaximizedRect = area.borderSafeFillFrame.roundedToPhysicalPixels(scale: area.scale)
        renderedMaximizedRect = canonicalMaximizedRect
            .offsetBy(dx: workspaceOffset, dy: 0)
            .roundedToPhysicalPixels(scale: area.scale)
        canonicalFullscreenRect = area.fullscreenLayoutFrame.roundedToPhysicalPixels(scale: area.scale)
        renderedFullscreenRect = canonicalFullscreenRect
            .offsetBy(dx: workspaceOffset, dy: 0)
            .roundedToPhysicalPixels(scale: area.scale)
        viewFrame = area.viewFrame
        self.orientation = orientation
    }
}

struct NiriContainerLayoutFrames {
    let canonicalRect: CGRect
    let renderedRect: CGRect
    let contentRect: CGRect
    let viewFrame: CGRect
    let scale: CGFloat
    let orientation: Monitor.Orientation

    init(
        canonicalRect: CGRect,
        renderedRect: CGRect,
        tabOffset: CGFloat,
        layoutFrames: NiriLayoutFrames
    ) {
        self.canonicalRect = canonicalRect
        self.renderedRect = renderedRect
        contentRect = CGRect(
            x: canonicalRect.origin.x + tabOffset,
            y: canonicalRect.origin.y,
            width: max(0, canonicalRect.width - tabOffset),
            height: canonicalRect.height
        )
        viewFrame = layoutFrames.viewFrame
        scale = layoutFrames.scale
        orientation = layoutFrames.orientation
    }

    func secondarySpan() -> CGFloat {
        switch orientation {
        case .horizontal: contentRect.height
        case .vertical: contentRect.width
        }
    }

    func secondaryStart(gap: CGFloat) -> CGFloat {
        var pos: CGFloat = switch orientation {
        case .horizontal: contentRect.origin.y
        case .vertical: contentRect.origin.x
        }
        pos += gap
        return pos
    }

    func windowLayout(
        for sizingMode: SizingMode,
        position pos: CGFloat,
        span: CGFloat,
        layoutFrames: NiriLayoutFrames
    ) -> NiriWindowLayout {
        let frame: CGRect
        let renderedBaseFrame: CGRect
        let resolvedSpan: CGFloat
        switch sizingMode {
        case .fullscreen:
            frame = layoutFrames.canonicalFullscreenRect.roundedToPhysicalPixels(scale: layoutFrames.scale)
            renderedBaseFrame = layoutFrames.renderedFullscreenRect
            resolvedSpan = switch orientation {
            case .horizontal: frame.height
            case .vertical: frame.width
            }
        case .maximized:
            frame = layoutFrames.canonicalMaximizedRect.roundedToPhysicalPixels(scale: layoutFrames.scale)
            renderedBaseFrame = layoutFrames.renderedMaximizedRect
            resolvedSpan = switch orientation {
            case .horizontal: frame.height
            case .vertical: frame.width
            }
        case .normal:
            switch orientation {
            case .horizontal:
                frame = CGRect(
                    x: contentRect.origin.x,
                    y: pos,
                    width: contentRect.width,
                    height: span
                ).roundedToPhysicalPixels(scale: layoutFrames.scale)
            case .vertical:
                frame = CGRect(
                    x: pos,
                    y: contentRect.origin.y,
                    width: span,
                    height: contentRect.height
                ).roundedToPhysicalPixels(scale: layoutFrames.scale)
            }
            renderedBaseFrame = frame.offsetBy(
                dx: renderedRect.origin.x - canonicalRect.origin.x,
                dy: renderedRect.origin.y - canonicalRect.origin.y
            )
            .roundedToPhysicalPixels(scale: layoutFrames.scale)
            resolvedSpan = span
        }
        return NiriWindowLayout(frame: frame, renderedBaseFrame: renderedBaseFrame, resolvedSpan: resolvedSpan)
    }
}

struct NiriAxisLayout {
    let availableSpace: CGFloat
    let gap: CGFloat
    let isTabbed: Bool
    let orientation: Monitor.Orientation
}

struct NiriWindowLayout {
    let frame: CGRect
    let renderedBaseFrame: CGRect
    let resolvedSpan: CGFloat
}
