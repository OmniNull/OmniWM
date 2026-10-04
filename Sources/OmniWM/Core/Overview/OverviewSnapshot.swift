// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore

@MainActor
final class OverviewSnapshot {
    private weak var wmController: WMController?
    private let facts: OverviewWindowFacts
    private(set) var workspaces: [OverviewWorkspaceLayoutItem] = []
    private(set) var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
    private(set) var niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
    private(set) var dwindleGroupsByWorkspace: [WorkspaceDescriptor.ID: [OverviewDwindleGroup]] = [:]

    init(wmController: WMController, facts: OverviewWindowFacts) {
        self.wmController = wmController
        self.facts = facts
    }

    var windowIds: [Int] {
        windows.values.map(\.token.windowId).sorted()
    }

    func reset() {
        workspaces = []
        windows = [:]
        niriSnapshotsByWorkspace = [:]
        dwindleGroupsByWorkspace = [:]
    }

    func remove(_ handle: WindowHandle) -> OverviewWindowLayoutData? {
        windows.removeValue(forKey: handle)
    }

    func refresh(affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>, settledNiriFrames: Bool = false) {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager
        refreshWorkspaces(affectedWorkspaceIds: affectedWorkspaceIds, workspaceManager: workspaceManager)
        let projections = refreshEngineProjections(
            affectedWorkspaceIds: affectedWorkspaceIds,
            wmController: wmController,
            settledNiriFrames: settledNiriFrames
        )
        refreshCachedWindows(engineFrames: projections.frames)
        for workspaceId in projections.niriWorkspaceIds {
            reconcileNiriOverviewProjection(
                workspaceId: workspaceId,
                frames: projections.frames
            )
        }

        for (workspaceId, projection) in projections.dwindleProjections {
            reconcileDwindleOverviewProjection(
                projection,
                workspaceId: workspaceId
            )
        }
    }

    private func refreshWorkspaces(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        workspaceManager: WorkspaceManager
    ) {
        guard let wmController else { return }
        var workspaces: [OverviewWorkspaceLayoutItem] = []
        for monitor in workspaceManager.monitors {
            let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id
            for workspace in displayedWorkspaces(
                on: monitor,
                activeWorkspaceId: activeWorkspaceId,
                workspaceManager: workspaceManager
            ) {
                workspaces.append(OverviewWorkspaceLayoutItem(
                    id: workspace.id,
                    name: wmController.settings.workspaces.displayName(for: workspace.name),
                    isActive: workspace.id == activeWorkspaceId,
                    displayId: monitor.displayId
                ))
            }
        }
        self.workspaces = workspaces

        let workspaceIds = Set(workspaces.map(\.id))
        dwindleGroupsByWorkspace = dwindleGroupsByWorkspace.filter {
            workspaceIds.contains($0.key) && !affectedWorkspaceIds.contains($0.key)
                && workspaceManager.activeLayoutKind(for: $0.key) == .dwindle
        }
    }

    private struct EngineProjections {
        var frames: [WindowToken: CGRect]
        var niriWorkspaceIds: Set<WorkspaceDescriptor.ID>
        var dwindleProjections: [WorkspaceDescriptor.ID: DwindleOverviewWorkspaceProjection]
    }

    private func refreshEngineProjections(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        wmController: WMController,
        settledNiriFrames: Bool
    ) -> EngineProjections {
        let workspaceManager = wmController.workspaceManager
        var engineFrames: [WindowToken: CGRect] = [:]
        var niriWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var dwindleProjections: [WorkspaceDescriptor.ID: DwindleOverviewWorkspaceProjection] = [:]
        for workspaceId in affectedWorkspaceIds {
            switch workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                niriWorkspaceIds.insert(workspaceId)
                let frames = (settledNiriFrames ? wmController.niriLayoutHandler.settledFrames(in: workspaceId) : nil)
                    ?? wmController.niriEngine?.captureWindowFrames(in: workspaceId)
                if let frames {
                    engineFrames.merge(frames) { _, new in new }
                }
                if let snapshot = wmController.niriLayoutHandler.overviewSnapshot(for: workspaceId),
                   let filteredSnapshot = facts.cachedNiriSnapshot(snapshot)
                {
                    niriSnapshotsByWorkspace[workspaceId] = filteredSnapshot
                } else {
                    niriSnapshotsByWorkspace.removeValue(forKey: workspaceId)
                }
            case .dwindle:
                if let projection = dwindleOverviewProjection(for: workspaceId) {
                    dwindleProjections[workspaceId] = projection
                    engineFrames.merge(projection.frames) { _, new in new }
                }
                niriSnapshotsByWorkspace.removeValue(forKey: workspaceId)
            }
        }

