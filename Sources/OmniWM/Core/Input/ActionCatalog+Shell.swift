// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension ActionCatalog {
    static let shellTogglePrefix = "toggleShellWidget."

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
