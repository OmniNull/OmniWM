// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

final class ShellFilePromiseBatch: Sendable {
    struct Item: Equatable, Sendable {
        let index: Int
        let receiver: Int
        let name: String
        let uti: String
    }

    struct Received: Sendable {
        let receiver: Int
        let name: String?
        let result: Result<ShellResourceReceivedFile, ShellResourceFailure>
    }

    struct Delivery: Sendable {
        let index: Int?
        let result: Result<ShellResourceReceivedFile, ShellResourceFailure>
    }

    struct Batch: Sendable {
        let deliveries: [Delivery]
        let finished: Bool
        let error: String?
    }

    private struct State {
        var expected: [Int]?
        var received: [Int]
        var items: [Item] = []
        var assigned: Set<Int> = []
        var results: [Received] = []
        var copies = 0
        var configured = false
        var activated = false
        var waking = false
        var terminalDelivered = false
        var error: String?
        var wake: (@Sendable () -> Void)?
    }

    static let itemLimit = 32
    let directory: URL
    let temporaryRoot: URL
    let operation: ShellResourceOperation
    private let state: Mutex<State>

    init(receiverCount: Int, directory: URL, temporaryRoot: URL, operation: ShellResourceOperation) throws {
        guard (1 ... Self.itemLimit).contains(receiverCount)
        else { throw ShellResourceFailure("invalid promise receiver count") }
        self.directory = directory
        self.temporaryRoot = temporaryRoot
        self.operation = operation
        state = Mutex(State(received: Array(repeating: 0, count: receiverCount)))
    }

    var isConfigured: Bool {
        state.withLock { $0.configured }
    }

    func attachWake(_ wake: @escaping @Sendable () -> Void) {
        state.withLock { $0.wake = wake }
        signal()
    }

    func configure(names: [[String]], types: [[String]]) throws -> [Item] {
        let result = state.withLock { state -> Result<[Item], ShellResourceFailure> in
            guard !state.configured, names.count == state.received.count, types.count == names.count else {
                return .failure(ShellResourceFailure("invalid promise declaration"))
            }
            state.configured = true
            state.expected = names.map(\.count)
            if zip(state.received, names).contains(where: { $0.0 > $0.1.count }) {
                state.error = "file promise produced more callbacks than declared files"
                return .failure(ShellResourceFailure(state.error!))
            }
            guard names.reduce(0, { $0 + $1.count }) <= Self.itemLimit, names.allSatisfy({ !$0.isEmpty }) else {
                state.error = "file promise batch exceeds 32 items or has no declared files"
                return .failure(ShellResourceFailure(state.error!))
            }
            for (receiver, names) in names.enumerated() {
                for (index, name) in names.enumerated() {
                    let uti = types[receiver].indices.contains(index) ? types[receiver][index] : "public.data"
                    guard !name.isEmpty, name.utf8.count <= 1024, !name.contains("\0"), uti.utf8.count <= 256 else {
                        state.error = "invalid promised file metadata"
                        return .failure(ShellResourceFailure(state.error!))
                    }
                    state.items.append(Item(index: state.items.count, receiver: receiver, name: name, uti: uti))
                }
            }
            return .success(state.items)
        }
        switch result {
        case let .success(items): return items
        case let .failure(error): cancel(error: error.description)
            throw error
        }
    }

    func activate() {
        state.withLock { $0.activated = true }
        signal()
    }

    func cancel(error: String = "cancelled") {
        operation.cancel()
        state.withLock { state in
            state.error = state.error ?? String(error.prefix(1024))
            state.activated = true
        }
        signal()
    }

    func receive(receiver: Int, url: URL, error: String?) {
        let copy = state.withLock { state -> Bool in
            guard state.received.indices.contains(receiver) else { return false }
            guard state.copies < Self.itemLimit, state.error == nil else { return false }
            state.copies += 1
            return true
        }
        var result: Result<ShellResourceReceivedFile, ShellResourceFailure>?
        if copy {
            do {
                if let error { throw ShellResourceFailure(String(error.prefix(1024))) }
                guard operation.isActive else { throw ShellResourceFailure("cancelled") }
                let root = directory.standardizedFileURL.path + "/"
                let path = url.standardizedFileURL.path
                guard url.isFileURL,
                      path.hasPrefix(root)
                else { throw ShellResourceFailure("promised file is outside its destination") }
                result = .success(try ShellResourceReceivedFile.copy(
                    String(path.dropFirst(root.count)),
                    directory: directory,
                    root: temporaryRoot,
                    operation: operation
                ))
            } catch { result = .failure(ShellResourceFailure(String(describing: error))) }
        }
        state.withLock { state in
            guard state.received.indices.contains(receiver) else { return }
            state.received[receiver] += 1
            if let result { state.results.append(Received(
                receiver: receiver,
                name: error == nil ? url.lastPathComponent : nil,
                result: result
            )) }
            if let expected = state.expected, state.received[receiver] > expected[receiver] {
                state.error = "file promise produced more callbacks than declared files"
            }
        }
        signal()
    }

    func takeBatch() -> Batch {
        state.withLock { state in
            guard state.activated, state.configured else { return Batch(deliveries: [], finished: false, error: nil) }
            var deliveries: [Delivery] = []
            while deliveries.count < ShellServiceLedger.batchLimit, let index = Self.deliverableIndex(state) {
                let result = state.results.remove(at: index)
                let candidates = state.items
                    .filter { $0.receiver == result.receiver && !state.assigned.contains($0.index) }
                let item = candidates.first { $0.name == result.name } ?? candidates.first
                if let item { state.assigned.insert(item.index) }
                deliveries.append(Delivery(index: state.error == nil ? item?.index : nil, result: result.result))
            }
            let done = Self.finished(state) && !state.terminalDelivered
            if done { state.terminalDelivered = true }
            return Batch(deliveries: deliveries, finished: done, error: state.error)
        }
    }

    func finishBatch() {
        let wake = state.withLock { state -> (@Sendable () -> Void)? in
            if state.activated, state.configured,
               Self.deliverableIndex(state) != nil || Self.finished(state) && !state
                   .terminalDelivered { return state.wake }
            state.waking = false
            return nil
        }
        wake?()
    }

    private func signal() {
        let wake = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.activated, state.configured, !state.waking, let wake = state.wake,
                  Self.deliverableIndex(state) != nil || Self.finished(state) && !state.terminalDelivered
            else { return nil }
            state.waking = true
            return wake
        }
        wake?()
    }

    private static func deliverableIndex(_ state: State) -> Int? {
        if state.error != nil { return state.results.indices.first }
        if let named = state.results.firstIndex(where: { $0.name != nil }) { return named }
        guard let expected = state.expected else { return nil }
        return state.results.firstIndex { state.received[$0.receiver] >= expected[$0.receiver] }
    }

    private static func finished(_ state: State) -> Bool {
        guard let expected = state.expected, state.results.isEmpty else { return false }
        return zip(state.received, expected).allSatisfy { $0.0 >= $0.1 }
    }
}
