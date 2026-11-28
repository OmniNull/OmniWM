// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

final class ShellIslandConfigWriter: Sendable {
    typealias Confirmation = @MainActor @Sendable (ShellLuauConfirmation) async throws -> Bool

    struct Write: Sendable {
        let id: ShellServiceID
        let profile: String
        let root: String
        let change: ShellIslandLayout.Change
    }

    struct Commit: Sendable {
        let id: ShellServiceID
        let revision: UInt64
        let error: String?
    }

    private struct State {
        var submitted: UInt64 = 0
        var completed: UInt64 = 0
        var deferredReload = false
        var reloadTask: Task<Void, Never>?
    }

    let shellDirectory: URL
    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.configuration", qos: .utility)
    private let state = Mutex(State())
    private let writeFile: (@Sendable (Data, URL) throws -> Void)?
    private let confirm: Confirmation?
    private let reloadReady: @Sendable () async -> Void

    init(
        shellDirectory: URL,
        writeFile: (@Sendable (Data, URL) throws -> Void)? = nil,
        confirm: Confirmation? = nil,
        reloadReady: @escaping @Sendable () async -> Void
    ) {
        self.shellDirectory = shellDirectory
        self.confirm = confirm
        self.writeFile = writeFile
        self.reloadReady = reloadReady
    }

    func deferReloadIfWriting() -> Bool {
        state.withLock { state in
            guard state.completed != state.submitted else { return false }
            state.deferredReload = true
            return true
        }
    }

    func submit(_ write: Write, completion: @escaping @Sendable (Commit) -> Void) {
        enqueue(islandOperation(write.change, profile: write.profile, root: write.root)) { revision, result in
            completion(Commit(id: write.id, revision: revision, error: result.failureMessage))
        }
    }

    func persist(_ change: ShellIslandLayout.Change, profile: String, root: String) async throws -> UInt64 {
        try await performConfirmed(islandOperation(change, profile: profile, root: root), confirm: confirm).revision
    }

    private func islandOperation(
        _ change: ShellIslandLayout.Change, profile: String, root: String
    ) -> @Sendable (URL) throws -> Bool {
        { [writeFile] directory in
            try ShellLuauDocument.write(
                [ShellIslandLayout.entry(for: change, profile: profile, root: root)],
                in: directory, writeFile: writeFile
            )
        }
    }

    func perform<Value: Sendable>(
        confirm confirmation: Confirmation? = nil,
        _ operation: @escaping @Sendable (URL) throws -> Value
    ) async throws -> Value {
        try await performConfirmed(operation, confirm: confirmation ?? confirm).value
    }

    private func performConfirmed<Value: Sendable>(
        _ operation: @escaping @Sendable (URL) throws -> Value, confirm: Confirmation?
    ) async throws -> (revision: UInt64, value: Value) {
        do {
            return try await queued(operation)
        } catch let question as ShellLuauConfirmation {
            guard let confirm else { throw question }
            guard try await confirm(question) else { throw CancellationError() }
            return try await queued { directory in
                try question.checkCurrent()
                return try ShellLuauDocument.$approved.withValue(question) { try operation(directory) }
            }
        }
    }

    private func queued<Value: Sendable>(
        _ operation: @escaping @Sendable (URL) throws -> Value
    ) async throws -> (revision: UInt64, value: Value) {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(operation) { revision, result in
                continuation.resume(with: result.map { (revision, $0) })
            }
        }
    }

    private func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable (URL) throws -> Value,
        completion: @escaping @Sendable (UInt64, Result<Value, Error>) -> Void
    ) {
        state.withLock { state in
            state.submitted += 1
            let revision = state.submitted
            queue.async { [self] in
                let result = Result { try operation(shellDirectory) }
                self.state.withLock { state in
                    state.completed = revision
                    guard state.completed == state.submitted, state.deferredReload else { return }
                    state.deferredReload = false
                    let previous = state.reloadTask
                    state.reloadTask = Task { [reloadReady] in
                        await previous?.value
                        await reloadReady()
                    }
                }
                completion(revision, result)
            }
        }
    }

    func flush() async {
        let reload = await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: state.withLock { $0.reloadTask })
            }
        }
        await reload?.value
    }
}

extension Result where Success == Bool, Failure == Error {
    fileprivate var failureMessage: String? {
        if case let .failure(error) = self { error.localizedDescription } else { nil }
    }
}
