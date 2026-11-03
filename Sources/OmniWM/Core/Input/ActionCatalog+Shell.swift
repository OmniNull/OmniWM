// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ActionCatalog {
    static var shellAppExampleTitle: LocalizedStringResource {
        LocalizedStringResource(
            "command.shell.appOpenExample", defaultValue: "Open OmniShell Example", table: "Commands", bundle: .omniWM
        )
    }

    static let shellTogglePrefix = "toggleShellWidget."
    static let shellAppExampleActionID = "openShellApp.example"

    static func appendShellAppBindings(_ specs: inout [ActionSpec]) {
        specs.append(action(
            id: shellAppExampleActionID,
            command: .shellAppOpen(ShellAppWindowManager.exampleID),
            category: .focus,
            binding: .unassigned,
            keywords: ["shell", "app", "window", "example"]
        ))
    }

    static func shellToggleSpec(for id: String) -> ActionSpec? {
        guard id.hasPrefix(shellTogglePrefix) else { return nil }
        return shellToggleSpec(name: String(id.dropFirst(shellTogglePrefix.count)))
    }

    static func shellToggleSpec(name: String) -> ActionSpec? {
        guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
        return action(
            id: shellTogglePrefix + name,
            command: .shellToggle(name),
            category: .focus,
            binding: .unassigned,
            keywords: ["shell", "widget", "drawer", name]
        )
    }
}
