// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

struct ConfigScriptLoad: Sendable {
    let versions: [URL: ConfigScriptFileVersion]
    let result: Result<ConfigScriptEvaluation?, ConfigScriptError>
}

enum ConfigScriptFileVersion: Equatable, Sendable {
    case target(SettingsFileAccess.Fingerprint)
    case unresolved(link: SettingsFileAccess.Fingerprint?, error: Int)

    init(at fileURL: URL) {
        do {
            self = try .target(SettingsFileAccess.fileFingerprint(at: fileURL))
        } catch {
            self = .unresolved(
                link: try? SettingsFileAccess.fileFingerprint(at: fileURL, followingLinks: false),
                error: (error as NSError).code
            )
        }
    }

    var targetFingerprint: SettingsFileAccess.Fingerprint? {
        if case let .target(fingerprint) = self { return fingerprint }
        return nil
    }
}

@MainActor @Observable
final class ConfigScriptController {
    private struct Input: Equatable {
        var versions: [URL: ConfigScriptFileVersion]
        var hyperMask: UInt32
    }

    private let fileURL: URL
    private let settings: SettingsStore
    let observation: SettingsFileObservation
    private let loader = ConfigScriptLoader()
    private let didChangeBindings: @MainActor ([HotkeyBinding]) -> Void
    @ObservationIgnored var onDiagnosticChanged: (@MainActor (String?) -> Void)?
    @ObservationIgnored var onRulesChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onReloadProcessed: (@MainActor () -> Void)?
    @ObservationIgnored private var requested: Input?
    @ObservationIgnored private var job: Task<Void, Never>?
    private(set) var acceptedBindings: [ConfigScriptBinding] = []
    private(set) var acceptedRules: [ConfigScriptRule] = []
    private(set) var maskedBindingChords: Set<KeyBinding> = []
    @ObservationIgnored private var acceptedFiles: Set<URL> = []
    @ObservationIgnored private var bindingConflict: String?
    @ObservationIgnored private var acceptedMask: UInt32 = 0
    @ObservationIgnored private var loadError: String?
    @ObservationIgnored private(set) var diagnostic: String?
    @ObservationIgnored private(set) var effectiveBindings: [HotkeyBinding] = []

    init(
        fileURL: URL,
        settings: SettingsStore,
        didChangeBindings: @escaping @MainActor ([HotkeyBinding]) -> Void
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.settings = settings
        self.didChangeBindings = didChangeBindings
        observation = SettingsFileObservation(
            directoryURL: self.fileURL.deletingLastPathComponent(),
            fileURL: self.fileURL
        )
    }

    func start() {
        guard requested == nil else { return }
        observation.onPossibleChange = { [weak self] url in
            guard let self else { return }
            requestCurrent(changed: observation.filesAffected(by: url))
        }
        observation.start()
        requestCurrent()
    }

    func stop() {
        observation.onPossibleChange = nil
        observation.stop()
        job?.cancel()
        job = nil
        requested = nil
    }

    private func requestCurrent(changed: Set<URL>? = nil) {
        var versions = requested?.versions ?? [:]
        let affected = changed ?? [fileURL]
        for path in affected where path == fileURL || versions[path] != nil {
            versions[path] = ConfigScriptFileVersion(at: path)
        }
        observation.refresh(files: versions.mapValues(\.targetFingerprint))
        let input = Input(versions: versions, hyperMask: settings.hyperKeyModifiers.carbonMask)
        guard input != requested else { return }
        requested = input
        if job == nil { schedule(input) }
    }

    private func schedule(_ input: Input) {
        job = Task { [weak self, fileURL, loader] in
            let load = await loader.load(fileURL: fileURL, hyperMask: input.hyperMask)
            guard !Task.isCancelled else { return }
            self?.finish(load, input: input)
        }
    }

