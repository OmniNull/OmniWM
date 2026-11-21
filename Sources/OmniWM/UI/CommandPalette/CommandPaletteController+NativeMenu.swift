// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteController {
    func presentShellMenu(_ target: String, at anchor: ShellAnchor, in view: NSView) {
        let items = shellMenuItems(for: target)
        guard !items.isEmpty else { return }
        let action = nativeMenu.present(items, at: anchor, in: view)
        syncLauncherPaths()
        guard let action else { return }
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
        if target == Self.shellLauncherAddTarget {
            guard selectedMode == .applications, !isUnifiedSearch else { return [] }
            return CommandPaletteNativeMenu.launcherAdd
        }
        switch shellSelection(for: target) {
        case let .clipboard(id)?:
            guard isClipboardHistoryEnabled, let item = clipboardItems.first(where: { $0.id == id }) else { return [] }
            return CommandPaletteNativeMenu.clipboard(item)
        case let selection?:
            return launcherMenuItems(for: selection)
        case nil:
            return []
        }
    }

    private func launcherMenuItems(for selection: CommandPaletteSelectionID) -> [CommandPaletteNativeMenu.Item] {
        guard isLauncherMode, !isUnifiedSearch, launcherPublishedGeneration == launcherRequestGeneration,
              let item = Self.launcherSelection(selection)
        else { return [] }
        switch selection {
        case .launcherEntry:
            return CommandPaletteNativeMenu.saved(item)
        case .executable:
            return CommandPaletteNativeMenu.executable(item)
        case let .application(sectionID, id):
            let suggestion = sectionID == .suggestions ? applicationResult(sectionID, id)?.displayName : nil
            return CommandPaletteNativeMenu.launcher(item, quickLook: false, suggestion: suggestion)
        case .file:
            return CommandPaletteNativeMenu.launcher(item, quickLook: true, suggestion: nil)
        default:
            return []
        }
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
        case let .launcherAdd(kind):
            addLauncherEntry(kind)
        case .launcherManage:
            showLauncherSettings()
        case .launcherRefresh:
            refreshLauncher()
        case let .launcherRun(selection):
            selectLauncherItem(selection, activate: true)
        case let .launcher(selection, action):
            performLauncherContextAction(action, for: selection)
        }
        return true
    }
}
