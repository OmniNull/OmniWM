// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct CommandPaletteMarkActionsView: View {
    let controller: CommandPaletteController

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { controller.setMarkOnSelectedWindow() }, label: {
                HStack(spacing: 6) {
                    Label("Mark selected window…", systemImage: "tag")
                    CommandPaletteShortcutBadge(text: CommandPalettePresentation.setMarkShortcut)
                }
            })
            .accessibilityHint(String(localized: "Marks the selected window row. Shortcut Control-Option-Shift-M."))
            .help(String(localized: "Mark the selected window (Control-Option-Shift-M)"))

            Button(action: { controller.removeMarkFromSelectedWindow() }, label: {
                HStack(spacing: 6) {
                    Label("Remove mark…", systemImage: "tag.slash")
                    CommandPaletteShortcutBadge(text: CommandPalettePresentation.removeMarkShortcut)
                }
            })
            .accessibilityHint(
                String(localized: "Choose a mark to remove from the selected window. Shortcut Control-Option-Shift-R.")
            )
            .help(String(localized: "Choose a mark to remove from the selected window (Control-Option-Shift-R)"))
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
