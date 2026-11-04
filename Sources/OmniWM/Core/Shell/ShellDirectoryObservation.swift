// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreServices
import Darwin
import Foundation

@MainActor
final class ShellDirectoryObservation {
    static let maximumDescriptorCost = 32
    private static let reservedDescriptorCount = 64

    private struct FileIdentity: Equatable {
        let deviceID: UInt64
        let inode: UInt64
    }

    private struct DirectoryWatch {
        let source: DispatchSourceFileSystemObject
        let identity: FileIdentity
    }

    private let onChange: @MainActor () -> Void
    private let watchLinks: Bool
    private let createStream: @MainActor (FSEventStreamContext, [String]) -> FSEventStreamRef?
    private let startStream: (FSEventStreamRef) -> Bool
    private let openDirectory: @MainActor (String) -> Int32
    private let hasDescriptorReserve: @MainActor (Int) -> Bool
    private let eventQueue = DispatchQueue(label: "com.omniwm.shell-directory-observation")
    private var stream: FSEventStreamRef?
    private var retiringGeneration: UInt64?
    private var generation: UInt64 = 0
    private(set) var retryTimer: DispatchSourceTimer?
    private var paths: [URL] = []
    private var recursivePaths: [URL] = []
    private var watchedPaths: Set<String> = []
    private var roots: [String] = []
    private var rootIdentities: [String: FileIdentity] = [:]
    private var directoryWatches: [String: DirectoryWatch] = [:]
    private var directoryIdentities: [String: FileIdentity] = [:]
    var onNativeObservationReady: (@MainActor () -> Void)?

    var isUsingNativeObservation: Bool {
        stream != nil && retryTimer == nil
    }

    init(
        watchLinks: Bool = false,
        createStream: @escaping @MainActor (FSEventStreamContext, [String])
            -> FSEventStreamRef? = ShellDirectoryObservation.makeStream,
        startStream: @escaping (FSEventStreamRef) -> Bool = FSEventStreamStart,
        openDirectory: @escaping @MainActor (String) -> Int32 = { open($0, O_EVTONLY) },
        hasDescriptorReserve: @escaping @MainActor (Int) -> Bool = ShellDirectoryObservation.hasDescriptorReserve,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.watchLinks = watchLinks
        self.createStream = createStream
        self.startStream = startStream
        self.openDirectory = openDirectory
        self.hasDescriptorReserve = hasDescriptorReserve
        self.onChange = onChange
    }

    isolated deinit {
        cancel()
    }

    func sync(paths: [URL], recursivePaths: [URL]) {
        guard !paths.isEmpty else {
            cancel()
            return
        }
        self.paths = paths
        self.recursivePaths = recursivePaths
        watchedPaths = Set(paths.map(Self.canonicalPath))
        let next = Self.directoryRoots(for: recursivePaths)
        let identities = Self.identities(for: next)
        let directories = shallowDirectories(roots: next)
        directoryIdentities = directories
        if next != roots || identities != rootIdentities {
            stopStream()
            roots = next
            rootIdentities = identities
        }
        for path in directoryWatches.keys where directories[path] != directoryWatches[path]?.identity {
            directoryWatches.removeValue(forKey: path)?.source.cancel()
        }
        let opening = directories.keys.filter { directoryWatches[$0] == nil }.count
        guard hasDescriptorBudget(
            for: roots, shallowCount: directories.count, opening: opening, starting: stream == nil
        ) else {
            stopStream()
            cancelDirectoryWatches()
            retry()
            return
        }
        for (path, _) in directories where directoryWatches[path] == nil {
            guard let watch = makeDirectoryWatch(path) else {
                Log.shell.error("Failed to watch shell link directory \(path)")
                continue
            }
            directoryWatches[path] = watch
        }
        if roots.isEmpty {
            if directoryWatches.isEmpty {
                retry()
            } else {
                retryTimer?.cancel()
                retryTimer = nil
            }
        } else if stream == nil {
            start()
        }
    }

    func cancel() {
        retryTimer?.cancel()
        retryTimer = nil
        stopStream()
        cancelDirectoryWatches()
        paths = []
        recursivePaths = []
        watchedPaths = []
        roots = []
        rootIdentities = [:]
        directoryIdentities = [:]
    }

    private func cancelDirectoryWatches() {
        for watch in directoryWatches.values {
            watch.source.cancel()
        }
        directoryWatches.removeAll()
    }

    private func stopStream() {
        let stoppedGeneration = generation
        generation &+= 1
        guard let stream else { return }
        self.stream = nil
        retiringGeneration = stoppedGeneration
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventQueue.sync {}
    }