        return EngineProjections(
            frames: engineFrames,
            niriWorkspaceIds: niriWorkspaceIds,
            dwindleProjections: dwindleProjections
        )
    }

    private func refreshCachedWindows(engineFrames: [WindowToken: CGRect]) {
        var staleHandles: [WindowHandle] = []
        for (handle, data) in windows {
            guard let entry = facts.visibleManagedEntry(for: handle) else {
                staleHandles.append(handle)
                continue
            }
            let frame = engineFrames[entry.token] ?? data.frame
            if entry.token != data.token || entry.workspaceId != data.workspaceId || frame != data.frame || data
                .floatingPreviewFrame != facts.floatingPreviewFrame(for: entry)
            {
                windows[handle] = OverviewWindowLayoutData(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    title: data.title,
                    appName: data.appName,
                    appIcon: data.appIcon,
                    frame: frame,
                    isNativeFullscreen: data.isNativeFullscreen,
                    floatingPreviewFrame: facts.floatingPreviewFrame(for: entry)
                )
            }
        }
        for handle in staleHandles {
            windows.removeValue(forKey: handle)
        }
    }

    func build() {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager

        var workspaces: [OverviewWorkspaceLayoutItem] = []
        var windowData: [WindowHandle: OverviewWindowLayoutData] = [:]
        var dwindleGroupsByWorkspace: [WorkspaceDescriptor.ID: [OverviewDwindleGroup]] = [:]

        for monitor in workspaceManager.monitors {
            let activeWs = workspaceManager.activeWorkspace(on: monitor.id)

            for ws in displayedWorkspaces(
                on: monitor,
                activeWorkspaceId: activeWs?.id,
                workspaceManager: workspaceManager
            ) {
                workspaces.append(OverviewWorkspaceLayoutItem(
                    id: ws.id,
                    name: wmController.settings.workspaces.displayName(for: ws.name),
                    isActive: ws.id == activeWs?.id,
                    displayId: monitor.displayId
                ))

                let dwindleProjection = dwindleOverviewProjection(for: ws.id)

                for entry in workspaceManager.entries(in: ws.id) {
                    guard facts.isOverviewEligible(entry, workspaceManager: workspaceManager),
                          dwindleProjection?.includes(entry.token) != false,
                          let handle = workspaceManager.handle(for: entry.token)
                    else {
                        continue
                    }

                    windowData[handle] = facts.makeOverviewWindowData(
                        for: entry,
                        preferredFrame: dwindleProjection?.frames[entry.token],
                        appInfoCache: wmController.appInfoCache
                    )
                }
                if let dwindleProjection, !dwindleProjection.groups.isEmpty {
                    dwindleGroupsByWorkspace[ws.id] = overviewGroups(
                        dwindleProjection,
                        workspaceManager: workspaceManager
                    )
                }
            }
        }

        self.workspaces = workspaces
        windows = windowData
        self.dwindleGroupsByWorkspace = dwindleGroupsByWorkspace
        niriSnapshotsByWorkspace = buildNiriOverviewSnapshots()
    }

    private func displayedWorkspaces(
        on monitor: Monitor,
        activeWorkspaceId: WorkspaceDescriptor.ID?,
        workspaceManager: WorkspaceManager
    ) -> [WorkspaceDescriptor] {
        let workspaces = workspaceManager.workspaces(on: monitor.id)
        guard wmController?.settings.workspaceBar.resolved(for: monitor).hideEmptyWorkspaces == true else {
            return workspaces
        }
        return workspaces.filter { $0.id == activeWorkspaceId || workspaceManager.isOccupied($0.id) }
    }
}

extension OverviewSnapshot {
    private func overviewGroups(
        _ projection: DwindleOverviewWorkspaceProjection,
        workspaceManager: WorkspaceManager
    ) -> [OverviewDwindleGroup] {
        projection.groups.compactMap { group in
            let handles = group.tokens.compactMap { workspaceManager.handle(for: $0) }
            guard handles.count > 1, let activeHandle = handles.first(where: { $0.id == group.activeToken }) else {
                return nil
            }
            return OverviewDwindleGroup(id: group.id, windowHandles: handles, activeHandle: activeHandle)
        }
    }

