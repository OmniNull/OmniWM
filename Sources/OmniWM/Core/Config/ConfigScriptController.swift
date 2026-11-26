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
    nonisolated static let fileName = "init.luau"

    private struct Input: Equatable {
        var versions: [URL: ConfigScriptFileVersion]
        var hyperMask: UInt32
    }

    @ObservationIgnored private(set) weak var wmController: WMController?
    @ObservationIgnored private(set) var eventObservers: ConfigScriptEventObservers?
    private let fileURL: URL
    private let settings: SettingsStore
    let observation: SettingsFileObservation
    let loader: ConfigScriptLoader
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
    @ObservationIgnored private(set) var acceptedNamedModes: [ConfigScriptNamedMode] = []
    private(set) var acceptedRules: [ConfigScriptRule] = []
    private(set) var acceptedCommands: [ConfigScriptNamedCommand] = []
    private(set) var maskedBindingChords: Set<KeyBinding> = []
    @ObservationIgnored private var acceptedFiles: Set<URL> = []
    @ObservationIgnored private var bindingConflict: String?
    @ObservationIgnored private var acceptedRuleConflict: String?
    @ObservationIgnored private var acceptedMask: UInt32 = 0
    @ObservationIgnored private var loadError: String?
    @ObservationIgnored private(set) var callbackQueue: ConfigScriptCallbackQueue?
    @ObservationIgnored private var callbackError: String?
    @ObservationIgnored private(set) var diagnostic: String?
    @ObservationIgnored private(set) var effectiveBindings: [HotkeyBinding] = []

    init(
        fileURL: URL,
        settings: SettingsStore,
        loader: ConfigScriptLoader = ConfigScriptLoader(),
        wmController: WMController? = nil,
        timerSleep: @escaping ConfigScriptTimerSleep = { try await Task.sleep(for: $0) },
        didChangeBindings: @escaping @MainActor ([HotkeyBinding]) -> Void
    ) {
        self.wmController = wmController
        self.fileURL = fileURL.standardizedFileURL
        self.settings = settings
        self.loader = loader
        self.timerSleep = timerSleep
        self.didChangeBindings = didChangeBindings
        observation = SettingsFileObservation(
            directoryURL: self.fileURL.deletingLastPathComponent(),
            fileURL: self.fileURL
        )
    }

    isolated deinit {
        eventObservers?.stop()
        callbackQueue?.retire()
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
        acceptedNamedModes = []
        wmController?.hotkeys.updateNamedKeyModes(NamedKeyModes())
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
            let conflict = resolved.conflict ?? (rules == acceptedRules ? acceptedRuleConflict : ruleConflict(rules))
            if let conflict {
                loadError = conflict
            } else {
                retireCallbacks()
                callbackQueue = evaluation?.generation.map { ConfigScriptCallbackQueue(
                    generation: $0, bindings: declarations, commands: commands, events: evaluation?.events ?? [],
                    fullQueueDiagnostic: { source, line in
                        description(
                            source: source,
                            line: line,
                            message: "Callback queue is full. This press was dropped."
                        )
                    }
                ) }
                callbackQueue?.activate(owner: self, controller: wmController)
                callbackError = nil
                (acceptedBindings, acceptedNamedModes) = (declarations, evaluation?.namedModes ?? [])
                acceptedRules = rules
                acceptedRuleConflict = nil
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
                publishNamedKeyModes()
                if rulesChanged { onRulesChanged?() }
                if commandsChanged { onCommandsChanged?() }
                refreshLoadDiagnostic()
                installEvents(evaluation?.events ?? [])
                if let timers = evaluation?.timers, !timers.isEmpty { installTimers(timers) }
                return true
            }
        }
        refreshLoadDiagnostic()
        return false
    }

    func bindings(for base: [HotkeyBinding]) -> [HotkeyBinding] {
        if let requested, requested.hyperMask != settings.hyperKeyModifiers.carbonMask {
            requestCurrent()
        }
        let resolved = resolve(acceptedBindings, parsedWith: acceptedMask, base: base)
        effectiveBindings = resolved.rows
        maskedBindingChords = resolved.masked
        publishNamedKeyModes(masking: resolved.maskedModeKeys)
        bindingConflict = resolved.conflict
        refreshLoadDiagnostic()
        return resolved.rows
    }

    func refreshRuleConflicts() {
        acceptedRuleConflict = ruleConflict(acceptedRules)
        refreshLoadDiagnostic()
    }

    private var loadDiagnostic: String? {
        loadError ?? bindingConflict ?? acceptedRuleConflict
    }

    private func refreshLoadDiagnostic() {
        refreshDiagnostic()
        let current = loadDiagnostic
        if settings.configScriptLoadError != current {
            settings.configScriptLoadError = current
        }
    }

    private func refreshDiagnostic() {
        let configError = loadDiagnostic
        if let configError, let callbackError {
            updateDiagnostic("\(configError)\n\(callbackError)")
        } else {
            updateDiagnostic(configError ?? callbackError)
        }
    }

    struct UnpublishedRefusal: Error {
        let diagnostic: String
    }

    static func enqueue(
        _ function: Int, from script: inout ConfigScriptController?, controller: WMController
    ) throws(UnpublishedRefusal) -> ExternalCommandResult {
        guard let script else { return .notFound }
        let result = ConfigScriptCallbackQueue.enqueue(function, in: &script.callbackQueue, controller: controller)
        if result == .windowActionFailed,
           let message = script.callbackQueue?.declarations[function]?.fullQueueDiagnostic,
           script.callbackError != message
        {
            throw UnpublishedRefusal(diagnostic: message)
        }
        return result
    }

    func publishCallbackDiagnostic(_ message: String) {
        callbackError = message
        refreshDiagnostic()
    }

    func reportCallbackError(_ error: ConfigScriptError) {
        publishCallbackDiagnostic(description(source: error.source, line: error.line, message: error.message))
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

    func description(source: String, line: Int?, message: String) -> String {
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
    struct Claim {
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
        var maskedModeKeys: Set<Int> = []
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
        for row in declarations where row.mode == nil {
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
        let modeKeys = namedKeyMask(declarations, claims: claims)
        (resolution.maskedModeKeys, resolution.conflict) = (modeKeys.masked, resolution.conflict ?? modeKeys.conflict)
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
                    return queue.capture(reads: reads, controller: controller)
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
            eventObservers = ConfigScriptEventObservers(controller: controller, kinds: kinds, queue: queue)
        }
        publishReloaded(reloaded, controller: controller)
    }

    func publishReloaded(_ subscribed: Bool, controller: WMController) {
        guard subscribed else { return }
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.eventPayloadBuilt()
        #endif
        ConfigScriptCallbackQueue.publish(.configReloaded, .init(), in: &callbackQueue, controller: controller)
    }
}
