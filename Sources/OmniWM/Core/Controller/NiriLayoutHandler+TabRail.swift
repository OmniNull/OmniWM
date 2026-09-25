// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func desiredTabRailInfos() -> [TabRailInfo] {
        guard let controller, let engine = controller.niriEngine else { return [] }

        var infos: [TabRailInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
                  controller.workspaceManager.activeLayoutKind(for: workspace.id) == .niri
            else { continue }

            infos.append(contentsOf: niriTabRailInfos(
                engine: engine,
                workspaceId: workspace.id,
                monitor: monitor
            ))
        }
        return infos
    }

    func niriTabRailGeometryCommands(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: LayoutMonitorSnapshot
    ) -> [TabRailGeometryCommand] {
        var commands: [TabRailGeometryCommand] = []
        for column in engine.columns(in: workspaceId) where column.isTabbed {
            let key = TabRailKey(workspaceId: workspaceId, owner: .niriColumn(column.id))
            guard let frame = column.renderedFrame,
                  !frame.isNull,
                  !frame.isInfinite,
                  frame.width > 0,
                  frame.height > 0
            else {
                commands.append(
                    TabRailGeometryCommand(
                        key: key,
                        tileFrame: .zero,
                        visibleTileFrame: .null
                    )
                )
                continue
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

    private func niriTabRailInfos(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) -> [TabRailInfo] {
        guard let controller else { return [] }
        var infos: [TabRailInfo] = []
        for column in engine.columns(in: workspaceId) where column.isTabbed {
            let windows = engine.projectedWindows(in: column, workspaceId: workspaceId)
            guard windows.count > 1 else { continue }

            guard let activeWindow = engine.projectedActiveWindow(
                in: column,
                workspaceId: workspaceId
            ) else { continue }
            let activeWindowId = controller.workspaceManager.entry(for: activeWindow.token)?.windowId
            guard let activeStorageIndex = windows.firstIndex(where: { $0 === activeWindow }) else { continue }
            let activeVisualIndex = windows.count - 1 - activeStorageIndex
            let tabs = tabbedColumnTabs(
                windows: windows,
                activeVisualIndex: activeVisualIndex,
                controller: controller
            )
            let candidateFrame = column.renderedFrame ?? column.frame
            let frame = candidateFrame.map {
                !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 ? $0 : .zero
            } ?? .zero
            let visibleColumnFrame = frame == .zero ? CGRect.null : frame.intersection(monitor.visibleFrame)

            infos.append(
                TabRailInfo(
                    workspaceId: workspaceId,
                    owner: .niriColumn(column.id),
                    plannedSeq: controller.workspaceManager.worldSeq,
                    tileFrame: frame,
                    visibleTileFrame: visibleColumnFrame,
                    tabCount: windows.count,
                    activeVisualIndex: activeVisualIndex,
                    activeWindowId: activeWindowId,
                    tabs: tabs
                )
            )
        }
        return infos
    }

    private func tabbedColumnTabs(
        windows: [NiriWindow],
        activeVisualIndex: Int,
        controller: WMController
    ) -> [TabRailTabInfo] {
        guard !windows.isEmpty else { return [] }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), windows.count - 1)
        var tabs: [TabRailTabInfo] = []
        tabs.reserveCapacity(windows.count)
        for visualIndex in 0 ..< windows.count {
            let storageIndex = windows.count - 1 - visualIndex
            let window = windows[storageIndex]
            let entry = controller.workspaceManager.entry(for: window.token)
            let appName: String?
            if let entry, controller.appInfoCache.hasCachedInfo(for: entry.pid) {
                appName = controller.appInfoCache.name(for: entry.pid)
            } else {
                appName = nil
            }
            let title = entry?.managedReplacementMetadata?.title
                ?? entry.flatMap { entry in
                    UInt32(exactly: entry.windowId).flatMap {
                        AXWindowService.titlePreferFast(windowId: $0)
                    }
                }
            tabs.append(
                TabRailTabInfo(
                    visualIndex: visualIndex,
                    token: window.token,
                    windowId: entry?.windowId,
                    appName: appName,
                    title: title,
                    isActive: visualIndex == clampedActiveVisualIndex
                )
            )
        }
        return tabs
    }

    func selectTabInNiri(
        info: TabRailInfo,
        visualIndex: Int,
        expectedToken: WindowToken?
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        guard let selection = tabSelection(
            info: info,
            visualIndex: visualIndex,
            expectedToken: expectedToken,
            controller: controller,
            engine: engine
        ) else { return }
        let workspaceId = info.workspaceId
        let column = selection.column
        let target = selection.target
        let storageIndex = selection.storageIndex

        let activeTileChanged = column.activeTileIdx != storageIndex
        controller.workspaceManager.withEngineMutationScope {
            column.setActiveTileIdx(storageIndex)
            engine.updateTabbedColumnVisibility(column: column)
        }
        if activeTileChanged {
            recordLayoutOperation(.tabActivated(token: target.token), in: workspaceId, source: .mouse)
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        revealSelectedTab(target, workspaceId: workspaceId, engine: engine, controller: controller, state: &state)
        activateNode(
            target, in: workspaceId, state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                focusOrigin: .pointerSelection,
                startAnimation: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        if controller.workspaceManager.animationDriver.hasMotion(in: workspaceId)
            || engine.hasAnyWindowAnimationsRunning(in: workspaceId)
        {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    private struct TabSelection {
        let column: NiriContainer
        let target: NiriWindow
        let storageIndex: Int
    }

    private func tabSelection(
        info: TabRailInfo,
        visualIndex: Int,
        expectedToken: WindowToken?,
        controller: WMController,
        engine: NiriLayoutEngine
    ) -> TabSelection? {
        guard case let .niriColumn(columnId) = info.owner else { return nil }
        let workspaceId = info.workspaceId
        guard controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri else { return nil }
        guard controller.workspaceManager.isSeqCurrent(
            info.plannedSeq,
            for: workspaceId,
            domains: .layoutCommit
        ) else {
            return nil
        }
        guard let column = engine.columns(in: workspaceId).first(where: { $0.id == columnId }) else { return nil }

        let windows = engine.projectedWindows(in: column, workspaceId: workspaceId)
        let target: NiriWindow
        if let expectedToken {
            guard let expectedWindow = windows.first(where: { $0.token == expectedToken }) else { return nil }
            target = expectedWindow
        } else {
            let storageIndex = windows.count - 1 - visualIndex
            guard windows.indices.contains(storageIndex) else { return nil }
            target = windows[storageIndex]
        }
        guard let storageIndex = column.windowNodes.firstIndex(where: { $0 === target }) else { return nil }

        return TabSelection(column: column, target: target, storageIndex: storageIndex)
    }

    private func revealSelectedTab(
        _ target: NiriWindow,
        workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        controller: WMController,
        state: inout ViewportState
    ) {
        controller.workspaceManager.withEngineMutationScope {
            if let monitor = controller.workspaceManager.monitor(for: workspaceId) {
                let gap = controller.innerGap(for: monitor)
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                engine.ensureSelectionVisible(
                    node: target,
                    context: .init(
                        workspaceId: workspaceId,
                        motion: controller.motionPolicy.snapshot(),
                        workingFrame: workingFrame,
                        gaps: gap,
                        orientation: resolvedOrientation(
                            for: workspaceId,
                            monitor: monitor,
                            engine: engine
                        )
                    ),
                    state: &state
                )
            }
        }
    }
}
