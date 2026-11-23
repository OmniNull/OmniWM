// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import OmniWMScriptHost
import Synchronization

struct ConfigScriptStage {
    private static let nextFunction = Atomic<Int>(0)
    let hyperMask: UInt32
    var bindings: [ConfigScriptBinding] = []
    var rules: [ConfigScriptRule] = []
    var namedCommands: [ConfigScriptNamedCommand] = []
    var events: [ConfigScriptEventListener] = []
    var sources: ConfigScriptSources
    private var ruleIDs: [UUID: Int] = [:]
    private var commandNames: [String: Int] = [:]
    private struct Action {
        let command: HotkeyCommand
        let text: String
    }

    private var actions: [Action] = []
    private var actionIDs: [HotkeyCommand: UInt32]?
    private var actionBytes = 0
    private var sourceNames: [String] = []
    private(set) var functions: [Int: UInt32] = [:]
    var dispatched: [ConfigScriptDispatch] = []

    func forCallbacks() -> Self {
        var stage = Self(hyperMask: 0, fileURL: nil)
        stage.actions = actions
        stage.actionIDs = [:]
        for (index, action) in actions.enumerated() {
            stage.actionIDs?[action.command] = UInt32(index)
            stage.actionBytes += action.text.utf8.count
        }
        stage.sourceNames = (0 ... sources.moduleCount).map { sources.name(of: UInt32($0)) }
        return stage
    }

