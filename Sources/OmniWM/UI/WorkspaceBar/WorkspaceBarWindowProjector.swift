// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
struct WorkspaceBarWindowProjector {
    private let workspaceManager: WorkspaceManager
    private let appInfoCache: AppInfoCache
    private let iconResolver: WorkspaceBarIconResolver

    init(
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver
    ) {
        self.workspaceManager = workspaceManager
        self.appInfoCache = appInfoCache
        self.iconResolver = iconResolver
    }

    private enum AppGroupKey: Hashable {
        case hosted(String)
        case bundleId(String)
        case pid(pid_t)
    }

    func isExcluded(
        _ entry: WindowState,
        options: WorkspaceBarProjectionOptions
    ) -> Bool {
        guard !options.excludedBundleIDs.isEmpty else { return false }
        return options.excludes(bundleId: bundleId(for: entry))
    }

    enum Grouping {
        case individual
        case byApp(keepsLayoutOrder: Bool)
    }

    func items(
        entries: [WindowState],
        order: [Int],
        grouping: Grouping,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> [WorkspaceBarWindowItem] {
        switch grouping {
        case let .byApp(keepsLayoutOrder):
            createDedupedWindowItems(
                entries: entries,
                order: order,
                useLayoutOrder: keepsLayoutOrder,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs
            )
        case .individual:
            createIndividualWindowItems(
                entries: entries,
                order: order,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs
            )
        }
    }

    private func createDedupedWindowItems(
        entries: [WindowState],
        order: [Int],
        useLayoutOrder: Bool,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> [WorkspaceBarWindowItem] {
        var indicesByApp: [AppGroupKey: [Int]] = [:]
        var appOrder: [AppGroupKey] = []
        indicesByApp.reserveCapacity(order.count)
        appOrder.reserveCapacity(order.count)

        for index in order {
            let groupKey = appGroupKey(for: entries[index])
            if indicesByApp[groupKey] == nil {
                indicesByApp[groupKey] = []
                appOrder.append(groupKey)
            }
            indicesByApp[groupKey]?.append(index)
        }

        let indexedItems = appOrder.enumerated().compactMap { position, groupKey -> (Int, WorkspaceBarWindowItem)? in
            guard let appIndices = indicesByApp[groupKey],
                  let item = createDeduplicatedWindowItem(
                      entries: entries,
                      indices: appIndices,
                      focusedToken: focusedToken,
                      hiddenAppPIDs: hiddenAppPIDs
                  )
            else {
                return nil
            }
            return (position, item)
        }

        if useLayoutOrder {
            return indexedItems.map(\.1)
        }

        return indexedItems.sorted {
            if $0.1.isAppHidden != $1.1.isAppHidden {
                return !$0.1.isAppHidden
            }
            if $0.1.appName != $1.1.appName {
                return $0.1.appName < $1.1.appName
            }
            return $0.0 < $1.0
        }.map(\.1)
    }

    private func createDeduplicatedWindowItem(
        entries: [WindowState],
        indices: [Int],
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> WorkspaceBarWindowItem? {
        guard let firstIndex = indices.first,
              let firstHandle = workspaceManager.handle(for: entries[firstIndex].token)
        else {
            return nil
        }
        let appIndex = indices.first { appInfoCache.info(for: entries[$0].pid) != nil } ?? firstIndex
        let presentation = appInfoCache.presentation(for: entries[appIndex])
        let appName = presentation.name ?? String(localized: "Unknown")
        let windowInfos = indices.compactMap { index -> WorkspaceBarWindowInfo? in
            let token = entries[index].token
            guard let handle = workspaceManager.handle(for: token) else { return nil }
            return WorkspaceBarWindowInfo(
                id: token,
                handle: handle,
                windowId: token.windowId,
                title: windowTitle(for: entries[index]) ?? appName,
                isFocused: token == focusedToken,
                isAppHidden: hiddenAppPIDs.contains(token.pid)
            )
        }

        return WorkspaceBarWindowItem(
            id: entries[firstIndex].token,
            handle: firstHandle,
            windowId: entries[firstIndex].windowId,
            appName: appName,
            bundleId: bundleId(for: entries[firstIndex]),
            icon: icon(
                for: entries[firstIndex],
                fallback: presentation.icon,
                processPid: entries[appIndex].pid
            ),
            isFocused: indices.contains { entries[$0].token == focusedToken },
            windowCount: windowInfos.count,
            hiddenWindowCount: windowInfos.count { $0.isAppHidden },
            allWindows: windowInfos
        )
    }

    private func createIndividualWindowItems(
        entries: [WindowState],
        order: [Int],
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> [WorkspaceBarWindowItem] {
        order.compactMap { index -> WorkspaceBarWindowItem? in
            let token = entries[index].token
            guard let handle = workspaceManager.handle(for: token) else { return nil }
            let presentation = appInfoCache.presentation(for: entries[index])
            let appName = presentation.name ?? String(localized: "Unknown")
            let title = windowTitle(for: entries[index]) ?? appName

            return WorkspaceBarWindowItem(
                id: token,
                handle: handle,
                windowId: token.windowId,
                appName: appName,
                bundleId: bundleId(for: entries[index]),
                icon: icon(
                    for: entries[index],
                    fallback: presentation.icon,
                    processPid: token.pid
                ),
                isFocused: token == focusedToken,
                windowCount: 1,
                hiddenWindowCount: hiddenAppPIDs.contains(token.pid) ? 1 : 0,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: token,
                        handle: handle,
                        windowId: token.windowId,
                        title: title,
                        isFocused: token == focusedToken,
                        isAppHidden: hiddenAppPIDs.contains(token.pid)
                    )
                ]
            )
        }
    }

    private func icon(
        for entry: WindowState,
        fallback: NSImage?,
        processPid: pid_t
    ) -> NSImage? {
        guard iconResolver.hasOverrides else { return fallback }
        if let bundleId = normalizedBundleId(entry.managedReplacementMetadata?.bundleId)
            ?? normalizedBundleId(appInfoCache.bundleId(for: processPid)),
           let override = iconResolver.image(for: bundleId)
        {
            return override
        }
        return fallback
    }

    private func appGroupKey(
        for entry: WindowState
    ) -> AppGroupKey {
        if let hosted = entry.target.hostedMetadata { return .hosted(hosted.appId) }
        if let bundleId = bundleId(for: entry) {
            return .bundleId(bundleId.lowercased())
        }
        return .pid(entry.pid)
    }

    private func bundleId(
        for entry: WindowState
    ) -> String? {
        normalizedBundleId(entry.managedReplacementMetadata?.bundleId)
            ?? normalizedBundleId(appInfoCache.bundleId(for: entry.pid))
    }

    private func normalizedBundleId(_ bundleId: String?) -> String? {
        guard let trimmed = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func windowTitle(for entry: WindowState) -> String? {
        guard let title = entry.target.hostedMetadata?.title
            ?? AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
            !title.isEmpty
        else { return nil }
        return title
    }
}