    private func start() {
        guard retiringGeneration == nil else { return }
        let generation = generation
        let callback = Callback(onEvents: { [weak self] paths, flags in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                receive(paths: paths, flags: flags)
            }
        }, onRelease: { [weak self] in
            Task { @MainActor [weak self] in
                self?.didReleaseStream(generation: generation)
            }
        })
        let context = Self.makeContext(callback)
        guard let candidate = withExtendedLifetime(callback, { createStream(context, roots) }) else {
            retry()
            return
        }
        FSEventStreamSetDispatchQueue(candidate, eventQueue)
        guard startStream(candidate) else {
            retiringGeneration = generation
            FSEventStreamInvalidate(candidate)
            FSEventStreamRelease(candidate)
            eventQueue.sync {}
            retry()
            return
        }
        stream = candidate
        retryTimer?.cancel()
        retryTimer = nil
        onNativeObservationReady?()
    }

    private func didReleaseStream(generation: UInt64) {
        guard retiringGeneration == generation else { return }
        retiringGeneration = nil
        guard !paths.isEmpty, retryTimer == nil else { return }
        sync(paths: paths, recursivePaths: recursivePaths)
        onChange()
    }

    private func retry() {
        guard retryTimer == nil else { return }
        Log.shell.error("Failed to start shell directory observation; retrying with periodic refreshes")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            sync(paths: paths, recursivePaths: recursivePaths)
            onChange()
        }
        retryTimer = timer
        timer.resume()
    }

    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        guard flags.contains(where: { $0 & rescan != 0 }) || paths.contains(where: {
            let path = $0.hasSuffix("/") && $0 != "/" ? String($0.dropLast()) : $0
            return watchedPaths.contains(path) || watchedPaths.contains((path as NSString).deletingLastPathComponent)
        }) else { return }
        sync(paths: self.paths, recursivePaths: recursivePaths)
        onChange()
    }

    private func receiveDirectoryChange() {
        let next = Self.directoryRoots(for: recursivePaths)
        guard next != roots || Self.identities(for: next) != rootIdentities
            || shallowDirectories(roots: next) != directoryIdentities
        else { return }
        sync(paths: paths, recursivePaths: recursivePaths)
        onChange()
    }

    private func shallowDirectories(roots: [String]) -> [String: FileIdentity] {
        guard watchLinks else { return [:] }
        var candidates: Set<String> = []
        for path in recursivePaths {
            candidates.formUnion(SettingsFileObservationDirectories.linkParents(for: path).map(Self.canonicalPath))
        }
        return Self.identities(for: candidates.filter { !Self.contains($0, in: roots) })
    }

    private func makeDirectoryWatch(_ path: String) -> DirectoryWatch? {
        let descriptor = openDirectory(path)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in self?.receiveDirectoryChange() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return DirectoryWatch(
            source: source, identity: FileIdentity(deviceID: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        )
    }

    private static func identities(for paths: some Sequence<String>) -> [String: FileIdentity] {
        var identities: [String: FileIdentity] = [:]
        for path in paths {
            var status = stat()
            guard fstatat(AT_FDCWD, path, &status, 0) == 0, status.st_mode & S_IFMT == S_IFDIR else { continue }
            identities[path] = FileIdentity(deviceID: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        }
        return identities
    }

    private func hasDescriptorBudget(
        for roots: [String], shallowCount: Int, opening: Int, starting: Bool
    ) -> Bool {
        let streamCost = roots.isEmpty ? 0 : roots.reduce(4) { $0 + URL(fileURLWithPath: $1).pathComponents.count }
        guard streamCost + shallowCount <= Self.maximumDescriptorCost else { return false }
        let estimate = opening + (starting ? streamCost : 0)
        guard estimate > 0 else { return true }
        return hasDescriptorReserve(estimate + Self.reservedDescriptorCount)
    }

    private static func hasDescriptorReserve(_ count: Int) -> Bool {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return false }
        var available = 0
        for descriptor in 0 ..< Int32(min(limit.rlim_cur, 1024)) where fcntl(descriptor, F_GETFD) < 0 {
            available += 1
            if available >= count { return true }
        }
        return false
    }

    private static func directoryRoots(for paths: [URL]) -> [String] {
        let directories = Set(paths.compactMap { url -> String? in
            guard let resolved = try? SettingsFileAccess.canonicalURL(for: url) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return nil }
            let directory = isDirectory.boolValue ? resolved : resolved.deletingLastPathComponent()
            return directory.path == "/" ? nil : directory.path
        })
        var roots: [String] = []
        let sorted = directories.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        for directory in sorted
            where !contains(directory, in: roots)
        {
            roots.append(directory)
        }
        return roots
    }

    private static func contains(_ path: String, in roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func canonicalPath(_ url: URL) -> String {
        var ancestor = url
        var missing: [String] = []
        while true {
            if let resolved = try? SettingsFileAccess.canonicalURL(for: ancestor) {
                return missing.reversed().reduce(resolved) { $0.appendingPathComponent($1) }.path
            }
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { return url.path }
            missing.append(ancestor.lastPathComponent)
            ancestor = parent
        }
    }
}

extension ShellDirectoryObservation {
    final class Callback: Sendable {
        let onEvents: @Sendable ([String], [FSEventStreamEventFlags]) -> Task<Void, Never>
        let onRelease: @Sendable () -> Task<Void, Never>

        init(
            onEvents: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Task<Void, Never>,
            onRelease: @escaping @Sendable () -> Task<Void, Never>
        ) {
            self.onEvents = onEvents
            self.onRelease = onRelease
        }
    }

    nonisolated static func makeContext(_ callback: Callback) -> FSEventStreamContext {
        FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { UnsafeRawPointer(Unmanaged<Callback>.fromOpaque($0!).retain().toOpaque()) },
            release: {
                let callback = Unmanaged<Callback>.fromOpaque($0!).takeRetainedValue()
                _ = callback.onRelease()
            },
            copyDescription: nil
        )
    }

    nonisolated static func makeStream(context: FSEventStreamContext, paths: [String]) -> FSEventStreamRef? {
        var context = context
        return FSEventStreamCreate(
            nil,
            { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
                _ = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().onEvents(paths, flags)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot)
        )
    }
}
