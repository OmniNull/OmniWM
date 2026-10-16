// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

struct ShellServiceOwner: Hashable, Sendable {
    let generation: UInt64
    let owner: UInt32
    let epoch: UInt32
}

struct ShellServiceID: Hashable, Sendable {
    let owner: ShellServiceOwner
    let request: UInt64
}

struct ShellServiceCompletion: Sendable {
    let id: ShellServiceID
    let revision: UInt64
    let payload: [UInt8]
    let resource: ShellResourceCompletion?
    let desktopResources: [ShellResourceID]?
    var onDiscard: (@Sendable (ShellServiceCompletion) -> Void)?

    init(
        id: ShellServiceID,
        revision: UInt64 = 0,
        payload: [UInt8],
        desktopResources: [ShellResourceID]? = nil,
        resource: ShellResourceCompletion? = nil
    ) {
        self.id = id
        self.revision = revision
        self.payload = payload
        self.desktopResources = desktopResources
        self.resource = resource
    }

    func discardUndelivered() {
        onDiscard?(self)
    }
}

final class ShellServiceLedger: Sendable {
    static let capacity = 256
    static let batchLimit = 16

    struct Capture: Equatable, Sendable {
        var id: UInt64 = 0
        var activeBegin = 0
        var activeEnd = 0
        var activePeak = 0
        var completionsBegin = 0
        var completionsEnd = 0
        var completionsPeak = 0
        var wakes = ShellCaptureWakeCounters()

        var detail: String {
            "utility=service_ledger active_begin=\(activeBegin) active_end=\(activeEnd) active_peak=\(activePeak)"
                + " completion_begin=\(completionsBegin) completion_end=\(completionsEnd) completion_peak=\(completionsPeak)"
                + " " + wakes.detail
        }
    }

    private struct Operation {
        var cancel: @Sendable () -> Void
        var discard: (@Sendable (ShellServiceCompletion) -> Void)?
        var completed = false
    }

    private struct State {
        var operations: [ShellServiceID: Operation] = [:]
        var completions: [ShellServiceCompletion] = []
        var wake: (@Sendable () -> Void)?
        var waking = false
        var closed = false
        var capture = Capture()
    }

    private struct TimerState {
        var source: (any DispatchSourceTimer)?
        var cancelled = false
    }

    private final class Timer: Sendable {
        private let state = Mutex(TimerState())

        func start(seconds: Double, queue: DispatchSerialQueue, fire: @escaping @Sendable () -> Void) {
            state.withLock { state in
                guard !state.cancelled else { return }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                let deadline: DispatchTime = seconds < Double(Int.max) / 1_000_000_000 ? .now() + seconds :
                    .distantFuture
                timer.schedule(deadline: deadline)
                timer.setEventHandler(handler: fire)
                state.source = timer
                timer.resume()
            }
        }

        func cancel() {
            state.withLock { state in
                state.cancelled = true
                state.source?.cancel()
                state.source = nil
            }
        }
    }

    let generation: UInt64
    private let state = Mutex(State())

    init(generation: UInt64) {
        self.generation = generation
    }

    func captureBegin(_ id: UInt64) {
        state.withLock {
            guard id != 0, $0.capture.id != id else { return }
            $0.capture = Capture(
                id: id, activeBegin: $0.operations.count, activePeak: $0.operations.count,
                completionsBegin: $0.completions.count, completionsPeak: $0.completions.count
            )
        }
    }

    func captureEnd(_ id: UInt64) -> Capture? {
        state.withLock {
            guard id != 0, $0.capture.id == id else { return nil }
            $0.capture.activeEnd = $0.operations.count
            $0.capture.completionsEnd = $0.completions.count
            defer { $0.capture = Capture() }
            return $0.capture
        }
    }

    func captureWakeConsumed() {
        state.withLock { if $0.capture.id != 0 { $0.capture.wakes.consume() } }
    }

    func contains(_ id: ShellServiceID) -> Bool {
        state.withLock { $0.operations[id] != nil }
    }

    var activeCount: Int {
        state.withLock { $0.operations.count }
    }

    var pendingCount: Int {
        state.withLock { $0.completions.count }
    }

    @discardableResult
    func register(
        _ id: ShellServiceID,
        cancel: @escaping @Sendable () -> Void = {},
        discard: (@Sendable (ShellServiceCompletion) -> Void)? = nil
    ) -> Bool {
        state.withLock { state in
            guard !state.closed, id.owner.generation == generation,
                  state.operations[id] == nil, state.operations.count < Self.capacity
            else { return false }
            state.operations[id] = Operation(cancel: cancel, discard: discard)
            if state.capture
                .id != 0 { state.capture.activePeak = max(state.capture.activePeak, state.operations.count) }
            return true
        }
    }

