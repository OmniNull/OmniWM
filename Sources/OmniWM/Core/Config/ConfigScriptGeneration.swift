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

struct ConfigScriptDispatchRefusal: Error {
    let reason: String
}

struct ConfigScriptDispatch: Sendable {
    enum Operation: Equatable, Sendable {
        case native(HotkeyCommand)
        case window(ConfigScriptWindowRequest)
        case gather(ConfigScriptGatherRequest)
        case mark(WindowMarkAction)
        case workspace(ConfigScriptWorkspaceRequest)
        indirect case dwindleReplace(ConfigScriptDwindleReplace)
    }

    let operation: Operation
    let source: String
    let line: Int

    var displayName: String {
        switch operation {
        case let .native(command): command.displayName
        case let .window(window): "window " + window.name.rawValue
        case .gather: "window gather"
        case let .mark(action): "mark " + action.kind.rawValue
        case let .workspace(request): "workspace " + request.name.rawValue
        case .dwindleReplace: "dwindle replace"
        }
    }

    func refusalMessage(_ outcome: ExternalCommandResult) -> String {
        if case .native(.namedKeyMode) = operation, outcome == .ignoredDisabled {
            return "Key mode: keys can't be captured now. A key mode needs Input Monitoring and doesn't start "
                + "while shortcuts are paused or Secure Input is on."
        }
        return "\(displayName): \(outcome)."
    }
}

struct ConfigScriptInvocation: Sendable {
    let batch: [ConfigScriptDispatch]?
    let allocations: Int

    var commands: [ConfigScriptDispatch] {
        batch ?? []
    }
}

actor ConfigScriptGeneration {
    static let callbackBudget: UInt64 = 25_000_000

    private struct TitleWindowID {
        let token: WindowToken
        let epoch: UInt64
        let id: String
    }

    private static let retired = ConfigScriptError(line: nil, message: "This function belongs to a retired config.")
    private let queue: DispatchSerialQueue
    private let store: ConfigScriptStore
    private var resident: OpaquePointer?
    private var lastTitleID: TitleWindowID?
    private var stage = ConfigScriptStage(hyperMask: 0, fileURL: nil)
    private var functions: [Int: UInt32] = [:]
    var timerWorkers = ConfigScriptTimerWorkers()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(queue: DispatchSerialQueue, store: ConfigScriptStore) {
        self.queue = queue
        self.store = store
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
        if let empty = declarations.namedModes.first(where: { mode in
            !declarations.bindings.contains { $0.mode == mode.id }
        }) {
            throw ConfigScriptError(
                line: empty.line,
                message: "Mode '\(empty.name)' has no keys.",
                source: empty.source
            )
        }
        var timers: [ConfigScriptTimer] = []
        if let resident {
            stage = declarations.forCallbacks()
            stage.store = ConfigScriptStoreAccess(store: store)
            functions = declarations.functions
            timers = ConfigScriptTimer.declarations(in: resident, cancelled: stats.cancelled_timers)
        }
        return ConfigScriptEvaluation(
            bindings: declarations.bindings, peakBytes: stats.peak_bytes, rules: declarations.rules,
            namedCommands: declarations.namedCommands, namedModes: declarations.namedModes,
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
        function: Int, target: borrowing ConfigScriptTarget, snapshot: ConfigScriptSnapshot? = nil
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        try invoke(function: function, input: .context(target.context), snapshot: snapshot)
    }

    func invoke(function: Int, context: ConfigScriptContext) throws(ConfigScriptError) -> ConfigScriptInvocation {
        try invoke(function: function, input: .context(context))
    }

    func invoke(
        function: Int, queuedEvent: consuming ConfigScriptQueuedEvent, missed: UInt64, snapshot: ConfigScriptSnapshot?
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        switch consume queuedEvent {
        case let .title(title):
            let id = eventWindowID(title.token, session: title.session, epoch: title.epoch)
            return try invoke(function: function, event: title.payload(id: id), missed: missed, snapshot: snapshot)
        case let .native(native):
            let id: String? = if case let .window(token, session, epoch) = native.id {
                eventWindowID(token, session: session, epoch: epoch)
            } else { nil }
            return try invoke(
                function: function,
                event: native.payload(windowID: id),
                missed: missed,
                snapshot: snapshot
            )
        }
    }

    private func eventWindowID(_ token: WindowToken, session: ConfigScriptSession, epoch: UInt64) -> String {
        if let previous = lastTitleID, previous.token == token, previous.epoch == epoch { return previous.id }
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.windowStateIDEncoded()
        #endif
        let id = ConfigScriptWindowID.string(token, session: session)
        lastTitleID = TitleWindowID(token: token, epoch: epoch, id: id)
        return id
    }

    func invoke(
        function: Int, event: ConfigScriptEventPayload, missed: UInt64 = 0, snapshot: ConfigScriptSnapshot? = nil
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        try invoke(function: function, input: .event(event, missed: missed), snapshot: snapshot)
    }

    private func invoke(
        function: Int, input: borrowing ConfigScriptInvocationInput, snapshot: ConfigScriptSnapshot? = nil
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        guard let reference = functions[function] else { throw Self.retired }
        return try invoke(reference: reference, input: input, snapshot: snapshot)
    }

    func invoke(
        reference: UInt32, input: borrowing ConfigScriptInvocationInput, snapshot: ConfigScriptSnapshot? = nil
    ) throws(ConfigScriptError) -> ConfigScriptInvocation {
        guard !Task.isCancelled, let resident else { throw Self.retired }
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
                    source: sourceName(stats.location.source_id)
                )
            }
        }
        if stats.cancelled_timers != 0 { timerWorkers.cancel(mask: stats.cancelled_timers) }
        defer { stage.dispatched = [] }
        if stats.store_used { try finishStore(committing: diagnostic == nil) }
        if let diagnostic { throw diagnostic }
        return ConfigScriptInvocation(
            batch: stage.dispatched.isEmpty ? nil : stage.dispatched,
            allocations: Int(stats.allocations)
        )
    }

    private func sourceName(_ id: UInt32) -> String {
        withUnsafeMutablePointer(to: &stage) { $0.pointee.name(of: id) }
    }

    private func finishStore(committing: Bool) throws(ConfigScriptError) {
        guard let staged = stage.store?.staged.take(), committing, let location = staged.location else { return }
        guard !Task.isCancelled else { throw Self.retired }
        do throws(ConfigScriptStoreError) {
            try store.commit(staged.snapshot)
        } catch {
            throw ConfigScriptError(
                line: Int(location.line), message: error.message, source: sourceName(location.source_id)
            )
        }
    }
}
