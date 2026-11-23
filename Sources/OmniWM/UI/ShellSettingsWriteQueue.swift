// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Observation

@MainActor
@Observable
final class ShellSettingsWriteQueue {
    struct Target: Hashable, Sendable {
        let profile: String
        var monitor: Monitor.ID?
        let path: [String]
    }

    private struct Entry {
        var value: any Sendable
        var write: @MainActor () async throws -> Void
        var running: Bool
        var pending = false
        var failure: String?
    }

    private var entries: [Target: Entry] = [:]
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    var failures: [Target: String] {
        entries.compactMapValues(\.failure)
    }

    func value<Value>(for target: Target, as _: Value.Type = Value.self) -> Value? {
        entries[target]?.value as? Value
    }

    func failure(for target: Target) -> String? {
        entries[target]?.failure
    }

    func submit<Value: Sendable>(
        _ value: Value, for target: Target, write: @escaping @MainActor (Value) async throws -> Void
    ) {
        let operation: @MainActor () async throws -> Void = { try await write(value) }
        if var entry = entries[target], entry.running {
            entry.value = value
            entry.write = operation
            entry.pending = true
            entries[target] = entry
            return
        }
        entries[target] = Entry(value: value, write: operation, running: true)
        Task { await run(target) }
    }

    func retry(_ target: Target) {
        guard var entry = entries[target], !entry.running, entry.failure != nil else { return }
        entry.running = true
        entry.failure = nil
        entries[target] = entry
        Task { await run(target) }
    }

    func discard(_ target: Target) {
        guard entries[target]?.running == false else { return }
        entries[target] = nil
    }

    func drain() async -> Bool {
        while entries.values.contains(where: \.running) {
            await withCheckedContinuation { waiters.append($0) }
        }
        return failures.isEmpty
    }

    private func run(_ target: Target) async {
        while let write = entries[target]?.write {
            var failure: String?
            do { try await write() }
            catch is CancellationError {
                entries[target] = nil
                break
            } catch { failure = error.localizedDescription }
            guard var entry = entries[target] else { break }
            if entry.pending {
                entry.pending = false
                entries[target] = entry
                continue
            }
            if let failure {
                entry.running = false
                entry.failure = failure
                entries[target] = entry
            } else {
                entries[target] = nil
            }
            break
        }
        guard !entries.values.contains(where: \.running) else { return }
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed {
            waiter.resume()
        }
    }
}
