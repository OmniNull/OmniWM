// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Dispatch
import OmniWMScriptHost
import Synchronization

struct ShellWidgetScriptRequest: Equatable, Sendable {
    let bar: ShellBarKey?
    let text: String
    var owner: ShellServiceOwner?
}

struct ShellWidgetDelivery: Sendable {
    struct Acknowledgement: Equatable, Sendable {
        let invocationID: UInt64
        let failed: Bool
        let changed: Bool
    }

    struct Tree: Sendable {
        var nodes: [UInt8] = []
        var sequence = 0
        var trace: ShellFrameTraceContext?

        var demand: UInt64 {
            nodes.withUnsafeBytes { bytes in
                let header = bytes.loadUnaligned(as: omni_wire_header.self)
                return header.deps | (header.flags & OMNI_WIRE_AUDIO != 0 ? ShellDataKey.spectrum.bit : 0)
            }
        }
    }

    let generation: Int
    var epoch = 0
    var trees: [ShellTreeKey: Tree] = [:]
    var acknowledgements: [ShellTreeKey: Acknowledgement] = [:]
    var strings: [UInt8] = []
    var stringCount = 0
    var failure: ShellScriptFailure?
    var failedDeps: UInt64 = 0
    var backgroundDemand: UInt64?
    var reload = false
    var requests: [ShellWidgetScriptRequest] = []
    var configurationRequests: [ShellConfigurationRequest] = []
    var desktopRequests: [ShellDesktopSubmission] = []

    init(generation: Int) {
        self.generation = generation
    }
}

final class ShellWidgetOutbox: Sendable {
    private struct InvocationKey: Hashable {
        let name: String
        let generation: Int
    }

    private struct State {
        var pending: [String: ShellWidgetDelivery] = [:]
        var scheduled = false
        var invoking: [InvocationKey: ShellWidgetDelivery] = [:]
    }

    private let state = Mutex(State())
    private let drain: @MainActor @Sendable ([String: ShellWidgetDelivery]) -> Void

    init(drain: @escaping @MainActor @Sendable ([String: ShellWidgetDelivery]) -> Void) {
        self.drain = drain
    }

    func publish(
        name: String,
        generation: Int,
        key: ShellTreeKey,
        sequence: Int,
        output: UnsafeRawBufferPointer,
        trace: ShellFrameTraceContext? = nil
    ) {
        let header = output.loadUnaligned(as: omni_wire_header.self)
        let nodeBytes = MemoryLayout<omni_wire_header>.stride
            + Int(header.node_count) * MemoryLayout<omni_wire_node>.stride
        guard header.magic == OMNI_WIRE_MAGIC, nodeBytes <= output.count else { return }
        let needsDelivery = state.withLock { state in
            return Self.update(name: name, generation: generation, in: &state) { delivery in
                if delivery.epoch != Int(header.epoch) {
                    delivery.epoch = Int(header.epoch)
                    delivery.trees.removeAll()
                    delivery.strings.removeAll()
                    delivery.stringCount = 0
                }
                if let previous = delivery.trees[key]?.trace {
                    ShellFrameTrace.shared.record(.coalesced, context: previous)
                }
                delivery.trees[key] = ShellWidgetDelivery.Tree(
                    nodes: Array(output[0 ..< nodeBytes]), sequence: sequence, trace: trace
                )
                delivery.strings.append(contentsOf: output[nodeBytes...])
                delivery.stringCount += Int(header.string_count)
            }
        }
        if needsDelivery {
            deliver()
        }
    }

    func demand(name: String, generation: Int, background: UInt64) {
        let needsDelivery = state.withLock { state in
            return Self.update(name: name, generation: generation, in: &state) { delivery in
                delivery.backgroundDemand = background
            }
        }
        if needsDelivery { deliver() }
    }

    func reload(name: String, generation: Int) {
        let needsDelivery = state.withLock { state in
            return Self.update(name: name, generation: generation, in: &state) { delivery in
                delivery.reload = true
            }
        }
        if needsDelivery { deliver() }
    }

    func request(name: String, generation: Int, requests: [ShellWidgetScriptRequest]) {
        let needsDelivery = state.withLock { state in
            return Self.update(name: name, generation: generation, in: &state) { delivery in
                delivery.requests += requests
            }
        }
        if needsDelivery {
            deliver()
        }
    }

    func configure(name: String, generation: Int, requests: [ShellConfigurationRequest]) {
        let needsDelivery = state.withLock { state in
            return Self.update(name: name, generation: generation, in: &state) { delivery in
                delivery.configurationRequests += requests
            }
        }
        if needsDelivery { deliver() }
    }

