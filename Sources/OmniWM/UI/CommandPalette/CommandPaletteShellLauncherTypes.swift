// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct CommandPaletteLauncherLayout {
    let grid: Bool
    let columns: Int
    let limit: Float
    let points: CGFloat
    let scale: CGFloat
    let showsPaths: Bool
    let current: CommandPaletteSelectionID?
    let currentKey: String?
}

struct CommandPaletteLauncherCursor {
    let range: Range<Int>
    var position = 0
}

enum CommandPaletteShellLauncherSource: Equatable {
    case application(String, String?)
    case file(String, Date?, String?, Bool)
    case saved(LauncherEntry)
    case executable(String)
}

struct CommandPaletteShellLauncherRow {
    let source: CommandPaletteShellLauncherSource
    let row: ShellCommandPaletteData.Row
}

struct CommandPaletteLauncherKeys {
    var ids: [String] = []
    var selected: Int?
}

struct CommandPaletteShellLauncherToolbar {
    let mode: CommandPaletteMode
    let filter: LauncherFilter
    let style: LauncherViewStyle
    let columns: Int
    let chips: [LauncherChip]
    let chip: String?
    let value: ShellCommandPaletteData.Launcher
}
