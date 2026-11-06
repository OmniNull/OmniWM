// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreServices
import Darwin
import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

private final class ObservationStreams: Sendable {
    private struct State {
        var roots: [[String]] = []
        var callbacks: [ShellDirectoryObservation.Callback] = []
        var streamIDs: [UInt: Int] = [:]
        var releases: [Int: Int] = [:]
        var tasks: [Task<Void, Never>] = []
        var onStart: (@Sendable ([String]) -> Void)?
        var onRelease: (@Sendable (Int) -> Void)?
    }

    private let state = Mutex(State())
    var roots: [[String]] {
        state.withLock { $0.roots }
    }

    var callbacks: [ShellDirectoryObservation.Callback] {
        state.withLock { $0.callbacks }
    }

    var releases: [Int: Int] {
        state.withLock { $0.releases }
    }

    var tasks: [Task<Void, Never>] {
        state.withLock { $0.tasks }
    }

    func started(_ handler: @escaping @Sendable ([String]) -> Void) {
        state.withLock { $0.onStart = handler }
    }

    func released(_ handler: @escaping @Sendable (Int) -> Void) {
        state.withLock { $0.onRelease = handler }
    }

    @MainActor
    func create(_ context: FSEventStreamContext, _ roots: [String]) -> FSEventStreamRef? {
        let id = state.withLock { value in
            XCTAssertEqual(Set(value.releases.keys), Set(value.roots.indices))
            let id = value.roots.count
            value.roots.append(roots)
            return id
        }
        let original = Unmanaged<ShellDirectoryObservation.Callback>.fromOpaque(context.info!).takeUnretainedValue()
        let release = original.onRelease
        let callback = ShellDirectoryObservation.Callback(onEvents: original.onEvents, onRelease: { [weak self] in
            let notification = self?.state.withLock { value in
                value.releases[id, default: 0] += 1
                return value.onRelease
            }
            let task = release()
            self?.state.withLock { $0.tasks.append(task) }
            notification?(id)
            return task
        })
        state.withLock { $0.callbacks.append(callback) }
        let stream = withExtendedLifetime(callback) {
            ShellDirectoryObservation.makeStream(context: ShellDirectoryObservation.makeContext(callback), paths: roots)
        }
        if let stream { state.withLock { $0.streamIDs[UInt(bitPattern: stream)] = id } }
        return stream
    }

    @MainActor
    func start(_ stream: FSEventStreamRef) -> Bool {
        let result = FSEventStreamStart(stream)
        if result {
            let notification = state.withLock { value -> ((@Sendable ([String]) -> Void)?, [String]) in
                let id = value.streamIDs[UInt(bitPattern: stream)]!
                return (value.onStart, value.roots[id])
            }
            notification.0?(notification.1)
        }
        return result
    }
}

extension ShellConfigurationCoordinatorTests {
    private struct ObservationDescriptor: Hashable {
        let device: Int32
        let inode: UInt64
        let path: String
    }

    private func observationDescriptors(under root: URL? = nil) throws -> [ObservationDescriptor] {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { throw POSIXError(.EIO) }
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let count = entries.withUnsafeMutableBytes {
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard count >= 0 else { throw POSIXError(.EIO) }
        return entries.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride).compactMap { entry in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(entry.proc_fd, F_GETPATH, &buffer) == 0 else { return nil }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let root, path != root.path && !path.hasPrefix(root.path + "/") { return nil }
            var status = stat()
            guard fstat(entry.proc_fd, &status) == 0 else { return nil }
            return ObservationDescriptor(device: status.st_dev, inode: status.st_ino, path: path)
        }
    }

