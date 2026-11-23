// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Dispatch
import Foundation
import OmniWMScriptHost

struct ConfigScriptContext: Equatable, Sendable {
    var windowId: String?
    var bundleId: String?
    var workspace: String?
    var layout: String?
}

struct ConfigScriptDispatch: Sendable {
    enum Operation: Equatable, Sendable {
        case native(HotkeyCommand)
        indirect case window(ConfigScriptWindowRequest)
    }

    let operation: Operation
    let source: String
    let line: Int

    var displayName: String {
        switch operation {
        case let .native(command): command.displayName
        case let .window(window): "window " + window.request.name.rawValue
        }
    }
}

struct ConfigScriptInvocation: Sendable {
    let commands: [ConfigScriptDispatch]
    let allocations: Int
}

actor ConfigScriptGeneration {
    static let callbackBudget: UInt64 = 25_000_000

    private let queue: DispatchSerialQueue
    private var resident: OpaquePointer?
    private var stage = ConfigScriptStage(hyperMask: 0, fileURL: nil)
    private var functions: [Int: UInt32] = [:]
    var timerWorkers = ConfigScriptTimerWorkers()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(queue: DispatchSerialQueue) {
        self.queue = queue
    }

    func load(fileURL: URL, hyperMask: UInt32) -> ConfigScriptLoad {
        let url = fileURL.standardizedFileURL
        var declarations = ConfigScriptStage(hyperMask: hyperMask, fileURL: url)
        do {
            guard let data = try declarations.sources.readEntry(at: url) else {
                return ConfigScriptLoad(versions: declarations.sources.versions, result: .success(nil))
            }
            let evaluated = try evaluate(data, declarations: &declarations)
            return ConfigScriptLoad(versions: declarations.sources.versions, result: .success(evaluated))
        } catch {
            let diagnostic = error as? ConfigScriptError ?? ConfigScriptError(
                line: nil,
                message: error.localizedDescription
            )
            return ConfigScriptLoad(versions: declarations.sources.versions, result: .failure(diagnostic))
        }
    }

    func evaluate(_ source: Data, hyperMask: UInt32) throws -> ConfigScriptEvaluation {
        var declarations = ConfigScriptStage(hyperMask: hyperMask, fileURL: nil)
        return try evaluate(source, declarations: &declarations)
    }

    private func evaluate(_ source: Data, declarations: inout ConfigScriptStage) throws -> ConfigScriptEvaluation {
        var stats = omni_config_stats()
        var callbacks = ConfigScriptStage.callbacks
        var error = [CChar](repeating: 0, count: Int(OMNI_CONFIG_ERROR_CAPACITY))
        let status = source.withUnsafeBytes { bytes in
            let span = omni_config_span(data: bytes.bindMemory(to: CChar.self).baseAddress, length: bytes.count)
            return withUnsafeMutablePointer(to: &declarations) { context in
                omni_config_load(
                    "@init.luau", span, ConfigScriptLoader.heapLimit, ConfigScriptLoader.cpuBudget,
                    &callbacks, context, &stats, &error, error.count, &resident
                )
            }
        }
        guard status == OMNI_OK else {
            throw ConfigScriptError(
                line: stats.location.line > 0 ? Int(stats.location.line) : nil,
                message: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) },
                source: declarations.sources.name(of: stats.location.source_id)
            )
        }
        var timers: [ConfigScriptTimer] = []
        if let resident {
            stage = declarations.forCallbacks()
            functions = declarations.functions
            timers = ConfigScriptTimer.declarations(in: resident, cancelled: stats.cancelled_timers)
        }
        return ConfigScriptEvaluation(
            bindings: declarations.bindings, peakBytes: stats.peak_bytes, rules: declarations.rules,
            namedCommands: declarations.namedCommands,
            events: declarations.events, timers: timers,
            moduleReads: declarations.sources.moduleCount, moduleExecutions: Int(stats.module_executions),
            generation: resident == nil ? nil : self
        )
    }

    isolated deinit {
        omni_config_destroy(resident)
    }

    func releaseFinishedTimerVM() {
        guard functions.isEmpty, let current = resident else { return }
        omni_config_destroy(current)
        resident = nil
        stage = ConfigScriptStage(hyperMask: 0, fileURL: nil)
    }

    func invoke(
        function: Int, target: ConfigScriptTarget, snapshot: ConfigScriptSnapshot? = nil
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        try invoke(function: function, input: .context(target.context), snapshot: snapshot)
    }

    func invoke(function: Int, context: ConfigScriptContext) throws(ConfigScriptError) -> ConfigScriptInvocation {
        try invoke(function: function, input: .context(context))
    }

    func invoke(
        function: Int, event: ConfigScriptEventPayload, missed: UInt64 = 0, snapshot: ConfigScriptSnapshot? = nil
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        try invoke(function: function, input: .event(event, missed: missed), snapshot: snapshot)
    }

    private func invoke(
        function: Int, input: borrowing ConfigScriptInvocationInput, snapshot: ConfigScriptSnapshot? = nil
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        guard let reference = functions[function] else {
            throw ConfigScriptError(line: nil, message: "This function belongs to a retired config.")
        }
        return try invoke(reference: reference, input: input, snapshot: snapshot)
    }

    func invoke(
        reference: UInt32, input: borrowing ConfigScriptInvocationInput, snapshot: ConfigScriptSnapshot? = nil
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        guard !Task.isCancelled, let resident else {
            throw ConfigScriptError(line: nil, message: "This function belongs to a retired config.")
        }
        var stats = omni_config_stats()
        var diagnostic: ConfigScriptError?
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(OMNI_CONFIG_ERROR_CAPACITY)) { buffer in
            let status = input.withTrigger(snapshot: snapshot) { trigger in
                withUnsafeMutablePointer(to: &stage) { state in
                    #if OMNIWM_CONFIG_CALLBACK_TRACE
                        ConfigScriptLatencyTrace.mark(.callback)
                    #endif
                    return omni_config_invoke(
                        resident, reference, trigger, Self.callbackBudget, state, &stats,
                        buffer.baseAddress, buffer.count
                    )
                }
            }
            if status != OMNI_OK {
                diagnostic = ConfigScriptError(
                    line: stats.location.line > 0 ? Int(stats.location.line) : nil,
                    message: String(cString: buffer.baseAddress!),
                    source: stage.name(of: stats.location.source_id)
                )
            }
        }
        if stats.cancelled_timers != 0 { timerWorkers.cancel(mask: stats.cancelled_timers) }
        defer { stage.dispatched = [] }
        if let diagnostic { throw diagnostic }
        return ConfigScriptInvocation(commands: stage.dispatched, allocations: Int(stats.allocations))
    }
}