    func desktop(name: String, generation: Int, request: ShellDesktopSubmission) {
        let needsDelivery = state.withLock { state in
            return Self.update(name: name, generation: generation, in: &state) { delivery in
                delivery.desktopRequests.append(request)
            }
        }
        if needsDelivery { deliver() }
    }

    func cancelDesktop(name: String, generation: Int, id: ShellServiceID) {
        state.withLock { state in
            if state.pending[name]?.generation == generation {
                state.pending[name]?.desktopRequests.removeAll { $0.request.id == id }
            }
            let key = InvocationKey(name: name, generation: generation)
            state.invoking[key]?.desktopRequests.removeAll { $0.request.id == id }
        }
    }

    func cancelConfiguration(name: String, generation: Int, id: ShellServiceID) {
        state.withLock { state in
            if state.pending[name]?.generation == generation {
                state.pending[name]?.configurationRequests.removeAll { $0.id == id }
            }
            let key = InvocationKey(name: name, generation: generation)
            state.invoking[key]?.configurationRequests.removeAll { $0.id == id }
        }
    }

    func fail(name: String, generation: Int, failure: ShellScriptFailure, deps: UInt64 = 0) {
        let needsDelivery = state.withLock { state in
            return Self.update(name: name, generation: generation, in: &state) { delivery in
                delivery.failure = delivery.failure ?? failure
                delivery.failedDeps |= deps
            }
        }
        if needsDelivery {
            deliver()
        }
    }

    func beginInvoke(name: String, generation: Int) {
        state.withLock { state in
            state
                .invoking[InvocationKey(name: name, generation: generation)] =
                ShellWidgetDelivery(generation: generation)
        }
    }

    func finishInvoke(name: String, generation: Int, key: ShellTreeKey, invocationID: UInt64, failed: Bool) {
        let needsDelivery = state.withLock { state in
            guard var staged = state.invoking.removeValue(forKey: InvocationKey(name: name, generation: generation))
            else {
                return false
            }
            return Self.update(name: name, generation: generation, in: &state) { delivery in
                staged.acknowledgements[key] = ShellWidgetDelivery.Acknowledgement(
                    invocationID: invocationID, failed: failed || staged.failure != nil,
                    changed: staged.trees[key] != nil
                )
                Self.merge(staged, into: &delivery)
            }
        }
        if needsDelivery { deliver() }
    }

    private static func merge(_ next: ShellWidgetDelivery, into delivery: inout ShellWidgetDelivery) {
        if !next.trees.isEmpty {
            if delivery.epoch != next.epoch {
                delivery.epoch = next.epoch
                delivery.trees.removeAll()
                delivery.strings.removeAll()
                delivery.stringCount = 0
            }
            for (key, tree) in next.trees {
                if let previous = delivery.trees[key]?.trace {
                    ShellFrameTrace.shared.record(.coalesced, context: previous)
                }
                delivery.trees[key] = tree
            }
            delivery.strings.append(contentsOf: next.strings)
            delivery.stringCount += next.stringCount
        }
        for (key, acknowledgement) in next.acknowledgements
            where acknowledgement.invocationID > (delivery.acknowledgements[key]?.invocationID ?? 0)
        {
            delivery.acknowledgements[key] = acknowledgement
        }
        delivery.failure = delivery.failure ?? next.failure
        delivery.failedDeps |= next.failedDeps
        delivery.backgroundDemand = next.backgroundDemand ?? delivery.backgroundDemand
        delivery.reload = delivery.reload || next.reload
        delivery.requests += next.requests
        delivery.configurationRequests += next.configurationRequests
        delivery.desktopRequests += next.desktopRequests
    }

    private static func update(
        name: String,
        generation: Int,
        in state: inout State,
        _ body: (inout ShellWidgetDelivery) -> Void
    ) -> Bool {
        let key = InvocationKey(name: name, generation: generation)
        if state.invoking[key] != nil {
            body(&state.invoking[key]!)
            return false
        }
        if let pendingGeneration = state.pending[name]?.generation {
            guard pendingGeneration <= generation else { return false }
            if pendingGeneration < generation {
                state.pending[name] = ShellWidgetDelivery(generation: generation)
            }
        }
        body(&state.pending[name, default: ShellWidgetDelivery(generation: generation)])
        return Self.schedule(&state)
    }

    private static func schedule(_ state: inout State) -> Bool {
        guard !state.scheduled else { return false }
        state.scheduled = true
        return true
    }

    private func deliver() {
        DispatchQueue.main.async { [self] in
            let batch = state.withLock { state in
                let pending = state.pending
                state.pending = [:]
                state.scheduled = false
                return pending
            }
            if ShellFrameTrace.shared.isActive {
                for delivery in batch.values {
                    for tree in delivery.trees.values {
                        ShellFrameTrace.shared.record(.outboxDrain, context: tree.trace)
                    }
                }
            }
            drain(batch)
        }
    }
}
