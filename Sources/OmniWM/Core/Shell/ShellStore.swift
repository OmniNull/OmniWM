// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CryptoKit
import Foundation
import Synchronization

struct ShellStoreNamespace: Hashable, Sendable {
    let profile: String
    let package: String
    let instance: String?
}

struct ShellStoreFailure: Error, Equatable, Sendable {
    let namespace: ShellStoreNamespace
    let message: String
}

actor ShellStore {
    struct Snapshot: Sendable {
        let bytes: [UInt8]?
        let error: String?
    }

    struct Write: Sendable {
        let namespace: ShellStoreNamespace
        let id: ShellServiceID
        let revision: UInt64
        let bytes: [UInt8]
    }

    struct Commit: Sendable {
        let id: ShellServiceID
        let revision: UInt64
        let error: String?
    }

    private struct Pending: Sendable {
        let write: Write
        let final: Bool
        var flushImmediately: Bool
        var completion: (@Sendable (Commit) -> Void)?
    }

    private struct SubmissionState {
        var pending: [ShellStoreNamespace: Pending] = [:]
        var waking = false
    }

    private final class SubmissionInbox: Sendable {
        private let state = Mutex(SubmissionState())

        func post(_ pending: Pending) -> (wake: Bool, superseded: Pending?) {
            state.withLock { state in
                let previous = state.pending[pending.write.namespace]
                if let previous, previous.write.id == pending.write.id,
                   previous.write.revision > pending.write.revision
                {
                    return (false, nil)
                }
                var latest = pending
                latest.flushImmediately = latest.flushImmediately || previous?.flushImmediately == true
                state.pending[pending.write.namespace] = latest
                let wake = !state.waking
                state.waking = true
                return (wake, previous?.write.id == pending.write.id ? nil : previous)
            }
        }

        func take() -> [Pending] {
            state.withLock { state in
                let pending = Array(state.pending.values)
                state.pending.removeAll(keepingCapacity: true)
                state.waking = false
                return pending
            }
        }
    }

    private struct Entry {
        var owner: ShellServiceOwner
        var pending: Pending?
        var failed: Pending?
        var error: String?
        var lastAttempt: UInt64?
        var deadline: UInt64?
        var retired = false
    }

    static let byteLimit = 256 << 10
    static let commitInterval: UInt64 = 1_000_000_000
    static let defaultDirectoryURL = OmniWMStoragePaths.live.stateDirectory.appendingPathComponent(
        "shell",
        isDirectory: true
    )
    static let shared = ShellStore()

    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.store", qos: .utility)
    private nonisolated let inbox = SubmissionInbox()
    nonisolated let directoryURL: URL
    private let now: @Sendable () -> UInt64
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private var entries: [ShellStoreNamespace: Entry] = [:]
    private var scheduled: Task<Void, Never>?
    private var scheduledDeadline: UInt64?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(
        directoryURL: URL = ShellStore.defaultDirectoryURL,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        writeFile: @escaping @Sendable (Data, URL) throws
            -> Void = { try SettingsFileAccess.writeAtomically($0, at: $1) }
    ) {
        self.directoryURL = directoryURL
        self.now = now
        self.writeFile = writeFile
    }

    func load(_ namespace: ShellStoreNamespace) -> Snapshot {
        drainSubmissions()
        if let entry = entries[namespace], let latest = entry.pending ?? entry.failed {
            return Snapshot(bytes: latest.write.bytes, error: entry.error)
        }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL(for: namespace))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
            guard data.count <= Self.byteLimit else {
                return Snapshot(bytes: nil, error: "store snapshot exceeds 256 KiB")
            }
            return Snapshot(bytes: Array(data), error: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Snapshot(bytes: nil, error: nil)
        } catch {
            return Snapshot(bytes: nil, error: error.localizedDescription)
        }
    }

    nonisolated func submit(_ write: Write, final: Bool = false, completion: @escaping @Sendable (Commit) -> Void) {
        guard write.bytes.count <= Self.byteLimit else {
            completion(Commit(id: write.id, revision: write.revision, error: "store snapshot exceeds 256 KiB"))
            return
        }
        let posted = inbox.post(Pending(
            write: write,
            final: final,
            flushImmediately: final,
            completion: final ? nil : completion
        ))
        if let previous = posted.superseded {
            previous.completion?(Commit(
                id: previous.write.id,
                revision: previous.write.revision,
                error: "store write superseded"
            ))
        }
        if posted.wake {
            Task { await drainSubmissions() }
        }
    }

    private func drainSubmissions() {
        let submissions = inbox.take()
        for pending in submissions { apply(pending) }
        let final = submissions.filter(\.flushImmediately).map { $0.write.namespace }
        if !final.isEmpty {
            for failure in flushEntries(final) {
                Log.shell.error("Could not save shell store for \(failure.namespace.package): \(failure.message)")
            }
        }
        if !submissions.isEmpty { schedule() }
    }

    private func apply(_ pending: Pending) {
        let write = pending.write
        var entry = entries[write.namespace] ?? Entry(owner: write.id.owner)
        if let previous = entry.pending, previous.write.id != write.id {
            previous.completion?(Commit(
                id: previous.write.id,
                revision: previous.write.revision,
                error: "store write superseded"
            ))
        }
        if let previous = entry.pending,
           previous.write.id == write.id, previous.write.revision > write.revision
        {
            return
        }
        entry.pending = pending
        entry.failed = nil
        entry.error = nil
        entry.owner = write.id.owner
        entry.retired = pending.final
        if entry.deadline == nil {
            let time = now()
            let start = entry.lastAttempt ?? time
            entry.deadline = max(time, start > UInt64.max - Self.commitInterval ? .max : start + Self.commitInterval)
        }
        entries[write.namespace] = entry
    }

    @discardableResult
    func flush(_ namespaces: Set<ShellStoreNamespace>? = nil) -> [ShellStoreFailure] {
        drainSubmissions()
        let targets = entries.keys.filter { namespaces?.contains($0) ?? true }
        return flushEntries(targets)
    }

    @discardableResult
    func close(_ owners: [ShellStoreNamespace: ShellServiceOwner]) -> [ShellStoreFailure] {
        drainSubmissions()
        let namespaces = Set(owners.compactMap { namespace, owner in
            entries[namespace]?.owner == owner ? namespace : nil
        })
        for namespace in namespaces {
            entries[namespace]?.retired = true
            entries[namespace]?.pending?.completion = nil
            entries[namespace]?.failed?.completion = nil
        }
        let failures = flushEntries(Array(namespaces))
        for namespace in namespaces where entries[namespace]?.failed == nil {
            entries.removeValue(forKey: namespace)
        }
        schedule()
        return failures
    }

    private func flushEntries(_ namespaces: [ShellStoreNamespace]) -> [ShellStoreFailure] {
        cancelSchedule()
        let failures = namespaces.compactMap { commit($0) }
        schedule()
        return failures
    }

    func flushDue() {
        drainSubmissions()
        cancelSchedule()
        let time = now()
        let targets = entries.compactMap { namespace, entry in
            entry.deadline.map { $0 <= time } == true ? namespace : nil
        }
        for namespace in targets { _ = commit(namespace) }
        schedule()
    }

    nonisolated func fileURL(for namespace: ShellStoreNamespace) -> URL {
        var writer = ShellValueWriter()
        writer.array(3)
        writer.string(namespace.profile)
        writer.string(namespace.package)
        if let instance = namespace.instance {
            writer.string(instance)
        } else {
            writer.null()
        }
        let digest = SHA256.hash(data: Data(writer.bytes)).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(digest).store", isDirectory: false)
    }

    private func commit(_ namespace: ShellStoreNamespace) -> ShellStoreFailure? {
        guard var entry = entries[namespace], let pending = entry.pending ?? entry.failed else { return nil }
        entry.pending = nil
        entry.failed = nil
        entry.deadline = nil
        entry.lastAttempt = now()
        let failure: ShellStoreFailure?
        do {
            try SettingsFileAccess.ensureDirectoryExists(at: directoryURL)
            try writeFile(Data(pending.write.bytes), fileURL(for: namespace))
            failure = nil
            entry.error = nil
        } catch {
            failure = ShellStoreFailure(namespace: namespace, message: error.localizedDescription)
            entry.failed = pending
            entry.error = failure?.message
        }
        if entry.retired, failure == nil {
            entries.removeValue(forKey: namespace)
        } else {
            entries[namespace] = entry
        }
        pending.completion?(Commit(id: pending.write.id, revision: pending.write.revision, error: failure?.message))
        return failure
    }

    private func cancelSchedule() {
        scheduled?.cancel()
        scheduled = nil
        scheduledDeadline = nil
    }

    private func schedule() {
        let deadline = entries.values.compactMap(\.deadline).min()
        guard deadline != scheduledDeadline else { return }
        cancelSchedule()
        guard let deadline else { return }
        scheduledDeadline = deadline
        let time = now()
        let delay = deadline > time ? deadline - time : 0
        scheduled = Task { [weak self] in
            do {
                try await Task.sleep(for: .nanoseconds(Int64(min(delay, UInt64(Int64.max)))))
            } catch {
                return
            }
            await self?.flushDue()
        }
    }
}
