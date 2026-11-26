// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import OmniWMScriptHost
import Synchronization

struct ConfigScriptStage {
    private static let nextFunction = Atomic<Int>(0)
    private static let nextMode = Atomic<Int>(0)
    let hyperMask: UInt32
    var bindings: [ConfigScriptBinding] = []
    var rules: [ConfigScriptRule] = []
    var namedCommands: [ConfigScriptNamedCommand] = []
    var events: [ConfigScriptEventListener] = []
    var namedModes: [ConfigScriptNamedMode] = []
    var sources: ConfigScriptSources
    var store: ConfigScriptStoreAccess?
    private var ruleIDs: [UUID: Int] = [:]
    private var commandNames: [String: Int] = [:]
    private struct Action {
        let command: HotkeyCommand
        let text: String
    }

    private struct EffectText: Hashable {
        let value: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.value.utf8.elementsEqual(rhs.value.utf8)
        }

        func hash(into hasher: inout Hasher) {
            var text = value
            text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }

    private enum ActionKey: Hashable {
        case command(HotkeyCommand)
        case effect(EffectText)
    }

    private enum Phase {
        case declarations
        case callbacks(sourceNames: [String])
    }

    private var actions: [Action] = []
    private var actionIDs: [ActionKey: UInt32] = [:]
    private var actionBytes = 0
    private var phase = Phase.declarations
    private(set) var functions: [Int: UInt32] = [:]
    var dispatched: [ConfigScriptDispatch] = []

    func forCallbacks() -> Self {
        var stage = Self(hyperMask: 0, fileURL: nil)
        stage.actions = actions
        stage.actionIDs = actionIDs
        stage.actionBytes = actionBytes
        stage.phase = .callbacks(sourceNames: (0 ... sources.moduleCount).map { sources.name(of: UInt32($0)) })
        return stage
    }

    @inline(__always)
    func name(of sourceID: UInt32) -> String {
        switch phase {
        case .declarations: sources.name(of: sourceID)
        case let .callbacks(names): names[Int(sourceID)]
        }
    }

    init(hyperMask: UInt32, fileURL: URL?) {
        self.hyperMask = hyperMask
        sources = ConfigScriptSources(entry: fileURL)
    }

