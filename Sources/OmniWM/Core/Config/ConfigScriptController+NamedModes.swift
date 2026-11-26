// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ConfigScriptController {
    func namedKeyMask(
        _ declarations: [ConfigScriptBinding],
        claims: [UInt32: [Claim]]
    ) -> (masked: Set<Int>, conflict: String?) {
        var masked: Set<Int> = []
        var conflict: String?
        for (index, row) in declarations.enumerated() where row.mode != nil {
            let prior = claims[row.chord.keyCode]?.first {
                $0.modeCommand == nil && $0.chord.conflicts(with: row.chord)
            }?.owner ?? declarations.first { $0.mode == nil && $0.chord.conflicts(with: row.chord) }.map {
                "the shortcut at \($0.source):\($0.line)"
            }
            guard let prior else { continue }
            masked.insert(index)
            conflict = conflict ?? description(
                source: row.source, line: row.line, message: "'\(row.rawChord)' in a mode conflicts with \(prior)."
            )
        }
        return (masked, conflict)
    }

    func publishNamedKeyModes(masking masked: Set<Int> = []) {
        var modes: [NamedKeyModes.Mode] = []
        for mode in acceptedNamedModes {
            var entries: [KeyboardModeTable.Entry] = []
            for (index, row) in acceptedBindings.enumerated() where row.mode == mode.id && !masked.contains(index) {
                entries.append(KeyboardModeTable.Entry(binding: row.chord, command: row.command))
            }
            if !entries.isEmpty { modes.append(NamedKeyModes.Mode(id: mode.id, name: mode.name, entries: entries)) }
        }
        guard let controller = wmController,
              controller.hotkeys.updateNamedKeyModes(NamedKeyModes(modes)) else { return }
        controller.refreshHotkeyFailureSnapshots()
        controller.refreshDiagnosticsIssues()
        controller.refreshKeyboardModeIndicator()
    }
}