    func adopt(
        _ id: ShellServiceID,
        cancel: @escaping @Sendable () -> Void,
        discard: (@Sendable (ShellServiceCompletion) -> Void)? = nil
    ) -> Bool {
        state.withLock { state in
            guard var operation = state.operations[id], !operation.completed else { return false }
            operation.cancel = cancel
            operation.discard = discard
            state.operations[id] = operation
            return true
        }
    }

    @discardableResult
    func startTimer(_ id: ShellServiceID, seconds: Double, queue: DispatchSerialQueue) -> Bool {
        guard seconds.isFinite, seconds >= 0.01 else { return false }
        let timer = Timer()
        guard register(id, cancel: { timer.cancel() }) else { return false }
        timer.start(seconds: seconds, queue: queue) { [weak self] in
            self?.complete(ShellServiceCompletion(id: id, payload: [0]))
        }
        return true
    }

    func attachWake(_ wake: @escaping @Sendable () -> Void) {
        let shouldWake = state.withLock { state in
            guard !state.closed else { return false }
            state.wake = wake
            guard !state.waking, !state.completions.isEmpty else { return false }
            state.waking = true
            if state.capture.id != 0 { state.capture.wakes.emit() }
            return true
        }
        if shouldWake { wake() }
    }

    @discardableResult
    func complete(_ completion: ShellServiceCompletion) -> Bool {
        let result = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard var operation = state.operations[completion.id], !operation.completed else { return (false, nil) }
            operation.completed = true
            state.operations[completion.id] = operation
            state.completions.append(completion)
            if state.capture.id != 0 {
                state.capture.completionsPeak = max(state.capture.completionsPeak, state.completions.count)
            }
            guard !state.waking, let wake = state.wake else { return (true, nil) }
            state.waking = true
            if state.capture.id != 0 { state.capture.wakes.emit() }
            return (true, wake)
        }
        result.1?()
        return result.0
    }

    func takeBatch(limit: Int = batchLimit) -> [ShellServiceCompletion] {
        let batch = state.withLock { state -> ([ShellServiceCompletion], [@Sendable () -> Void]) in
            let count = min(max(0, limit), Self.batchLimit, state.completions.count)
            var completions = Array(state.completions.prefix(count))
            state.completions.removeFirst(count)
            var cancellations: [@Sendable () -> Void] = []
            for index in completions.indices {
                if let operation = state.operations.removeValue(forKey: completions[index].id) {
                    completions[index].onDiscard = operation.discard
                    cancellations.append(operation.cancel)
                }
            }
            return (completions, cancellations)
        }
        for cancel in batch.1 { cancel() }
        return batch.0
    }

    func finishBatch() -> Bool {
        let result = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard state.completions.isEmpty else {
                if state.capture.id != 0, state.wake != nil { state.capture.wakes.emit() }
                return (true, state.wake)
            }
            state.waking = false
            return (false, nil)
        }
        result.1?()
        return result.0
    }

    func takeRegistered(_ id: ShellServiceID) -> Bool {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            guard let operation = state.operations.removeValue(forKey: id) else { return nil }
            state.completions.removeAll { $0.id == id }
            return operation.cancel
        }
        cancel?()
        return cancel != nil
    }

    func cancel(_ id: ShellServiceID) {
        discard(where: { $0 == id })
    }

    func cancel(owner: ShellServiceOwner) {
        discard(where: { $0.owner == owner })
    }

    private func discard(where matches: (ShellServiceID) -> Bool) {
        let removed = state.withLock { state -> ([Operation], [ShellServiceCompletion]) in
            let ids = state.operations.keys.filter(matches)
            var completions: [ShellServiceCompletion] = []
            var retained: [ShellServiceCompletion] = []
            for completion in state.completions {
                if matches(completion.id) {
                    var discarded = completion
                    discarded.onDiscard = state.operations[completion.id]?.discard
                    completions.append(discarded)
                } else { retained.append(completion) }
            }
            state.completions = retained
            return (ids.compactMap { state.operations.removeValue(forKey: $0) }, completions)
        }
        for operation in removed.0 { operation.cancel() }
        for completion in removed.1 { completion.discardUndelivered() }
    }

    func close() {
        let removed = state.withLock { state -> ([Operation], [ShellServiceCompletion]) in
            let operations = Array(state.operations.values)
            let completions = state.completions.map { completion in
                var discarded = completion
                discarded.onDiscard = state.operations[completion.id]?.discard
                return discarded
            }
            state.operations.removeAll()
            state.completions.removeAll()
            state.wake = nil
            state.waking = false
            state.closed = true
            return (operations, completions)
        }
        for operation in removed.0 { operation.cancel() }
        for completion in removed.1 { completion.discardUndelivered() }
    }
}
