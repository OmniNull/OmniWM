// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension CommandPaletteController {
    var filteredWindowItems: [CommandPaletteWindowItem] {
        CommandPaletteSearch.filterWindowItems(windows, query: searchText)
    }

    var filteredMenuItems: [MenuItemModel] {
        CommandPaletteSearch.filterMenuItems(menuItems, query: searchText)
    }

    var filteredClipboardItems: [ClipboardPaletteItem] {
        CommandPaletteSearch.filterClipboardItems(clipboardItems, query: searchText)
    }

    var filteredCommandItems: [CommandPaletteCommandItem] {
        CommandPaletteSearch.filterCommandItems(commandItems, query: searchText)
    }

    var isMenuModeAvailable: Bool {
        CommandPalettePresentation.menuModeAvailable(hasMenuFocusTarget: focusSession.menuFocusTarget != nil)
    }

    var isSummonRightAvailable: Bool {
        focusSession.summonAnchor != nil
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

    func isModeAvailable(_ mode: CommandPaletteMode) -> Bool {
        switch mode {
        case .windows,
             .clipboard,
             .commands:
            return true
        case .menu:
            return isMenuModeAvailable
        }
    }

    func resolvedSelectionAction(
        for trigger: CommandPaletteSelectionTrigger
    ) -> CommandPaletteActionExecutor.Action? {
        switch selectedMode {
        case .windows:
            let filtered = filteredWindowItems
            guard let wmController,
                  case let .window(token)? = selectedItemID,
                  let item = filtered.first(where: { $0.id == token })
            else {
                return nil
            }
            switch trigger {
            case .primary:
                return .navigateWindow(wmController, item.handle)
            case .alternate:
                guard CommandPalettePresentation.allowsSummonRight(item),
                      let summonAnchor = focusSession.summonAnchor else { return nil }
                return .summonWindowRight(wmController, item.handle, summonAnchor)
            }
        case .menu:
            let filtered = filteredMenuItems
            guard case let .menu(id)? = selectedItemID,
                  let item = filtered.first(where: { $0.id == id }),
                  let menuFocusTarget = focusSession.menuFocusTarget
            else {
                return nil
            }
            return .pressMenu(menuFocusTarget, item.axElement)
        case .clipboard:
            guard let wmController,
                  isClipboardHistoryEnabled,
                  case let .clipboard(id)? = selectedItemID,
                  filteredClipboardItems.contains(where: { $0.id == id })
            else {
                return nil
            }
            switch trigger {
            case .primary:
                return .copyClipboard(wmController, id)
            case .alternate:
                return .pasteClipboard(wmController, id, focusSession.clipboardPasteTarget(), false)
            }
        case .commands:
            guard let wmController,
                  case let .command(id)? = selectedItemID,
                  let item = filteredCommandItems.first(where: { $0.id == id }),
                  item.isLayoutCompatible
            else {
                return nil
            }
            return .command(wmController, item.spec.command, focusSession.restoreFocusTarget)
        }
    }

    func currentSelectionList() -> [CommandPaletteSelectionID] {
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
        }
    }

    func updateSelectionAfterFilterChange() {
        let selectionList = currentSelectionList()
        if selectionList.isEmpty {
            selectedItemID = nil
            return
        }

        if let selectedItemID, !selectionList.contains(selectedItemID) {
            self.selectedItemID = selectionList.first
        } else if selectedItemID == nil {
            selectedItemID = selectionList.first
        }
    }
}
