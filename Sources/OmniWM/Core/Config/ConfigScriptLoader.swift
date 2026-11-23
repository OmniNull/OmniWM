// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Dispatch
import Foundation
import OmniWMIPC
import OmniWMScriptHost

struct ConfigScriptBinding: Equatable, Sendable {
    let rawChord: String
    let chord: KeyBinding
    let command: HotkeyCommand
    let commandText: String
    let line: Int
    var source = "init.luau"
    var modeKey: KeyBinding?
}

struct ConfigScriptRule: Equatable, Sendable {
    let rule: AppRule
    let source: String
    let line: Int
}

struct ConfigScriptEvaluation: Sendable {
    let bindings: [ConfigScriptBinding]
    let peakBytes: Int
    let rules: [ConfigScriptRule]
    let moduleReads: Int
    let moduleExecutions: Int
}

struct ConfigScriptError: LocalizedError, Equatable {
    let line: Int?
    let message: String
    var source = "init.luau"

    var errorDescription: String? {
        message
    }
}

actor ConfigScriptLoader {
    static let sourceLimit = Int(OMNI_CONFIG_BYTE_LIMIT)
    static let heapLimit = 32 << 20
    static let cpuBudget: UInt64 = 100_000_000

    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.config.luau", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func evaluate(_ source: Data, hyperMask: UInt32) throws -> ConfigScriptEvaluation {
        var stage = ConfigScriptStage(hyperMask: hyperMask, fileURL: nil)
        return try evaluate(source, stage: &stage)
    }

    func load(fileURL: URL, hyperMask: UInt32) -> ConfigScriptLoad {
        let url = fileURL.standardizedFileURL
        var stage = ConfigScriptStage(hyperMask: hyperMask, fileURL: url)
        do {
            guard let data = try stage.sources.readEntry(at: url) else {
                return ConfigScriptLoad(versions: stage.sources.versions, result: .success(nil))
            }
            let result = try evaluate(data, stage: &stage)
            return ConfigScriptLoad(versions: stage.sources.versions, result: .success(result))
        } catch {
            let diagnostic = error as? ConfigScriptError ?? ConfigScriptError(
                line: nil,
                message: error.localizedDescription
            )
            return ConfigScriptLoad(versions: stage.sources.versions, result: .failure(diagnostic))
        }
    }

    private func evaluate(_ source: Data, stage: inout ConfigScriptStage) throws -> ConfigScriptEvaluation {
        var stats = omni_config_stats()
        var callbacks = ConfigScriptStage.callbacks
        var error = [CChar](repeating: 0, count: Int(OMNI_CONFIG_ERROR_CAPACITY))
        let status = source.withUnsafeBytes { bytes in
            let span = omni_config_span(data: bytes.bindMemory(to: CChar.self).baseAddress, length: bytes.count)
            return withUnsafeMutablePointer(to: &stage) { context in
                omni_config_evaluate(
                    "@init.luau", span, Self.heapLimit, Self.cpuBudget, &callbacks, context, &stats, &error, error.count
                )
            }
        }
        guard status == OMNI_OK else {
            let message = error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            throw ConfigScriptError(
                line: stats.location.line > 0 ? Int(stats.location.line) : nil,
                message: message,
                source: stage.sources.name(of: stats.location.source_id)
            )
        }
        return ConfigScriptEvaluation(
            bindings: stage.bindings,
            peakBytes: stats.peak_bytes,
            rules: stage.rules,
            moduleReads: stage.sources.moduleCount,
            moduleExecutions: Int(stats.module_executions)
        )
    }
}

private struct ConfigScriptStage {
    let hyperMask: UInt32
    var bindings: [ConfigScriptBinding] = []
    var rules: [ConfigScriptRule] = []
    var sources: ConfigScriptSources
    private var ruleIDs: [UUID: Int] = [:]
    private struct Action {
        let command: HotkeyCommand
        let text: String
    }

    private var actions: [Action] = []

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
                    try stage.pointee.bind(chord, actionID: actionID, mode: modeKey, location: location)
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
            }
        )
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
        let index = UInt32(actions.count)
        actions.append(Action(command: command, text: words.joined(separator: " ")))
        return index
    }

    private mutating func bind(
        _ span: omni_config_span,
        actionID: UInt32,
        mode: omni_config_span,
        location: omni_config_location
    ) throws(ConfigScriptError) {
        let raw = try Self.string(span)
        guard let chord = KeySymbolMapper.fromHumanReadable(raw, hyperMask: hyperMask), !chord.isUnassigned else {
            throw ConfigScriptError(line: nil, message: "Invalid keyboard chord '\(raw)'.")
        }
        let index = Int(actionID)
        guard actions.indices.contains(index) else {
            throw ConfigScriptError(line: nil, message: "Expected an action returned by omniwm.cmd.")
        }
        let action = actions[index]
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
            source: sources.name(of: location.source_id), modeKey: modeKey
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
}
