// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct OverviewWorkspaceLayoutItem {
    let id: WorkspaceDescriptor.ID
    let name: String
    let isActive: Bool
    var displayId: CGDirectDisplayID?
}

struct OverviewWindowLayoutData {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let title: String
    let appName: String
    let appIcon: NSImage?
    let frame: CGRect
    var isNativeFullscreen = false
    var floatingPreviewFrame: CGRect?
}

enum OverviewLayoutMetrics {
    static let searchBarHeight: CGFloat = 44
    static let searchBarPadding: CGFloat = 20
    static let workspaceLabelHeight: CGFloat = 32
    static let workspaceSectionPadding: CGFloat = 16
    static let windowSpacing: CGFloat = 16
    static let windowPadding: CGFloat = 24
    static let minThumbnailWidth: CGFloat = 200
    static let maxThumbnailWidth: CGFloat = 400
    static let thumbnailAspectRatio: CGFloat = 16.0 / 10.0
    static let closeButtonSize: CGFloat = 20
    static let closeButtonPadding: CGFloat = 6
    static let contentTopPadding: CGFloat = 20
    static let contentBottomPadding: CGFloat = 40
    static let overflowPillHeight: CGFloat = 26
    static let overflowPillWidth: CGFloat = 52
    static let dragAutoScrollBand: CGFloat = 56
}

@MainActor
struct OverviewLayoutCalculator {
    private let geometry: OverviewLayoutGeometry
    private let scale: CGFloat

    /// Creates a layout calculator with a top safe-area inset in display points, independent of zoom.
    init(screenFrame: CGRect, scale: CGFloat, topSafeAreaInset: CGFloat = 0) {
        geometry = OverviewLayoutGeometry(screenFrame: screenFrame, scale: scale, topSafeAreaInset: topSafeAreaInset)
        self.scale = scale
    }

    nonisolated static func clampedScale(_ scale: CGFloat) -> CGFloat {
        max(0.5, min(1.5, scale))
    }

