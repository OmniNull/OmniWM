// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension CommandPaletteController {
    func shellRowKey(_ selection: CommandPaletteSelectionID) -> String {
        if let key = shellRowKeys[selection] { return key }
        let key: String
        switch selection {
        case let .window(token): key = Self.shellRowID(token)
        case let .menu(id): key = "menu-" + id.uuidString
        case let .clipboard(id): key = "clipboard-" + id.uuidString
        case let .command(id): key = id
        default:
            shellUnifiedKeySequence &+= 1
            key = "unified-" + String(shellUnifiedKeySequence)
        }
        shellRowKeys[selection] = key
        return key
    }

    func updateShellSelectionIndex(_ selections: [CommandPaletteSelectionID]) {
        guard presentation.shell != nil else {
            shellSelectionIndex.removeAll(keepingCapacity: true)
            return
        }
        if shellSelectionIndex.count == selections.count,
           selections.allSatisfy({ selection in
               guard let key = shellRowKeys[selection] else { return false }
               return shellSelectionIndex[key] == selection
           })
        {
            return
        }
        shellSelectionIndex.removeAll(keepingCapacity: true)
        shellSelectionIndex.reserveCapacity(selections.count)
        for selection in selections {
            shellSelectionIndex[shellRowKey(selection)] = selection
        }
    }
}
