// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let shellActionDescriptors: [IPCShellActionDescriptor] = [
        .init(
            path: "shell set <key> <value...>",
            name: .set,
            summary: "Set a runtime-only value that Luau widgets read as ctx.data.vars[key].",
            arguments: ["key", "value"]
        ),
        .init(
            path: "shell unset <key>",
            name: .unset,
            summary: "Remove a runtime-only value from ctx.data.vars.",
            arguments: ["key"]
        ),
        .init(
            path: "shell toggle <widget>",
            name: .toggle,
            summary: "Open or close a Luau widget's popout, at the screen edge when the widget has no bar slot.",
            arguments: ["widget"]
        ),
        .init(
            path: "shell profile <name>",
            name: .profile,
            summary: "Switch the shell to a profile folder in ~/.config/omniwm/shell.",
            arguments: ["name"]
        ),
        .init(
            path: "shell theme <name> [scheme]",
            name: .theme,
            summary: "Recolour the shell with a theme from a themes folder, native, or wallpaper with a Material scheme.",
            arguments: ["name", "scheme"]
        ),
        .init(
            path: "shell eject <widget|lib/path>",
            name: .eject,
            summary: "Copy a widget, component or library into an editable override.",
            arguments: ["widget"]
        ),
        .init(
            path: "shell init <widget>",
            name: .initialize,
            summary: "Create a starter widget in the shell's widgets folder.",
            arguments: ["widget"]
        ),
        .init(
            path: "shell trigger <widget> <name> [value...]",
            name: .trigger,
            summary: "Call a widget's trigger function with an event name and an optional value.",
            arguments: ["widget", "name", "value"]
        )
    ]
}
