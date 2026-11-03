// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func desiredTabRailInfos() -> [TabRailInfo] {
        guard let controller, let engine = controller.dwindleEngine else { return [] }

        var infos: [TabRailInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
                  controller.workspaceManager.activeLayoutKind(for: workspace.id) == .dwindle
            else {
                continue
            }

            let presentationTime = controller.animationClock.now()
            let scale = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor).scale
            for snapshot in engine.groupedTileSnapshots(in: workspace.id) {
                let presentedFrame = presentedTileFrame(
                    geometry: .init(
                        id: snapshot.id,
                        activeToken: snapshot.activeToken,
                        tileFrame: snapshot.tileFrame,
                        contentFrame: snapshot.contentFrame
                    ),
                    engine: engine,
                    workspaceId: workspace.id,
                    at: presentationTime,
                    scale: scale
                )
                let frame = presentedFrame ?? snapshot.tileFrame ?? .zero
                let visibleFrame = presentedFrame?.intersection(monitor.visibleFrame) ?? .null

                let tabs = tabInfos(for: snapshot, controller: controller)

                infos.append(
                    TabRailInfo(
                        workspaceId: workspace.id,
                        owner: .dwindleTile(snapshot.id),
                        plannedSeq: controller.workspaceManager.worldSeq,
                        tileFrame: frame,
                        visibleTileFrame: visibleFrame,
                        tabCount: tabs.count,
                        activeVisualIndex: snapshot.activeIndex,
                        activeWindowId: controller.workspaceManager.entry(for: snapshot.activeToken)?.windowId,
                        tabs: tabs
                    )
                )
            }
        }
        return infos
    }

    private func tabInfos(for snapshot: DwindleTileSnapshot, controller: WMController) -> [TabRailTabInfo] {
        var tabs: [TabRailTabInfo] = []
        tabs.reserveCapacity(snapshot.members.count)
        for (index, member) in snapshot.members.enumerated() {
            let entry = controller.workspaceManager.entry(for: member.token)
            let presentation = entry.map { entry in
                controller.appInfoCache.presentation(
                    for: entry,
                    title: entry.managedReplacementMetadata?.title ?? UInt32(exactly: entry.windowId).flatMap {
                        AXWindowService.titlePreferFast(windowId: $0)
                    },
                    cachedProcessOnly: true
                )
            }
            tabs.append(
                TabRailTabInfo(
                    visualIndex: index,
                    token: member.token,
                    windowId: entry?.windowId,
                    appName: presentation?.name,
                    title: presentation?.title,
                    isActive: index == snapshot.activeIndex,
                    icon: presentation?.icon
                )
            )
        }

        return tabs
    }

    func dwindleTabRailGeometryCommands(
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: LayoutMonitorSnapshot,
        targetTime: TimeInterval
    ) -> [TabRailGeometryCommand] {
        var commands: [TabRailGeometryCommand] = []
        engine.forEachGroupedTileGeometry(in: workspaceId) { geometry in
            let key = TabRailKey(workspaceId: workspaceId, owner: .dwindleTile(geometry.id))
            guard let frame = presentedTileFrame(
                geometry: geometry,
                engine: engine,
                workspaceId: workspaceId,
                at: targetTime,
                scale: monitor.scale
            ) else {
                commands.append(
                    TabRailGeometryCommand(
                        key: key,
                        tileFrame: .zero,
                        visibleTileFrame: .null
                    )
                )
                return
            }
            commands.append(
                TabRailGeometryCommand(
                    key: key,
                    tileFrame: frame,
                    visibleTileFrame: frame.intersection(monitor.visibleFrame)
                )
            )
        }
        return commands
    }

    func presentedTileFrame(
        geometry: DwindleGroupedTileGeometry,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        at targetTime: TimeInterval,
        scale: CGFloat
    ) -> CGRect? {
        guard let tileFrame = geometry.tileFrame,
              let contentFrame = geometry.contentFrame,
              let presentedContentFrame = engine.presentedFrame(
                  for: geometry.activeToken,
                  in: workspaceId,
                  at: targetTime
              )
        else {
            return nil
        }
        let left = max(0, contentFrame.minX - tileFrame.minX)
        let right = max(0, tileFrame.maxX - contentFrame.maxX)
        let bottom = max(0, contentFrame.minY - tileFrame.minY)
        let top = max(0, tileFrame.maxY - contentFrame.maxY)
        let frame = CGRect(
            x: presentedContentFrame.minX - left,
            y: presentedContentFrame.minY - bottom,
            width: presentedContentFrame.width + left + right,
            height: presentedContentFrame.height + bottom + top
        ).roundedToPhysicalPixels(scale: max(scale, 1))
        guard !frame.isNull,
              !frame.isInfinite,
              frame.width > 0,
              frame.height > 0
        else {
            return nil
        }
        return frame
    }
}
