// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
struct WorkspaceBarDataSource {
    private let workspaceManager: WorkspaceManager
    private let windowProjector: WorkspaceBarWindowProjector
    private let settings: SettingsStore

    init(
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        settings: SettingsStore
    ) {
        self.workspaceManager = workspaceManager
        self.windowProjector = WorkspaceBarWindowProjector(
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            iconResolver: iconResolver
        )
        self.settings = settings
    }

    private struct WorkspaceSnapshot {
        let workspace: WorkspaceDescriptor
        let entries: [WindowState]
        let tiled: [Int]
        let floating: [Int]

        var hasBarOccupancy: Bool {
            !tiled.isEmpty || !floating.isEmpty
        }
    }

    func workspaceBarProjection(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        focusedToken: WindowToken?
    ) -> WorkspaceBarProjection {
        WorkspaceBarProjection(
            items: workspaceItems(
                for: monitor,
                options: options,
                focusedToken: focusedToken
            ),
            scratchpads: scratchpadItems(
                options: options,
                focusedToken: focusedToken
            )
        )
    }

    private func workspaceItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        focusedToken: WindowToken?
    ) -> [WorkspaceBarItem] {
        var workspaces = workspaceManager.workspaces(on: monitor.id).map { workspace in
            workspaceSnapshot(
                for: workspace,
                options: options
            )
        }

        let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id
        let hiddenAppPIDs = workspaceManager.hiddenAppPIDs

        if options.hideEmptyWorkspaces {
            workspaces = workspaces.filter { $0.hasBarOccupancy || $0.workspace.id == activeWorkspaceId }
        }

        return workspaces.map { snapshot in
            workspaceItem(
                snapshot,
                options: options,
                activeWorkspaceId: activeWorkspaceId,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs
            )
        }
    }

    private func workspaceItem(
        _ snapshot: WorkspaceSnapshot,
        options: WorkspaceBarProjectionOptions,
        activeWorkspaceId: WorkspaceDescriptor.ID?,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> WorkspaceBarItem {
        let windows = snapshot.hasBarOccupancy
            ? windowItems(snapshot, options: options, focusedToken: focusedToken, hiddenAppPIDs: hiddenAppPIDs)
            : (tiled: [], floating: [])
        return WorkspaceBarItem(
            id: snapshot.workspace.id,
            name: settings.workspaces.displayName(for: snapshot.workspace.name),
            rawName: snapshot.workspace.name,
            isFocused: snapshot.workspace.id == activeWorkspaceId,
            tiledWindows: windows.tiled,
            floatingWindows: windows.floating
        )
    }

    private func windowItems(
        _ snapshot: WorkspaceSnapshot,
        options: WorkspaceBarProjectionOptions,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> (tiled: [WorkspaceBarWindowItem], floating: [WorkspaceBarWindowItem]) {
        let topology = workspaceManager.layoutTopology(for: snapshot.workspace.id)
        let grouping: WorkspaceBarWindowProjector.Grouping = options.deduplicateAppIcons
            ? .byApp(keepsLayoutOrder: topology.hasColumns) : .individual
        let entries = snapshot.entries
        func items(_ indices: [Int]) -> [WorkspaceBarWindowItem] {
            windowProjector.items(
                entries: entries,
                order: visibilityOrdered(
                    WorkspaceEntryOrdering.orderedIndices(indices, in: entries, topology: topology),
                    in: entries,
                    hiddenAppPIDs: hiddenAppPIDs
                ),
                grouping: grouping,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs
            )
        }
        return (items(snapshot.tiled), items(snapshot.floating))
    }

    private func workspaceSnapshot(
        for workspace: WorkspaceDescriptor,
        options: WorkspaceBarProjectionOptions
    ) -> WorkspaceSnapshot {
        let entries = workspaceManager.barVisibleEntries(
            in: workspace.id,
            showFloatingWindows: options.showFloatingWindows
        )
        var tiled: [Int] = []
        var floating: [Int] = []
        for index in entries.indices where !windowProjector.isExcluded(entries[index], options: options) {
            switch entries[index].mode {
            case .tiling:
                tiled.append(index)
            case .floating:
                floating.append(index)
            }
        }
        return WorkspaceSnapshot(workspace: workspace, entries: entries, tiled: tiled, floating: floating)
    }

    private func scratchpadItems(
        options: WorkspaceBarProjectionOptions,
        focusedToken: WindowToken?
    ) -> [WorkspaceBarScratchpadItem] {
        workspaceManager.occupiedScratchpadIndices().compactMap { index in
            let entries = workspaceManager.scratchpadMembers(in: index).compactMap { token in
                workspaceManager.entry(for: token).flatMap {
                    windowProjector.isExcluded($0, options: options) ? nil : $0
                }
            }
            guard !entries.isEmpty else { return nil }

            let windows = windowProjector.items(
                entries: entries,
                order: Array(entries.indices),
                grouping: .byApp(keepsLayoutOrder: false),
                focusedToken: focusedToken,
                hiddenAppPIDs: workspaceManager.hiddenAppPIDs
            )
            guard !windows.isEmpty else { return nil }
            let isRevealed = workspaceManager.revealedScratchpadIndex() == index

            return WorkspaceBarScratchpadItem(
                index: index.rawValue,
                label: settings.scratchpadLabel(for: index.rawValue),
                windows: windows,
                isVisible: isRevealed && entries.contains {
                    workspaceManager.hiddenState(for: $0.token) == nil
                        && !workspaceManager.isAppHidden(pid: $0.pid)
                },
                isRevealed: isRevealed
            )
        }
    }

    private func visibilityOrdered(
        _ order: [Int],
        in entries: [WindowState],
        hiddenAppPIDs: Set<pid_t>
    ) -> [Int] {
        guard !hiddenAppPIDs.isEmpty else { return order }
        var visible: [Int] = []
        var hidden: [Int] = []
        visible.reserveCapacity(order.count)
        for index in order {
            if hiddenAppPIDs.contains(entries[index].pid) {
                hidden.append(index)
            } else {
                visible.append(index)
            }
        }
        visible.append(contentsOf: hidden)
        return visible
    }
}
