// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension IPCCommandPaletteMode {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .windows: LocalizedStringResource(
                "command.palette.mode.windows", defaultValue: "Command Palette: Windows", table: "Commands",
                bundle: .omniWM
            )
        case .menu: LocalizedStringResource(
                "command.palette.mode.menu", defaultValue: "Command Palette: Menu", table: "Commands",
                bundle: .omniWM
            )
        case .clipboard: LocalizedStringResource(
                "command.palette.mode.clipboard", defaultValue: "Command Palette: Clipboard", table: "Commands",
                bundle: .omniWM
            )
        case .commands: LocalizedStringResource(
                "command.palette.mode.commands", defaultValue: "Command Palette: Commands", table: "Commands",
                bundle: .omniWM
            )
        case .applications: LocalizedStringResource(
                "command.palette.mode.applications", defaultValue: "Command Palette: Applications",
                table: "Commands", bundle: .omniWM
            )
        case .files: LocalizedStringResource(
                "command.palette.mode.files", defaultValue: "Command Palette: Files", table: "Commands",
                bundle: .omniWM
            )
        }
    }

    func actionSpec() -> ActionSpec {
        let keywords: [String] = switch self {
        case .windows: ["palette", "windows", "switch"]
        case .menu: ["palette", "menu"]
        case .clipboard: ["palette", "clipboard", "history", "paste"]
        case .commands: ["palette", "commands"]
        case .applications: ["palette", "applications", "apps", "launcher"]
        case .files: ["palette", "files", "search"]
        }
        return ActionCatalog.action(
            id: "openCommandPalette." + rawValue,
            command: .openCommandPaletteMode(self),
            category: .focus,
            binding: .unassigned,
            keywords: keywords
        )
    }
}