    private func finish(_ load: ConfigScriptLoad, input: Input) {
        job = nil
        guard let requested else { return }
        let paths = acceptedFiles.union(load.versions.keys)
        var current = Dictionary(uniqueKeysWithValues: paths.map { ($0, ConfigScriptFileVersion(at: $0)) })
        observation.refresh(files: current.mapValues(\.targetFingerprint))
        for path in paths { current[path] = ConfigScriptFileVersion(at: path) }
        let mask = settings.hyperKeyModifiers.carbonMask
        let updated = Input(versions: current, hyperMask: mask)
        self.requested = updated
        guard input == requested, input.hyperMask == mask,
              load.versions.allSatisfy({ current[$0.key] == $0.value })
        else {
            schedule(updated)
            return
        }
        if publish(load, hyperMask: mask) {
            acceptedFiles = Set(load.versions.keys)
            self.requested = Input(versions: load.versions, hyperMask: mask)
            if current.count != load.versions.count {
                observation.refresh(files: load.versions.mapValues(\.targetFingerprint))
            }
        }
        onReloadProcessed?()
    }

    @discardableResult
    func apply(_ load: ConfigScriptLoad, hyperMask: UInt32) -> Bool {
        guard load.versions.allSatisfy({ ConfigScriptFileVersion(at: $0.key) == $0.value }) else { return false }
        _ = publish(load, hyperMask: hyperMask)
        return true
    }

    private func publish(_ load: ConfigScriptLoad, hyperMask: UInt32) -> Bool {
        switch load.result {
        case let .failure(error):
            loadError = description(source: error.source, line: error.line, message: error.message)
        case let .success(evaluation):
            let declarations = evaluation?.bindings ?? []
            let rules = evaluation?.rules ?? []
            let resolved = resolve(declarations, parsedWith: hyperMask, base: settings.hotkeyBindings)
            if let conflict = resolved.conflict ?? ruleConflict(rules) {
                loadError = conflict
            } else {
                acceptedBindings = declarations
                acceptedRules = rules
                maskedBindingChords = []
                acceptedMask = hyperMask
                loadError = nil
                bindingConflict = nil
                let rulesChanged = settings.setScriptAppRules(rules.map(\.rule))
                if effectiveBindings != resolved.rows {
                    effectiveBindings = resolved.rows
                    didChangeBindings(resolved.rows)
                }
                if rulesChanged { onRulesChanged?() }
                updateDiagnostic(nil)
                return true
            }
        }
        updateDiagnostic(loadError)
        return false
    }

    func bindings(for base: [HotkeyBinding]) -> [HotkeyBinding] {
        if let requested, requested.hyperMask != settings.hyperKeyModifiers.carbonMask {
            requestCurrent()
        }
        let resolved = resolve(acceptedBindings, parsedWith: acceptedMask, base: base)
        effectiveBindings = resolved.rows
        maskedBindingChords = resolved.masked
        bindingConflict = resolved.conflict
        refreshRuleConflicts()
        return resolved.rows
    }

    func refreshRuleConflicts() {
        updateDiagnostic(loadError ?? bindingConflict ?? ruleConflict(acceptedRules))
    }

    private func ruleConflict(_ rules: [ConfigScriptRule]) -> String? {
        guard !rules.isEmpty, !settings.appRules.isEmpty else { return nil }
        let baseIDs = Set(settings.appRules.map(\.id))
        guard let row = rules.first(where: { baseIDs.contains($0.rule.id) }) else { return nil }
        return description(
            source: row.source,
            line: row.line,
            message: "Rule ID \(row.rule.id) conflicts with Settings/TOML."
        )
    }

    private func description(source: String, line: Int?, message: String) -> String {
        let path = source.hasPrefix("/") ? source : fileURL.deletingLastPathComponent().appendingPathComponent(source)
            .path
        let location = line.map { ":\($0)" } ?? ""
        return "\(path)\(location): \(message)"
    }

    private func updateDiagnostic(_ value: String?) {
        guard diagnostic != value else { return }
        diagnostic = value
        if let value { Log.config.error(value) }
        onDiagnosticChanged?(value)
    }

