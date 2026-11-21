// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation

@MainActor
enum CommandPaletteSearch {
    private struct WindowSearchMatch {
        let item: CommandPaletteWindowItem
        let rank: Int
        let recency: Int
    }

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

        var markedMatches: [CommandPaletteWindowItem] = []
        var otherMatches: [WindowSearchMatch] = []
        for (recency, item) in items.enumerated() {
            if item.markNames.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                markedMatches.append(item)
            } else if let rank = windowSearchRank(item, query: query) {
                otherMatches.append(.init(item: item, rank: rank, recency: recency))
            }
        }
        return markedMatches + otherMatches.sorted {
            $0.rank == $1.rank ? $0.recency < $1.recency : $0.rank < $1.rank
        }.map(\.item)
    }

    private static func windowSearchRank(_ item: CommandPaletteWindowItem, query: String) -> Int? {
        let title = item.title.lowercased()
        if let range = title.range(of: query) {
            return title.distance(from: title.startIndex, to: range.lowerBound)
        }
        let appName = item.appName.lowercased()
        if let range = appName.range(of: query) {
            return 1000 + appName.distance(from: appName.startIndex, to: range.lowerBound)
        }
        let workspaceName = item.workspaceName.lowercased()
        if let range = workspaceName.range(of: query) {
            return 2000 + workspaceName.distance(from: workspaceName.startIndex, to: range.lowerBound)
        }
        if item.isAppHidden,
           let term = hiddenSearchTerms.first(where: { $0.contains(query) }),
           let range = term.range(of: query)
        {
            return 3000 + term.distance(from: term.startIndex, to: range.lowerBound)
        }
        return nil
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

        let apps = wmController.shellAppCatalog.definitions.values.filter { $0.id != ShellAppWindowManager.exampleID }
        let appSpecs = apps.flatMap { app in
            [false, true].compactMap { ActionCatalog.shellAppSpec(appID: app.id, title: app.title, newWindow: $0) }
        }
        return (ActionCatalog.allSpecs() + appSpecs).filter {
            wmController.settings.isCommandFeatureEnabled($0.command)
        }.map { spec in
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
        let keys = ActionCatalog.searchKeys(for: item.spec)
        if keys.title.hasPrefix(query) { return 0 }
        if keys.title.contains(query) { return 1 }
        for term in keys.terms where term.contains(query) { return 2 }
        for term in keys.categoryTerms where term.contains(query) { return 3 }
        for term in keys.layoutTerms where term.contains(query) { return 4 }
        for term in item.shortcutSearchTerms where term.contains(query) { return 5 }
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

    static func orderWindowItems(
        _ items: [CommandPaletteWindowItem],
        focusRecencyOrder: [WindowToken],
        confirmedFocusToken: WindowToken? = nil,
        focusedWindowToken: WindowToken? = nil
    ) -> [CommandPaletteWindowItem] {
        let focusOrder = [confirmedFocusToken, focusedWindowToken].compactMap { $0 } + focusRecencyOrder
        let focusRanks = Dictionary(
            focusOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.sorted {
            (
                $0.isAppHidden ? 1 : 0,
                focusRanks[$0.id] ?? Int.max,
                $0.appName,
                $0.title
            ) < (
                $1.isAppHidden ? 1 : 0,
                focusRanks[$1.id] ?? Int.max,
                $1.appName,
                $1.title
            )
        }
    }

    static func buildWindowItems(
        from wmController: WMController,
        focusedWindow: CommandPaletteFocusTarget? = nil
    ) -> [CommandPaletteWindowItem] {
        let entries = wmController.workspaceManager.allEntries()
        var items: [CommandPaletteWindowItem] = []
        items.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.layoutReason == .standard,
                  let handle = wmController.workspaceManager.handle(for: entry.token) else { continue }

            let presentation = wmController.appInfoCache.presentation(
                for: entry, title: AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId))
            )
            let workspaceName = wmController.workspaceManager.descriptor(for: entry.workspaceId)?.name ?? "?"

            items.append(CommandPaletteWindowItem(
                id: entry.token,
                handle: handle,
                title: presentation.title ?? "",
                appName: presentation.name ?? String(localized: "Unknown"),
                workspaceName: workspaceName,
                isAppHidden: wmController.workspaceManager.isAppHidden(pid: entry.pid),
                markNames: wmController.windowMarkRegistry.names(for: entry.token),
                bundleIdentifier: entry.target.hostedMetadata == nil
                    ? wmController.appInfoCache.bundleId(for: entry.pid)
                    : nil,
                hostedSymbol: entry.target.hostedMetadata?.icon
            ))
        }

        let focusedWindowToken = focusedWindow.flatMap { target in
            target.focusedWindowID.map {
                WindowToken(pid: target.app.processIdentifier, windowId: Int($0))
            }
        }
        return orderWindowItems(
            items,
            focusRecencyOrder: wmController.workspaceManager.windowFocusRecencyOrder,
            confirmedFocusToken: wmController.workspaceManager.selectedManagedToken,
            focusedWindowToken: focusedWindowToken
        )
    }
}