    func name(of sourceID: UInt32) -> String {
        sourceNames.isEmpty ? sources.name(of: sourceID) : sourceNames[Int(sourceID)]
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
                    return ConfigScriptStage.writeError(failure, to: error, capacity: capacity)
                }
            },
            bind: { context, chord, actionID, modeKey, location, error, capacity in
                guard let context else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let action = try stage.pointee.action(actionID)
                    try stage.pointee.bind(chord, action: action, mode: modeKey, location: location)
                    return true
                } catch let failure {
                    return ConfigScriptStage.writeError(failure, to: error, capacity: capacity)
                }
            },
            read_module: { context, requester, spec, result, error, capacity in
                guard let context, let result else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    result.pointee = try stage.pointee.sources.module(requestedBy: requester, spec: spec)
                    return true
                } catch let failure {
                    return ConfigScriptStage.writeError(failure, to: error, capacity: capacity)
                }
            },
            rule: { context, fields, count, location, error, capacity in
                guard let context, let fields else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    try stage.pointee.addRule(UnsafeBufferPointer(start: fields, count: count), location: location)
                    return true
                } catch let failure {
                    return ConfigScriptStage.writeError(failure, to: error, capacity: capacity)
                }
            },
            bind_function: { context, chord, functionID, modeKey, reads, location, error, capacity in
                guard let context else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let id = stage.pointee.register(functionID)
                    let action = Action(command: .configFunction(id), text: "function")
                    try stage.pointee.bind(
                        chord,
                        action: action,
                        mode: modeKey,
                        reads: .init(rawValue: reads),
                        location: location
                    )
                    return true
                } catch let failure {
                    return ConfigScriptStage.writeError(failure, to: error, capacity: capacity)
                }
            },
            dispatch: { context, actionID, location, error, capacity in
                guard let context else { return false }
                do throws(ConfigScriptError) {
                    let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
                    let command = try stage.pointee.action(actionID).command
                    stage.pointee.dispatch(.native(command), at: location)
                    return true
                } catch let failure {
                    return ConfigScriptStage.writeError(failure, to: error, capacity: capacity)
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
                    return ConfigScriptStage.writeError(failure, to: error, capacity: capacity)
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
                    return ConfigScriptStage.writeError(failure, to: error, capacity: capacity)
                }
            }
        )
    }

    private mutating func register(_ function: UInt32) -> Int {
        let id = Self.nextFunction.wrappingAdd(1, ordering: .relaxed).newValue
        functions[id] = function
        return id
    }

    private mutating func dispatch(_ operation: ConfigScriptDispatch.Operation, at location: omni_config_location) {
        dispatched.append(ConfigScriptDispatch(
            operation: operation,
            source: name(of: location.source_id),
            line: Int(location.line)
        ))
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

    private static let maximumWordCount = IPCAutomationManifest.commandDescriptors.reduce(0) {
        max($0, $1.commandWords.count + $1.arguments.count)
    }

    private mutating func resolve(_ spans: UnsafeBufferPointer<omni_config_span>) throws(ConfigScriptError) -> UInt32 {
        guard (1 ... Self.maximumWordCount).contains(spans.count) else {
            throw ConfigScriptError(line: nil, message: "Expected one command with its individual argument words.")
        }
        var words: [String] = []
        words.reserveCapacity(spans.count)
        for span in spans {
            words.append(try Self.string(span))
        }
        guard let request = IPCCommandRequest(commandWords: words) else {
            let name = words[0]
            let unknown = IPCAutomationManifest.commandDescriptors(matching: words).isEmpty
            let message = unknown ? "Unknown command '\(name)'." : "Invalid arguments for '\(name)'."
            throw ConfigScriptError(line: nil, message: message)
        }
        guard let command = HotkeyCommand(direct: request) else {
            throw ConfigScriptError(
                line: nil,
                message: "'\(words.joined(separator: " "))' is not a direct hotkey action."
            )
        }
        if let existing = actionIDs?[command] { return existing }
        let text = words.joined(separator: " ")
        let index = UInt32(actions.count)
        if actionIDs != nil {
            guard actions.count < Int(OMNI_CONFIG_DECLARATION_LIMIT),
                  text.utf8.count <= ConfigScriptLoader.sourceLimit - actionBytes
            else { throw ConfigScriptError(line: nil, message: "Config action storage limit exceeded.") }
            actionIDs?[command] = index
            actionBytes += text.utf8.count
        }
        actions.append(Action(command: command, text: text))
        return index
    }

    private func action(_ id: UInt32) throws(ConfigScriptError) -> Action {
        guard actions.indices.contains(Int(id)) else {
            throw ConfigScriptError(line: nil, message: "Expected an action returned by omniwm.cmd.")
        }
        return actions[Int(id)]
    }

    private mutating func bind(
        _ span: omni_config_span,
        action: Action,
        mode: omni_config_span,
        reads: ConfigScriptReads = [],
        location: omni_config_location
    ) throws(ConfigScriptError) {
        let raw = try Self.string(span)
        guard let chord = KeySymbolMapper.fromHumanReadable(raw, hyperMask: hyperMask), !chord.isUnassigned else {
            throw ConfigScriptError(line: nil, message: "Invalid keyboard chord '\(raw)'.")
        }
        var modeKey: KeyBinding?
        if mode.data != nil {
            let name = try Self.string(mode)
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
        if let prior = bindings.first(where: { $0.chord.conflicts(with: chord) }) {
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

    private static func writeError(
        _ failure: ConfigScriptError,
        to buffer: UnsafeMutablePointer<CChar>?,
        capacity: Int
    ) -> Bool {
        guard let buffer, capacity > 0 else { return false }
        let bytes = failure.message.utf8
        var end = bytes.index(bytes.startIndex, offsetBy: capacity - 1, limitedBy: bytes.endIndex) ?? bytes.endIndex
        while end != bytes.startIndex, end != bytes.endIndex, bytes[end] & 0xC0 == 0x80 {
            bytes.formIndex(before: &end)
        }
        var count = 0
        for byte in bytes[..<end] {
            buffer[count] = CChar(bitPattern: byte)
            count += 1
        }
        buffer[count] = 0
        return false
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
        func stage(_ command: HotkeyCommand, text: @autoclosure () -> String) {
            if let actionID {
                actionID.pointee = UInt32(actions.count)
                actions.append(Action(command: command, text: text()))
            } else {
                dispatch(.native(command), at: location)
            }
        }
        switch kind {
        case OMNI_CONFIG_WINDOW_DISPATCH:
            var arguments: [String] = []
            arguments.reserveCapacity(words.count)
            for word in words { arguments.append(try Self.string(word)) }
            dispatch(.window(try ConfigScriptWindowRequest(words: arguments)), at: location)
        case OMNI_CONFIG_OPEN_APP:
            let bundleID = try Self.string(words[0])
            guard ActionCatalog.isValidOpenAppBundleID(bundleID) else {
                throw ConfigScriptError(line: nil, message: "Expected an app bundle ID without whitespace.")
            }
            stage(.openApp(bundleID), text: "open \(bundleID.debugDescription)")
        case OMNI_CONFIG_SHOW_NOTICE:
            let message = try Self.string(words[0])
            stage(.showNotice(message), text: "notify \(message.debugDescription)")
        case OMNI_CONFIG_RUN_PROGRAM:
            var argv: [String] = []
            argv.reserveCapacity(words.count)
            for word in words { argv.append(try Self.string(word)) }
            stage(.runProgram(argv), text: "run [" + argv.map(\.debugDescription).joined(separator: ", ") + "]")
        default:
            throw ConfigScriptError(line: nil, message: "Unknown native action.")
        }
    }
}
