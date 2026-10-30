// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import Synchronization

final class ShellProviderObservation: Sendable {
    static let shared = ShellProviderObservation()

    final class Subscription: Sendable {
        private let observation: ShellProviderObservation
        private let id: UUID

        fileprivate init(observation: ShellProviderObservation, id: UUID) {
            self.observation = observation
            self.id = id
        }

        deinit { cancel() }

        func sync(paths: Set<String>) {
            observation.sync(id, paths: paths)
        }

        func cancel() {
            observation.remove(id)
        }
    }

    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
    }

    private struct Watch {
        let id: UUID
        let source: any DispatchSourceFileSystemObject
        let identity: FileIdentity
        let completion: DispatchGroup
    }

    private struct Entry {
        var subscribers: Set<UUID> = []
        var watch: Watch?
    }

    private struct Subscriber {
        var paths: Set<String> = []
        let onChange: @Sendable () -> Void
    }

    private struct State {
        var subscribers: [UUID: Subscriber] = [:]
        var entries: [String: Entry] = [:]
        var cancellations: [UUID: DispatchGroup] = [:]
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.omniwm.shell-provider-observation", qos: .utility)

    deinit {
        state.withLock { state in
            for entry in state.entries.values { entry.watch?.source.cancel() }
        }
    }

    func observe(paths: Set<String>, onChange: @escaping @Sendable () -> Void) -> Subscription {
        let id = UUID()
        state.withLock { $0.subscribers[id] = Subscriber(onChange: onChange) }
        sync(id, paths: paths)
        return Subscription(observation: self, id: id)
    }

    func finishCancellations() async {
        let pending = state.withLock { Array($0.cancellations.values) }
        for completion in pending {
            await withCheckedContinuation { continuation in
                completion.notify(queue: queue) { continuation.resume() }
            }
        }
    }

    private func sync(_ id: UUID, paths: Set<String>) {
        let paths = Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        let callbacks = state.withLock { state -> [@Sendable () -> Void] in
            guard let previous = state.subscribers[id]?.paths else { return [] }
            guard previous != paths else { return [] }
            state.subscribers[id]?.paths = paths
            for path in previous.subtracting(paths) { remove(id, from: path, state: &state) }
            for path in paths.subtracting(previous) { state.entries[path, default: Entry()].subscribers.insert(id) }
            let changed = refresh(&state)
            return callbacks(for: changed.subtracting([id]), state: state)
        }
        for callback in callbacks { callback() }
    }

    private func remove(_ id: UUID) {
        state.withLock { state in
            if let subscriber = state.subscribers.removeValue(forKey: id) {
                for path in subscriber.paths { remove(id, from: path, state: &state) }
            }
        }
    }

    private func remove(_ id: UUID, from path: String, state: inout State) {
        state.entries[path]?.subscribers.remove(id)
        if state.entries[path]?.subscribers.isEmpty == true {
            if let watch = state.entries.removeValue(forKey: path)?.watch { cancel(watch, state: &state) }
        }
    }

    private func refresh(_ state: inout State) -> Set<UUID> {
        var changed: Set<UUID> = []
        for path in state.entries.keys.sorted() {
            guard var entry = state.entries[path] else { continue }
            let identity = Self.identity(at: path)
            if let watch = entry.watch {
                guard identity != watch.identity else { continue }
                cancel(watch, state: &state)
                entry.watch = nil
                changed.formUnion(entry.subscribers)
            }
            if identity != nil, let watch = makeWatch(path) {
                entry.watch = watch
                changed.formUnion(entry.subscribers)
            }
            state.entries[path] = entry
        }
        return changed
    }

    private func makeWatch(_ path: String) -> Watch? {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            _ = Darwin.close(descriptor)
            return nil
        }
        let id = UUID()
        let completion = DispatchGroup()
        completion.enter()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .revoke], queue: queue
        )
        source.setEventHandler { [weak self] in self?.receive(path: path, watch: id) }
        source.setCancelHandler { [weak self] in
            _ = Darwin.close(descriptor)
            _ = self?.state.withLock { $0.cancellations.removeValue(forKey: id) }
            completion.leave()
        }
        source.resume()
        return Watch(
            id: id,
            source: source,
            identity: FileIdentity(device: status.st_dev, inode: status.st_ino),
            completion: completion
        )
    }

    private func cancel(_ watch: Watch, state: inout State) {
        state.cancellations[watch.id] = watch.completion
        watch.source.cancel()
    }

    private func receive(path: String, watch: UUID) {
        let callbacks = state.withLock { state -> [@Sendable () -> Void] in
            guard let entry = state.entries[path], entry.watch?.id == watch else { return [] }
            let changed = entry.subscribers.union(refresh(&state))
            return callbacks(for: changed, state: state)
        }
        for callback in callbacks { callback() }
    }

    private func callbacks(for ids: Set<UUID>, state: State) -> [@Sendable () -> Void] {
        ids.compactMap { state.subscribers[$0]?.onChange }
    }

    private static func identity(at path: String) -> FileIdentity? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }
}
