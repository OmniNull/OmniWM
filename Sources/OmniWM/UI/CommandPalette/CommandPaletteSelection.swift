// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum CommandPaletteFilteredItems {
    case windows([CommandPaletteWindowItem])
    case menu([MenuItemModel])
    case clipboard([ClipboardPaletteItem])
    case commands([CommandPaletteCommandItem])
    case launcher
}

extension CommandPaletteController {
    var filteredWindowItems: [CommandPaletteWindowItem] {
        guard case let .windows(items) = filteredItems else { return [] }
        return items
    }

    var filteredMenuItems: [MenuItemModel] {
        guard case let .menu(items) = filteredItems else { return [] }
        return items
    }

    var filteredClipboardItems: [ClipboardPaletteItem] {
        guard case let .clipboard(items) = filteredItems else { return [] }
        return items
    }

    var filteredCommandItems: [CommandPaletteCommandItem] {
        guard case let .commands(items) = filteredItems else { return [] }
        return items
    }

    var isMenuModeAvailable: Bool {
        CommandPalettePresentation.menuModeAvailable(hasMenuFocusTarget: focusSession.menuFocusTarget != nil)
    }

    var isSummonRightAvailable: Bool {
        focusSession.summonAnchor != nil
    }

    func allowsWindowAlternateAction(_ item: CommandPaletteWindowItem) -> Bool {
        guard let wmController,
              let entry = wmController.workspaceManager.entry(for: item.id),
              !wmController.workspaceManager.isAppHidden(pid: item.id.pid)
        else { return false }
        return CommandPalettePresentation.allowsSummonRight(
            item,
            isTiling: entry.mode == .tiling,
            isCurrentWorkspaceEmpty: isCurrentWorkspaceEmpty
        )
    }

    var menuStatusText: String {
        if let menuFocusTarget = focusSession.menuFocusTarget {
            return CommandPalettePresentation.availableMenuStatusText(for: menuFocusTarget.app.localizedName)
        }
        return CommandPalettePresentation.unavailableMenuStatusText
    }

    var clipboardStatusText: String {
        if let clipboardErrorText { return clipboardErrorText }
        guard isClipboardHistoryEnabled else {
            return String(localized: "Clipboard history is disabled.")
        }
        if clipboardItems.isEmpty {
            return String(localized: "Clipboard history is empty.")
        }
        return String(localized: "Enter copies. Shift-Enter pastes.")
    }

    func resolvedInitialMode(_ preferredMode: CommandPaletteMode) -> CommandPaletteMode {
        isModeAvailable(preferredMode) ? preferredMode : .windows
    }

    func selectInitialMode(_ requestedMode: CommandPaletteMode?, settings: SettingsStore) {
        selectedMode = resolvedInitialMode(requestedMode ?? settings.commandPaletteLastMode)
        if requestedMode != nil {
            settings.commandPaletteLastMode = selectedMode
        }
    }

    func isModeAvailable(_ mode: CommandPaletteMode) -> Bool {
        switch mode {
        case .windows,
             .clipboard,
             .commands,
             .applications,
             .files:
            return true
        case .menu:
            return isMenuModeAvailable
        }
    }

    var selectableWindowItems: [CommandPaletteWindowItem] {
        isUnifiedSearch ? windows : filteredWindowItems
    }

    func resolvedSelectionAction(
        for trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        if isUnifiedSearch {
            return resolvedUnifiedSelectionAction(for: trigger)
        }
        switch selectedMode {
        case .windows:
            return resolvedWindowSelectionAction(for: trigger)
        case .menu:
            guard case let .menu(id)? = selectedItemID,
                  filteredMenuItems.contains(where: { $0.id == id })
            else {
                return nil
            }
            return menuSelectionAction(id)
        case .clipboard:
            guard case let .clipboard(id)? = selectedItemID,
                  filteredClipboardItems.contains(where: { $0.id == id })
            else {
                return nil
            }
            return clipboardSelectionAction(id, trigger: trigger)
        case .commands:
            guard case let .command(id)? = selectedItemID,
                  filteredCommandItems.contains(where: { $0.id == id })
            else {
                return nil
            }
            return commandSelectionAction(id)
        case .applications:
            return resolvedLauncherSelectionAction(for: trigger)
        case .files:
            return resolvedLauncherSelectionAction(for: trigger)
        }
    }

    private func resolvedUnifiedSelectionAction(
        for trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        switch selectedItemID {
        case .window?:
            return resolvedWindowSelectionAction(for: trigger)
        case let .menu(id)?:
            return menuSelectionAction(id)
        case let .clipboard(id)?:
            return clipboardSelectionAction(id, trigger: trigger)
        case let .command(id)?:
            return commandSelectionAction(id)
        case let .launcherEntry(id)?:
            guard let entry = wmController?.settings.launcher.entries.first(where: { $0.id == id }) else {
                return nil
            }
            return launcherEntryAction(entry, trigger: trigger)
        case let .application(sectionID, id)?:
            return applicationResult(sectionID, id).flatMap { applicationAction($0, trigger: trigger) }
        case let .file(sectionID, id)?:
            return fileResult(sectionID, id).flatMap { fileAction($0, trigger: trigger) }
        case .executable?,
             .showAll?,
             nil:
            return nil
        }
    }

