// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

@MainActor
enum CommandPaletteSearch {
    private static let unassignedShortcut = String(localized: "Unassigned")
    private static let noShortcut = String(localized: "No shortcut")
    private static let hiddenSearchTerms = ActionCatalog.uniqueTerms([
        String(localized: "hidden").lowercased(),
        "hidden"
    ])
    private static let commandCategoryOrder = Dictionary(
        uniqueKeysWithValues: HotkeyCategory.allCases.enumerated().map { ($0.element, $0.offset) }
    )

    static func filterWindowItems(
        _ items: [CommandPaletteWindowItem],
        query rawQuery: String
    ) -> [CommandPaletteWindowItem] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(CommandPaletteWindowItem, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let appLower = item.appName.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = appLower.range(of: query) {
                let pos = appLower.distance(from: appLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            let workspaceLower = item.workspaceName.lowercased()
            if let range = workspaceLower.range(of: query) {
                let pos = workspaceLower.distance(from: workspaceLower.startIndex, to: range.lowerBound)
                return (item, 2000 + pos)
            }

            if item.isAppHidden {
                for term in hiddenSearchTerms {
                    if let range = term.range(of: query) {
                        let pos = term.distance(from: term.startIndex, to: range.lowerBound)
                        return (item, 3000 + pos)
                    }
                }
            }

            return nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.title.count != rhs.0.title.count { return lhs.0.title.count < rhs.0.title.count }
                return lhs.0.title < rhs.0.title
            }
            .map(\.0)
    }

    static func filterMenuItems(_ items: [MenuItemModel], query rawQuery: String) -> [MenuItemModel] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(MenuItemModel, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let pathLower = item.fullPath.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = pathLower.range(of: query) {
                let pos = pathLower.distance(from: pathLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            return nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.title.count != rhs.0.title.count { return lhs.0.title.count < rhs.0.title.count }
                return lhs.0.title < rhs.0.title
            }
            .map(\.0)
    }

    static func filterClipboardItems(
        _ items: [ClipboardPaletteItem],
        query rawQuery: String
    ) -> [ClipboardPaletteItem] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(ClipboardPaletteItem, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let searchLower = item.searchText.lowercased()
            let subtitleLower = item.subtitle.lowercased()
            let kindLower = item.kind.rawValue.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = searchLower.range(of: query) {
                let pos = searchLower.distance(from: searchLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            if let range = subtitleLower.range(of: query) {
                let pos = subtitleLower.distance(from: subtitleLower.startIndex, to: range.lowerBound)
                return (item, 2000 + pos)
            }

            if let range = kindLower.range(of: query) {
                let pos = kindLower.distance(from: kindLower.startIndex, to: range.lowerBound)
                return (item, 3000 + pos)
            }

            return nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.0.isPinned != rhs.0.isPinned { return lhs.0.isPinned }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.title.count != rhs.0.title.count { return lhs.0.title.count < rhs.0.title.count }
                return lhs.0.title < rhs.0.title
            }
            .map(\.0)
    }

    static func filterCommandItems(
        _ items: [CommandPaletteCommandItem],
        query rawQuery: String
    ) -> [CommandPaletteCommandItem] {
        let query = ActionCatalog.normalizedSearchTerm(rawQuery)
        if query.isEmpty {
            return items.sorted(by: commandCatalogOrder)
        }

        return items.compactMap { item -> (CommandPaletteCommandItem, Int)? in
            commandSearchRank(item, query: query).map { (item, $0) }
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? commandTitleOrder(lhs.0, rhs.0) : lhs.1 < rhs.1
        }
        .map(\.0)
    }

    static func buildCommandItems(from wmController: WMController) -> [CommandPaletteCommandItem] {
        let layoutType = wmController.activeWorkspace().map {
            wmController.settings.workspaces.layoutType(for: $0.name)
        } ?? .niri
        let triggersByID = Dictionary(
            wmController.settings.hotkeyBindings.map { ($0.id, $0.binding) },
            uniquingKeysWith: { first, _ in first }
        )

        return ActionCatalog.allSpecs().map { spec in
            let trigger = spec.visibility == .unassignable ? nil : triggersByID[spec.id]
            let hasShortcut = trigger?.isUnassigned == false
            let shortcut = if spec.visibility == .unassignable {
                noShortcut
            } else if let trigger, hasShortcut {
                trigger.displayString
            } else {
                unassignedShortcut
            }
            let canonicalShortcut = if spec.visibility == .unassignable {
                "No shortcut"
            } else if hasShortcut {
                trigger?.humanReadableString ?? shortcut
            } else {
                "Unassigned"
            }
            return CommandPaletteCommandItem(
                spec: spec,
                shortcut: shortcut,
                hasShortcut: hasShortcut,
                shortcutSearchTerms: ActionCatalog.uniqueTerms([
                    shortcut,
                    canonicalShortcut
                ]).map(ActionCatalog.normalizedSearchTerm),
                isLayoutCompatible: CommandHandler.isLayoutCompatible(
                    spec.layoutCompatibility,
                    with: layoutType
                )
            )
        }
        .sorted(by: commandCatalogOrder)
    }

    private static func commandSearchRank(_ item: CommandPaletteCommandItem, query: String) -> Int? {
        let title = ActionCatalog.normalizedSearchTerm(item.spec.localizedTitle)
        if title.hasPrefix(query) { return 0 }
        if title.contains(query) { return 1 }

        let layout = ActionCatalog.normalizedSearchTerm(item.spec.layoutCompatibility.rawValue)
        let localizedLayout = ActionCatalog.normalizedSearchTerm(item.spec.layoutCompatibility.localizedDisplayName)
        let category = ActionCatalog.normalizedSearchTerm(item.spec.category.rawValue)
        let localizedCategory = ActionCatalog.normalizedSearchTerm(item.spec.category.localizedDisplayName)
        let terms = ActionCatalog.normalizedSearchTerms(for: item.id)
            ?? item.spec.searchTerms.map(ActionCatalog.normalizedSearchTerm)
        if terms.contains(where: {
            $0 != title && $0 != layout && $0 != localizedLayout && $0 != category && $0 != localizedCategory
                && $0.contains(query)
        }) { return 2 }
        if category.contains(query) || localizedCategory.contains(query) { return 3 }
        if layout.contains(query) || localizedLayout.contains(query) { return 4 }
        if item.shortcutSearchTerms.contains(where: { $0.contains(query) }) { return 5 }
        return nil
    }

    private static func commandCatalogOrder(_ lhs: CommandPaletteCommandItem, _ rhs: CommandPaletteCommandItem)
        -> Bool
    {
        let leftCategory = commandCategoryOrder[lhs.spec.category] ?? .max
        let rightCategory = commandCategoryOrder[rhs.spec.category] ?? .max
        return leftCategory == rightCategory ? commandTitleOrder(lhs, rhs) : leftCategory < rightCategory
    }

    private static func commandTitleOrder(_ lhs: CommandPaletteCommandItem, _ rhs: CommandPaletteCommandItem)
        -> Bool
    {
        let titleOrder = lhs.spec.localizedTitle.localizedStandardCompare(rhs.spec.localizedTitle)
        return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
    }

    static func buildWindowItems(from wmController: WMController) -> [CommandPaletteWindowItem] {
        let entries = wmController.workspaceManager.allEntries()
        var items: [CommandPaletteWindowItem] = []
        items.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.layoutReason == .standard,
                  let handle = wmController.workspaceManager.handle(for: entry.token) else { continue }

            let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)) ?? ""
            let appInfo = wmController.appInfoCache.info(for: entry.pid)
            let workspaceName = wmController.workspaceManager.descriptor(for: entry.workspaceId)?.name ?? "?"

            items.append(CommandPaletteWindowItem(
                id: entry.token,
                handle: handle,
                title: title,
                appName: appInfo?.name ?? String(localized: "Unknown"),
                appIcon: appInfo?.icon,
                workspaceName: workspaceName,
                isAppHidden: wmController.workspaceManager.isAppHidden(pid: entry.pid)
            ))
        }

        items.sort {
            ($0.isAppHidden ? 1 : 0, $0.appName, $0.title)
                < ($1.isAppHidden ? 1 : 0, $1.appName, $1.title)
        }
        return items
    }
}
