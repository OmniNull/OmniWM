// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Synchronization

final class ShellIslandConfigWriter: Sendable {
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
    private let readFile: @Sendable (URL) throws -> Data
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private let reloadReady: @Sendable () async -> Void

    init(
        shellDirectory: URL,
        readFile: @escaping @Sendable (URL) throws -> Data = { try SettingsFileAccess.readContents(at: $0).data },
        writeFile: @escaping @Sendable (Data, URL) throws
            -> Void = { try SettingsFileAccess.writeAtomically($0, at: $1) },
        reloadReady: @escaping @Sendable () async -> Void
    ) {
        self.shellDirectory = shellDirectory
        self.readFile = readFile
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
        try await withCheckedThrowingContinuation { continuation in
            enqueue(islandOperation(change, profile: profile, root: root)) { revision, result in
                continuation.resume(with: result.map { _ in revision })
            }
        }
    }

    private func islandOperation(
        _ change: ShellIslandLayout.Change, profile: String, root: String
    ) -> @Sendable (URL) throws -> Bool {
        { [self] directory in
            let url = directory.appendingPathComponent("shell.toml")
            let original: String
            do {
                original = String(decoding: try readFile(url), as: UTF8.self)
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
            {
                original = ""
            }
            let updated = try ShellIslandLayout.persisted(
                change, profile: profile, root: root, in: original
            )
            guard updated != original else { return false }
            try SettingsFileAccess.ensureDirectoryExists(at: directory)
            try writeFile(Data(updated.utf8), url)
            return true
        }
    }

    func perform<Value: Sendable>(_ operation: @escaping @Sendable (URL) throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(operation) { _, result in continuation.resume(with: result) }
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
