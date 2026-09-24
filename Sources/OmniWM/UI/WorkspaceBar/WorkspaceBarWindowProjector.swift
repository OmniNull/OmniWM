// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    func items(
        entries: [WindowState],
        deduplicate: Bool,
        useLayoutOrder: Bool,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> [WorkspaceBarWindowItem] {
        if deduplicate {
            return createDedupedWindowItems(
                entries: entries,
                useLayoutOrder: useLayoutOrder,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs
            )
        }

        return createIndividualWindowItems(
            entries: entries,
            focusedToken: focusedToken,
            hiddenAppPIDs: hiddenAppPIDs
        )
    }

    private func createDedupedWindowItems(
        entries: [WindowState],
        useLayoutOrder: Bool,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> [WorkspaceBarWindowItem] {
        var entriesByApp: [AppGroupKey: [WindowState]] = [:]
        var appOrder: [AppGroupKey] = []
        entriesByApp.reserveCapacity(entries.count)
        appOrder.reserveCapacity(entries.count)

        for entry in entries {
            let groupKey = appGroupKey(for: entry)
            if entriesByApp[groupKey] == nil {
                entriesByApp[groupKey] = []
                appOrder.append(groupKey)
            }
            entriesByApp[groupKey]?.append(entry)
        }

        let indexedItems = appOrder.enumerated().compactMap { index, groupKey -> (Int, WorkspaceBarWindowItem)? in
            guard let appEntries = entriesByApp[groupKey],
                  let item = createDeduplicatedWindowItem(
                      entries: appEntries,
                      focusedToken: focusedToken,
                      hiddenAppPIDs: hiddenAppPIDs
                  )
            else {
                return nil
            }
            return (index, item)
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
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> WorkspaceBarWindowItem? {
        guard let firstEntry = entries.first,
              let firstHandle = workspaceManager.handle(for: firstEntry.token)
        else {
            return nil
        }
        let appInfo = entries.lazy.compactMap { appInfoCache.info(for: $0.pid) }.first
        let appName = appInfo?.name ?? String(localized: "Unknown")
        let windowInfos = entries.compactMap { entry -> WorkspaceBarWindowInfo? in
            guard let handle = workspaceManager.handle(for: entry.token) else { return nil }
            return WorkspaceBarWindowInfo(
                id: entry.token,
                handle: handle,
                windowId: entry.windowId,
                title: windowTitle(for: entry) ?? appName,
                isFocused: entry.token == focusedToken,
                isAppHidden: hiddenAppPIDs.contains(entry.pid)
            )
        }

        return WorkspaceBarWindowItem(
            id: firstEntry.token,
            handle: firstHandle,
            windowId: firstEntry.windowId,
            appName: appName,
            bundleId: bundleId(for: firstEntry),
            icon: icon(
                for: firstEntry,
                appInfo: appInfo
            ),
            isFocused: entries.contains { $0.token == focusedToken },
            windowCount: windowInfos.count,
            hiddenWindowCount: windowInfos.count { $0.isAppHidden },
            allWindows: windowInfos
        )
    }

    private func createIndividualWindowItems(
        entries: [WindowState],
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> [WorkspaceBarWindowItem] {
        entries.compactMap { entry -> WorkspaceBarWindowItem? in
            guard let handle = workspaceManager.handle(for: entry.token) else { return nil }
            let appInfo = appInfoCache.info(for: entry.pid)
            let appName = appInfo?.name ?? String(localized: "Unknown")
            let title = windowTitle(for: entry) ?? appName

            return WorkspaceBarWindowItem(
                id: entry.token,
                handle: handle,
                windowId: entry.windowId,
                appName: appName,
                bundleId: bundleId(for: entry),
                icon: icon(
                    for: entry,
                    appInfo: appInfo
                ),
                isFocused: entry.token == focusedToken,
                windowCount: 1,
                hiddenWindowCount: hiddenAppPIDs.contains(entry.pid) ? 1 : 0,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: entry.token,
                        handle: handle,
                        windowId: entry.windowId,
                        title: title,
                        isFocused: entry.token == focusedToken,
                        isAppHidden: hiddenAppPIDs.contains(entry.pid)
                    )
                ]
            )
        }
    }

    private func icon(
        for entry: WindowState,
        appInfo: AppInfoCache.AppInfo?
    ) -> NSImage? {
        guard iconResolver.hasOverrides else { return appInfo?.icon }
        if let bundleId = normalizedBundleId(entry.managedReplacementMetadata?.bundleId)
            ?? normalizedBundleId(appInfo?.bundleId),
            let override = iconResolver.image(for: bundleId)
        {
            return override
        }
        return appInfo?.icon
    }

    private func appGroupKey(
        for entry: WindowState
    ) -> AppGroupKey {
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
        guard let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
              !title.isEmpty else { return nil }
        return title
    }
}
