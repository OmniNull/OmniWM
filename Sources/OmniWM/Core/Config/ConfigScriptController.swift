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
    private let didChangeBindings: @MainActor (ConfigScriptShortcutResolution) -> Void
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
    @ObservationIgnored private var shortcutInputs: ShortcutInputs?
    @ObservationIgnored private var shortcutResolution = ConfigScriptShortcutResolution()

    var effectiveBindings: [HotkeyBinding] {
        shortcutResolution.scriptBindings
    }

    private struct ShortcutInputs: Equatable {
        let base: [HotkeyBinding]
        let hyperMask: UInt32
        let overviewEnabled: Bool
        let quakeEnabled: Bool

        @MainActor
        init(base: [HotkeyBinding], settings: SettingsStore) {
            self.base = base
            hyperMask = settings.hyperKeyModifiers.carbonMask
            overviewEnabled = settings.overview.enabled
            quakeEnabled = settings.quakeTerminal.enabled
        }
    }

    init(
        fileURL: URL,
        settings: SettingsStore,
        loader: ConfigScriptLoader = ConfigScriptLoader(),
        wmController: WMController? = nil,
        timerSleep: @escaping ConfigScriptTimerSleep = { try await Task.sleep(for: $0) },
        didChangeBindings: @escaping @MainActor (ConfigScriptShortcutResolution) -> Void
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
        if let hotkeys = wmController?.hotkeys {
            hotkeys.retireHeldBindings()
            hotkeys.updateNamedKeyModes(NamedKeyModes())
        }
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
            let inputs = ShortcutInputs(base: settings.hotkeyBindings, settings: settings)
            let validated = ConfigScriptValidatedShortcuts(
                declarations,
                parsedWith: hyperMask,
                hyperMask: inputs.hyperMask
            )
            let conflict = bindingDiagnostic(validated.error)
                ?? (rules == acceptedRules ? acceptedRuleConflict : ruleConflict(rules))
            if let conflict {
                loadError = conflict
            } else {
                replaceCallbackQueue(evaluation, bindings: declarations, commands: commands)
                callbackError = nil
                (acceptedBindings, acceptedNamedModes) = (declarations, evaluation?.namedModes ?? [])
                acceptedRules = rules
                acceptedRuleConflict = nil
                let commandsChanged = commands != acceptedCommands
                if commandsChanged { acceptedCommands = commands }
                acceptedMask = hyperMask
                loadError = nil
                let rulesChanged = settings.setScriptAppRules(rules.map(\.rule))
                let previous = shortcutResolution
                let resolved = resolve(validated, inputs: inputs)
                if previous.scriptBindings != resolved.scriptBindings || previous.namedModes != resolved.namedModes
                    || previous.overrides != resolved.overrides
                {
                    didChangeBindings(resolved)
                }
                if rulesChanged { onRulesChanged?() }
                if commandsChanged { onCommandsChanged?() }
                publishDiagnostics(overrides: resolved.overrides)
                installEvents(evaluation?.events ?? [])
                if let timers = evaluation?.timers, !timers.isEmpty { installTimers(timers) }
                return true
            }
        }
        publishDiagnostics()
        return false
    }

    func resolveBindings(for base: [HotkeyBinding]) -> ConfigScriptShortcutResolution {
        let inputs = ShortcutInputs(base: base, settings: settings)
        if let requested, requested.hyperMask != inputs.hyperMask {
            requestCurrent()
        }
        if inputs == shortcutInputs { return shortcutResolution }
        let validated = ConfigScriptValidatedShortcuts(
            acceptedBindings, parsedWith: acceptedMask, hyperMask: inputs.hyperMask
        )
        return resolve(validated, inputs: inputs)
    }

    private func resolve(
        _ validated: ConfigScriptValidatedShortcuts, inputs: ShortcutInputs
    ) -> ConfigScriptShortcutResolution {
        let resolved = validated.resolve(base: inputs.base, modes: acceptedNamedModes, settings: settings)
        shortcutInputs = inputs
        shortcutResolution = resolved
        if maskedBindingChords != validated.masked { maskedBindingChords = validated.masked }
        bindingConflict = bindingDiagnostic(validated.error)
        return resolved
    }

    private func bindingDiagnostic(_ error: ConfigScriptError?) -> String? {
        error.map { description(source: $0.source, line: $0.line, message: $0.message) }
    }

    func refreshRuleConflicts() {
        acceptedRuleConflict = ruleConflict(acceptedRules)
        publishDiagnostics()
    }

    private var loadDiagnostic: String? {
        loadError ?? bindingConflict ?? acceptedRuleConflict
    }

    func publishDiagnostics(overrides: [ConfigScriptShortcutOverride]? = nil) {
        let configError = loadDiagnostic
        if let configError, let callbackError {
            updateDiagnostic("\(configError)\n\(callbackError)")
        } else {
            updateDiagnostic(configError ?? callbackError)
        }
        settings.publishConfigScriptErrors(load: configError, callback: callbackError, overrides: overrides)
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
        guard callbackError != message else { return }
        callbackError = message
        publishDiagnostics()
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
    private func replaceCallbackQueue(
        _ evaluation: ConfigScriptEvaluation?, bindings: [ConfigScriptBinding], commands: [ConfigScriptNamedCommand]
    ) {
        let controller = wmController
        controller?.hotkeys.retireHeldBindings()
        retireCallbacks()
        callbackQueue = evaluation?.generation.map { ConfigScriptCallbackQueue(
            generation: $0, bindings: bindings, commands: commands, events: evaluation?.events ?? [],
            fullQueueDiagnostic: { source, line in
                description(
                    source: source,
                    line: line,
                    message: "Callback queue is full. This press was dropped."
                )
            }
        ) }
        callbackQueue?.activate(owner: self, controller: controller)
    }

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
