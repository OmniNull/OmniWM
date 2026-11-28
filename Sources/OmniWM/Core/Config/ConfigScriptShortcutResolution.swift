// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ConfigScriptShortcutOverride: Equatable {
    enum Field {
        case shortcut, modeKey
    }

    let bindingID: String
    let field: Field
    let chord: KeyBinding
    let command: HotkeyCommand
    let source: String
    let line: Int
    let modeName: String?
}

struct ConfigScriptShortcutConflicts {
    let overrides: [ConfigScriptShortcutOverride]
    let message: String

    init?(_ overrides: [ConfigScriptShortcutOverride]) {
        guard let first = overrides.first else { return nil }
        self.overrides = overrides
        let chord = first.chord.humanReadableString
        let command = first.command.displayName
        let location = "\(first.source):\(first.line)"
        let assignment = first.field == .modeKey ? "mode key" : "shortcut"
        let detail = "Settings \(assignment) '\(chord)' for \(command) is overridden by \(location)."
        let mode: String
        if let name = first.modeName {
            mode = " It is unavailable outside the \(name) key mode while that binding is loaded."
        } else if overrides.contains(where: { $0.modeName != nil }) {
            mode = " Shortcuts overridden by a key mode are also unavailable outside that mode while it is loaded."
        } else {
            mode = ""
        }
        let total = overrides.count > 1 ? " \(overrides.count) Settings assignments are overridden." : ""
        message = detail + mode + total
    }
}

struct ConfigScriptShortcutResolution: Equatable {
    var bindings: [HotkeyBinding] = []
    var scriptBindings: [HotkeyBinding] = []
    var namedModes = NamedKeyModes()
    var overrides: [ConfigScriptShortcutOverride] = []
}

struct ConfigScriptValidatedShortcuts {
    private enum Scope {
        case ordinary, modeKey, named
    }

    private struct Claim {
        let row: ConfigScriptBinding
        let chord: KeyBinding
        let scope: Scope

        func conflicts(with entry: KeyboardModeTable.Entry) -> Bool {
            switch scope {
            case .ordinary: chord.conflicts(with: entry.binding)
            case .modeKey: entry.conflicts(with: KeyboardModeTable.Entry(binding: chord, command: row.command))
            case .named: false
            }
        }
    }

    private var ordinary: [ConfigScriptBinding] = []
    private var named: [ConfigScriptBinding] = []
    private(set) var masked: Set<KeyBinding> = []
    private(set) var error: ConfigScriptError?

    init(_ declarations: [ConfigScriptBinding], parsedWith mask: UInt32, hyperMask: UInt32) {
        if mask == hyperMask, declarations.allSatisfy({ $0.mode == nil && $0.modeKey == nil }) {
            ordinary = declarations
            return
        }
        var claims: [UInt32: [Claim]] = [:]
        for var row in declarations where row.mode == nil {
            let parsed = mask == hyperMask ? row.chord : KeySymbolMapper.fromHumanReadable(
                row.rawChord,
                hyperMask: hyperMask
            )
            guard let key = parsed, !key.isUnassigned else {
                reject(row, message: "Invalid chord '\(row.rawChord)'.")
                continue
            }
            if let prior = claims[key.keyCode]?.first(where: { $0.chord.conflicts(with: key) }) {
                reject(
                    row,
                    message: "'\(row.rawChord)' for \(row.command.displayName) conflicts with \(prior.row.source):\(prior.row.line)."
                )
                continue
            }
            if let modeKey = row.modeKey {
                let entry = KeyboardModeTable.Entry(binding: modeKey, command: row.command)
                let prior = claims[modeKey.keyCode]?.first { $0.conflicts(with: entry) }
                if let prior {
                    reject(
                        row,
                        message: "Mode key '\(modeKey.humanReadableString)' for \(row.command.displayName) conflicts with \(prior.row.source):\(prior.row.line)."
                    )
                    continue
                }
                if modeKey.conflicts(with: key) {
                    reject(
                        row,
                        message: "Mode key '\(modeKey.humanReadableString)' conflicts with its shortcut '\(row.rawChord)'."
                    )
                    continue
                }
            }
            row.chord = key
            ordinary.append(row)
            Self.addClaims(for: row, to: &claims)
        }
        validateNamed(declarations, against: claims)
    }