    private struct Claim {
        let chord: KeyBinding
        let owner: String
        var modeCommand: HotkeyCommand?

        func conflicts(with entry: KeyboardModeTable.Entry) -> Bool {
            if let modeCommand {
                return entry.conflicts(with: KeyboardModeTable.Entry(binding: chord, command: modeCommand))
            }
            return chord.conflicts(with: entry.binding)
        }

        static func configured(_ base: [HotkeyBinding]) -> [UInt32: [Self]] {
            var claims: [UInt32: [Self]] = [:]
            for row in base {
                if let key = row.binding.chordBinding {
                    claims[key.keyCode, default: []].append(Self(chord: key, owner: "Settings/TOML \(row.id)"))
                }
                if let key = row.modeKey {
                    claims[key.keyCode, default: []].append(Self(
                        chord: key, owner: "Settings/TOML mode key \(row.id)", modeCommand: row.command
                    ))
                }
            }
            return claims
        }

        static func conflict(
            for row: ConfigScriptBinding,
            chord: KeyBinding,
            in claims: [UInt32: [Self]]
        ) -> String? {
            if let prior = claims[chord.keyCode]?.first(where: { $0.chord.conflicts(with: chord) }) {
                return "'\(row.rawChord)' for \(row.command.displayName) conflicts with \(prior.owner)."
            }
            if let key = row.modeKey {
                let mode = KeyboardModeTable.Entry(binding: key, command: row.command)
                if let prior = claims[key.keyCode]?.first(where: { $0.conflicts(with: mode) }) {
                    return "Mode key '\(key.humanReadableString)' for \(row.command.displayName) conflicts with \(prior.owner)."
                }
            }
            return nil
        }
    }

    private struct Resolution {
        var rows: [HotkeyBinding] = []
        var masked: Set<KeyBinding> = []
        var conflict: String?
    }

    private func resolve(
        _ declarations: [ConfigScriptBinding],
        parsedWith mask: UInt32,
        base: [HotkeyBinding]
    ) -> Resolution {
        guard !declarations.isEmpty else { return Resolution() }
        let hyperMask = settings.hyperKeyModifiers.carbonMask
        let checkScriptClaims = mask != hyperMask || declarations.contains { $0.modeKey != nil }
        var claims = Claim.configured(base)
        var resolution = Resolution()
        resolution.rows.reserveCapacity(declarations.count)
        for row in declarations {
            let key = mask == hyperMask ? row.chord : KeySymbolMapper.fromHumanReadable(
                row.rawChord,
                hyperMask: hyperMask
            )
            guard let key, !key.isUnassigned else {
                resolution.masked.insert(row.chord)
                resolution.conflict = resolution.conflict ?? description(
                    source: row.source, line: row.line,
                    message: "Invalid chord '\(row.rawChord)'."
                )
                continue
            }
            if let conflict = Claim.conflict(for: row, chord: key, in: claims) {
                resolution.masked.insert(row.chord)
                resolution.conflict = resolution.conflict ?? description(
                    source: row.source, line: row.line, message: conflict
                )
                continue
            }
            if let modeKey = row.modeKey {
                claims[modeKey.keyCode, default: []].append(Claim(
                    chord: modeKey, owner: "\(row.source):\(row.line) mode key for \(row.command.displayName)",
                    modeCommand: row.command
                ))
            }
            if checkScriptClaims {
                claims[key.keyCode, default: []].append(Claim(
                    chord: key,
                    owner: "\(row.source):\(row.line) \(row.command.displayName)"
                ))
            }
            let id = "script:\(key.keyCode):\(key.modifiers):\(key.sidedModifiers.left):\(key.sidedModifiers.right)"
            resolution.rows.append(HotkeyBinding(
                id: id,
                command: row.command,
                trigger: .chord(key),
                modeKey: row.modeKey
            ))
        }
        resolution.rows.sort { $0.id < $1.id }
        return resolution
    }
}
