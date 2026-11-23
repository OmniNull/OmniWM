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

    @ObservationIgnored private weak var wmController: WMController?
    @ObservationIgnored private(set) var eventObservers: ConfigScriptEventObservers?
    private let fileURL: URL
    private let settings: SettingsStore
    let observation: SettingsFileObservation
    private let loader = ConfigScriptLoader()
    private let timerSleep: ConfigScriptTimerSleep
    @ObservationIgnored private(set) var timerWorker: Task<Void, Never>?
    private let didChangeBindings: @MainActor ([HotkeyBinding]) -> Void
    @ObservationIgnored var onDiagnosticChanged: (@MainActor (String?) -> Void)?
    @ObservationIgnored var onRulesChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onCommandsChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onReloadProcessed: (@MainActor () -> Void)?
    @ObservationIgnored private var requested: Input?
    @ObservationIgnored private var job: Task<Void, Never>?
    private(set) var acceptedBindings: [ConfigScriptBinding] = []
    private(set) var acceptedRules: [ConfigScriptRule] = []
    private(set) var acceptedCommands: [ConfigScriptNamedCommand] = []
    private(set) var maskedBindingChords: Set<KeyBinding> = []
    @ObservationIgnored private var acceptedFiles: Set<URL> = []
    @ObservationIgnored private var bindingConflict: String?
    @ObservationIgnored private var acceptedMask: UInt32 = 0
    @ObservationIgnored private var loadError: String?
    @ObservationIgnored private(set) var callbackQueue: ConfigScriptCallbackQueue?
    @ObservationIgnored private var callbackError: String?
    @ObservationIgnored private(set) var diagnostic: String?
    @ObservationIgnored private(set) var effectiveBindings: [HotkeyBinding] = []

    init(
        fileURL: URL,
        settings: SettingsStore,
        wmController: WMController? = nil,
        timerSleep: @escaping ConfigScriptTimerSleep = { try await Task.sleep(for: $0) },
        didChangeBindings: @escaping @MainActor ([HotkeyBinding]) -> Void
    ) {
        self.wmController = wmController
        self.fileURL = fileURL.standardizedFileURL
        self.settings = settings
        self.timerSleep = timerSleep
        self.didChangeBindings = didChangeBindings
        observation = SettingsFileObservation(
            directoryURL: self.fileURL.deletingLastPathComponent(),
            fileURL: self.fileURL
        )
    }

    isolated deinit {
        timerWorker?.cancel()
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
        retireCallbacks()
        if !acceptedCommands.isEmpty {
            acceptedCommands.removeAll()
            onCommandsChanged?()
        }
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
            let commands = evaluation?.namedCommands ?? []
            let resolved = resolve(declarations, parsedWith: hyperMask, base: settings.hotkeyBindings)
            if let conflict = resolved.conflict ?? ruleConflict(rules) {
                loadError = conflict
            } else {
                retireCallbacks()
                callbackQueue = evaluation?.generation.map { ConfigScriptCallbackQueue(
                    generation: $0, bindings: declarations, commands: commands, events: evaluation?.events ?? []
                ) }
                callbackError = nil
                acceptedBindings = declarations
                acceptedRules = rules
                let commandsChanged = commands != acceptedCommands
                if commandsChanged { acceptedCommands = commands }
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
                if commandsChanged { onCommandsChanged?() }
                updateDiagnostic(nil)
                installEvents(evaluation?.events ?? [])
                if let timers = evaluation?.timers, !timers.isEmpty { installTimers(timers) }
                return true
            }
        }
        refreshRuleConflicts()
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
        let configError = loadError ?? bindingConflict ?? ruleConflict(acceptedRules)
        if let configError, let callbackError {
            updateDiagnostic("\(configError)\n\(callbackError)")
        } else {
            updateDiagnostic(configError ?? callbackError)
        }
    }

    func enqueue(function: Int, controller: WMController) -> ExternalCommandResult {
        guard let callbackQueue, let reads = callbackQueue.declarations[function]?.reads else { return .notFound }
        guard callbackQueue.hasCapacity else {
            guard let row = callbackQueue.declarations[function] else { return .notFound }
            reportCallbackError(ConfigScriptError(
                line: row.line, message: "Callback queue is full. This press was dropped.", source: row.source
            ))
            return .windowActionFailed
        }
        callbackQueue.enqueue(function: function, reads: reads, controller: controller, owner: self)
        return .executed
    }

    func reportCallbackError(_ error: ConfigScriptError) {
        callbackError = description(source: error.source, line: error.line, message: error.message)
        refreshRuleConflicts()
    }

    private func ruleConflict(_ rules: [ConfigScriptRule]) -> String? {
        guard !rules.isEmpty, !settings.appRules.isEmpty else { return nil }
        let baseIDs = Set(settings.appRules.map(\.id))
        guard let row = rules.first(where: { baseIDs.contains($0.rule.id) }) else { return nil }
        return description(
            source: row.source,
            line: row.line,
            message: "Rule ID \(row.rule.id) conflicts with Settings."
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
}

extension ConfigScriptController {
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
                    claims[key.keyCode, default: []].append(Self(chord: key, owner: "Settings \(row.id)"))
                }
                if let key = row.modeKey {
                    claims[key.keyCode, default: []].append(Self(
                        chord: key, owner: "Settings mode key \(row.id)", modeCommand: row.command
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

extension ConfigScriptController {
    private func retireCallbacks() {
        timerWorker?.cancel()
        timerWorker = nil
        eventObservers?.stop()
        eventObservers = nil
        callbackQueue?.retire()
        callbackQueue = nil
    }

    private func installTimers(_ timers: [ConfigScriptTimer]) {
        guard let queue = callbackQueue, let controller = wmController else { return }
        timerWorker = Task { [generation = queue.generation, timerSleep, weak self, weak queue, weak controller] in
            await generation.runTimers(
                timers,
                sleep: timerSleep,
                capture: { [weak self, weak queue, weak controller] reads in
                    guard !Task.isCancelled, let self, let queue, let controller,
                          callbackQueue === queue else { return nil }
                    return controller.configScriptCapture(reads: reads)
                },
                deliver: { [weak self, weak queue, weak controller] result, target in
                    guard !Task.isCancelled, let self, let queue, let controller,
                          callbackQueue === queue else { return }
                    await queue.applyTimer(result, target: target, controller: controller, owner: self)
                }
            )
        }
    }

    private func installEvents(_ events: [ConfigScriptEventListener]) {
        guard !events.isEmpty, let controller = wmController, let queue = callbackQueue else { return }
        var kinds = Set(events.map(\.kind))
        let reloaded = kinds.remove(.configReloaded) != nil
        if !kinds.isEmpty {
            eventObservers = ConfigScriptEventObservers(controller: controller, kinds: kinds) {
                [weak self] kind, payload in
                guard let self, let queue = callbackQueue, let controller = wmController else { return }
                queue.enqueue(event: kind, payload: payload, controller: controller, owner: self)
            }
        }
        if reloaded {
            #if OMNIWM_CONFIG_CALLBACK_TRACE
                ConfigScriptLatencyTrace.eventPayloadBuilt()
            #endif
            queue.enqueue(event: .configReloaded, payload: .init(), controller: controller, owner: self)
        }
    }
}