    private func dwindleOverviewProjection(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleOverviewWorkspaceProjection? {
        guard let wmController,
              wmController.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let engine = wmController.dwindleEngine
        else {
            return nil
        }
        let eligibleTokens = Set(
            wmController.workspaceManager.entries(in: workspaceId).lazy
                .filter { self.facts.isOverviewEligible($0, workspaceManager: wmController.workspaceManager) }
                .map(\.token)
        )
        return DwindleOverviewWorkspaceProjection(
            engine: engine,
            workspaceId: workspaceId,
            eligibleTokens: eligibleTokens
        )
    }

    private func reconcileDwindleOverviewProjection(
        _ projection: DwindleOverviewWorkspaceProjection,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager
        var desiredHandles: Set<WindowHandle> = []

        for entry in workspaceManager.entries(in: workspaceId) {
            guard facts.isOverviewEligible(entry, workspaceManager: workspaceManager),
                  projection.includes(entry.token),
                  let handle = workspaceManager.handle(for: entry.token)
            else {
                continue
            }

            desiredHandles.insert(handle)
            let frame = projection.frames[entry.token]
                ?? windows[handle]?.frame
                ?? facts.windowFrame(entry)
                ?? .zero
            if let data = windows[handle] {
                if data.token != entry.token || data.workspaceId != workspaceId || data.frame != frame || data
                    .floatingPreviewFrame != facts.floatingPreviewFrame(for: entry)
                {
                    windows[handle] = OverviewWindowLayoutData(
                        token: entry.token,
                        workspaceId: workspaceId,
                        title: data.title,
                        appName: data.appName,
                        appIcon: data.appIcon,
                        frame: frame,
                        isNativeFullscreen: data.isNativeFullscreen,
                        floatingPreviewFrame: facts.floatingPreviewFrame(for: entry)
                    )
                }
            } else {
                windows[handle] = facts.makeOverviewWindowData(
                    for: entry,
                    preferredFrame: frame,
                    appInfoCache: wmController.appInfoCache
                )
            }
        }

        if !projection.groups.isEmpty {
            dwindleGroupsByWorkspace[workspaceId] = overviewGroups(projection, workspaceManager: workspaceManager)
        }

        let staleHandles = windows.compactMap { handle, data in
            data.workspaceId == workspaceId && !desiredHandles.contains(handle) ? handle : nil
        }
        for handle in staleHandles {
            windows.removeValue(forKey: handle)
        }
    }

    private func reconcileNiriOverviewProjection(
        workspaceId: WorkspaceDescriptor.ID,
        frames: [WindowToken: CGRect]
    ) {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager
        var desiredHandles: Set<WindowHandle> = []

        for entry in workspaceManager.entries(in: workspaceId) {
            guard facts.isOverviewEligible(entry, workspaceManager: workspaceManager),
                  let handle = workspaceManager.handle(for: entry.token)
            else {
                continue
            }

            desiredHandles.insert(handle)
            let frame = frames[entry.token]
                ?? windows[handle]?.frame
                ?? facts.windowFrame(entry)
                ?? .zero
            if let data = windows[handle] {
                if data.token != entry.token || data.workspaceId != workspaceId || data.frame != frame || data
                    .floatingPreviewFrame != facts.floatingPreviewFrame(for: entry)
                {
                    windows[handle] = OverviewWindowLayoutData(
                        token: entry.token,
                        workspaceId: workspaceId,
                        title: data.title,
                        appName: data.appName,
                        appIcon: data.appIcon,
                        frame: frame,
                        isNativeFullscreen: data.isNativeFullscreen,
                        floatingPreviewFrame: facts.floatingPreviewFrame(for: entry)
                    )
                }
            } else {
                windows[handle] = facts.makeOverviewWindowData(
                    for: entry,
                    preferredFrame: frame,
                    appInfoCache: wmController.appInfoCache
                )
            }
        }

        let staleHandles = windows.compactMap { handle, data in
            data.workspaceId == workspaceId && !desiredHandles.contains(handle) ? handle : nil
        }
        for handle in staleHandles {
            windows.removeValue(forKey: handle)
        }
    }

    private func buildNiriOverviewSnapshots() -> [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] {
        guard let wmController, wmController.niriEngine != nil else { return [:] }

        var snapshots: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
        snapshots.reserveCapacity(workspaces.count)

        for workspace in workspaces {
            guard facts.isNiriLayout(workspaceId: workspace.id),
                  let snapshot = wmController.niriLayoutHandler.overviewSnapshot(for: workspace.id),
                  let filteredSnapshot = facts.cachedNiriSnapshot(snapshot)
            else {
                continue
            }
            snapshots[workspace.id] = filteredSnapshot
        }

        return snapshots
    }
}