    private mutating func validateNamed(_ declarations: [ConfigScriptBinding], against claims: [UInt32: [Claim]]) {
        for row in declarations where row.mode != nil {
            if let prior = claims[row.chord.keyCode]?.first(where: {
                $0.scope == .ordinary && $0.chord.conflicts(with: row.chord)
            }) {
                reject(
                    row,
                    message: "'\(row.rawChord)' in a mode conflicts with the shortcut at \(prior.row.source):\(prior.row.line)."
                )
            } else {
                named.append(row)
            }
        }
    }

    @MainActor
    func resolve(
        base: [HotkeyBinding], modes: [ConfigScriptNamedMode], settings: SettingsStore
    ) -> ConfigScriptShortcutResolution {
        var resolution = ConfigScriptShortcutResolution()
        var claims: [UInt32: [Claim]] = [:]
        var enabledBindings: [HotkeyBinding] = []
        for row in ordinary {
            let key = row.chord
            let id = "script:\(key.keyCode):\(key.modifiers):\(key.sidedModifiers.left):\(key.sidedModifiers.right)"
            let binding = HotkeyBinding(id: id, command: row.command, trigger: .chord(key), modeKey: row.modeKey)
            resolution.scriptBindings.append(binding)
            if settings.isCommandFeatureEnabled(row.command) {
                enabledBindings.append(binding)
                Self.addClaims(for: row, to: &claims)
            }
        }
        var entries: [Int: [KeyboardModeTable.Entry]] = [:]
        for row in named where settings.isCommandFeatureEnabled(row.command) {
            guard let mode = row.mode else { continue }
            entries[mode, default: []].append(KeyboardModeTable.Entry(binding: row.chord, command: row.command))
            claims[row.chord.keyCode, default: []].append(Claim(row: row, chord: row.chord, scope: .named))
        }
        resolution.namedModes = NamedKeyModes(modes.compactMap { mode in
            entries[mode.id].map { NamedKeyModes.Mode(id: mode.id, name: mode.name, entries: $0) }
        })
        resolution.bindings.reserveCapacity(base.count + enabledBindings.count)
        for var row in base where settings.isCommandFeatureEnabled(row.command) {
            Self.maskSettingsFields(in: &row, claims: claims, overrides: &resolution.overrides)
            resolution.bindings.append(row)
        }
        resolution.scriptBindings.sort { $0.id < $1.id }
        enabledBindings.sort { $0.id < $1.id }
        resolution.bindings.append(contentsOf: enabledBindings)
        return resolution
    }

    private mutating func reject(_ row: ConfigScriptBinding, message: String) {
        masked.insert(row.chord)
        error = error ?? ConfigScriptError(line: row.line, message: message, source: row.source)
    }

    private static func addClaims(for row: ConfigScriptBinding, to claims: inout [UInt32: [Claim]]) {
        claims[row.chord.keyCode, default: []].append(Claim(row: row, chord: row.chord, scope: .ordinary))
        if let key = row.modeKey {
            claims[key.keyCode, default: []].append(Claim(row: row, chord: key, scope: .modeKey))
        }
    }

    private static func maskSettingsFields(
        in row: inout HotkeyBinding, claims: [UInt32: [Claim]], overrides: inout [ConfigScriptShortcutOverride]
    ) {
        if let chord = row.binding.chordBinding,
           let winner = claims[chord.keyCode]?.first(where: { $0.chord.conflicts(with: chord) })
        {
            overrides.append(record(row, field: .shortcut, chord: chord, winner: winner.row))
            row.binding = .unassigned
        }
        if let chord = row.modeKey {
            let entry = KeyboardModeTable.Entry(binding: chord, command: row.command)
            if entry.isSupported, let winner = claims[chord.keyCode]?.first(where: { $0.conflicts(with: entry) }) {
                overrides.append(record(row, field: .modeKey, chord: chord, winner: winner.row))
                row.modeKey = nil
            }
        }
    }

    private static func record(
        _ row: HotkeyBinding, field: ConfigScriptShortcutOverride.Field, chord: KeyBinding, winner: ConfigScriptBinding
    ) -> ConfigScriptShortcutOverride {
        ConfigScriptShortcutOverride(
            bindingID: row.id, field: field, chord: chord, command: row.command, source: winner.source,
            line: winner.line, modeName: winner.modeName
        )
    }
}
