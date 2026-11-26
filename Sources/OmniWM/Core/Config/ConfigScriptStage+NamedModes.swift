// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension ConfigScriptStage {
    mutating func bind(_ row: ConfigScriptBinding, inMode name: String) throws(ConfigScriptError) {
        guard let mode = namedModes.first(where: { $0.name == name }) else {
            throw ConfigScriptError(
                line: nil, message: "Mode '\(name)' isn't declared. Declare it with omniwm.keymap.mode first."
            )
        }
        guard let slot = NamedKeyModes.slot(for: row.chord) else {
            throw ConfigScriptError(
                line: nil,
                message: "'\(row.rawChord)' in mode \(name) must be one key, with Shift at most, other than Escape."
            )
        }
        var count = 0
        for prior in bindings where prior.mode == mode.id {
            guard NamedKeyModes.slot(for: prior.chord) != slot else {
                throw ConfigScriptError(
                    line: nil,
                    message: "'\(row.rawChord)' in mode \(name) is already bound at \(prior.source):\(prior.line)."
                )
            }
            count += 1
        }
        guard count < NamedKeyModes.keyLimit else {
            throw ConfigScriptError(line: nil, message: "Mode \(name) has at most \(NamedKeyModes.keyLimit) keys.")
        }
        var row = row
        row.mode = mode.id
        row.modeName = name
        bindings.append(row)
    }
}