    static func viewportFrame(for monitorFrame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: monitorFrame.size)
    }

    static func localizedFrame(_ frame: CGRect, to monitorFrame: CGRect) -> CGRect {
        frame.offsetBy(dx: -monitorFrame.minX, dy: -monitorFrame.minY)
    }

    func calculateLayout(
        workspaces: [OverviewWorkspaceLayoutItem],
        windows: [WindowHandle: OverviewWindowLayoutData],
        niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:],
        dwindleGroupsByWorkspace: [WorkspaceDescriptor.ID: [OverviewDwindleGroup]] = [:],
        searchQuery: String,
        stripPans: [WorkspaceDescriptor.ID: CGFloat] = [:],
        monitorId: Monitor.ID? = nil
    ) -> OverviewLayout {
        let context = geometry
        var layout = OverviewLayout()
        layout.scale = scale
        layout.searchBarFrame = context.searchBarFrame
        layout.viewportFrame = context.screenFrame

        let windowsByWorkspace = Self.indexWindows(windows, workspaceCount: workspaces.count)

        var sections: [OverviewWorkspaceSection] = []
        sections.reserveCapacity(workspaces.count)
        var currentY = context.initialContentY

        for workspace in workspaces {
            guard let workspaceWindows = windowsByWorkspace[workspace.id], !workspaceWindows.isEmpty else {
                sections.append(context.buildEmptyWorkspaceSection(workspace: workspace, currentY: &currentY))
                continue
            }
            if let snapshot = niriSnapshotsByWorkspace[workspace.id],
               let projection = context.buildNiriWorkspaceProjection(
                   workspace: workspace,
                   snapshot: snapshot,
                   windows: workspaceWindows,
                   searchQuery: searchQuery,
                   currentY: &currentY
               )
            {
                sections.append(projection.section)
                layout.niriColumnsByWorkspace[workspace.id] = projection.columns
                layout.niriColumnDropZonesByWorkspace[workspace.id] = projection.columnDropZones
            } else if let section = context.buildGenericWorkspaceSection(
                workspace: workspace,
                windows: workspaceWindows,
                dwindleGroups: dwindleGroupsByWorkspace[workspace.id] ?? [],
                searchQuery: searchQuery,
                currentY: &currentY
            ) {
                sections.append(section)
                layout.dwindleGroupsByWorkspace[workspace.id] = dwindleGroupsByWorkspace[workspace.id]
            }
        }

        if let monitorId {
            let frame = context.ribbonFrame(for: context.visibleFrame(top: currentY, scale: context.stripScale))
            layout.newWorkspaceTarget = OverviewNewWorkspaceTarget(monitorId: monitorId, frame: frame)
            currentY = frame.minY - context.scaledWorkspaceSectionPadding
        }
        layout.replaceWorkspaceSections(sections)
        layout.totalContentHeight = context.totalContentHeight(currentY: currentY)
        for (workspaceId, pan) in stripPans {
            layout.restoreStripPan(workspaceId, to: pan)
        }
        layout.refreshOverflow()
        return layout
    }

    static func dragAutoScrollVelocity(
        pointerY: CGFloat,
        viewportFrame: CGRect,
        scale _: CGFloat
    ) -> CGFloat {
        let band = OverviewLayoutMetrics.dragAutoScrollBand
        guard band > 0, viewportFrame.height > band * 2 else { return 0 }
        let maximumSpeed: CGFloat = 1_400
        if pointerY > viewportFrame.maxY - band {
            let depth = min(1, (pointerY - (viewportFrame.maxY - band)) / band)
            return depth * maximumSpeed
        }
        if pointerY < viewportFrame.minY + band {
            let depth = min(1, ((viewportFrame.minY + band) - pointerY) / band)
            return -depth * maximumSpeed
        }
        return 0
    }

    private static func indexWindows(
        _ windows: [WindowHandle: OverviewWindowLayoutData],
        workspaceCount: Int
    ) -> [WorkspaceDescriptor.ID: [(WindowHandle, OverviewWindowLayoutData)]] {
        var windowsByWorkspace: [WorkspaceDescriptor.ID: [(WindowHandle, OverviewWindowLayoutData)]] = [:]
        windowsByWorkspace.reserveCapacity(workspaceCount)
        for (handle, windowData) in windows {
            windowsByWorkspace[windowData.workspaceId, default: []].append((handle, windowData))
        }
        return windowsByWorkspace
    }

    static func scrollOffsetBounds(layout: OverviewLayout, screenFrame: CGRect) -> ClosedRange<CGFloat> {
        let metricsScale = clampedScale(layout.scale)
        let contentTop = layout.searchBarFrame.minY - OverviewLayoutMetrics.contentTopPadding * metricsScale
        let contentBottom = contentTop - layout.totalContentHeight
        let minOffset = min(0, contentBottom - screenFrame.minY)
        return minOffset ... 0
    }

    static func clampedScrollOffset(
        _ scrollOffset: CGFloat,
        layout: OverviewLayout,
        screenFrame: CGRect
    ) -> CGFloat {
        scrollOffset.clamped(to: scrollOffsetBounds(layout: layout, screenFrame: screenFrame))
    }

    static func visibleContentFrame(
        layout: OverviewLayout,
        screenFrame: CGRect,
        scrollOffset: CGFloat? = nil
    ) -> CGRect {
        let metricsScale = clampedScale(layout.scale)
        let contentTop = layout.searchBarFrame.minY - OverviewLayoutMetrics.contentTopPadding * metricsScale
        let offset = scrollOffset ?? layout.scrollOffset
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY + offset,
            width: screenFrame.width,
            height: max(0, contentTop - screenFrame.minY)
        )
    }

    static func scrollOffsetRevealing(
        targetFrame: CGRect,
        currentOffset: CGFloat,
        layout: OverviewLayout,
        screenFrame: CGRect
    ) -> CGFloat {
        let currentOffset = clampedScrollOffset(
            currentOffset,
            layout: layout,
            screenFrame: screenFrame
        )
        let viewport = visibleContentFrame(
            layout: layout,
            screenFrame: screenFrame,
            scrollOffset: currentOffset
        )
        guard viewport.height > 0 else { return currentOffset }

        let targetFrame = targetFrame.standardized
        let padding = min(
            OverviewLayoutMetrics.windowSpacing * clampedScale(layout.scale),
            max(0, (viewport.height - targetFrame.height) / 2)
        )
        let paddedViewport = viewport.insetBy(dx: 0, dy: padding)

        if targetFrame.minY >= paddedViewport.minY,
           targetFrame.maxY <= paddedViewport.maxY
        {
            return currentOffset
        }

        let nextOffset: CGFloat
        if targetFrame.height >= viewport.height {
            nextOffset = targetFrame.maxY - viewport.maxY + currentOffset
        } else {
            let alignTop = targetFrame.maxY - paddedViewport.maxY + currentOffset
            let alignBottom = targetFrame.minY - paddedViewport.minY + currentOffset
            nextOffset = abs(alignTop - currentOffset) <= abs(alignBottom - currentOffset)
                ? alignTop
                : alignBottom
        }

        return clampedScrollOffset(
            nextOffset,
            layout: layout,
            screenFrame: screenFrame
        )
    }
}