    private func resolvedWindowSelectionAction(
        for trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        guard let wmController,
              case let .window(token)? = selectedItemID,
              let item = selectableWindowItems.first(where: { $0.id == token }),
              let entry = wmController.workspaceManager.entry(for: token),
              entry.layoutReason == .standard,
              let liveHandle = wmController.workspaceManager.handle(for: token),
              liveHandle === item.handle
        else {
            return nil
        }
        switch trigger {
        case .primary,
             .reveal:
            return .navigateWindow(wmController, item.handle)
        case .alternate:
            guard allowsWindowAlternateAction(item) else { return nil }
            if isCurrentWorkspaceEmpty, let workspaceId = focusSession.workspaceId {
                return .moveWindowToWorkspace(wmController, item.handle, workspaceId)
            }
            let summonAnchor = focusSession.summonAnchor
            if !item.markNames.isEmpty || summonAnchor == nil {
                return .summonMarkedWindowRight(wmController, item.handle, summonAnchor)
            }
            guard let summonAnchor,
                  wmController.workspaceManager.entry(for: summonAnchor.token) != nil
            else { return .summonMarkedWindowRight(wmController, item.handle, nil) }
            return .summonWindowRight(wmController, item.handle, summonAnchor)
        }
    }

    private func menuSelectionAction(_ id: UUID) -> CommandPaletteActionExecutor.Action? {
        guard let item = menuItems.first(where: { $0.id == id }),
              let menuFocusTarget = focusSession.menuFocusTarget
        else {
            return nil
        }
        return .pressMenu(menuFocusTarget, item.axElement)
    }

    private func clipboardSelectionAction(
        _ id: UUID,
        trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        guard let wmController,
              isClipboardHistoryEnabled,
              clipboardItems.contains(where: { $0.id == id })
        else {
            return nil
        }
        switch trigger {
        case .primary,
             .reveal:
            return .copyClipboard(wmController, id)
        case .alternate:
            return .pasteClipboard(wmController, id, focusSession.clipboardPasteTarget(), false)
        }
    }

    private func commandSelectionAction(_ id: String) -> CommandPaletteActionExecutor.Action? {
        guard let wmController,
              let item = commandItems.first(where: { $0.id == id }),
              item.isLayoutCompatible
        else {
            return nil
        }
        return .command(wmController, item.spec.command, focusSession.restoreFocusTarget)
    }

    private func resolvedLauncherSelectionAction(
        for trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        guard launcherPublishedGeneration == launcherRequestGeneration else { return nil }
        switch selectedItemID {
        case let .launcherEntry(id)? where selectedMode == .applications:
            guard let entry = launcherSavedEntries.first(where: { $0.id == id }) else { return nil }
            return launcherEntryAction(entry, trigger: trigger)
        case let .application(sectionID, id)? where selectedMode == .applications:
            return applicationResult(sectionID, id).flatMap { applicationAction($0, trigger: trigger) }
        case let .file(sectionID, id)? where selectedMode == .files:
            return fileResult(sectionID, id).flatMap { fileAction($0, trigger: trigger) }
        default:
            return nil
        }
    }

    private func launcherEntryAction(
        _ entry: LauncherEntry,
        trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        guard let wmController else { return nil }
        if trigger == .reveal {
            guard !entry.path.isEmpty else { return nil }
            return .revealFile(URL(fileURLWithPath: LauncherPaths.expanded(entry.path)))
        }
        return .launchEntry(wmController, entry, searchText)
    }

    private func applicationAction(
        _ item: LauncherApplicationResult,
        trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        guard let wmController else { return nil }
        return trigger == .reveal
            ? .revealApplication(item.bundleURL)
            : .openApplication(wmController, item, searchText)
    }

    private func fileAction(
        _ item: LauncherFileResult,
        trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        guard let wmController else { return nil }
        return trigger == .reveal ? .revealFile(item.fileURL) : .openFile(wmController, item, searchText)
    }

    func applicationResult(_ sectionID: LauncherSectionID, _ id: String) -> LauncherApplicationResult? {
        applicationSections.first(where: { $0.id == sectionID })?.items.first(where: { $0.id == id })
    }

    func fileResult(_ sectionID: LauncherSectionID, _ id: String) -> LauncherFileResult? {
        fileSections.first(where: { $0.id == sectionID })?.items.first(where: { $0.id == id })
    }

    func currentSelectionList() -> [CommandPaletteSelectionID] {
        if isUnifiedSearch {
            return unifiedSelectionList
        }
        switch selectedMode {
        case .windows:
            return filteredWindowItems.map { CommandPaletteSelectionID.window($0.id) }
        case .menu:
            return filteredMenuItems.map { CommandPaletteSelectionID.menu($0.id) }
        case .clipboard:
            guard isClipboardHistoryEnabled else { return [] }
            return filteredClipboardItems.map { CommandPaletteSelectionID.clipboard($0.id) }
        case .commands:
            return filteredCommandItems.filter(\.isLayoutCompatible).map { CommandPaletteSelectionID.command($0.id) }
        case .applications:
            if launcherFilter == .cli { return launcherExecutables.map { .executable($0.path) } }
            return launcherSavedEntries.map { .launcherEntry($0.id) } + displayedApplicationSections
                .flatMap { section in
                    section.items.map { .application(section.id, $0.id) }
                }
        case .files:
            return fileSections.flatMap { section in
                section.items.map { .file(section.id, $0.id) }
            }
        }
    }

    func updateSelectionAfterFilterChange() {
        let selectionList = currentSelectionList()
        if isUnifiedSearch, let selectedItemID, !selectionList.contains(selectedItemID) {
            unifiedSelectionFollowsFirstRow = true
        }
        if selectionList.isEmpty {
            selectedItemID = nil
            return
        }

        if isUnifiedSearch, unifiedSelectionFollowsFirstRow {
            selectedItemID = selectionList.first
        } else if let selectedItemID, !selectionList.contains(selectedItemID) {
            self.selectedItemID = selectionList.first
        } else if selectedItemID == nil {
            selectedItemID = selectionList.first
        }
    }
}
