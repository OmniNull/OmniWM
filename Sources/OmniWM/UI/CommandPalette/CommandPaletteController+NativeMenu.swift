// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteController {
    func presentShellMenu(_ target: String, at anchor: ShellAnchor, in view: NSView) {
        let items = shellMenuItems(for: target)
        guard !items.isEmpty, let action = nativeMenu.present(items, at: anchor, in: view) else { return }
        performShellMenuAction(action, target: target)
    }

    func shellMenuItems(for target: String) -> [CommandPaletteNativeMenu.Item] {
        guard isVisible else { return [] }
        if target == "modes" {
            guard isExpanded, !isUnifiedSearch else { return [] }
            return CommandPaletteNativeMenu.modes(
                selected: selectedMode,
                menuAvailable: isMenuModeAvailable,
                clearHistory: selectedMode == .clipboard && isClipboardHistoryEnabled
                    && clipboardItems.contains(where: { !$0.isPinned })
            )
        }
        guard isClipboardHistoryEnabled,
              case let .clipboard(id)? = shellSelection(for: target),
              let item = clipboardItems.first(where: { $0.id == id })
        else { return [] }
        return CommandPaletteNativeMenu.clipboard(item)
    }

    @discardableResult
    func performShellMenuAction(_ action: CommandPaletteNativeMenu.Action, target: String) -> Bool {
        let available = shellMenuItems(for: target).contains { item in
            guard case let .action(_, candidate, enabled, _) = item else { return false }
            return candidate == action && enabled
        }
        guard available else { return false }
        switch action {
        case let .mode(mode):
            selectMode(mode)
        case let .clipboardPastePlain(id):
            pasteClipboardItem(id, withoutFormatting: true)
        case let .clipboardPin(id, pinned):
            setClipboardItemPinned(pinned, id: id)
        case let .clipboardDelete(id):
            deleteClipboardItem(id)
        case .clipboardClear:
            clearClipboardHistory()
        }
        return true
    }
}