    static var callbacks: omni_config_callbacks {
        omni_config_callbacks(
            resolve: { context, words, count, _, actionID, error, capacity in
                guard let context, let words, let actionID else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    actionID.pointee = try stage.pointee.resolve(UnsafeBufferPointer(start: words, count: count))
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            bind: { context, chord, actionID, modeKey, mode, location, error, capacity in
                guard let context else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let action = try Self.action(actionID, in: stage)
                    try stage.pointee.bind(chord, action: action, modeKey: modeKey, mode: mode, location: location)
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            read_module: { context, requester, spec, result, error, capacity in
                guard let context else { return false }
                return context.assumingMemoryBound(to: ConfigScriptStage.self).pointee.sources.resolve(
                    requester, spec: spec, into: result, error: error, capacity: capacity
                )
            },
            rule: { context, fields, count, location, error, capacity in
                guard let context, let fields else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    try stage.pointee.addRule(UnsafeBufferPointer(start: fields, count: count), location: location)
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            bind_function: { context, chord, functionID, modeKey, mode, reads, location, error, capacity in
                guard let context else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let id = stage.pointee.register(functionID)
                    let action = Action(command: .configFunction(id), text: "function")
                    try stage.pointee.bind(
                        chord,
                        action: action,
                        modeKey: modeKey,
                        mode: mode,
                        reads: .init(rawValue: reads),
                        location: location
                    )
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            dispatch: { context, actionID, location, error, capacity in
                guard let context else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let command = try Self.action(actionID, in: stage).command
                    stage.pointee.dispatch(.native(command), at: location)
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            log: { context, span, location in
                guard let context else { return }
                let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                let text = String(decoding: UnsafeRawBufferPointer(start: span.data, count: span.length), as: UTF8.self)
                let source = stage.pointee.name(of: location.source_id)
                Log.config.notice("\(source):\(location.line): \(text)")
            },
            named_function: { context, isEvent, name, function, mask, location, error, capacity in
                guard let context else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let reads = ConfigScriptReads(rawValue: mask)
                    if isEvent {
                        try stage.pointee.addEvent(name, function: function, reads: reads, location: location)
                    } else {
                        try stage.pointee.addNamedCommand(name, function: function, reads: reads, location: location)
                    }
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            effect: { context, kind, words, count, location, actionID, error, capacity in
                guard let context, let words else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    try stage.pointee.effect(
                        kind, words: UnsafeBufferPointer(start: words, count: count), location: location,
                        actionID: actionID
                    )
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            window: { context, words, count, destination, destinationCount, location, error, capacity in
                guard let context, let words else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let words = UnsafeBufferPointer(start: words, count: count)
                    let operation: ConfigScriptDispatch.Operation = if ConfigScriptGatherRequest.matches(words) {
                        try .gather(ConfigScriptGatherRequest(words: words))
                    } else {
                        try .window(ConfigScriptWindowRequest(
                            words: words,
                            destination: destination.map { UnsafeBufferPointer(start: $0, count: destinationCount) }
                        ))
                    }
                    stage.pointee.dispatch(operation, at: location)
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            dwindle: { context, tree, location, error, capacity in
                guard let context, let tree else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let replace = try ConfigScriptDwindleReplace(tree: tree.pointee)
                    stage.pointee.dispatch(.dwindleReplace(replace), at: location)
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            mode: { context, name, location, actionID, error, capacity in
                guard let context, let actionID else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    actionID.pointee = try stage.pointee.declareMode(name, location: location)
                    return true
                } catch let failure {
                    return failure.write(to: error, capacity: capacity)
                }
            },
            store: storeCallbacks
        )
    }

    private mutating func dispatch(_ operation: ConfigScriptDispatch.Operation, at location: omni_config_location) {
        dispatched.append(ConfigScriptDispatch(
            operation: operation,
            source: name(of: location.source_id),
            line: Int(location.line)
        ))
    }

    private mutating func resolve(_ spans: UnsafeBufferPointer<omni_config_span>) throws(ConfigScriptError) -> UInt32 {
        guard (1 ... ConfigScriptCommandParser.maximumWordCount).contains(spans.count) else {
            throw ConfigScriptError(line: nil, message: "Expected one command with its individual argument words.")
        }
        let outcome = ConfigScriptCommandParser.request(spans)
        guard case let .request(request) = outcome else {
            for span in spans {
                _ = try Self.string(span)
            }
            let name = try Self.string(spans[0])
            let message = if case .unknown = outcome {
                "Unknown command '\(name)'."
            } else {
                "Invalid arguments for '\(name)'."
            }
            throw ConfigScriptError(line: nil, message: message)
        }
        guard let command = HotkeyCommand(direct: request) else {
            throw ConfigScriptError(
                line: nil,
                message: "'\(ConfigScriptCommandParser.text(spans))' is not a direct hotkey action."
            )
        }
        let key = ActionKey.command(command)
        if case .callbacks = phase, let existing = actionIDs[key] { return existing }
        let text = ConfigScriptCommandParser.text(spans)
        let index = UInt32(actions.count)
        try reserveAction(byteCount: text.utf8.count)
        actionIDs[key] = index
        actions.append(Action(command: command, text: text))
        return index
    }

    private mutating func reserveAction(byteCount: Int) throws(ConfigScriptError) {
        guard actions.count < Int(OMNI_CONFIG_DECLARATION_LIMIT),
              byteCount <= ConfigScriptLoader.sourceLimit - actionBytes
        else { throw ConfigScriptError(line: nil, message: "Config action storage limit exceeded.") }
        actionBytes += byteCount
    }

    private mutating func bind(
        _ span: omni_config_span,
        action: Action,
        modeKey modeSpan: omni_config_span,
        mode: omni_config_span,
        reads: ConfigScriptReads = [],
        location: omni_config_location
    ) throws(ConfigScriptError) {
        let raw = try Self.string(span)
        guard let chord = KeySymbolMapper.fromHumanReadable(raw, hyperMask: hyperMask), !chord.isUnassigned else {
            throw ConfigScriptError(line: nil, message: "Invalid keyboard chord '\(raw)'.")
        }
        if mode.data != nil {
            try bind(ConfigScriptBinding(
                rawChord: raw, chord: chord, command: action.command, commandText: action.text,
                line: Int(location.line), source: sources.name(of: location.source_id), reads: reads
            ), inMode: Self.string(mode))
            return
        }
        var modeKey: KeyBinding?
        if modeSpan.data != nil {
            let name = try Self.string(modeSpan)
            guard let key = KeySymbolMapper.fromHumanReadable(name, hyperMask: hyperMask),
                  KeyboardModeTable.Entry(binding: key, command: action.command).isSupported
            else {
                throw ConfigScriptError(line: nil, message: "Unsupported mode key '\(name)' for \(action.text).")
            }
            guard !key.conflicts(with: chord) else {
                throw ConfigScriptError(line: nil, message: "Mode key '\(name)' conflicts with its shortcut '\(raw)'.")
            }
            modeKey = key
        }
        if let prior = bindings.first(where: { $0.mode == nil && $0.chord.conflicts(with: chord) }) {
            throw ConfigScriptError(
                line: nil,
                message: "'\(raw)' for \(action.command.displayName) conflicts with \(prior.command.displayName) at \(prior.source):\(prior.line)."
            )
        }
        bindings.append(ConfigScriptBinding(
            rawChord: raw, chord: chord, command: action.command, commandText: action.text, line: Int(location.line),
            source: sources.name(of: location.source_id), modeKey: modeKey, reads: reads
        ))
    }
}

extension ConfigScriptStage {
    private static func action(_ id: UInt32, in stage: UnsafeMutablePointer<Self>) throws(ConfigScriptError) -> Action {
        guard stage.pointee.actions.indices.contains(Int(id)) else {
            throw ConfigScriptError(line: nil, message: "Expected an action from omniwm.cmd or omniwm.act.")
        }
        return stage.pointee.actions[Int(id)]
    }

    private mutating func register(_ function: UInt32) -> Int {
        let id = Self.nextFunction.wrappingAdd(1, ordering: .relaxed).newValue
        functions[id] = function
        return id
    }

    private mutating func addNamedCommand(
        _ span: omni_config_span, function: UInt32, reads: ConfigScriptReads, location: omni_config_location
    ) throws(ConfigScriptError) {
        let name = try Self.string(span).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ConfigScriptError(line: nil, message: "A palette command needs a nonempty, single-line name.")
        }
        if let index = commandNames[name] {
            let prior = namedCommands[index]
            throw ConfigScriptError(
                line: nil,
                message: "Command '\(name)' already declared at \(prior.source):\(prior.line)."
            )
        }
        let id = register(function)
        commandNames[name] = namedCommands.count
        namedCommands.append(ConfigScriptNamedCommand(
            name: name, function: id, source: sources.name(of: location.source_id), line: Int(location.line),
            reads: reads
        ))
    }

    private mutating func addRule(
        _ fields: UnsafeBufferPointer<omni_config_field>,
        location: omni_config_location
    ) throws(ConfigScriptError) {
        let rule = try ConfigScriptRuleField.decode(fields, ordinal: UInt32(rules.count))
        if let prior = ruleIDs[rule.id] {
            let original = rules[prior]
            throw ConfigScriptError(
                line: nil,
                message: "Rule ID \(rule.id.uuidString) already declared at \(original.source):\(original.line)."
            )
        }
        ruleIDs[rule.id] = rules.count
        rules.append(ConfigScriptRule(
            rule: rule,
            source: sources.name(of: location.source_id),
            line: Int(location.line)
        ))
    }

    private static func string(_ span: omni_config_span) throws(ConfigScriptError) -> String {
        let bytes = UnsafeRawBufferPointer(start: span.data, count: span.length)
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw ConfigScriptError(line: nil, message: "Command words and chords must be valid UTF-8.")
        }
        return string
    }

    private mutating func addEvent(
        _ span: omni_config_span, function: UInt32, reads: ConfigScriptReads, location: omni_config_location
    ) throws(ConfigScriptError) {
        let name = try Self.string(span)
        guard let kind = ConfigScriptEventKind(rawValue: name) else {
            throw ConfigScriptError(line: nil, message: "Unknown event '\(name)'.")
        }
        let id = register(function)
        events.append(ConfigScriptEventListener(
            kind: kind, function: id, source: sources.name(of: location.source_id), line: Int(location.line),
            reads: reads
        ))
    }

    private mutating func effect(
        _ kind: omni_config_effect_kind, words: UnsafeBufferPointer<omni_config_span>,
        location: omni_config_location, actionID: UnsafeMutablePointer<UInt32>?
    ) throws(ConfigScriptError) {
        func stage(_ command: HotkeyCommand, text: @autoclosure () -> String) throws(ConfigScriptError) {
            if let actionID {
                let description = text()
                let key = ActionKey.effect(EffectText(value: description))
                if let existing = actionIDs[key] {
                    actionID.pointee = existing
                } else {
                    try reserveAction(byteCount: description.utf8.count)
                    let index = UInt32(actions.count)
                    actions.append(Action(command: command, text: description))
                    actionIDs[key] = index
                    actionID.pointee = index
                }
            } else {
                dispatch(.native(command), at: location)
            }
        }
        switch kind {
        case OMNI_CONFIG_OPEN_APP:
            let bundleID = try Self.string(words[0])
            guard ActionCatalog.isValidOpenAppBundleID(bundleID) else {
                throw ConfigScriptError(line: nil, message: "Expected an app bundle ID without whitespace.")
            }
            try stage(.openApp(bundleID), text: "open \(bundleID.debugDescription)")
        case OMNI_CONFIG_SHOW_NOTICE:
            let message = try Self.string(words[0])
            try stage(.showNotice(message), text: "notify \(message.debugDescription)")
        case OMNI_CONFIG_RUN_PROGRAM:
            var argv: [String] = []
            argv.reserveCapacity(words.count)
            for word in words { argv.append(try Self.string(word)) }
            try stage(.runProgram(argv), text: "run [" + argv.map(\.debugDescription).joined(separator: ", ") + "]")
        default:
            throw ConfigScriptError(line: nil, message: "Unknown native action.")
        }
    }
}

extension ConfigScriptStage {
    private mutating func declareMode(
        _ span: omni_config_span,
        location: omni_config_location
    ) throws(ConfigScriptError) -> UInt32 {
        let name = try Self.string(span)
        guard NamedKeyModes.isValidName(name) else {
            throw ConfigScriptError(
                line: nil,
                message: "Mode name '\(name)' needs 1 to \(NamedKeyModes.nameLimit) lowercase letters, digits, '-' or '_', "
                    + "starting with a letter, and can't be normal, paused, prefix or window."
            )
        }
        if let prior = namedModes.first(where: { $0.name == name }) {
            throw ConfigScriptError(
                line: nil,
                message: "Mode '\(name)' already declared at \(prior.source):\(prior.line)."
            )
        }
        guard namedModes.count < NamedKeyModes.modeLimit else {
            throw ConfigScriptError(line: nil, message: "A config declares at most \(NamedKeyModes.modeLimit) modes.")
        }
        let text = "mode \(name)"
        try reserveAction(byteCount: text.utf8.count)
        let id = Self.nextMode.wrappingAdd(1, ordering: .relaxed).newValue
        namedModes.append(ConfigScriptNamedMode(
            id: id, name: name, source: sources.name(of: location.source_id), line: Int(location.line)
        ))
        actions.append(Action(command: .namedKeyMode(id), text: text))
        return UInt32(actions.count - 1)
    }
}