    private func observationRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SettingsFileAccess.canonicalURL(for: root)
    }

    func testObservingBundledShellKeepsFileDescriptorsAvailable() async throws {
        let shell = try SettingsFileAccess.canonicalURL(for: fixture())
        defer { try? FileManager.default.removeItem(at: shell) }
        let streams = ObservationStreams()
        let released = expectation(description: "Bundled observation releases its native context")
        streams.released { _ in released.fulfill() }
        var opened: [Int32] = []
        var observation: ShellDirectoryObservation?
        let coordinator = ShellConfigurationCoordinator(shellDirectory: shell)
        coordinator.makeObservation = { onChange in
            let value = ShellDirectoryObservation(
                watchLinks: true, createStream: streams.create, startStream: streams.start,
                openDirectory: { path in
                    let descriptor = open(path, O_EVTONLY)
                    if descriptor >= 0 { opened.append(descriptor) }
                    return descriptor
                },
                onChange: onChange
            )
            observation = value
            return value
        }
        try await coordinator.refresh()
        let inputs = try ShellConfigurationInputs(directory: shell, config: coordinator.config)
        let entries = try XCTUnwrap(FileManager.default.enumerator(
            at: shell, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )).compactMap { $0 as? URL }
        let declaredPaths = Set(entries.map(\.path))
        XCTAssertGreaterThan(declaredPaths.count, ShellDirectoryObservation.maximumDescriptorCost)
        XCTAssertTrue(declaredPaths.isSubset(of: Set(inputs.paths.map(\.path))))
        let before = Dictionary(grouping: try observationDescriptors(), by: \.path).mapValues(\.count)
        let refreshQueued = expectation(description: "Starting observation queues its refresh")
        withObservationTracking { _ = coordinator.isSaving } onChange: { refreshQueued.fulfill() }
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        await fulfillment(of: [refreshQueued], timeout: failureBound)
        await coordinator.flush()
        XCTAssertFalse(coordinator.isSaving)
        XCTAssertTrue(try XCTUnwrap(observation).isUsingNativeObservation)
        XCTAssertEqual(streams.roots, [[shell.path]])
        XCTAssertEqual(try observationDescriptors(under: shell).map(\.path), [shell.path])
        XCTAssertTrue(opened.isEmpty)
        let active = Dictionary(grouping: try observationDescriptors(), by: \.path).mapValues(\.count)
        let watchedPaths = active.keys.filter { active[$0, default: 0] > before[$0, default: 0] }
        XCTAssertFalse(try Data(contentsOf: shell.appendingPathComponent("shell.toml")).isEmpty)
        let height = 45.0
        try await coordinator.set(height, key: "height")
        XCTAssertEqual(try load(shell).barOverride?.settings.height, height)
        XCTAssertNil(coordinator.metadataError)
        coordinator.stopObserving()
        await coordinator.flush()
        await fulfillment(of: [released], timeout: failureBound)
        for task in streams.tasks { await task.value }
        XCTAssertEqual(Set(streams.releases.keys), Set(streams.roots.indices))
        XCTAssertTrue(streams.releases.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(try observationDescriptors(under: shell).map(\.path), [])
        let after = Dictionary(grouping: try observationDescriptors(), by: \.path).mapValues(\.count)
        for path in watchedPaths { XCTAssertLessThanOrEqual(after[path, default: 0], before[path, default: 0], path) }
    }

    func testDirectoryObservationRefreshesAndRetriesWhenStreamCreationFails() async throws {
        let shell = try observationRoot()
        var attempts = 0
        var changes = 0
        var refreshed: XCTestExpectation? = expectation(description: "Periodic refresh after stream creation failure")
        let completion = try XCTUnwrap(refreshed)
        let observation = ShellDirectoryObservation(createStream: { _, _ in
            attempts += 1
            return nil
        }) {
            changes += 1
            refreshed?.fulfill()
            refreshed = nil
        }
        defer { observation.cancel() }
        XCTAssertTrue(try observationDescriptors(under: shell).isEmpty)
        observation.sync(paths: [shell], recursivePaths: [shell])
        let initialAttempts = attempts
        XCTAssertGreaterThan(initialAttempts, 0)
        await fulfillment(of: [completion], timeout: failureBound)
        XCTAssertGreaterThan(attempts, initialAttempts)
        XCTAssertTrue(try observationDescriptors(under: shell).isEmpty)
        let stopped = changes
        let stoppedAttempts = attempts
        try await cancelRetryAndWait(observation)
        XCTAssertEqual(changes, stopped)
        XCTAssertEqual(attempts, stoppedAttempts)
        XCTAssertFalse(observation.isUsingNativeObservation)
        XCTAssertTrue(try observationDescriptors(under: shell).isEmpty)
    }

    func testDirectoryObservationFallsBackBeforeExceedingRootBudget() async throws {
        let root = try observationRoot()
        let directories = try (0 ... ShellDirectoryObservation.maximumDescriptorCost).map { index in
            let directory = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        var attempts = 0
        var changes = 0
        var refreshed: XCTestExpectation? = expectation(description: "Periodic refresh with too many independent roots")
        let fallback = try XCTUnwrap(refreshed)
        let observation = ShellDirectoryObservation(createStream: { _, _ in
            attempts += 1
            return nil
        }) {
            changes += 1
            refreshed?.fulfill()
            refreshed = nil
        }
        defer { observation.cancel() }
        observation.sync(paths: directories, recursivePaths: directories)
        await fulfillment(of: [fallback], timeout: failureBound)
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(try observationDescriptors(under: root).isEmpty)
        let stopped = changes
        try await cancelRetryAndWait(observation)
        XCTAssertEqual(changes, stopped)
        XCTAssertTrue(try observationDescriptors(under: root).isEmpty)
    }

    private func cancelRetryAndWait(_ observation: ShellDirectoryObservation) async throws {
        let timer = try XCTUnwrap(observation.retryTimer)
        let cancelled = expectation(description: "Fallback timer cancellation completes")
        timer.setCancelHandler { cancelled.fulfill() }
        defer { timer.cancel() }
        observation.cancel()
        await fulfillment(of: [cancelled], timeout: failureBound)
        XCTAssertTrue(timer.isCancelled)
    }

    func testDirectoryObservationReplacesAndCancelsRootsWithoutLeakingDescriptors() async throws {
        let root = try observationRoot()
        let directories = ["first", "second"].map { root.appendingPathComponent($0) }
        for directory in directories { try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        ) }
        let first = try XCTUnwrap(directories.first)
        let replacementCount = 32
        let sequence = (0 ..< replacementCount).map { directories[$0 % directories.count] }
        let latest = try XCTUnwrap(sequence.last)
        let streams = ObservationStreams()
        let rearmed = expectation(description: "Latest root starts native observation after retirement")
        streams.started { if $0 == [latest.path] { rearmed.fulfill() } }
        var expectedChange: (URL, Data, XCTestExpectation)?
        let observation = ShellDirectoryObservation(createStream: streams.create, startStream: streams.start) {
            guard let (file, bytes, changed) = expectedChange, (try? Data(contentsOf: file)) == bytes else { return }
            expectedChange = nil
            changed.fulfill()
        }
        defer { observation.cancel() }
        XCTAssertTrue(try observationDescriptors(under: root).isEmpty)
        let before = Dictionary(grouping: try observationDescriptors(), by: \.path).mapValues(\.count)
        observation.sync(paths: [first], recursivePaths: [first])
        XCTAssertTrue(observation.isUsingNativeObservation)
        XCTAssertFalse(try observationDescriptors(under: root).isEmpty)
        let firstChange = expectation(description: "Real native event on the initial root")
        let initialFile = first.appendingPathComponent("initial.luau")
        let initialBytes = Data("initial change".utf8)
        expectedChange = (initialFile, initialBytes, firstChange)
        try initialBytes.write(to: initialFile)
        await fulfillment(of: [firstChange], timeout: failureBound)
        let active = try observationDescriptors(under: root)
        let reference = Dictionary(grouping: try observationDescriptors(), by: \.path).mapValues(\.count)
        let watchedPaths = Set(reference.keys.filter { reference[$0, default: 0] > before[$0, default: 0] })
            .union([latest.path])
        func assertPhysicalBound() throws {
            var counts: [String: Int] = [:]
            for descriptor in try observationDescriptors() where watchedPaths.contains(descriptor.path) {
                let path = descriptor.path == latest.path ? first.path : descriptor.path
                counts[path, default: 0] += 1
            }
            for (path, count) in counts { XCTAssertLessThanOrEqual(count, reference[path, default: 0], path) }
        }

        for directory in sequence { observation.sync(paths: [directory], recursivePaths: [directory]) }
        XCTAssertEqual(streams.roots, [[first.path]])
        XCTAssertFalse(observation.isUsingNativeObservation)
        try assertPhysicalBound()
        let gapChange = expectation(description: "Rearming refreshes changes made during retirement")
        let gapFile = latest.appendingPathComponent("retirement.luau")
        let gapBytes = Data("change during retirement".utf8)
        expectedChange = (gapFile, gapBytes, gapChange)
        try gapBytes.write(to: gapFile)
        await fulfillment(of: [rearmed, gapChange], timeout: failureBound)
        XCTAssertTrue(observation.isUsingNativeObservation)
        XCTAssertEqual(streams.roots, [[first.path], [latest.path]])
        let current = try observationDescriptors(under: root)
        XCTAssertEqual(current.count, active.count)
        try assertPhysicalBound()
        XCTAssertFalse(current.contains { $0.path == first.path })
        let latestChange = expectation(description: "Real native event after retargeting")
        let latestFile = latest.appendingPathComponent("latest.luau")
        let latestBytes = Data("latest change".utf8)
        expectedChange = (latestFile, latestBytes, latestChange)
        try latestBytes.write(to: latestFile)
        await fulfillment(of: [latestChange], timeout: failureBound)

        let finalRelease = expectation(description: "Cancelled native stream releases its context")
        let finalID = try XCTUnwrap(streams.roots.indices.last)
        streams.released { if $0 == finalID { finalRelease.fulfill() } }
        observation.cancel()
        await fulfillment(of: [finalRelease], timeout: failureBound)
        for task in streams.tasks { await task.value }
        XCTAssertEqual(Set(streams.releases.keys), Set(streams.roots.indices))
        XCTAssertTrue(streams.releases.values.allSatisfy { $0 == 1 })
        let after = Dictionary(grouping: try observationDescriptors(), by: \.path).mapValues(\.count)
        for path in watchedPaths { XCTAssertLessThanOrEqual(after[path, default: 0], before[path, default: 0], path) }
        XCTAssertTrue(try observationDescriptors(under: root).isEmpty)
        XCTAssertFalse(observation.isUsingNativeObservation)
    }

    func testDirectoryObservationDropsAwaitedCallbacksAfterCancellation() async throws {
        let root = try observationRoot()
        let streams = ObservationStreams()
        let released = expectation(description: "Cancelled context is released")
        streams.released { _ in released.fulfill() }
        var changes = 0
        let observation = ShellDirectoryObservation(createStream: streams.create, startStream: streams.start) {
            changes += 1
        }
        defer { observation.cancel() }
        observation.sync(paths: [root], recursivePaths: [root])
        XCTAssertTrue(observation.isUsingNativeObservation)
        XCTAssertFalse(try observationDescriptors(under: root).isEmpty)
        let callback = try XCTUnwrap(streams.callbacks.first)
        let events = [([root.path], [UInt32(kFSEventStreamEventFlagMustScanSubDirs)])]
        for (paths, flags) in events { await callback.onEvents(paths, flags).value }
        XCTAssertEqual(changes, events.count)
        let pending = callback.onEvents(events[0].0, events[0].1)
        observation.cancel()
        let late = callback.onEvents(events[0].0, events[0].1)
        await pending.value
        await late.value
        XCTAssertEqual(changes, events.count)
        await fulfillment(of: [released], timeout: failureBound)
        for task in streams.tasks { await task.value }
        XCTAssertEqual(Set(streams.releases.keys), Set(streams.roots.indices))
        XCTAssertTrue(streams.releases.values.allSatisfy { $0 == 1 })
        XCTAssertTrue(try observationDescriptors(under: root).isEmpty)
        XCTAssertFalse(observation.isUsingNativeObservation)
    }
}
